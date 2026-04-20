#!/bin/bash
#
# lib/remote.sh - SSH remote management module for Mac Pro Ubuntu deployment
#
# Provides functions for managing a remote Mac Pro 2013 running Ubuntu via SSH.
# This module is called from prepare-deployment.sh's "Manage" mode.
# All functions execute commands on the remote instance.
#
# Dependencies: lib/colors.sh, lib/logging.sh
#

[ "${_REMOTE_SH_SOURCED:-0}" -eq 1 ] && return 0
_REMOTE_SH_SOURCED=1

source "${LIB_DIR:-./lib}/colors.sh"
source "${LIB_DIR:-./lib}/logging.sh"
source "${LIB_DIR:-./lib}/tui.sh" 2>/dev/null || true
source "${LIB_DIR:-./lib}/retry.sh" 2>/dev/null || true
source "${LIB_DIR:-./lib}/rollback.sh" 2>/dev/null || true
source "${LIB_DIR:-./lib}/verify.sh" 2>/dev/null || true
source "${LIB_DIR:-./lib}/dryrun.sh"

## Connection Helpers

remote__get_host() {
    local host="${1:-macpro-linux}"
    echo "$host"
}

remote__ssh_cmd() {
    local host
    host=$(remote__get_host "$1")
    echo "ssh -o ConnectTimeout=10 -o BatchMode=yes $host"
}

remote__exec() {
    local host="${1:-macpro-linux}"
    shift
    local cmd="$*"
    local ssh_cmd="ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no $host"

    if command -v retry_ssh >/dev/null 2>&1; then
        retry_ssh "$host" "$cmd"
    else
        $ssh_cmd "$cmd"
    fi
}

## Connection

remote_test_connection() {
    local host
    host=$(remote__get_host "${1:-}")

    if ssh -o ConnectTimeout=10 -o BatchMode=yes "$host" 'echo ok' >/dev/null 2>&1; then
        log "SSH connection to $host: OK"
        return 0
    else
        error "SSH connection to $host: FAILED"
        return 1
    fi
}

remote_get_info() {
    local host
    host=$(remote__get_host "${1:-}")

    log "Gathering system info from $host..."
    echo ""

    local kernel wifi_status disk_usage uptime apt_sources dkms_status

    kernel=$(remote__exec "$host" "uname -r") || { error "Failed to get kernel version"; return 1; }
    wifi_status=$(remote__exec "$host" "ip link show | grep -E 'wlan|wlp' | head -1") || wifi_status="Not detected"
    disk_usage=$(remote__exec "$host" "df -h / | tail -1") || { error "Failed to get disk usage"; return 1; }
    uptime=$(remote__exec "$host" "uptime -p") || { error "Failed to get uptime"; return 1; }
    apt_sources=$(remote__exec "$host" "grep -c '^deb' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null | grep -v ':0' | wc -l") || apt_sources="0"
    dkms_status=$(remote__exec "$host" "dkms status broadcom-sta 2>/dev/null || echo 'Not installed'") || dkms_status="Unknown"

    echo "=== System Information ==="
    echo "  Host: $host"
    echo "  Kernel: $kernel"
    echo "  Uptime: $uptime"
    echo "  DKMS Status: $dkms_status"
    echo "  WiFi Interface: $wifi_status"
    echo "  Root Disk: $disk_usage"
    echo "  Active apt sources: $apt_sources"
    echo ""
}

## Kernel Management

remote_kernel_status() {
    local host
    host=$(remote__get_host "${1:-}")

    log "Checking kernel status on $host..."
    echo ""

    local kernel pinned held

    kernel=$(remote__exec "$host" "uname -r") || { error "Failed to get kernel version"; return 1; }
    pinned=$(remote__exec "$host" "cat /etc/apt/preferences.d/99-pin-kernel 2>/dev/null || echo 'No pinning configured'")
    held=$(remote__exec "$host" "apt-mark showhold 2>/dev/null | grep linux || echo 'No kernel packages held'")

    echo "=== Kernel Status ==="
    echo "  Current Kernel: $kernel"
    echo ""
    echo "=== Held Packages ==="
    echo "$held"
    echo ""
    echo "=== Apt Preferences ==="
    echo "$pinned"
    echo ""
}

