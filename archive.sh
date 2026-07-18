#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================================
# Frigate Archive Manager v1.3
#
# Funktioner:
# - flock-lås
# - kopierer kun afsluttede datoer
# - verificerer kopien
# - springer allerede færdige dage over
# - statistik over filer og størrelse
# - state.json til Home Assistant
# - history.json med kørsler
# ==========================================================

VERSION="1.3"
CONFIG_FILE="/opt/frigate-archive/config.conf"
DEST_MOUNT="/mnt/truenas/frigate_archive"

# ----------------------------------------------------------
# Konfiguration
# ----------------------------------------------------------

if [[ ! -r "$CONFIG_FILE" ]]; then
    echo "Kan ikke læse $CONFIG_FILE" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

: "${SOURCE:?SOURCE mangler i config.conf}"
: "${DEST:?DEST mangler i config.conf}"
: "${LOGFILE:?LOGFILE mangler i config.conf}"
: "${STATEFILE:?STATEFILE mangler i config.conf}"
: "${HISTORYFILE:?HISTORYFILE mangler i config.conf}"

LOCKFILE="${LOCKFILE:-/run/frigate-archive.lock}"
VERIFY_COPY="${VERIFY_COPY:-true}"
COMPLETE_MARKER="${COMPLETE_MARKER:-.archive_complete}"

mkdir -p "$(dirname "$LOGFILE")"
mkdir -p "$(dirname "$STATEFILE")"
mkdir -p "$(dirname "$HISTORYFILE")"
mkdir -p /opt/frigate-archive/tmp

[[ -f "$HISTORYFILE" ]] || printf '[]\n' > "$HISTORYFILE"

# ----------------------------------------------------------
# Lås
# ----------------------------------------------------------

exec 9>"$LOCKFILE"

if ! flock -n 9; then
    printf '[%s] En arkivering kører allerede.\n' \
        "$(date '+%F %T')" | tee -a "$LOGFILE"
    exit 0
fi

# ----------------------------------------------------------
# Statusvariabler
# ----------------------------------------------------------

START_EPOCH=$(date +%s)
TODAY=$(date +%F)

STATUS="running"
ERROR_MESSAGE=""
CURRENT_DAY=""
LAST_ARCHIVED_DAY=""

ARCHIVED_DAYS=0
SKIPPED_DAYS=0
TOTAL_FILES=0
TOTAL_BYTES=0

# ----------------------------------------------------------
# Funktioner
# ----------------------------------------------------------

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOGFILE"
}

json_escape() {
    local value="${1:-}"

    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}

    printf '%s' "$value"
}

human_size() {
    local bytes="${1:-0}"

    numfmt \
        --to=iec-i \
        --suffix=B \
        --format="%.2f" \
        "$bytes"
}

write_state() {
    local end_epoch duration total_size temp_state

    end_epoch=$(date +%s)
    duration=$((end_epoch - START_EPOCH))
    total_size=$(human_size "$TOTAL_BYTES")
    temp_state="${STATEFILE}.tmp"

    cat > "$temp_state" <<EOF
{
  "version": "$(json_escape "$VERSION")",
  "status": "$(json_escape "$STATUS")",
  "last_run": "$(date --iso-8601=seconds)",
  "last_archived_day": "$(json_escape "$LAST_ARCHIVED_DAY")",
  "current_day": "$(json_escape "$CURRENT_DAY")",
  "archived_days": $ARCHIVED_DAYS,
  "skipped_days": $SKIPPED_DAYS,
  "files": $TOTAL_FILES,
  "bytes": $TOTAL_BYTES,
  "size": "$(json_escape "$total_size")",
  "duration_seconds": $duration,
  "error": "$(json_escape "$ERROR_MESSAGE")"
}
EOF

    mv "$temp_state" "$STATEFILE"
}

append_history() {
    local end_epoch duration total_size temp_history

    end_epoch=$(date +%s)
    duration=$((end_epoch - START_EPOCH))
    total_size=$(human_size "$TOTAL_BYTES")
    temp_history="${HISTORYFILE}.tmp"

    jq \
        --arg timestamp "$(date --iso-8601=seconds)" \
        --arg status "$STATUS" \
        --arg last_day "$LAST_ARCHIVED_DAY" \
        --arg size "$total_size" \
        --arg error "$ERROR_MESSAGE" \
        --argjson archived_days "$ARCHIVED_DAYS" \
        --argjson skipped_days "$SKIPPED_DAYS" \
        --argjson files "$TOTAL_FILES" \
        --argjson bytes "$TOTAL_BYTES" \
        --argjson duration "$duration" \
        '. + [{
          timestamp: $timestamp,
          status: $status,
          last_archived_day: $last_day,
          archived_days: $archived_days,
          skipped_days: $skipped_days,
          files: $files,
          bytes: $bytes,
          size: $size,
          duration_seconds: $duration,
          error: $error
        }] | if length > 365 then .[-365:] else . end' \
        "$HISTORYFILE" > "$temp_history"

    mv "$temp_history" "$HISTORYFILE"
}

finish_failed() {
    ERROR_MESSAGE="$1"
    STATUS="failed"

    log "ERROR: $ERROR_MESSAGE"

    write_state
    append_history

    exit 1
}

