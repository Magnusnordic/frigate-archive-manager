#!/usr/bin/env bash

LOGFILE=""

init_logging() {
    ensure_directory "$LOG_DIR"
    LOGFILE="$LOG_DIR/archive.log"
}

log_message() {
    local level="$1"
    shift

    local message="$*"
    local timestamp

    timestamp=$(date '+%F %T')

    printf '[%s] [%s] %s\n' \
        "$timestamp" \
        "$level" \
        "$message" | tee -a "$LOGFILE"
}

log_info() {
    log_message "INFO" "$@"
}

log_warning() {
    log_message "WARNING" "$@"
}

log_error() {
    log_message "ERROR" "$@"
}

log_success() {
    log_message "SUCCESS" "$@"
}
