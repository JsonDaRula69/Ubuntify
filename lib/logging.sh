#!/bin/bash
#
# lib/logging.sh - Multi-target logging module for Mac Pro 2013 Ubuntu deployment
#
# Provides serial console, file, and webhook logging with configurable levels.
# Runs in dual context: macOS host (deploy) and Ubuntu installer (autoinstall).
#
# Dependencies: lib/colors.sh
#

## Guard

[ "${_LOGGING_SH_SOURCED:-0}" -eq 1 ] && return 0
_LOGGING_SH_SOURCED=1

## Dependencies

source "${LIB_DIR:-./lib}/colors.sh"

## Configuration

readonly LOG_LEVEL_DEBUG=0
readonly LOG_LEVEL_INFO=1
readonly LOG_LEVEL_WARN=2
readonly LOG_LEVEL_ERROR=3
readonly LOG_LEVEL_FATAL=4

readonly LOG_LEVEL_NAMES=("DEBUG" "INFO" "WARN" "ERROR" "FATAL")
readonly LOG_LEVEL_COLORS=("${BLUE}" "${GREEN}" "${YELLOW}" "${RED}" "${RED}")

LOG_LEVEL="${LOG_LEVEL:-${LOG_LEVEL_INFO}}"
LOG_FILE_PATH="${LOG_FILE_PATH:-/tmp/macpro-deploy.log}"
LOG_WEBHOOK_URL="${LOG_WEBHOOK_URL:-}"
LOG_WEBHOOK_QUEUE=()
LOG_WEBHOOK_QUEUE_MAX=10
LOG_SERIAL_FD=""
LOG_SERIAL_DEVICE=""
LOG_LAST_PROGRESS=0
_LOGGING_INIT=0

## Helper Functions

_log_get_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

_log_get_severity_name() {
    local level="$1"
    if [ "$level" -ge 0 ] && [ "$level" -le 4 ]; then
        echo "${LOG_LEVEL_NAMES[$level]}"
    else
        echo "UNKNOWN"
    fi
}

_log_get_severity_color() {
    local level="$1"
    if [ "$level" -ge 0 ] && [ "$level" -le 4 ]; then
        echo "${LOG_LEVEL_COLORS[$level]}"
    else
        echo "${NC}"
    fi
}

_log_level_to_num() {
    local level_name="$1"
    # Bash 3.2 compat: manual case-fold instead of ${var^^}
    case "$(printf '%s' "$level_name" | tr 'a-z' 'A-Z')" in
        DEBUG|0) echo 0 ;;
        INFO|1) echo 1 ;;
        WARN|WARNING|2) echo 2 ;;
        ERROR|3) echo 3 ;;
        FATAL|4) echo 4 ;;
        *) echo 1 ;;
    esac
}

## Core Logging Functions

log_init() {
    local log_dir="${1:-}"
    local webhook_url="${2:-}"

    _LOGGING_INIT=1

    # Determine log directory and file path
    if [ -n "$log_dir" ]; then
        LOG_FILE_PATH="${log_dir}/install.log"
    else
        # Auto-detect platform and set appropriate default
        if [ "$(uname -s)" = "Darwin" ]; then
            LOG_FILE_PATH="${LOG_FILE_PATH:-/tmp/macpro-deploy.log}"
        else
            LOG_FILE_PATH="/var/log/macpro-install/install.log"
        fi
    fi

    # Create log directory if needed
    local log_dir_path
    log_dir_path="$(dirname "$LOG_FILE_PATH")"
    if [ ! -d "$log_dir_path" ]; then
        mkdir -p "$log_dir_path" 2>/dev/null || {
            LOG_FILE_PATH="/tmp/macpro-deploy.log"
        }
    fi

    # Set webhook URL
    LOG_WEBHOOK_URL="$webhook_url"

    # Detect and open serial device
    if [ "$(uname -s)" = "Linux" ]; then
        # Ubuntu installer environment
        for device in /dev/ttyS0 /dev/ttyS1 /dev/ttyS2 /dev/ttyS3; do
            if [ -c "$device" ] && exec 99<>"$device" 2>/dev/null; then
                LOG_SERIAL_DEVICE="$device"
                LOG_SERIAL_FD=99
                break
            fi
        done
    elif [ "$(uname -s)" = "Darwin" ]; then
        : # Serial detection skipped on macOS (blocking open on USB-CDC devices)
    fi

    # Initialize webhook queue
    LOG_WEBHOOK_QUEUE=()
    LOG_LAST_PROGRESS=0

    # Write initialization message
    {
        echo "========================================"
        echo "Mac Pro 2013 Deployment Logging Started"
        echo "Log file: $LOG_FILE_PATH"
        [ -n "$LOG_SERIAL_DEVICE" ] && echo "Serial: $LOG_SERIAL_DEVICE"
        [ -n "$LOG_WEBHOOK_URL" ] && echo "Webhook: $(echo "$LOG_WEBHOOK_URL" | sed 's#://[^@]*@#://****@#; s#\?.*#\?...#')"
        echo "Timestamp: $(_log_get_timestamp)"
        echo "========================================"
    } >> "$LOG_FILE_PATH"

    return 0
}

