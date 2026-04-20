#!/bin/bash
# lib/remote_mac.sh — Remote execution wrapper for macOS-side commands
# Routes commands to local execution or SSH based on DEPLOY_MODE.
# When DEPLOY_MODE=local, commands run directly on this machine.
# When DEPLOY_MODE=remote, commands run via SSH on TARGET_HOST.
set -e
set -o pipefail

[ "${_REMOTE_MAC_SH_SOURCED:-0}" -eq 1 ] && return 0
_REMOTE_MAC_SH_SOURCED=1

# ── SSH Options ──
_REMOTE_MAC_SSH_OPTS="-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no"

# ── Core Execution Wrapper ──
# Runs a command locally or remotely based on DEPLOY_MODE.
# Usage: remote_mac_exec diskutil list
#        remote_mac_exec "diskutil info disk0s2"
remote_mac_exec() {
    if [ "${DEPLOY_MODE:-local}" = "local" ]; then
        "$@"
    else
        ssh $_REMOTE_MAC_SSH_OPTS "${TARGET_HOST:-macpro}" "$*"
    fi
}

# ── Remote Command with sudo ──
# Runs a command with sudo on the remote host.
# In local mode, assumes already running as root (via sudo).
# In remote mode, uses the stored REMOTE_SUDO_PASSWORD.
remote_mac_sudo() {
    if [ "${DEPLOY_MODE:-local}" = "local" ]; then
        "$@"
    else
        if [ -n "${REMOTE_SUDO_PASSWORD:-}" ]; then
            printf '%s\n' "$REMOTE_SUDO_PASSWORD" | \
                ssh $_REMOTE_MAC_SSH_OPTS "${TARGET_HOST:-macpro}" \
                "sudo -S -p '' $*"
        else
            ssh $_REMOTE_MAC_SSH_OPTS "${TARGET_HOST:-macpro}" \
                "sudo -n $*"
        fi
    fi
}

# ── File Copy ──
# Copies a single file to the target.
# Local: cp. Remote: scp.
remote_mac_cp() {
    local src="$1"
    local dst="$2"
    if [ "${DEPLOY_MODE:-local}" = "local" ]; then
        cp "$src" "$dst"
    else
        local host="${TARGET_HOST:-macpro}"
        local remote_dst
        if echo "$dst" | grep -q ':'; then
            remote_dst="$dst"
        else
            remote_dst="${host}:${dst}"
        fi
        scp $_REMOTE_MAC_SSH_OPTS "$src" "$remote_dst"
    fi
}

# ── Directory Copy ──
# Copies a directory tree to the target.
# Local: cp -r. Remote: scp -r.
remote_mac_cp_dir() {
    local src="$1"
    local dst="$2"
    if [ "${DEPLOY_MODE:-local}" = "local" ]; then
        cp -r "$src" "$dst"
    else
        local host="${TARGET_HOST:-macpro}"
        local remote_dst
        if echo "$dst" | grep -q ':'; then
            remote_dst="$dst"
        else
            remote_dst="${host}:${dst}"
        fi
        scp -r $_REMOTE_MAC_SSH_OPTS "$src" "$remote_dst"
    fi
}

# ── Remote Path Prefix ──
# Returns the path prefix for accessing files on the target.
# Local: empty string (paths are local).
# Remote: host: prefix for scp, or empty for ssh commands.
remote_mac_path() {
    if [ "${DEPLOY_MODE:-local}" = "local" ]; then
        echo ""
    else
        echo "${TARGET_HOST:-macpro}:"
    fi
}

# ── Connectivity Test ──
# Returns 0 if the target is reachable, 1 otherwise.
remote_mac_test() {
    if [ "${DEPLOY_MODE:-local}" = "local" ]; then
        return 0
    fi
    local host="${TARGET_HOST:-macpro}"
    ssh $_REMOTE_MAC_SSH_OPTS "$host" 'echo ok' >/dev/null 2>&1
}

