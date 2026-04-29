#!/bin/bash
# lib/remote_mac.sh — Remote execution wrapper for macOS-side commands
# Routes commands to the remote Mac Pro via SSH.
set -e
set -o pipefail

[ "${_REMOTE_MAC_SH_SOURCED:-0}" -eq 1 ] && return 0
_REMOTE_MAC_SH_SOURCED=1

# ── SSH Options ──
_REMOTE_MAC_SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o BatchMode=yes -o StrictHostKeyChecking=no"
_REMOTE_CMD_TIMEOUT="${REMOTE_CMD_TIMEOUT:-300}"

_ssh_with_timeout() {
    local _timeout="${1:-$_REMOTE_CMD_TIMEOUT}"; shift
    local _outf="/tmp/_ssh_out_$$_${RANDOM}"
    local _errf="/tmp/_ssh_err_$$_${RANDOM}"
    ssh $_REMOTE_MAC_SSH_OPTS "$@" >"$_outf" 2>"$_errf" &
    local _pid=$!
    local _elapsed=0
    while [ "$_elapsed" -lt "$_timeout" ]; do
        if ! kill -0 "$_pid" 2>/dev/null; then break; fi
        sleep 1; _elapsed=$((_elapsed + 1))
    done
    local _rc=0
    if kill -0 "$_pid" 2>/dev/null; then
        kill "$_pid" 2>/dev/null; wait "$_pid" 2>/dev/null; _rc=124
        log_debug "SSH timed out after ${_timeout}s: $*"
    else
        wait "$_pid" 2>/dev/null; _rc=$?
    fi
    cat "$_outf" 2>/dev/null; rm -f "$_outf" 2>/dev/null
    [ -s "$_errf" ] && log_debug "ssh stderr: $(cat "$_errf")"
    rm -f "$_errf" 2>/dev/null
    return $_rc
}

# Non-interactive SSH doesn't include /usr/local/bin or /opt/homebrew/bin in PATH.
# This prefix ensures brew and brew-installed tools are findable on every remote command.
_REMOTE_MAC_PATH_PREFIX='export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"'

# ── Core Execution Wrapper ──