remote_kernel_unpin() {
    local host
    host=$(remote__get_host "${1:-}")

    warn "This will REMOVE kernel holds and pinning (Phase 2 of update process)"
    read -rp "Type 'yes' to confirm: " confirm
    if [ "$confirm" != "yes" ]; then
        log "Operation cancelled"
        return 1
    fi

    log "Removing kernel holds on $host..."

    local kver
    kver=$(remote__exec "$host" "uname -r") || { error "Failed to get kernel version"; return 1; }

    dry_run_exec "Unholding kernel image package on $host" \
        remote__exec "$host" "sudo apt-mark unhold linux-image-${kver} 2>/dev/null || true"
    dry_run_exec "Unholding kernel headers package on $host" \
        remote__exec "$host" "sudo apt-mark unhold linux-headers-${kver} 2>/dev/null || true"
    dry_run_exec "Unholding kernel modules package on $host" \
        remote__exec "$host" "sudo apt-mark unhold linux-modules-${kver} 2>/dev/null || true"
    dry_run_exec "Unholding kernel modules-extra package on $host" \
        remote__exec "$host" "sudo apt-mark unhold linux-modules-extra-${kver} 2>/dev/null || true"
    dry_run_exec "Removing kernel apt preferences on $host" \
        remote__exec "$host" "sudo rm /etc/apt/preferences.d/99-pin-kernel 2>/dev/null || true"
    dry_run_exec "Unmasking apt-daily service/timer on $host" \
        remote__exec "$host" "sudo systemctl unmask apt-daily.service apt-daily.timer 2>/dev/null || true"
    dry_run_exec "Unmasking apt-daily-upgrade service/timer on $host" \
        remote__exec "$host" "sudo systemctl unmask apt-daily-upgrade.service apt-daily-upgrade.timer 2>/dev/null || true"

    log "Kernel unpinned successfully"
}

remote_kernel_repin() {
    local host
    host=$(remote__get_host "${1:-}")

    warn "This will RE-APPLY kernel holds and pinning for the CURRENT kernel"
    read -rp "Type 'yes' to confirm: " confirm
    if [ "$confirm" != "yes" ]; then
        log "Operation cancelled"
        return 1
    fi

    log "Re-pinning kernel on $host..."

    local kver abi
    kver=$(remote__exec "$host" "uname -r") || { error "Failed to get kernel version"; return 1; }
    abi=$(echo "$kver" | sed 's/-generic$//')

    dry_run_exec "Holding kernel image package on $host" \
        remote__exec "$host" "sudo apt-mark hold linux-image-${kver}"
    dry_run_exec "Holding kernel headers package on $host" \
        remote__exec "$host" "sudo apt-mark hold linux-headers-${kver}"
    dry_run_exec "Holding kernel modules package on $host" \
        remote__exec "$host" "sudo apt-mark hold linux-modules-${kver}"
    dry_run_exec "Holding kernel modules-extra package on $host" \
        remote__exec "$host" "sudo apt-mark hold linux-modules-extra-${kver} 2>/dev/null || true"

    local prefs_content
    prefs_content="Package: linux-image-*
Pin: release o=Ubuntu
Pin-Priority: -1

Package: linux-headers-*
Pin: release o=Ubuntu
Pin-Priority: -1

Package: linux-modules-*
Pin: release o=Ubuntu
Pin-Priority: -1

Package: linux-image-${abi}*
Pin: release o=Ubuntu
Pin-Priority: 1001

Package: linux-headers-${abi}*
Pin: release o=Ubuntu
Pin-Priority: 1001

Package: linux-modules-${abi}*
Pin: release o=Ubuntu
Pin-Priority: 1001"
    echo "$prefs_content" | dry_run_exec "Writing kernel apt preferences on $host" \
        sh -c "remote__exec '$host' 'sudo tee /etc/apt/preferences.d/99-pin-kernel > /dev/null'"

    dry_run_exec "Disabling apt sources by commenting out on $host" \
        remote__exec "$host" "sudo sed -i '/^deb/ s/^/#/' /etc/apt/sources.list"
    dry_run_exec "Disabling apt sources in sources.list.d on $host" \
        remote__exec "$host" "for list in /etc/apt/sources.list.d/*.list; do [ -f \"\$list\" ] && sudo sed -i '/^deb/ s/^/#/' \"\$list\"; done"
    dry_run_exec "Masking apt-daily service on $host" \
        remote__exec "$host" "sudo systemctl mask apt-daily.service 2>/dev/null || true"
    dry_run_exec "Masking apt-daily timer on $host" \
        remote__exec "$host" "sudo systemctl mask apt-daily.timer 2>/dev/null || true"
    dry_run_exec "Masking apt-daily-upgrade service on $host" \
        remote__exec "$host" "sudo systemctl mask apt-daily-upgrade.service 2>/dev/null || true"
    dry_run_exec "Masking apt-daily-upgrade timer on $host" \
        remote__exec "$host" "sudo systemctl mask apt-daily-upgrade.timer 2>/dev/null || true"

    log "Kernel re-pinned successfully"
}

