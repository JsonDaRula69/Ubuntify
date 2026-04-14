#!/bin/bash
#
# lib/dryrun.sh - Dry-run execution wrapper and agent mode output
#
# Provides:
#   dry_run_exec  - Execute command or print what would run (DRY_RUN=1)
#   is_dry_run    - Test if dry-run mode is active
#   agent_output  - Emit structured output for LLM agent consumers
#   agent_error   - Emit structured error for LLM agent consumers
#   escape_json   - Escape string for safe JSON embedding
#
# Exit code constants (sourced by all scripts):
#   E_SUCCESS, E_GENERAL, E_USAGE, E_CONFIG, E_CHECK,
#   E_PARTIAL, E_DEPENDENCY, E_NETWORK, E_DISK, E_TIMEOUT,
#   E_AUTH, E_DRY_RUN_OK, E_AGENT_PARAM, E_AGENT_DENIED
#
# Bash 3.2 compatible.
#

[ "${_DRYRUN_SH_SOURCED:-0}" -eq 1 ] && return 0
_DRYRUN_SH_SOURCED=1

source "${LIB_DIR:-./lib}/colors.sh"

## ── Exit Code Constants ──

readonly E_SUCCESS=0
readonly E_GENERAL=1        # General error
readonly E_USAGE=2           # Invalid usage / missing arguments
readonly E_CONFIG=3          # Configuration error
readonly E_CHECK=4           # Pre-flight check failed
readonly E_PARTIAL=5         # Partial success (some steps failed)
readonly E_DEPENDENCY=6      # Missing dependency
readonly E_NETWORK=7         # Network error
readonly E_DISK=8            # Disk/partition operation error
readonly E_TIMEOUT=9         # Timeout
readonly E_AUTH=10           # Authentication error
readonly E_DRY_RUN_OK=11     # Dry-run completed (no changes made)
readonly E_AGENT_PARAM=12    # Agent mode: missing required parameter
readonly E_AGENT_DENIED=13   # Agent mode: confirmation denied

## ── Dry-Run Helpers ──

is_dry_run() {
    [ "${DRY_RUN:-0}" -eq 1 ]
}

# dry_run_exec "description" command [args...]
#   In DRY_RUN=1: prints description + full command, returns 0
#   In DRY_RUN=0: executes command, returns its exit code
#
# Example:
#   dry_run_exec "Shrinking APFS to ${TARGET}GB" \
#       diskutil apfs resizeContainer "$APFS_CONTAINER" "${TARGET}g" || return 1
#
dry_run_exec() {
    local description="$1"
    shift

    if is_dry_run; then
        local cmd_str
        cmd_str=$(printf '%q ' "$@")
        printf "${YELLOW}[DRY-RUN] %s${NC}\n" "$description"
        printf "${YELLOW}[DRY-RUN]   Command: %s${NC}\n" "$cmd_str"
        return 0
    fi

    "$@"
}

# dry_run_callback "description" callback_function [args...]
#   For operations that need custom logic in dry-run mode
#   (e.g., setting state variables without executing)
#   In DRY_RUN=1: prints description, calls callback, returns 0
#   In DRY_RUN=0: skips callback, executes real command after
#
dry_run_callback() {
    local description="$1"
    local callback="$2"
    shift 2

    if is_dry_run; then
        printf "${YELLOW}[DRY-RUN] %s${NC}\n" "$description"
        "$callback" "$@" 2>/dev/null || true
        return 0
    fi

    return 1  # Signal: not in dry-run, caller should execute real command
}

## ── JSON / Agent Mode Helpers ──

# Escape a string for safe JSON embedding
# Handles: backslash, double-quote, tab, newline (escaped as \n literal)
escape_json() {
    local input="${1:-}"
    printf '%s' "$input" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' | tr '\n' '|' | sed 's/|/\\n/g'
}

# agent_output TYPE TITLE VALUE [EXTRA_KEY EXTRA_VALUE ...]
#   Outputs structured data for LLM agent consumers.
#   In JSON_OUTPUT=1: emits JSON line
#   Otherwise: logs to stderr with [AGENT] prefix
#
# TYPE is one of: confirm, menu, msgbox, input, password, settings,
#                 progress, result, error
#
agent_output() {
    local type="$1"
    local title="$2"
    local value="$3"
    shift 3

    if [ "${JSON_OUTPUT:-0}" -eq 1 ]; then
        local extra=""
        while [ $# -ge 2 ]; do
            local k="$1" v="$2"
            shift 2
            extra="${extra},\"$(escape_json "$k")\":\"$(escape_json "$v")\""
        done
        printf '{"type":"%s","title":"%s","value":"%s"%s}\n' \
            "$(escape_json "$type")" \
            "$(escape_json "$title")" \
            "$(escape_json "$value")" \
            "$extra"
    else
        if command -v log_info >/dev/null 2>&1; then
            log_info "[AGENT] $type: $title → $value"
        else
            echo "[AGENT] $type: $title → $value" >&2
        fi
    fi
}

# agent_error MESSAGE [CODE]
#   Emit a structured error and exit with CODE (default: E_AGENT_PARAM)
agent_error() {
    local message="$1"
    local code="${2:-$E_AGENT_PARAM}"
    agent_output "error" "Error" "$message" "exitCode" "$code"
    exit "$code"
}

## ── Agent Confirmation Helper ──

# agent_confirm TITLE MESSAGE
#   In AGENT_MODE with CONFIRM_YES=1: auto-approve, return 0
#   In AGENT_MODE without CONFIRM_YES: auto-deny, return 1
#   Not in AGENT_MODE: fall through (caller should use tui_confirm)
#
# Returns 0 if confirmed, 1 if denied.
agent_confirm() {
    local title="$1"
    local message="$2"

    if [ "${AGENT_MODE:-0}" -eq 1 ]; then
        if [ "${CONFIRM_YES:-0}" -eq 1 ]; then
            agent_output "confirm" "$title" "yes"
            return 0
        else
            agent_output "confirm" "$title" "no"
            return 1
        fi
    fi

    return 2  # Not in agent mode — caller should use TUI
}