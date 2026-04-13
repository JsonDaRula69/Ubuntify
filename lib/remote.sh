#!/bin/bash
#
# lib/remote.sh - SSH remote management module for Mac Pro Ubuntu deployment
#
# Provides functions for managing a remote Mac Pro 2013 running Ubuntu via SSH.
# This module is called from prepare-deployment.sh's "Manage" mode.
# All functions execute commands on the remote instance.
#
# Dependencies: lib/colors.sh, lib/utils.sh
#

[ "${_REMOTE_SH_SOURCED:-0}" -eq 1 ] && return 0
_REMOTE_SH_SOURCED=1

source "${LIB_DIR:-./lib}/colors.sh"
source "${LIB_DIR:-./lib}/utils.sh"

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
    local host="$1"
    shift
    local cmd="$*"
    local ssh_cmd
    ssh_cmd=$(remote__ssh_cmd "$host")
    $ssh_cmd "$cmd"
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

    local kernel pinned held prefs

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

    remote__exec "$host" "sudo apt-mark unhold linux-image-${kver} 2>/dev/null || true"
    remote__exec "$host" "sudo apt-mark unhold linux-headers-${kver} 2>/dev/null || true"
    remote__exec "$host" "sudo apt-mark unhold linux-modules-${kver} 2>/dev/null || true"
    remote__exec "$host" "sudo apt-mark unhold linux-modules-extra-${kver} 2>/dev/null || true"
    remote__exec "$host" "sudo rm /etc/apt/preferences.d/99-pin-kernel 2>/dev/null || true"
    remote__exec "$host" "sudo systemctl unmask apt-daily.service apt-daily.timer 2>/dev/null || true"
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

    remote__exec "$host" "sudo apt-mark hold linux-image-${kver}"
    remote__exec "$host" "sudo apt-mark hold linux-headers-${kver}"
    remote__exec "$host" "sudo apt-mark hold linux-modules-${kver}"
    remote__exec "$host" "sudo apt-mark hold linux-modules-extra-${kver} 2>/dev/null || true"

    remote__exec "$host" "sudo tee /etc/apt/preferences.d/99-pin-kernel > /dev/null << 'PREFS'
Package: linux-image-*
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
Pin-Priority: 1001
PREFS"

    remote__exec "$host" "sudo sed -i '/^deb/ s/^/#/' /etc/apt/sources.list"
    remote__exec "$host" "for list in /etc/apt/sources.list.d/*.list; do [ -f \"\$list\" ] && sudo sed -i '/^deb/ s/^/#/' \"\$list\"; done"
    remote__exec "$host" "sudo systemctl mask apt-daily.service 2>/dev/null || true"
    remote__exec "$host" "sudo systemctl mask apt-daily.timer 2>/dev/null || true"
    remote__exec "$host" "sudo systemctl mask apt-daily-upgrade.service 2>/dev/null || true"
    remote__exec "$host" "sudo systemctl mask apt-daily-upgrade.timer 2>/dev/null || true"

    log "Kernel re-pinned successfully"
}

remote_kernel_update() {
    local host
    host=$(remote__get_host "${1:-}")

    error "WARNING: Full kernel update is a multi-phase process with ROLLBACK capability required."
    error "This function must be run interactively with Phase 1-7 verification."
    error "Please follow the process in How-to-Update.md manually."
    echo ""
    log "Summary of phases:"
    echo "  Phase 1: Enable apt sources"
    echo "  Phase 2: Remove holds and pinning (remote_kernel_unpin)"
    echo "  Phase 3: apt-get dist-upgrade"
    echo "  Phase 4: Verify DKMS built wl.ko for new kernel"
    echo "  Phase 5: Configure GRUB fallback (old kernel = default)"
    echo "  Phase 6: grub-reboot into new kernel (one-time)"
    echo "  Phase 7: Re-lock system (holds, preferences, sources)"
    echo ""
    warn "Use remote_kernel_unpin for Phase 2, then run remaining phases manually."
    return 1
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

    log "Enabling apt sources on $host..."
    remote__exec "$host" "sudo sed -i 's/^#deb/deb/' /etc/apt/sources.list"
    remote__exec "$host" "for list in /etc/apt/sources.list.d/*.list; do [ -f \"\$list\" ] && sudo sed -i 's/^#deb/deb/' \"\$list\"; done"

    log "Running apt-get update..."
    remote__exec "$host" "sudo apt-get update" || { error "apt-get update failed"; return 1; }

    log "Upgrading non-kernel packages..."
    remote__exec "$host" "sudo apt-get upgrade -y --exclude=linux-image-*,linux-headers-*,linux-modules-*" || { error "Upgrade failed"; return 1; }

    log "Disabling apt sources..."
    remote__exec "$host" "sudo sed -i '/^deb/ s/^/#/' /etc/apt/sources.list"
    remote__exec "$host" "for list in /etc/apt/sources.list.d/*.list; do [ -f \"\$list\" ] && sudo sed -i '/^deb/ s/^/#/' \"\$list\"; done"

    log "Non-kernel update completed successfully"
}

## WiFi/Driver Management

