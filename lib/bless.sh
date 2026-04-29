#!/bin/bash
#
# lib/bless.sh - Boot device configuration functions
#
# Provides verify_esp_contents for validating ESP files and
# attempt_bless for setting the boot device on macOS.
#
# Dependencies: lib/colors.sh, lib/logging.sh
#

[ "${_BLESS_SH_SOURCED:-0}" -eq 1 ] && return 0
_BLESS_SH_SOURCED=1

source "${LIB_DIR:-./lib}/colors.sh"
source "${LIB_DIR:-./lib}/logging.sh"
source "${LIB_DIR:-./lib}/dryrun.sh"
source "${LIB_DIR:-./lib}/remote_mac.sh"

: "${ESP_NAME:=CIDATA}"

verify_esp_contents() {
    local ESP_MOUNT="$1"

    log "Verifying ESP contents..."

    local is_remote=0
    if [ -n "${TARGET_HOST:-}" ]; then
        is_remote=1
    fi

    _vec_file_exists() {
        local path="$1"
        if [ "$is_remote" -eq 1 ]; then
            remote_mac_file_exists "$path"
        else
            [ -f "$path" ]
        fi
    }

    local REQUIRED_FILES=(
        "EFI/boot/bootx64.efi"
        "EFI/boot/grub.cfg"
        "casper/vmlinuz"
        "casper/initrd"
        "user-data"
        "meta-data"
        "autoinstall.yaml"
        "cidata/user-data"
        "cidata/meta-data"
    )

    local ALL_OK=true
    for f in "${REQUIRED_FILES[@]}"; do
        if _vec_file_exists "$ESP_MOUNT/$f" || _vec_file_exists "$ESP_MOUNT/$(echo "$f" | tr '[:lower:]' '[:upper:]')"; then
            log "  ✓ $f"
        else
            warn "  ✗ $f (not found)"
            ALL_OK=false
        fi
    done

    if [ "$is_remote" -eq 1 ]; then
        if remote_mac_exec "test -n \"\$(ls $ESP_MOUNT/macpro-pkgs/broadcom-sta-dkms_*.deb 2>/dev/null)\""; then
            log "  ✓ macpro-pkgs/broadcom-sta-dkms_*.deb"
        else
            warn "  ✗ macpro-pkgs/broadcom-sta-dkms (not found)"
            ALL_OK=false
        fi

        local PATCH_SERIES_OK
        PATCH_SERIES_OK=$(remote_mac_exec "test -f $ESP_MOUNT/macpro-pkgs/dkms-patches/series && echo ok || echo fail" 2>/dev/null || echo "fail")
        if [ "$PATCH_SERIES_OK" = "ok" ]; then
            local PATCH_COUNT
            PATCH_COUNT=$(remote_mac_exec "ls $ESP_MOUNT/macpro-pkgs/dkms-patches/*.patch 2>/dev/null | wc -l | tr -d ' '" 2>/dev/null || echo "0")
            log "  ✓ macpro-pkgs/dkms-patches/ ($PATCH_COUNT patches)"
        else
            warn "  ✗ macpro-pkgs/dkms-patches/ (missing)"
            ALL_OK=false
        fi
    else
        if ls "$ESP_MOUNT/macpro-pkgs/"broadcom-sta-dkms_*.deb 1>/dev/null 2>&1; then
            log "  ✓ macpro-pkgs/broadcom-sta-dkms_*.deb"
        else
            warn "  ✗ macpro-pkgs/broadcom-sta-dkms (not found)"
            ALL_OK=false
        fi

        if [ -f "$ESP_MOUNT/macpro-pkgs/dkms-patches/series" ]; then
            local PATCH_COUNT
            PATCH_COUNT=$(ls "$ESP_MOUNT/macpro-pkgs/dkms-patches/"*.patch 2>/dev/null | wc -l | tr -d ' ')
            log "  ✓ macpro-pkgs/dkms-patches/ ($PATCH_COUNT patches)"
        else
            warn "  ✗ macpro-pkgs/dkms-patches/ (missing)"
            ALL_OK=false
        fi
    fi

    if [ "$ALL_OK" = "false" ]; then
        die "Critical boot files missing from ESP"
    fi
}

attempt_bless() {
    local ESP_MOUNT="$1"
    local ESP_DEVICE="$2"

    log "Attempting to set boot device..."

    local BLESS_OK=0

    # Method 1: systemsetup
    if command -v systemsetup >/dev/null 2>&1; then
        log "Attempting systemsetup..."
        if dry_run_exec "Setting startup disk via systemsetup" \
            remote_mac_sudo systemsetup -setstartupdisk "$ESP_MOUNT" 2>/dev/null; then
            log "systemsetup succeeded"
            BLESS_OK=1
        fi
    fi

    # Method 2: bless --nextonly
    if [ "$BLESS_OK" -eq 0 ]; then
        log "Attempting bless --nextonly..."
        if dry_run_exec "Setting boot device via bless --nextonly" \
            remote_mac_sudo bless --verbose --setBoot --mount "$ESP_MOUNT" --file "$ESP_MOUNT/EFI/boot/bootx64.efi" --nextonly 2>/dev/null; then
            BLESS_OK=1
        else
      # Bless may fail due to system restrictions
      log "bless --nextonly failed — boot device must be selected manually"
        fi
    fi

    # Method 3: bless --device
    if [ "$BLESS_OK" -eq 0 ]; then
        log "Attempting bless --device..."
        if dry_run_exec "Setting boot device via bless --device" \
            remote_mac_sudo bless --verbose --device "/dev/$ESP_DEVICE" --setBoot --nextonly 2>/dev/null; then
            BLESS_OK=1
        else
            log "bless --device also failed"
        fi
    fi

    echo "$BLESS_OK"
}