# Runs a command on the remote Mac Pro via SSH.
# Two calling patterns:
#   1. Multi-arg simple command:  remote_mac_exec diskutil list "$DISK"
#      — each arg escaped individually for safe SSH transport
#   2. Single-string pipeline:   remote_mac_exec "csrutil status 2>/dev/null | grep ..."
#      — passed verbatim to remote shell (pipe/redirect operators preserved)
remote_mac_exec() {
    local _timeout="$_REMOTE_CMD_TIMEOUT"
    if [ "${1:-}" = "--timeout" ]; then
        _timeout="$2"; shift 2
    fi
    local _ssh_args=()
    if [ $# -eq 1 ]; then
        _ssh_args=("${TARGET_HOST:-macpro}" "${_REMOTE_MAC_PATH_PREFIX}; $1")
    else
        local cmd
        cmd=$(printf '%q ' "$@")
        _ssh_args=("${TARGET_HOST:-macpro}" "${_REMOTE_MAC_PATH_PREFIX}; $cmd")
    fi
    _ssh_with_timeout "$_timeout" "${_ssh_args[@]}"
}

# ── Remote Command with sudo ──
# Runs a command with sudo on the remote host via SSH.
# Uses the stored REMOTE_SUDO_PASSWORD if available, otherwise passwordless sudo.
# Same dual-pattern as remote_mac_exec: single-string or multi-arg.
remote_mac_sudo() {
    local _timeout="$_REMOTE_CMD_TIMEOUT"
    if [ "${1:-}" = "--timeout" ]; then
        _timeout="$2"; shift 2
    fi
    local _raw_cmd
    if [ $# -eq 1 ]; then
        _raw_cmd="$1"
    else
        _raw_cmd=$(printf '%q ' "$@")
    fi
    if [ -n "${REMOTE_SUDO_PASSWORD:-}" ]; then
        local _pwf="/tmp/_ssh_pw_$$_${RANDOM}"
        local _outf="/tmp/_ssh_out_$$_${RANDOM}"
        local _errf="/tmp/_ssh_err_$$_${RANDOM}"
        printf '%s\n' "$REMOTE_SUDO_PASSWORD" > "$_pwf"
        ssh $_REMOTE_MAC_SSH_OPTS "${TARGET_HOST:-macpro}" \
            "${_REMOTE_MAC_PATH_PREFIX}; sudo -S -p '' env PATH=\"\$PATH\" $_raw_cmd" \
            <"$_pwf" >"$_outf" 2>"$_errf" &
        local _pid=$!
        local _elapsed=0
        while [ "$_elapsed" -lt "$_timeout" ]; do
            if ! kill -0 "$_pid" 2>/dev/null; then break; fi
            sleep 1; _elapsed=$((_elapsed + 1))
        done
        local _rc=0
        if kill -0 "$_pid" 2>/dev/null; then
            kill "$_pid" 2>/dev/null; wait "$_pid" 2>/dev/null; _rc=124
        else
            wait "$_pid" 2>/dev/null; _rc=$?
        fi
        cat "$_outf" 2>/dev/null; rm -f "$_outf" "$_pwf" 2>/dev/null
        [ -s "$_errf" ] && log_debug "ssh stderr: $(cat "$_errf")"
        rm -f "$_errf" 2>/dev/null
        return $_rc
    else
        _ssh_with_timeout "$_timeout" "${TARGET_HOST:-macpro}" \
            "${_REMOTE_MAC_PATH_PREFIX}; sudo -n env PATH=\"\$PATH\" $_raw_cmd"
    fi
}

# ── Remote diskutil with retry ──
# Wraps remote_mac_sudo diskutil with exponential backoff for transient errors.
# "Resource busy" and IOKit errors are retried up to max_attempts times.
remote_mac_retry_diskutil() {
    local max_attempts=5
    local base_delay=2
    local attempt=1
    local delay="$base_delay"
    local exit_code=0
    local stderr_file
    stderr_file="$(mktemp)"

    while [ "$attempt" -le "$max_attempts" ]; do
        if [ "$attempt" -gt 1 ]; then
            warn "remote diskutil attempt $attempt/$max_attempts"
        fi

        remote_mac_sudo diskutil "$@" 2>"$stderr_file" && exit_code=0 || exit_code=$?

        if [ "$exit_code" -eq 0 ]; then
            rm -f "$stderr_file"
            return 0
        fi

        local stderr_content
        stderr_content="$(cat "$stderr_file" 2>/dev/null || true)"

        if echo "$stderr_content" | grep -q "Resource busy\|busy" 2>/dev/null; then
            warn "remote diskutil: resource busy, retrying"
            remote_mac_sudo diskutil unmount "$@" 2>/dev/null || true
            sleep 3
            attempt=$((attempt + 1))
            continue
        fi

        if echo "$stderr_content" | grep -q "IOKit\|Disk object not found" 2>/dev/null; then
            warn "remote diskutil: transient IOKit error, retrying"
        elif ! is_transient_error "$exit_code"; then
            rm -f "$stderr_file"
            return "$exit_code"
        fi

        sleep "$delay"
        delay=$((delay * 2))
        attempt=$((attempt + 1))
    done

    rm -f "$stderr_file"
    return "$exit_code"
}

# ── File Copy ──
# Copies a single file to the target via scp.
remote_mac_cp() {
    local src="$1"
    local dst="$2"
    local host="${TARGET_HOST:-macpro}"
    local remote_dst
    if echo "$dst" | grep -q ':'; then
        remote_dst="$dst"
    else
        remote_dst="${host}:${dst}"
    fi
    scp $_REMOTE_MAC_SSH_OPTS "$src" "$remote_dst"
}

# ── Directory Copy (preserves subdirs) ──
# scp -r creates the source dir name as a subdirectory of dst.
# Use remote_mac_cp_contents() to copy contents without the parent dir.
remote_mac_cp_dir() {
    local src="$1"
    local dst="$2"
    local host="${TARGET_HOST:-macpro}"
    local remote_dst
    if echo "$dst" | grep -q ':'; then
        remote_dst="$dst"
    else
        remote_dst="${host}:${dst}"
    fi
    scp -r $_REMOTE_MAC_SSH_OPTS "$src" "$remote_dst"
}

# ── Directory Contents Copy (flattens) ──
# rsync src/ dst/ copies contents; scp -r src/ dst/ copies the directory itself.
remote_mac_cp_contents() {
    local src="$1"
    local dst="$2"
    local host="${TARGET_HOST:-macpro}"
    case "$src" in
        */) ;;
        *) src="${src}/" ;;
    esac
    rsync -aze "ssh $_REMOTE_MAC_SSH_OPTS" "$src" "${host}:${dst}"
}