remote_pin_kernel() {
    local host
    host=$(remote__get_host "${1:-}")

    remote_kernel_repin "$host"
}

remote_unpin_kernel() {
    local host
    host=$(remote__get_host "${1:-}")

    remote_kernel_unpin "$host"
}

remote_toggle_apt_sources() {
    local host
    local action
    host=$(remote__get_host "${1:-}")
    action="${2:-}"

    case "$action" in
        enable)
            remote_apt_enable "$host"
            ;;
        disable)
            remote_apt_disable "$host"
            ;;
        *)
            error "remote_toggle_apt_sources: unknown action '$action'. Use 'enable' or 'disable'."
            return 1
            ;;
    esac
}

## APT Source Management (standalone wrappers)

remote_apt_enable() {
    local host
    host=$(remote__get_host "${1:-}")
    remote_toggle_apt_sources "$host" enable
}

remote_apt_disable() {
    local host
    host=$(remote__get_host "${1:-}")
    remote_toggle_apt_sources "$host" disable
}

## WiFi/Driver Status

remote_driver_status() {
    local host
    host=$(remote__get_host "${1:-}")
    local kver dkms_status wl_status

    log "Checking WiFi/driver status on $host..."

    kver=$(remote__exec "$host" "uname -r") || { error "Failed to get kernel version"; return 1; }
    log "Kernel: $kver"

    dkms_status=$(remote__exec "$host" "dkms status 2>/dev/null || echo 'DKMS not available'")
    log "DKMS status: $dkms_status"

    wl_status=$(remote__exec "$host" "lsmod | grep '^wl ' 2>/dev/null || echo 'wl module not loaded'")
    log "wl module: $wl_status"

    remote__exec "$host" "iwconfig 2>/dev/null | grep -E 'ESSID|IEEE' || echo 'No wireless interfaces'"
}

## WiFi/Driver Rebuild

remote_driver_rebuild() {
    local host="${1:-macpro-linux}"
    local kver="${2:-}"
    local detected_kver

    log "Rebuilding WiFi (wl) driver on $host..."

    if [ -z "$kver" ]; then
        detected_kver=$(remote__exec "$host" "uname -r") || { error "Failed to get kernel version"; return 1; }
        kver="$detected_kver"
    fi
    log "Kernel: $kver"

    dry_run_exec "Removing old wl module on $host" \
        remote__exec "$host" "sudo rmmod wl 2>/dev/null || true"

    dry_run_exec "Rebuilding broadcom-sta DKMS module for kernel $kver on $host" \
        remote__exec "$host" "sudo dkms remove broadcom-sta/6.30.223.271 -k '$kver' 2>/dev/null; sudo dkms build broadcom-sta/6.30.223.271 -k '$kver' && sudo dkms install broadcom-sta/6.30.223.271 -k '$kver'"

    dry_run_exec "Loading wl module on $host" \
        remote__exec "$host" "sudo modprobe wl"

    log "Driver rebuild complete on $host"
}