unexpected_error() {
    local exit_code=$?
    local line_number=$1

    trap - ERR

    if [[ "$STATUS" != "failed" ]]; then
        STATUS="failed"
        ERROR_MESSAGE="Uventet fejl på linje $line_number, kode $exit_code"

        log "ERROR: $ERROR_MESSAGE"
        write_state
        append_history
    fi

    exit "$exit_code"
}

trap 'unexpected_error $LINENO' ERR

verify_day() {
    local source_day="$1"
    local destination_day="$2"
    local verify_file

    verify_file=$(mktemp /opt/frigate-archive/tmp/verify.XXXXXX)

    if ! rsync -rtni \
        --size-only \
        --no-owner \
        --no-group \
        --no-perms \
        --exclude="$COMPLETE_MARKER" \
        "$source_day/" \
        "$destination_day/" > "$verify_file"; then

        rm -f "$verify_file"
        return 1
    fi

    if [[ -s "$verify_file" ]]; then
        log "Verificeringen fandt afvigelser:"
        cat "$verify_file" | tee -a "$LOGFILE"
        rm -f "$verify_file"
        return 1
    fi

    rm -f "$verify_file"
    return 0
}

# ----------------------------------------------------------
# Kontrol
# ----------------------------------------------------------

log "=================================================="
log "Frigate Archive Manager v$VERSION"
log "Starter arkivering"

[[ -d "$SOURCE" ]] ||
    finish_failed "Kildemappen findes ikke: $SOURCE"

mountpoint -q "$DEST_MOUNT" ||
    finish_failed "TrueNAS er ikke monteret på $DEST_MOUNT"

WRITE_TEST="$DEST_MOUNT/.frigate-archive-write-test"

touch "$WRITE_TEST" ||
    finish_failed "TrueNAS-mountet er ikke skrivbart"

rm -f "$WRITE_TEST"

command -v rsync >/dev/null ||
    finish_failed "rsync er ikke installeret"

command -v jq >/dev/null ||
    finish_failed "jq er ikke installeret"

command -v numfmt >/dev/null ||
    finish_failed "numfmt er ikke installeret"

mkdir -p "$DEST"

# ----------------------------------------------------------
# Arkivering
# ----------------------------------------------------------

shopt -s nullglob

for DAY_PATH in "$SOURCE"/*; do
    [[ -d "$DAY_PATH" ]] || continue

    DAY_NAME=$(basename "$DAY_PATH")

    if [[ ! "$DAY_NAME" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        log "Springer ukendt mappe over: $DAY_NAME"
        continue
    fi

    if [[ "$DAY_NAME" == "$TODAY" ]]; then
        log "Springer dagens aktive mappe over: $DAY_NAME"
        continue
    fi

    CURRENT_DAY="$DAY_NAME"
    DESTINATION_DAY="$DEST/$DAY_NAME"
    MARKER_PATH="$DESTINATION_DAY/$COMPLETE_MARKER"

    if [[ -f "$MARKER_PATH" ]]; then
        log "Allerede færdig: $DAY_NAME"
        SKIPPED_DAYS=$((SKIPPED_DAYS + 1))
        continue
    fi

    DAY_FILES=$(find "$DAY_PATH" -type f -printf '.' | wc -c)
    DAY_BYTES=$(find "$DAY_PATH" -type f -printf '%s\n' |
        awk '{sum += $1} END {print sum + 0}')

    log "Arkiverer dato: $DAY_NAME"
    log "Filer: $DAY_FILES"
    log "Størrelse: $(human_size "$DAY_BYTES")"

    mkdir -p "$DESTINATION_DAY"

    if ! rsync -rt \
        --ignore-existing \
        --partial \
        --no-owner \
        --no-group \
        --no-perms \
        "$DAY_PATH/" \
        "$DESTINATION_DAY/"; then

        finish_failed "rsync fejlede for $DAY_NAME"
    fi

    if [[ "$VERIFY_COPY" == "true" ]]; then
        log "Verificerer: $DAY_NAME"

        if ! verify_day "$DAY_PATH" "$DESTINATION_DAY"; then
            finish_failed "Verificering fejlede for $DAY_NAME"
        fi
    fi

    cat > "$MARKER_PATH" <<EOF
version=$VERSION
archived_at=$(date --iso-8601=seconds)
source_files=$DAY_FILES
source_bytes=$DAY_BYTES
EOF

    TOTAL_FILES=$((TOTAL_FILES + DAY_FILES))
    TOTAL_BYTES=$((TOTAL_BYTES + DAY_BYTES))
    ARCHIVED_DAYS=$((ARCHIVED_DAYS + 1))
    LAST_ARCHIVED_DAY="$DAY_NAME"

    log "Færdig og verificeret: $DAY_NAME"
done

# ----------------------------------------------------------
# Færdig
# ----------------------------------------------------------

CURRENT_DAY=""
STATUS="success"
ERROR_MESSAGE=""

write_state
append_history

DURATION=$(($(date +%s) - START_EPOCH))

log "Arkivering færdig"
log "Nye datoer: $ARCHIVED_DAYS"
log "Sprunget over: $SKIPPED_DAYS"
log "Nye filer: $TOTAL_FILES"
log "Ny datamængde: $(human_size "$TOTAL_BYTES")"
log "Køretid: $DURATION sekunder"
log "Status: SUCCESS"
log "=================================================="