# ── Directory Contents Copy (flattens) ──
# Copies the CONTENTS of a local directory to a remote directory via rsync.
# rsync src/ dst/ copies contents; scp -r src/ dst/ copies the directory itself.
remote_mac_cp_contents() {
    local src="$1"
    local dst="$2"
    local host="${TARGET_HOST:-macpro}"
    # Ensure trailing slash on src for rsync "contents only" semantics
    case "$src" in
        */) ;;
        *) src="${src}/" ;;
    esac
    rsync -aze "ssh $_REMOTE_MAC_SSH_OPTS" "$src" "${host}:${dst}"
}

# ── Remote Path Prefix ──
# Returns the path prefix for scp operations on the target.
remote_mac_path() {
    echo "${TARGET_HOST:-macpro}:"
}

# ── Connectivity Test ──
# Returns 0 if the target is reachable via SSH, 1 otherwise.
remote_mac_test() {
    local host="${TARGET_HOST:-macpro}"
    ssh $_REMOTE_MAC_SSH_OPTS "$host" "${_REMOTE_MAC_PATH_PREFIX}; echo ok" >/dev/null 2>&1
}

# ── Remote Preflight Checks ──
# Verifies the remote target has all required tools for deployment via SSH.
remote_mac_preflight() {
    local host="${TARGET_HOST:-macpro}"
    local errors=0
    local missing=""

    log_info "Checking remote connectivity to $host..."
    if ! remote_mac_test; then
        log_error "Cannot connect to $host via SSH. Ensure SSH is enabled and key authentication is configured."
        return 1
    fi
    log_info "SSH connection to $host: OK"

    local required_cmds="diskutil bless sgdisk python3 xorriso newfs_msdos mount_msdos"

    for cmd in $required_cmds; do
        if ! ssh $_REMOTE_MAC_SSH_OPTS "$host" "${_REMOTE_MAC_PATH_PREFIX}; command -v $cmd >/dev/null 2>&1"; then
            missing="${missing}${missing:+ }$cmd"
            errors=$((errors + 1))
        fi
    done

    if [ "$errors" -gt 0 ]; then
        log_error "Missing required commands on $host: $missing"
        log_error "Install missing prerequisites via Homebrew:"
        log_error "  brew install xorriso gptfdisk python@"
        log_error "  newfs_msdos, mount_msdos, diskutil, bless are built into macOS"

        if [ "${AGENT_MODE:-0}" -eq 1 ]; then
            return 1
        fi

        tui_menu "Missing Prerequisites" \
            "The following commands are missing on $host: $missing" \
            "Attempt to install via Homebrew" "install" \
            "Abort deployment" "abort" || true
        local answer="${_TUI_RESULT:-abort}"

        case "$answer" in
            install)
                log_info "Installing missing prerequisites on $host via Homebrew..."
                if ! ssh $_REMOTE_MAC_SSH_OPTS "$host" "${_REMOTE_MAC_PATH_PREFIX}; command -v brew >/dev/null 2>&1"; then
                    tui_confirm "Install Homebrew" "Homebrew is not installed on $host.\n\nInstall Homebrew now? (requires user interaction on the remote host)"
                    if [ "$?" -ne 0 ]; then
                        log_warn "Homebrew installation declined — cannot install prerequisites"
                        return 1
                    fi
                    log_info "Installing Homebrew on $host..."
                    if ! ssh $_REMOTE_MAC_SSH_OPTS "$host" 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'; then
                        log_error "Failed to install Homebrew on $host"
                        tui_menu "Homebrew Install Failed" \
                            "Homebrew installation failed on $host." \
                            "Retry Homebrew install" "retry" \
                            "Abort deployment" "abort" || true
                        local hb_answer="${_TUI_RESULT:-abort}"
                        case "$hb_answer" in
                            retry)
                                if ! ssh $_REMOTE_MAC_SSH_OPTS "$host" 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'; then
                                    log_error "Homebrew install failed again"
                                    return 1
                                fi
                                ;;
                            *) return 1 ;;
                        esac
                    fi
                    # Add brew to PATH for Apple Silicon Macs
                    ssh $_REMOTE_MAC_SSH_OPTS "$host" 'grep -q "homebrew" ~/.zprofile 2>/dev/null || echo "eval \"$(/opt/homebrew/bin/brew shellenv)\"" >> ~/.zprofile; eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null)" 2>/dev/null || true'
                fi
                if ! ssh $_REMOTE_MAC_SSH_OPTS "$host" 'export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"; command -v brew >/dev/null 2>&1'; then
                    log_error "Homebrew still not found after installation. PATH may need updating."
                    return 1
                fi
                for cmd in $missing; do
                    case "$cmd" in
                        xorriso)
                            log_info "Installing xorriso on $host..."
                            ssh $_REMOTE_MAC_SSH_OPTS "$host" "${_REMOTE_MAC_PATH_PREFIX}; brew install xorriso" || die "Failed to install xorriso on $host"
                            ;;
                        sgdisk)
                            log_info "Installing gptfdisk (sgdisk) on $host..."
                            ssh $_REMOTE_MAC_SSH_OPTS "$host" "${_REMOTE_MAC_PATH_PREFIX}; brew install gptfdisk" || die "Failed to install gptfdisk on $host"
                            ;;
                        python3)
                            log_info "Installing python3 on $host..."
                            ssh $_REMOTE_MAC_SSH_OPTS "$host" "${_REMOTE_MAC_PATH_PREFIX}; brew install python@3" || die "Failed to install python3 on $host"
                            ;;
                        mount_msdos|newfs_msdos|diskutil|bless)
                            log_error "Cannot auto-install macOS built-in $cmd — macOS may need reinstallation"
                            return 1
                            ;;
                        *)
                            log_error "Cannot auto-install $cmd"
                            return 1
                            ;;
                    esac
                done
                log_info "Prerequisites installed successfully"
                ;;
            *)
                die "Deployment aborted: missing prerequisites on $host"
                ;;
        esac
    fi

    if [ -n "${REMOTE_SUDO_PASSWORD:-}" ]; then
        log_info "Testing sudo access on $host..."
        if ! printf '%s\n' "$REMOTE_SUDO_PASSWORD" | \
            ssh $_REMOTE_MAC_SSH_OPTS "$host" "sudo -S -p '' true" 2>/dev/null; then
            log_error "Sudo password authentication failed on $host"
            return 1
        fi
        log_info "Sudo access on $host: OK"
    else
        log_info "Checking passwordless sudo on $host..."
        if ! ssh $_REMOTE_MAC_SSH_OPTS "$host" "sudo -n true" 2>/dev/null; then
            log_error "Passwordless sudo is not configured on $host."
            log_error "Configure it with: sudo visudo && add 'user ALL=(ALL) NOPASSWD:ALL'"
            if [ "${AGENT_MODE:-0}" -eq 1 ]; then
                return 1
            fi
            tui_password "Remote Sudo Password" \
                "Enter sudo password for $host:" || die "Sudo password required for remote deployment"
            REMOTE_SUDO_PASSWORD="$_TUI_RESULT"
        fi
    fi

    log_info "Remote preflight checks passed for $host"
    return 0
}