remote_kernel_update() {
    local host="${1:-macpro-linux}"
    local kver new_kver current_kver

    log "Starting interactive kernel update on $host..."
    log "This is a 7-phase process with rollback capability at each step."
    echo ""

    log "Pre-update checklist:"
    if ! remote_test_connection "$host"; then
        error "Cannot connect to $host"
        return 1
    fi

    kver=$(remote__exec "$host" "uname -r") || { error "Failed to get kernel version"; return 1; }
    current_kver="$kver"
    log "Current kernel: $current_kver"

    if ! command -v _remote_kernel_update_rollback >/dev/null 2>&1; then
        warn "Rollback helper not available — failures will require manual recovery"
    fi

    if ! tui_confirm "Kernel Update: Phase 1 of 7" "Enable apt package sources on $host?"; then
        return 1
    fi
    remote_toggle_apt_sources "$host" enable || return 1
    remote__exec "$host" "echo 'KUPDATE_PHASE=1' > /tmp/macpro-kernel-update.env"
    log "Phase 1 complete: apt sources enabled"

    if ! tui_confirm "Kernel Update: Phase 2 of 7" "Remove kernel pinning and apt holds?"; then
        _remote_kernel_update_rollback "$host" "1"
        return 1
    fi
    remote_unpin_kernel "$host" || { _remote_kernel_update_rollback "$host" "1"; return 1; }
    dry_run_exec "Setting kernel update phase marker to 2 on $host" \
        remote__exec "$host" "echo 'KUPDATE_PHASE=2' > /tmp/macpro-kernel-update.env"
    log "Phase 2 complete: kernel unpinned, holds removed"

    if ! tui_confirm "Kernel Update: Phase 3 of 7" "Run apt-get dist-upgrade? This will install a new kernel if available."; then
        _remote_kernel_update_rollback "$host" "2"
        return 1
    fi
    dry_run_exec "Running apt-get update and dist-upgrade on $host" \
        remote__exec "$host" "sudo apt-get update && sudo apt-get dist-upgrade -y" || {
        _remote_kernel_update_rollback "$host" "2"
        return 1
    }
    dry_run_exec "Setting kernel update phase marker to 3 on $host" \
        remote__exec "$host" "echo 'KUPDATE_PHASE=3' > /tmp/macpro-kernel-update.env"
    log "Phase 3 complete: dist-upgrade finished"

    new_kver=$(remote__exec "$host" "ls /boot/vmlinuz-* | sort -V | tail -1 | sed 's|/boot/vmlinuz-||'")
    current_kver=$(remote__exec "$host" "uname -r")

    if [ "$new_kver" = "$current_kver" ]; then
        log "No new kernel installed — skipping DKMS verification"
    else
        if ! tui_confirm "Kernel Update: Phase 4 of 7 (CRITICAL)" "Verify DKMS built wl.ko for new kernel $new_kver?"; then
            _remote_kernel_update_rollback "$host" "3"
            return 1
        fi

        local dkms_status
        dkms_status=$(remote__exec "$host" "dkms status broadcom-sta/6.30.223.271 -k $new_kver 2>/dev/null")

        if ! echo "$dkms_status" | grep -q "installed"; then
            log "DKMS did not auto-build for $new_kver — building manually..."
            if ! remote_driver_rebuild "$host" "$new_kver"; then
                error "DKMS build FAILED for kernel $new_kver"
                tui_msgbox "CRITICAL: DKMS Build Failed" "The WiFi driver cannot compile for kernel $new_kver.\n\nDO NOT REBOOT into this kernel.\n\nRolling back now..."
                _remote_kernel_update_rollback "$host" "3"
                return 1
            fi
        fi

        local wl_path
        wl_path=$(remote__exec "$host" "ls /lib/modules/$new_kver/updates/dkms/wl.ko /lib/modules/$new_kver/extra/wl.ko 2>/dev/null | head -1")
        if [ -z "$wl_path" ]; then
            error "wl.ko NOT FOUND for kernel $new_kver"
            _remote_kernel_update_rollback "$host" "3"
            return 1
        fi
        log "wl.ko verified at $wl_path"

        dry_run_exec "Updating initramfs for new kernel $new_kver on $host" \
            remote__exec "$host" "sudo update-initramfs -u -k $new_kver"
    fi
    dry_run_exec "Setting kernel update phase marker to 4 on $host" \
        remote__exec "$host" "echo 'KUPDATE_PHASE=4' > /tmp/macpro-kernel-update.env"
    log "Phase 4 complete: DKMS verified"

    if ! tui_confirm "Kernel Update: Phase 5 of 7" "Configure GRUB fallback so old kernel is default?"; then
        _remote_kernel_update_rollback "$host" "4"
        return 1
    fi
    dry_run_exec "Setting GRUB_DEFAULT to saved on $host" \
        remote__exec "$host" "sudo sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub"
    dry_run_exec "Adding GRUB_SAVEDEFAULT on $host" \
        remote__exec "$host" "grep -q '^GRUB_SAVEDEFAULT' /etc/default/grub || echo 'GRUB_SAVEDEFAULT=true' | sudo tee -a /etc/default/grub"
    dry_run_exec "Setting GRUB default to current kernel on $host" \
        remote__exec "$host" "sudo grub-set-default 'Ubuntu, with Linux $current_kver'"
    dry_run_exec "Updating GRUB on $host" \
        remote__exec "$host" "sudo update-grub"
    local saved_default
    saved_default=$(remote__exec "$host" "sudo grub-editenv list 2>/dev/null" || true)
    log "GRUB saved default: $saved_default"
    dry_run_exec "Setting kernel update phase marker to 5 on $host" \
        remote__exec "$host" "echo 'KUPDATE_PHASE=5' > /tmp/macpro-kernel-update.env"
    log "Phase 5 complete: GRUB fallback configured"

    if ! tui_confirm "Kernel Update: Phase 6 of 7" "Reboot into new kernel $new_kver? Power cycle returns to $current_kver if it fails."; then
        _remote_kernel_update_rollback "$host" "5"
        return 1
    fi
    dry_run_exec "Setting GRUB reboot to new kernel on $host" \
        remote__exec "$host" "sudo grub-reboot 'Ubuntu, with Linux $new_kver'"
    remote_reboot "$host"
    dry_run_exec "Setting kernel update phase marker to 6 on $host" \
        remote__exec "$host" "echo 'KUPDATE_PHASE=6' > /tmp/macpro-kernel-update.env"
    log "Phase 6 complete: rebooted into new kernel"

    if ! tui_confirm "Kernel Update: Phase 7 of 7" "Re-lock the system (pin kernel, disable apt sources, re-enable holds)?"; then
        log "WARNING: System left unlocked — manual re-lock required"
        return 0
    fi
    remote_pin_kernel "$host"
    remote_toggle_apt_sources "$host" disable
    dry_run_exec "Removing kernel update phase marker on $host" \
        remote__exec "$host" "rm -f /tmp/macpro-kernel-update.env"

    log "Kernel update complete!"
    return 0
}

