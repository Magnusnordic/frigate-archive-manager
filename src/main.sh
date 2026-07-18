#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")" &&
    pwd
)"

readonly PROJECT_DIR="$(
    cd "$SCRIPT_DIR/.." &&
    pwd
)"

readonly DEFAULT_CONFIG="/etc/frigate-archive/config.conf"

# shellcheck source=src/utils.sh
source "$SCRIPT_DIR/utils.sh"

# shellcheck source=src/logging.sh
source "$SCRIPT_DIR/logging.sh"

load_config() {
    local config_file="${FRIGATE_ARCHIVE_CONFIG:-$DEFAULT_CONFIG}"

    # Under udvikling bruges den eksisterende lokale config som fallback.
    if [[ ! -r "$config_file" ]] &&
       [[ -r "$PROJECT_DIR/config.conf" ]]; then
        config_file="$PROJECT_DIR/config.conf"
    fi

    if [[ ! -r "$config_file" ]]; then
        printf 'ERROR: Konfigurationen blev ikke fundet: %s\n' \
            "$config_file" >&2
        exit 1
    fi

    # shellcheck source=/dev/null
    source "$config_file"

    : "${SOURCE:?SOURCE mangler i konfigurationen}"
    : "${DEST:?DEST mangler i konfigurationen}"

    DEST_MOUNT="${DEST_MOUNT:-$(dirname "$DEST")}"
    LOG_DIR="${LOG_DIR:-$PROJECT_DIR/logs}"
    STATE_DIR="${STATE_DIR:-$PROJECT_DIR/state}"
    TMP_DIR="${TMP_DIR:-$PROJECT_DIR/tmp}"
    LOCKFILE="${LOCKFILE:-/run/frigate-archive.lock}"

    VERIFY_COPY="${VERIFY_COPY:-true}"
    COMPLETE_MARKER="${COMPLETE_MARKER:-.archive_complete}"
    HISTORY_LIMIT="${HISTORY_LIMIT:-365}"
}

validate_environment() {
    require_command bash
    require_command rsync
    require_command find
    require_command flock
    require_command jq
    require_command numfmt

    [[ -d "$SOURCE" ]] || {
        log_error "Kildemappen findes ikke: $SOURCE"
        return 1
    }

    [[ -d "$DEST_MOUNT" ]] || {
        log_error "Destinationens mountpoint findes ikke: $DEST_MOUNT"
        return 1
    }
}

main() {
    load_config

    ensure_directory "$LOG_DIR"
    ensure_directory "$STATE_DIR"
    ensure_directory "$TMP_DIR"

    init_logging

    local version
    version=$(<"$PROJECT_DIR/VERSION")

    log_info "Frigate Archive Manager v$version"
    log_info "V2.0-grundstrukturen er indlæst"
    log_info "Kilde: $SOURCE"
    log_info "Destination: $DEST"

    validate_environment

    log_success "Konfiguration og miljø er godkendt"
    log_info "Der er endnu ikke udført nogen arkivering af v2.0"
}

main "$@"