# ── Remote Preflight Checks ──
# Verifies the target has all required tools for deployment.
# In local mode, returns 0 (assumes running on Mac Pro).
# In remote mode, checks SSH connectivity and required commands.
remote_mac_preflight() {
    if [ "${DEPLOY_MODE:-local}" = "local" ]; then
        return 0
    fi

    local host="${TARGET_HOST:-macpro}"
    local errors=0
    local missing=""

    log_info "Checking remote connectivity to $host..."
    if ! remote_mac_test; then
        log_error "Cannot connect to $host via SSH. Ensure SSH is enabled and key authentication is configured."
        return 1
    fi
    log_info "SSH connection to $host: OK"

    local required_cmds="diskutil bless sgdisk python3"
    for cmd in $required_cmds; do
        if ! ssh $_REMOTE_MAC_SSH_OPTS "$host" "command -v $cmd >/dev/null 2>&1"; then
            missing="${missing}${missing:+ }$cmd"
            errors=$((errors + 1))
        fi
    done

    local deploy_cmds="xorriso newfs_msdos"
    for cmd in $deploy_cmds; do
        if ! ssh $_REMOTE_MAC_SSH_OPTS "$host" "command -v $cmd >/dev/null 2>&1"; then
            missing="${missing}${missing:+ }$cmd"
            errors=$((errors + 1))
        fi
    done

    if [ "$errors" -gt 0 ]; then
        log_error "Missing required commands on $host: $missing"
        log_error "Install missing prerequisites:"
                log_error "  brew install xorriso gptfdisk"
        log_error "  newfs_msdos and diskutil are built into macOS"

        if [ "${AGENT_MODE:-0}" -eq 1 ]; then
            return 1
        fi

        local answer
        answer=$(tui_menu "Missing Prerequisites" \
            "The following commands are missing on $host: $missing" \
            "Attempt to install via Homebrew" "install" \
            "Abort deployment" "abort") || answer="abort"

        case "$answer" in
            install)
                log_info "Installing missing prerequisites on $host via Homebrew..."
                if ! ssh $_REMOTE_MAC_SSH_OPTS "$host" "command -v brew >/dev/null 2>&1"; then
                    die "Homebrew is not installed on $host. Install it first: https://brew.sh"
                fi
                for cmd in $missing; do
                    case "$cmd" in
                        xorriso)
                            log_info "Installing xorriso on $host..."
                            ssh $_REMOTE_MAC_SSH_OPTS "$host" "brew install xorriso" || die "Failed to install xorriso on $host"
                            ;;
                        sgdisk)
                            log_info "Installing gptfdisk (sgdisk) on $host..."
                            ssh $_REMOTE_MAC_SSH_OPTS "$host" "brew install gptfdisk" || die "Failed to install gptfdisk on $host"
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
            REMOTE_SUDO_PASSWORD=$(tui_password "Remote Sudo Password" \
                "Enter sudo password for $host:") || die "Sudo password required for remote deployment"
        fi
    fi

    log_info "Remote preflight checks passed for $host"
    return 0
}

# ── Remote File Operations ──
# Check if a file exists on the target.
remote_mac_file_exists() {
    local path="$1"
    if [ "${DEPLOY_MODE:-local}" = "local" ]; then
        [ -f "$path" ]
    else
        ssh $_REMOTE_MAC_SSH_OPTS "${TARGET_HOST:-macpro}" "test -f '$path'" 2>/dev/null
    fi
}

# Check if a directory exists on the target.
remote_mac_dir_exists() {
    local path="$1"
    if [ "${DEPLOY_MODE:-local}" = "local" ]; then
        [ -d "$path" ]
    else
        ssh $_REMOTE_MAC_SSH_OPTS "${TARGET_HOST:-macpro}" "test -d '$path'" 2>/dev/null
    fi
}

# Create a directory on the target.
remote_mac_mkdir() {
    local path="$1"
    if [ "${DEPLOY_MODE:-local}" = "local" ]; then
        mkdir -p "$path"
    else
        ssh $_REMOTE_MAC_SSH_OPTS "${TARGET_HOST:-macpro}" "mkdir -p '$path'"
    fi
}

# Remove a file on the target.
remote_mac_rm() {
    local path="$1"
    if [ "${DEPLOY_MODE:-local}" = "local" ]; then
        rm -f "$path"
    else
        ssh $_REMOTE_MAC_SSH_OPTS "${TARGET_HOST:-macpro}" "rm -f '$path'"
    fi
}