_remote_kernel_update_rollback() {
    local host="$1"
    local from_phase="${2:-0}"

    error "Kernel update failed — rolling back from phase $from_phase..."

    case "$from_phase" in
        0|1)
            dry_run_exec "Disabling apt sources on $host (rollback)" \
                remote_toggle_apt_sources "$host" disable 2>/dev/null || true
            ;;
        2|3)
            dry_run_exec "Re-pinning kernel on $host (rollback)" \
                remote_pin_kernel "$host" 2>/dev/null || true
            dry_run_exec "Disabling apt sources on $host (rollback)" \
                remote_toggle_apt_sources "$host" disable 2>/dev/null || true
            ;;
        4)
            dry_run_exec "Re-pinning kernel on $host (rollback)" \
                remote_pin_kernel "$host" 2>/dev/null || true
            dry_run_exec "Disabling apt sources on $host (rollback)" \
                remote_toggle_apt_sources "$host" disable 2>/dev/null || true
            warn "New kernel is installed but NOT verified. Do NOT reboot into it."
            ;;
        5)
            dry_run_exec "Setting GRUB default to 0 on $host (rollback)" \
                remote__exec "$host" "sudo grub-set-default 0" 2>/dev/null || true
            dry_run_exec "Updating GRUB on $host (rollback)" \
                remote__exec "$host" "sudo update-grub" 2>/dev/null || true
            dry_run_exec "Re-pinning kernel on $host (rollback)" \
                remote_pin_kernel "$host" 2>/dev/null || true
            dry_run_exec "Disabling apt sources on $host (rollback)" \
                remote_toggle_apt_sources "$host" disable 2>/dev/null || true
            ;;
        6|7)
            dry_run_exec "Re-pinning kernel on $host (rollback)" \
                remote_pin_kernel "$host" 2>/dev/null || true
            dry_run_exec "Disabling apt sources on $host (rollback)" \
                remote_toggle_apt_sources "$host" disable 2>/dev/null || true
            warn "System has already rebooted into new kernel. Verify WiFi works (ping google.com)."
            warn "If WiFi is broken, power-cycle the Mac Pro — GRUB default was set to old kernel before reboot."
            ;;
    esac

    dry_run_exec "Removing kernel update phase marker on $host (rollback)" \
        remote__exec "$host" "rm -f /tmp/macpro-kernel-update.env" 2>/dev/null || true
    log "Rollback complete — system should be in pre-update state"
}