remote_driver_status() {
    local host
    host=$(remote__get_host "${1:-}")

    log "Checking driver status on $host..."
    echo ""

    local wl_loaded dkms_status wifi_iface

    wl_loaded=$(remote__exec "$host" "lsmod | grep -q wl && echo 'loaded' || echo 'NOT loaded'")
    dkms_status=$(remote__exec "$host" "dkms status broadcom-sta 2>/dev/null || echo 'Not installed'")
    wifi_iface=$(remote__exec "$host" "ip link show | grep -E 'wlan|wlp' | head -1 | awk -F: '{print \$2}' | tr -d ' '") || wifi_iface=""

    echo "=== Driver Status ==="
    echo "  wl module: $wl_loaded"
    echo "  DKMS status: $dkms_status"
    echo "  WiFi interface: ${wifi_iface:-Not detected}"
    echo ""
}

remote_driver_rebuild() {
    local host
    host=$(remote__get_host "${1:-}")

    warn "This will rebuild the DKMS module for the current kernel"
    read -rp "Type 'yes' to confirm: " confirm
    if [ "$confirm" != "yes" ]; then
        log "Operation cancelled"
        return 1
    fi

    log "Rebuilding DKMS module on $host..."

    local kver
    kver=$(remote__exec "$host" "uname -r") || { error "Failed to get kernel version"; return 1; }

    remote__exec "$host" "sudo dkms build broadcom-sta/6.30.223.271 -k $kver" || {
        error "DKMS build failed"
        return 1
    }

    remote__exec "$host" "sudo dkms install broadcom-sta/6.30.223.271 -k $kver" || {
        error "DKMS install failed"
        return 1
    }

    remote__exec "$host" "sudo modprobe wl" || {
        error "Failed to load wl module"
        return 1
    }

    log "Driver rebuilt and loaded successfully"
}

## macOS Erasure

remote_erase_macos() {
    local host
    host=$(remote__get_host "${1:-}")

    error "=== DANGER: macOS PARTITION ERASURE ==="
    error "This will PERMANENTLY DELETE all macOS partitions"
    error "This action CANNOT be undone"
    echo ""

    remote_get_info "$host" || return 1

    log "Gathering partition information..."
    echo ""

    local partitions
    partitions=$(remote__exec "$host" "lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT /dev/sda && echo '---' && sudo sgdisk -p /dev/sda") || {
        error "Failed to get partition information"
        return 1
    }

    echo "$partitions"
    echo ""

    error "Review the partition table above. The following will be DELETED:"
    echo "  - APFS partitions (macOS)"
    echo "  - Apple Boot/Recovery partitions"
    echo "  - Any partition with FSTYPE=apfs or Apple GUIDs"
    echo ""
    warn "Partitions mounted at /, /boot, /boot/efi will NOT be deleted"
    echo ""

    read -rp "Type 'ERASE MACOS' to confirm PERMANENT deletion: " confirm
    if [ "$confirm" != "ERASE MACOS" ]; then
        log "Operation cancelled"
        return 1
    fi

    warn "Starting macOS partition erasure..."

    remote__exec "$host" "sudo sgdisk -b /tmp/gpt-backup-\$(date +%Y%m%d%H%M%S).bin /dev/sda" || {
        error "Failed to backup GPT"
        return 1
    }

    log "GPT backup saved on remote host"
    warn "Now deleting macOS partitions one at a time..."
    warn "You must identify partition numbers manually from the output above"
    echo ""
    error "Manual intervention required: SSH to $host and follow Post-Install.md Operation 1"
    error "This automated function stops here for safety."
    return 1
}

## APT Source Management

remote_apt_enable() {
    local host
    host=$(remote__get_host "${1:-}")

    log "Enabling apt sources on $host..."

    remote__exec "$host" "sudo sed -i 's/^#deb/deb/' /etc/apt/sources.list"
    remote__exec "$host" "for list in /etc/apt/sources.list.d/*.list; do [ -f \"\$list\" ] && sudo sed -i 's/^#deb/deb/' \"\$list\"; done"

    log "Apt sources enabled"
}

remote_apt_disable() {
    local host
    host=$(remote__get_host "${1:-}")

    log "Disabling apt sources on $host..."

    remote__exec "$host" "sudo sed -i '/^deb/ s/^/#/' /etc/apt/sources.list"
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
    remote__exec "$host" "sudo reboot" || true

    log "Reboot command sent. Waiting for host to go down..."
    sleep 5

    local attempts=0
    local max_attempts=30

    while [ $attempts -lt $max_attempts ]; do
        if remote_test_connection "$host" 2>/dev/null; then
            log "Host is back online"
            remote_health_check "$host"
            return 0
        fi
        echo "  Waiting for $host to come back... ($attempts/$max_attempts)"
        sleep 10
        attempts=$((attempts + 1))
    done

    error "Host did not come back online within timeout"
    return 1
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
    remote__exec "$host" "sudo LIBEFIVAR_OPS=efivarfs efibootmgr --bootnext \$(sudo LIBEFIVAR_OPS=efivarfs efibootmgr | grep -i macos | head -1 | grep -oE 'Boot[0-9A-F]+' | sed 's/Boot//')" || {
        error "Failed to set macOS boot entry"
        return 1
    }

    log "Rebooting into macOS..."
    remote__exec "$host" "sudo reboot" || true
}
