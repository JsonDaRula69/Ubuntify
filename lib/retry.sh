#!/bin/bash
# shellcheck shell=bash
[ "${_RETRY_SH_SOURCED:-0}" -eq 1 ] && return 0; _RETRY_SH_SOURCED=1

source "${LIB_DIR:-./lib}/logging.sh"

readonly RETRY_MAX_ATTEMPTS=3
readonly RETRY_BASE_DELAY=1
readonly RETRY_MAX_DELAY=16

is_transient_error() {
    local code="${1:-0}"
    case "$code" in
        1|124|255|28|75) return 0 ;;
        2|126|127|130|0) return 1 ;;
        *) return 1 ;;
    esac
}

retry_ssh() {
    local host="${1:-}"
    shift || true

    if [ -z "$host" ]; then
        error "retry_ssh: no host specified"
        return 1
    fi

    local max_attempts=5
    local base_delay=5
    local attempt=1
    local delay="$base_delay"
    local exit_code=0
    local stderr_file
    stderr_file="$(mktemp)"

    while [ "$attempt" -le "$max_attempts" ]; do
        if [ "$attempt" -gt 1 ]; then
            warn "SSH attempt $attempt/$max_attempts to $host"
        fi

        ssh $_REMOTE_MAC_SSH_OPTS "$host" "$@" 2>"$stderr_file" && exit_code=0 || exit_code=$?

        if [ "$exit_code" -eq 0 ]; then
            rm -f "$stderr_file"
            return 0
        fi

        if grep -q "REMOTE HOST IDENTIFICATION HAS CHANGED" "$stderr_file" 2>/dev/null; then
            warn "SSH: host key verification failed - manual intervention required"
            rm -f "$stderr_file"
            return 255
        fi

        if grep -q "Connection refused" "$stderr_file" 2>/dev/null; then
            warn "SSH: connection refused (server may be rebooting)"
        elif grep -q "Connection timed out" "$stderr_file" 2>/dev/null; then
            warn "SSH: connection timed out"
        elif grep -q "broken pipe" "$stderr_file" 2>/dev/null; then
            warn "SSH: broken pipe"
        fi

        if [ "$attempt" -lt "$max_attempts" ]; then
            sleep "$delay"
            delay=$((delay * 2))
            if [ "$delay" -gt "${RETRY_MAX_DELAY}" ]; then
                delay="${RETRY_MAX_DELAY}"
            fi
        fi

        attempt=$((attempt + 1))
    done

    rm -f "$stderr_file"
    return "$exit_code"
}

retry_xorriso() {
    local max_attempts=3
    local base_delay=2
    local attempt=1
    local delay="$base_delay"
    local exit_code=0
    local stderr_file
    stderr_file="$(mktemp)"
    local out_dir=""

    while [ $# -gt 0 ]; do
        case "$1" in
            -extract*|extract)
                if [ "$1" = "-extract" ] || [ "$1" = "-extract_to" ]; then
                    shift
                    out_dir="$1"
                    shift
                elif [ "$1" = "extract" ]; then
                    shift
                    shift
                    out_dir="$1"
                    shift
                fi
                ;;
            *)
                break
                ;;
        esac
    done

    while [ "$attempt" -le "$max_attempts" ]; do
        if [ "$attempt" -gt 1 ]; then
            warn "xorriso attempt $attempt/$max_attempts"
        fi

        xorriso "$@" 2>"$stderr_file" && exit_code=0 || exit_code=$?

        if [ "$exit_code" -eq 0 ]; then
            rm -f "$stderr_file"
            return 0
        fi

        if grep -iq "I/O error\|read error\|medium error" "$stderr_file" 2>/dev/null; then
            warn "xorriso: media I/O error detected"

            if [ -n "$out_dir" ] && [ -d "$out_dir" ]; then
                warn "xorriso: cleaning partial output directory: $out_dir"
                rm -rf "${out_dir:?}"/*
            fi

            if [ "$attempt" -lt "$max_attempts" ]; then
                sleep "$delay"
                delay=$((delay * 2))
                if [ "$delay" -gt "${RETRY_MAX_DELAY}" ]; then
                    delay="${RETRY_MAX_DELAY}"
                fi
            fi
        elif ! is_transient_error "$exit_code"; then
            rm -f "$stderr_file"
            return "$exit_code"
        elif [ "$attempt" -lt "$max_attempts" ]; then
            sleep "$delay"
            delay=$((delay * 2))
            if [ "$delay" -gt "${RETRY_MAX_DELAY}" ]; then
                delay="${RETRY_MAX_DELAY}"
            fi
        fi

        attempt=$((attempt + 1))
    done

    rm -f "$stderr_file"
    return "$exit_code"
}