remote_non_kernel_update() {
    local host
    host=$(remote__get_host "${1:-}")

    warn "This will update non-kernel packages (security updates only)"
    read -rp "Type 'yes' to confirm: " confirm
    if [ "$confirm" != "yes" ]; then
        log "Operation cancelled"
        return 1
    fi

    local failed=0

    log "Enabling apt sources on $host..."
    dry_run_exec "Enabling apt sources on $host" \
        remote__exec "$host" "sudo sed -i 's/^#deb/deb/' /etc/apt/sources.list"
    dry_run_exec "Enabling apt sources in sources.list.d on $host" \
        remote__exec "$host" "for list in /etc/apt/sources.list.d/*.list; do [ -f \"\$list\" ] && sudo sed -i 's/^#deb/deb/' \"\$list\"; done"

    log "Running apt-get update..."
    if ! dry_run_exec "Running apt-get update on $host" \
        remote__exec "$host" "sudo apt-get update"; then
        error "apt-get update failed"
        failed=1
    fi

    log "Upgrading non-kernel packages..."
    if [ "$failed" -eq 0 ]; then
        if ! dry_run_exec "Running apt-get upgrade on $host" \
            remote__exec "$host" "sudo apt-get upgrade -y --exclude=linux-image-*,linux-headers-*,linux-modules-*"; then
            error "Upgrade failed"
            failed=1
        fi
    fi

    log "Disabling apt sources..."
    dry_run_exec "Disabling apt sources on $host" \
        remote__exec "$host" "sudo sed -i '/^deb/ s/^/#/' /etc/apt/sources.list"
    dry_run_exec "Disabling apt sources in sources.list.d on $host" \
        remote__exec "$host" "for list in /etc/apt/sources.list.d/*.list; do [ -f \"\$list\" ] && sudo sed -i '/^deb/ s/^/#/' \"\$list\"; done"

    log "Apt sources disabled"
}

## System Info

remote_health_check() {
    local host
    host=$(remote__get_host "${1:-}")

    log "Running comprehensive health check on $host..."
    echo ""

    local errors=0

    echo "=== SSH Connectivity ==="
    if remote_test_connection "$host"; then
        echo "  Status: OK"
    else
        echo "  Status: FAILED"
        errors=$((errors + 1))
    fi
    echo ""

    echo "=== WiFi Status ==="
    local wifi_check
    wifi_check=$(remote__exec "$host" "ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1 && echo 'connected' || echo 'disconnected'")
    if [ "$wifi_check" = "connected" ]; then
        echo "  Status: OK (can reach internet)"
    else
        echo "  Status: FAILED (no internet connectivity)"
        errors=$((errors + 1))
    fi
    echo ""

    echo "=== Disk Usage ==="
    remote__exec "$host" "df -h /" | tail -1 || errors=$((errors + 1))
    echo ""

    echo "=== DKMS Status ==="
    remote__exec "$host" "dkms status broadcom-sta" || {
        echo "  DKMS status unavailable"
        errors=$((errors + 1))
    }
    echo ""

    echo "=== Kernel ==="
    remote__exec "$host" "uname -r && uname -v" || errors=$((errors + 1))
    echo ""

    echo "=== Uptime ==="
    remote__exec "$host" "uptime" || errors=$((errors + 1))
    echo ""

    echo "=== UFW Status ==="
    remote__exec "$host" "sudo ufw status 2>/dev/null || echo 'UFW not active'"
    echo ""

    if [ $errors -eq 0 ]; then
        log "Health check PASSED"
        return 0
    else
        error "Health check FAILED with $errors errors"
        return 1
    fi
}

remote_reboot() {
    local host
    host=$(remote__get_host "${1:-}")

    warn "This will REBOOT the remote machine $host"
    read -rp "Type 'reboot' to confirm: " confirm
    if [ "$confirm" != "reboot" ]; then
        log "Operation cancelled"
        return 1
    fi

    log "Pre-reboot checks on $host..."

    local wifi_check
    wifi_check=$(remote__exec "$host" "ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1 && echo 'connected' || echo 'disconnected'")
    if [ "$wifi_check" != "connected" ]; then
        error "WiFi not connected. Aborting reboot to avoid losing access."
        return 1
    fi

    log "Initiating reboot..."
    dry_run_exec "Sending reboot command to $host" \
        remote__exec "$host" "sudo reboot" || true

    log "Reboot command sent. Waiting for host to go down..."
    sleep 10

    log "Waiting for $host to come back online..."

    local attempts=0
    local max_attempts=60

    while [ $attempts -lt $max_attempts ]; do
        attempts=$((attempts + 1))

        if command -v retry_ssh >/dev/null 2>&1; then
            if retry_ssh "$host" "echo 'SSH is up'" 2>/dev/null; then
                log "Host is back online (after $((attempts * 5)) seconds)"
                remote_health_check "$host"
                return 0
            fi
        else
            if remote_test_connection "$host" 2>/dev/null; then
                log "Host is back online (after $((attempts * 5)) seconds)"
                remote_health_check "$host"
                return 0
            fi
        fi

        if [ $((attempts % 6)) -eq 0 ]; then
            log "  Still waiting... ($((attempts / 6)) minutes elapsed)"
        fi
        sleep 5
    done

    error "Host did not come back online within timeout"
    return 1
}