log_shutdown() {
    # Flush any pending webhook calls
    if [ ${#LOG_WEBHOOK_QUEUE[@]} -gt 0 ]; then
        for payload in "${LOG_WEBHOOK_QUEUE[@]}"; do
            _log_webhook_send "$payload"
        done
        LOG_WEBHOOK_QUEUE=()
    fi

    # Close serial device
    if [ -n "$LOG_SERIAL_FD" ]; then
        eval "exec ${LOG_SERIAL_FD}<&- ${LOG_SERIAL_FD}>&-" 2>/dev/null || true
        LOG_SERIAL_FD=""
        LOG_SERIAL_DEVICE=""
    fi

    _LOGGING_INIT=0
}

_log_should_log() {
    local level="$1"
    [ "$level" -ge "$LOG_LEVEL" ]
}

_log_to_file() {
    local timestamp="$1"
    local severity="$2"
    local message="$3"
    local fallback_path="/tmp/macpro-deploy.log"

    if ! echo "[${timestamp}] [${severity}] ${message}" >> "$LOG_FILE_PATH" 2>/dev/null; then
        # Fallback to /tmp if preferred dir fails
        LOG_FILE_PATH="$fallback_path"
        echo "[${timestamp}] [${severity}] ${message}" >> "$LOG_FILE_PATH" 2>/dev/null || true
    fi
}

_log_to_terminal() {
    local level="$1"
    local message="$2"
    local color="$3"
    local severity_name="$4"

    # Check if stdout is a tty
    if [ -t 1 ]; then
        printf '%b\n' "${color}[${severity_name}]${NC} ${message}"
    else
        echo "[${severity_name}] ${message}"
    fi
}

_log_to_serial() {
    local level="$1"
    local message="$2"
    local timestamp="$3"
    local severity_name

    [ -z "$LOG_SERIAL_FD" ] && return 0

    severity_name="$(_log_get_severity_name "$level")"

    # Write to serial with timeout to avoid blocking
    printf "[%s] [%s] %s\n" "$severity_name" "$timestamp" "$message" >&"$LOG_SERIAL_FD" || true
}

_log_webhook_send() {
    local payload="$1"
    local webhook_url="${LOG_WEBHOOK_URL:-}"

    [ -z "$webhook_url" ] && return 0

    # Non-blocking curl with 2-second timeout
    {
        curl -s -X POST \
            -H "Content-Type: application/json" \
            -d "$payload" \
            --max-time 2 \
            --connect-timeout 2 \
            "$webhook_url" 2>/dev/null
    } &
    local curl_pid=$!

    # Don't wait for curl - fire and forget with background process
    # The timeout ensures it won't hang forever
    ( sleep 3 2>/dev/null; kill "$curl_pid" 2>/dev/null; wait "$curl_pid" 2>/dev/null; ) &
}

_log_queue_webhook() {
    local payload="$1"

    [ -z "$LOG_WEBHOOK_URL" ] && return 0

    # Add to queue
    LOG_WEBHOOK_QUEUE+=("$payload")

    # Drop oldest if queue full
    while [ ${#LOG_WEBHOOK_QUEUE[@]} -gt $LOG_WEBHOOK_QUEUE_MAX ]; do
        LOG_WEBHOOK_QUEUE=("${LOG_WEBHOOK_QUEUE[@]:1}")
    done

    # Try to send immediately in background
    _log_webhook_send "$payload" &
}

_log_internal() {
    local level="$1"
    local message="$2"
    local timestamp severity_name color

    _log_should_log "$level" || return 0

    timestamp="$(_log_get_timestamp)"
    severity_name="$(_log_get_severity_name "$level")"
    color="$(_log_get_severity_color "$level")"

    # Always log to file
    _log_to_file "$timestamp" "$severity_name" "$message"

    # Log to terminal if appropriate level
    _log_to_terminal "$level" "$message" "$color" "$severity_name"

    # Log to serial
    _log_to_serial "$level" "$message" "$timestamp"
}

## Public Logging Functions

log_debug() {
    _log_internal "$LOG_LEVEL_DEBUG" "$1"
}

log_info() {
    _log_internal "$LOG_LEVEL_INFO" "$1"
}

log_warn() {
    _log_internal "$LOG_LEVEL_WARN" "$1"
}

log_error() {
    _log_internal "$LOG_LEVEL_ERROR" "$1"
}

log_fatal() {
    local message="$1"
    _log_internal "$LOG_LEVEL_FATAL" "$message"

    # Send fatal webhook notification before exit
    if [ -n "$LOG_WEBHOOK_URL" ]; then
        local escaped_message
        escaped_message="$(printf '%s' "$message" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\n/\\n/g')"
        local payload
        payload="{\"progress\": 0, \"stage\": \"error\", \"status\": \"fatal\", \"message\": \"$escaped_message\"}"
        _log_webhook_send "$payload"
    fi

    exit 1
}

log_serial() {
    local message="$1"
    local timestamp severity_name

    [ -z "$LOG_SERIAL_FD" ] && return 0

    timestamp="$(_log_get_timestamp)"
    severity_name="$(_log_get_severity_name "$LOG_LEVEL_INFO")"

    # Write only to serial, not file or webhook
    printf "[%s] [%s] %s\n" "$severity_name" "$timestamp" "$message" >&"$LOG_SERIAL_FD" || true
}

log_progress() {
    local percent="$1"
    local stage="$2"
    local status="$3"
    local message="$4"
    local payload

    # Enforce monotonically increasing progress
    if [ "$percent" -lt "$LOG_LAST_PROGRESS" ]; then
        percent=$((LOG_LAST_PROGRESS + 1))
    fi
    LOG_LAST_PROGRESS="$percent"

    # Clamp to 0-100
    [ "$percent" -lt 0 ] && percent=0
    [ "$percent" -gt 100 ] && percent=100

    # Escape special characters in message for JSON
    local escaped_message
    escaped_message="$(printf '%s' "$message" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\n/\\n/g')"

    # Build JSON payload
    payload="{\"progress\": $percent, \"stage\": \"$stage\", \"status\": \"$status\", \"message\": \"$escaped_message\"}"

    # Queue webhook call
    _log_queue_webhook "$payload"

    # Also log to file and terminal
    _log_internal "$LOG_LEVEL_INFO" "Progress [$percent%] $stage: $status - $message"
}

## Backward Compatibility Aliases

log()   { log_info "$1"; }
warn()  { log_warn "$1"; }
error() { log_error "$1"; }
die()   { log_fatal "$1"; }
vlog()  { log_debug "$1"; }

## Utility Functions

log_set_level() {
    local level_name="$1"
    LOG_LEVEL="$(_log_level_to_num "$level_name")"
}

log_get_level_name() {
    _log_get_severity_name "$LOG_LEVEL"
}

log_get_file_path() {
    echo "$LOG_FILE_PATH"
}

log_is_initialized() {
    [ "$_LOGGING_INIT" -eq 1 ]
}

log_is_serial_available() {
    [ -n "$LOG_SERIAL_DEVICE" ]
}

log_is_webhook_configured() {
    [ -n "$LOG_WEBHOOK_URL" ]
}

log_get_serial_device() {
    echo "$LOG_SERIAL_DEVICE"
}

log_get_webhook_url() {
    echo "$LOG_WEBHOOK_URL"
}

log_get_last_progress() {
    echo "$LOG_LAST_PROGRESS"
}

## Export functions for sourcing

if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ]; then
    export -f log_init log_shutdown 2>/dev/null || true
    export -f log_debug log_info log_warn log_error log_fatal 2>/dev/null || true
    export -f log_serial log_progress 2>/dev/null || true
    export -f log warn error die vlog 2>/dev/null || true
    export -f log_set_level log_get_level_name log_get_file_path 2>/dev/null || true
    export -f log_is_initialized log_is_serial_available log_is_webhook_configured 2>/dev/null || true
    export -f log_get_serial_device log_get_webhook_url log_get_last_progress 2>/dev/null || true
fi
