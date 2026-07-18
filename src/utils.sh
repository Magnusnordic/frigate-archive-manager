#!/usr/bin/env bash

require_command() {
    local command_name="$1"

    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf 'ERROR: Kommandoen "%s" er ikke installeret.\n' \
            "$command_name" >&2
        return 1
    fi
}

ensure_directory() {
    local directory="$1"

    if [[ ! -d "$directory" ]]; then
        mkdir -p "$directory"
    fi
}

is_true() {
    case "${1,,}" in
        true|yes|1|on)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

human_size() {
    local bytes="${1:-0}"

    numfmt \
        --to=iec-i \
        --suffix=B \
        --format='%.2f' \
        "$bytes"
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