remote_rollback_status() {
    local host
    host=$(remote__get_host "${1:-}")

    log "Checking for incomplete kernel update on $host..."

    local phase_file phase
    phase_file="/tmp/macpro-kernel-update.env"
    phase=$(remote__exec "$host" "cat $phase_file 2>/dev/null || echo 'NOT_FOUND'")

    if [ "$phase" = "NOT_FOUND" ]; then
        log "No incomplete kernel update found"
        return 0
    fi

    local phase_num
    phase_num=$(echo "$phase" | grep -oE '[0-9]+' | head -1)

    error "INCOMPLETE KERNEL UPDATE DETECTED"
    error "Update stopped at phase $phase_num of 7"

    echo ""
    echo "Recovery actions:"
    case "$phase_num" in
        1)
            echo "  - Phase 1: Only apt sources enabled"
            echo "  - Action: remote_toggle_apt_sources $host disable"
            ;;
        2)
            echo "  - Phase 2: Holds removed, sources enabled"
            echo "  - Action: remote_pin_kernel $host; remote_toggle_apt_sources $host disable"
            ;;
        3)
            echo "  - Phase 3: Kernel installed, holds removed"
            echo "  - Action: remote_pin_kernel $host; remote_toggle_apt_sources $host disable"
            echo "  - Check: dkms status broadcom-sta for current kernel"
            ;;
        4)
            echo "  - Phase 4: DKMS verified for new kernel"
            echo "  - Action: Reboot into new kernel or roll back GRUB default"
            echo "  - Check: ls /lib/modules/\$(uname -r)/updates/dkms/wl.ko"
            ;;
        5)
            echo "  - Phase 5: GRUB fallback configured"
            echo "  - Action: remote__exec $host 'sudo grub-reboot \u003cdesired_kernel\u003e'"
            ;;
        6)
            echo "  - Phase 6: Rebooted into new kernel"
            echo "  - Action: Complete phase 7 manually (pin kernel, disable sources)"
            echo "  - Then: rm $phase_file"
            ;;
    esac
    echo ""
    echo "To rollback: _remote_kernel_update_rollback $host $phase_num"

    return 1
}

## macOS Erasure

remote_erase_macos() {
    local host="${1:-macpro-linux}"
    local part_info part_type part_num root_part
    local macos_parts=""
    local errors=0

    warn "erase_macos: This will DELETE all macOS partitions and expand Ubuntu."
    warn "erase_macos: This CANNOT be undone."
    if ! tui_confirm "ERASE macOS" "This will permanently delete all macOS partitions\nand expand Ubuntu to use the full disk.\n\nThis CANNOT be undone.\n\nProceed?"; then
        log "macOS erase cancelled"
        return 1
    fi

    log "Step 1: Identifying partition layout on $host..."
    part_info=$(remote__exec "$host" "sudo sgdisk -p /dev/sda") || {
        error "Failed to read partition table"
        return 1
    }
    echo "$part_info"

    local root_part=""
    while IFS= read -r line; do
        part_num=$(echo "$line" | awk '{print $1}')
        part_type=$(echo "$line" | awk '{for(i=4;i<=NF;i++) printf "%s ",$i}')

        case "$part_type" in
            *"/"*" "*"/boot"*|*"/boot/efi"*)
                if echo "$line" | grep -q ' /$'; then
                    root_part="$part_num"
                elif echo "$line" | grep -q ' /boot/efi'; then
                    : # EFI partition — never delete
                elif echo "$line" | grep -q ' /boot$'; then
                    part_num=""
                fi
                ;;
        esac
    done <<EOF