# ── Remote File Operations ──
# Check if a file exists on the target via SSH.
remote_mac_file_exists() {
    local path="$1"
    local escaped_path
    escaped_path=$(printf '%s' "$path" | sed "s/'/'\\\\''/g")
    ssh $_REMOTE_MAC_SSH_OPTS "${TARGET_HOST:-macpro}" "test -f '${escaped_path}'" 2>/dev/null
}

# Check if a directory exists on the target via SSH.
remote_mac_dir_exists() {
    local path="$1"
    local escaped_path
    escaped_path=$(printf '%s' "$path" | sed "s/'/'\\\\''/g")
    ssh $_REMOTE_MAC_SSH_OPTS "${TARGET_HOST:-macpro}" "test -d '${escaped_path}'" 2>/dev/null
}

# Create a directory on the target via SSH.
remote_mac_mkdir() {
    local path="$1"
    local escaped_path
    escaped_path=$(printf '%s' "$path" | sed "s/'/'\\\\''/g")
    ssh $_REMOTE_MAC_SSH_OPTS "${TARGET_HOST:-macpro}" "mkdir -p '${escaped_path}'"
}

# Remove a file on the target via SSH.
remote_mac_rm() {
    local path="$1"
    local escaped_path
    escaped_path=$(printf '%s' "$path" | sed "s/'/'\\\\''/g")
    ssh $_REMOTE_MAC_SSH_OPTS "${TARGET_HOST:-macpro}" "rm -f '${escaped_path}'"
}