$(remote__exec "$host" "lsblk -no NAME,MOUNTPOINT,FSTYPE,SIZE /dev/sda")
EOF

    macos_parts=$(remote__exec "$host" "sudo sgdisk -p /dev/sda | awk '\$3 ~ /7C3457EF|426F6F74|C12A7328/ || tolower(\$5) ~ /apfs|apple|hfs/ {print \$1}'") || true

    if [ -z "$macos_parts" ]; then
        log "No macOS partitions found on $host"
        return 0
    fi

    log "Step 2: Creating GPT backup and deleting macOS partitions..."

    remote__exec "$host" "sudo sgdisk -b /tmp/gpt-backup-\$(date +%Y%m%d%H%M%S).bin /dev/sda" || {
        error "Failed to create GPT backup"
        return 1
    }

    for pnum in $macos_parts; do
        local mount_check
        mount_check=$(remote__exec "$host" "lsblk -no MOUNTPOINT /dev/sda${pnum}" 2>/dev/null)
        case "$mount_check" in
            "/"|"/boot"|"/boot/efi")
                error "Partition $pnum is mounted at $mount_check — refusing to delete"
                errors=$((errors + 1))
                continue
                ;;
        esac

        log "Deleting macOS partition $pnum..."
        dry_run_exec "Deleting partition $pnum" \
            remote__exec "$host" "sudo sgdisk -d ${pnum} /dev/sda && sudo partprobe /dev/sda" || {
            error "Failed to delete partition $pnum"
            errors=$((errors + 1))
        }
    done

    if [ $errors -gt 0 ]; then
        error "Errors during partition deletion — aborting before resize"
        return 1
    fi

    log "Step 3: Expanding root partition..."
    root_part=$(remote__exec "$host" "lsblk -no NAME,MOUNTPOINT /dev/sda | grep ' /$' | awk '{print \$1}' | sed 's/sda//'") || {
        error "Cannot identify root partition"
        return 1
    }

    dry_run_exec "Expanding partition ${root_part}" \
        remote__exec "$host" "sudo growpart /dev/sda ${root_part} && sudo resize2fs /dev/sda${root_part}" || {
        error "Failed to expand root partition"
        return 1
    }

    log "Step 4: Updating GRUB and removing macOS boot entry..."
    remote__exec "$host" "sudo rm -f /etc/grub.d/40_macos" || true
    remote__exec "$host" "sudo update-grub" 2>/dev/null || true

    local macos_boot
    macos_boot=$(remote__exec "$host" "sudo LIBEFIVAR_OPS=efivarfs efibootmgr | grep -i macos | head -1 | grep -oE 'Boot[0-9A-F]+' | sed 's/Boot//'") || true
    if [ -n "$macos_boot" ]; then
        dry_run_exec "Removing macOS EFI boot entry" \
            remote__exec "$host" "sudo LIBEFIVAR_OPS=efivarfs efibootmgr --delete-bootnum --bootnum $macos_boot" || true
    fi

    remote__exec "$host" "sudo rm -f /usr/local/bin/boot-macos" || true

    log "Step 5: Verifying system integrity..."
    local wifi_ok root_ok grub_ok
    wifi_ok=$(remote__exec "$host" "ping -c 3 google.com >/dev/null 2>&1 && echo ok || echo FAIL")
    root_ok=$(remote__exec "$host" "df -h / | tail -1 | awk '{print \$5}'")
    grub_ok=$(remote__exec "$host" "grep -ic 'macos\|apple' /boot/grub/grub.cfg 2>/dev/null || echo 0")

    echo "WiFi: $wifi_ok"
    echo "Root usage: $root_ok"
    echo "GRUB macOS entries: $grub_ok"

    log "macOS erasure complete on $host. Reboot recommended."
    return 0
}

## Boot Management

remote_boot_macos() {
    local host
    host=$(remote__get_host "${1:-}")

    warn "This will reboot $host into macOS"
    read -rp "Type 'macos' to confirm: " confirm
    if [ "$confirm" != "macos" ]; then
        log "Operation cancelled"
        return 1
    fi

    log "Setting macOS as next boot device..."
    local boot_entry
    boot_entry=$(remote__exec "$host" "sudo LIBEFIVAR_OPS=efivarfs efibootmgr | grep -i macos | head -1 | grep -oE 'Boot[0-9A-F]+' | sed 's/Boot//'") || {
        error "Could not find macOS boot entry"
        return 1
    }

    if [ -z "$boot_entry" ]; then
        error "No macOS boot entry found in EFI"
        return 1
    fi

    dry_run_exec "Setting macOS as next boot device on $host" \
        remote__exec "$host" "sudo LIBEFIVAR_OPS=efivarfs efibootmgr --bootnext $boot_entry" || {
        error "Failed to set macOS as next boot device"
        return 1
    }

    log "Rebooting into macOS..."
    dry_run_exec "Rebooting $host into macOS" \
        remote__exec "$host" "sudo reboot" || true
}

## macOS Headless Readiness

remote_headless_verify() {
    local host
    host=$(remote__get_host "${1:-}")

    log "Running headless readiness verification on macOS host $host..."
    verify_headless_readiness "$host"
}
