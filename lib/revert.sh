#!/bin/bash
#
# lib/revert.sh - Cleanup and revert functions
#
# Provides revert_changes for cleaning up deployment artifacts
# and handle_revert_flag for the --revert command-line flag.
#
# Dependencies: lib/colors.sh, lib/logging.sh
#

[ "${_REVERT_SH_SOURCED:-0}" -eq 1 ] && return 0
_REVERT_SH_SOURCED=1

source "${LIB_DIR:-./lib}/colors.sh"
source "${LIB_DIR:-./lib}/logging.sh"
source "${LIB_DIR:-./lib}/rollback.sh" 2>/dev/null || true
source "${LIB_DIR:-./lib}/dryrun.sh"
source "${LIB_DIR:-./lib}/remote_mac.sh"

: "${ESP_NAME:=CIDATA}"

revert_changes() {
    # Load journal state at start
    journal_read

    error "Reverting deployment changes..."
    local REVERT_ERRORS=0

    # Determine deploy method from journal or fallback to variable
    local deploy_method="${JOURNAL_DEPLOY_METHOD:-${DEPLOY_METHOD:-}}"

    if [ "$deploy_method" = "1" ] || [ "$deploy_method" = "internal" ]; then
        # Internal partition method cleanup
        if [ -z "${INTERNAL_DISK:-}" ]; then
            INTERNAL_DISK=$(remote_mac_exec diskutil list | grep -E 'internal.*physical' | head -1 | grep -oE '/dev/disk[0-9]+' || true)
        fi

        # Prefer journal values over runtime variables
        local esp_created="${JOURNAL_ESP_CREATED:-${_ESP_CREATED:-0}}"
        local esp_device="${JOURNAL_ESP_DEVICE:-}"
        local apfs_resized="${JOURNAL_APFS_RESIZED:-${_APFS_RESIZED:-0}}"
        local apfs_container="${JOURNAL_ORIGINAL_APFS_CONTAINER:-${APFS_CONTAINER:-}}"
        local original_size="${JOURNAL_ORIGINAL_APFS_SIZE:-${_APFS_ORIGINAL_SIZE:-}}"

        # ESP removal with self-healing (try to mount if not found)
        if [ "$esp_created" = "1" ]; then
            if [ -z "$esp_device" ] && [ -n "${INTERNAL_DISK:-}" ]; then
                esp_device=$(remote_mac_exec diskutil list "$INTERNAL_DISK" 2>/dev/null | grep "$ESP_NAME" | grep -oE 'disk[0-9]+s[0-9]+' | head -1 || true)
            fi

            if [ -n "$esp_device" ]; then
                log "Removing ESP partition /dev/$esp_device..."

                # Self-healing: try to mount ESP if it's not mounted
                local mount_point
                mount_point=$(remote_mac_exec diskutil info "/dev/$esp_device" 2>/dev/null | grep "Mount Point" | awk '{print $NF}' || true)
                if [ -z "$mount_point" ] || [ "$mount_point" = "N/A" ]; then
                    log "ESP not mounted, attempting to mount..."
                    remote_mac_sudo diskutil mount "/dev/$esp_device" 2>/dev/null || true
                fi

remote_mac_sudo diskutil unmount "/dev/$esp_device" 2>/dev/null || true
                dry_run_exec "Remove ESP partition /dev/$esp_device" \
                    remote_mac_sudo diskutil eraseVolume free none "/dev/$esp_device" 2>/dev/null || {
                    warn "Could not remove ESP partition /dev/$esp_device"
                    REVERT_ERRORS=1
                }
            else
                warn "ESP device not found for removal"
                REVERT_ERRORS=1
            fi
            _ESP_CREATED=0
        fi

        # APFS container restoration - prefer journal values
        if [ "$apfs_resized" = "1" ] && [ -n "$apfs_container" ] && [ -n "$original_size" ]; then
            log "Restoring APFS container to ${original_size}GB..."
            dry_run_exec "Restore APFS container to ${original_size}GB" \
                remote_mac_sudo diskutil apfs resizeContainer "$apfs_container" "${original_size}g" 2>/dev/null || {
                warn "Could not restore APFS container size"
                REVERT_ERRORS=1
            }
            _APFS_RESIZED=0
        fi

        # After ESP removal, expand APFS to fill freed space
        if [ -n "$apfs_container" ]; then
            log "Expanding APFS container to fill available space..."
            dry_run_exec "Expand APFS container to fill free space" \
                remote_mac_sudo diskutil apfs resizeContainer "$apfs_container" 0 2>/dev/null || {
                warn "Could not expand APFS container to fill space"
                REVERT_ERRORS=1
            }
        fi

        # Restore macOS boot device
        local MACOS_VOLUME="/"
        if [ -n "$apfs_container" ]; then
            MACOS_VOLUME=$(remote_mac_exec diskutil info "$apfs_container" 2>/dev/null | grep "Mount Point" | awk '{print $NF}' || echo "/")
        fi
        if [ -d "$MACOS_VOLUME" ] && [ "$MACOS_VOLUME" != "/" ]; then
            dry_run_exec "Restore macOS boot device" \
                remote_mac_sudo bless --mount "$MACOS_VOLUME" --setBoot 2>/dev/null && \
                log "macOS boot device restored" || {
                warn "Could not restore macOS boot device"
                REVERT_ERRORS=1
            }
        else
            dry_run_exec "Restore macOS boot device (root fallback)" \
                remote_mac_sudo bless --mount / --setBoot 2>/dev/null && \
                log "macOS boot device restored (root fallback)" || {
                warn "Could not restore macOS boot device"
                REVERT_ERRORS=1
            }
        fi
    elif [ "$deploy_method" = "2" ] || [ "$deploy_method" = "usb" ]; then
        # USB method cleanup - use rollback_usb from rollback.sh
        if command -v rollback_usb >/dev/null 2>&1; then
            rollback_usb
        else
            # Fallback: just unmount
            local usb_device="${JOURNAL_USB_DEVICE:-${TARGET_DEVICE:-}}"
            if [ -n "$usb_device" ]; then
                log "Unmounting USB device $usb_device..."
                remote_mac_sudo diskutil unmountDisk "$usb_device" 2>/dev/null || true
            else
                warn "USB device not found for cleanup"
            fi
        fi
    elif [ "$deploy_method" = "4" ] || [ "$deploy_method" = "vm" ]; then
        # VM test cleanup - use rollback_vm from rollback.sh
        if command -v rollback_vm >/dev/null 2>&1; then
            rollback_vm
        else
            # Fallback: just power off
            if command -v VBoxManage >/dev/null 2>&1; then
                VBoxManage controlvm macpro-vmtest poweroff 2>/dev/null || true
            fi
        fi
    fi

    if [ "${REVERT_ERRORS:-0}" -eq 0 ]; then
        log "Revert complete"
    else
        error "Revert incomplete — some changes may require manual cleanup"
    fi
}

cleanup_on_error() {
    local EXIT_CODE=$?
    [ "${_CLEANUP_DONE:-0}" -eq 1 ] && return
    _CLEANUP_DONE=1

    # Trigger rollback for any error or signal exit (>=128 is signal-caused)
    if [ "$EXIT_CODE" -ne 0 ] || [ "$EXIT_CODE" -ge 128 ]; then
        # Skip rollback for agent remote operations (sysinfo, kernel_status, etc.)
        # These don't modify local disk state so there's nothing to roll back
        if [ "${AGENT_MODE:-0}" -eq 1 ] && [ -n "${REMOTE_OPERATION:-}" ]; then
            if [ "$EXIT_CODE" -ge 128 ]; then
                local signal_num=$((EXIT_CODE - 128))
                warn "Agent operation interrupted by signal $signal_num (exit code $EXIT_CODE)"
            fi
            return
        fi

        log "Cleanup triggered (exit code $EXIT_CODE)"

        # Use rollback_from_journal if available (more comprehensive)
        if command -v rollback_from_journal >/dev/null 2>&1; then
            rollback_from_journal
        else
            # Fallback to basic revert
            revert_changes
        fi

        # Destroy journal after successful rollback
        if command -v journal_destroy >/dev/null 2>&1; then
            journal_destroy
        fi

        if [ "$EXIT_CODE" -ge 128 ]; then
            # Signal exit codes: 130=SIGINT, 143=SIGTERM, etc.
            local signal_num=$((EXIT_CODE - 128))
            warn "Deployment interrupted by signal $signal_num (exit code $EXIT_CODE)"
        else
            error "Deployment failed (exit code $EXIT_CODE)."
        fi
    fi
}

handle_revert_flag() {
    # Handle --revert flag for manual rollback
    if [ "${1:-}" = "--revert" ]; then
        log "Manual revert requested..."

        # Load journal state first
        if command -v journal_read >/dev/null 2>&1; then
            journal_read
        fi

        # Use journal values when available, fall back to disk detection
        local internal_disk="${JOURNAL_INTERNAL_DISK:-}"
        local apfs_container="${JOURNAL_ORIGINAL_APFS_CONTAINER:-}"
        local original_size="${JOURNAL_ORIGINAL_APFS_SIZE:-}"
        local esp_device="${JOURNAL_ESP_DEVICE:-}"

        # Fallback to disk detection if journal values missing
        if [ -z "$internal_disk" ]; then
            internal_disk=$(remote_mac_exec diskutil list | grep -E 'internal.*physical' | head -1 | grep -oE '/dev/disk[0-9]+' || true)
        fi
        if [ -z "${internal_disk:-}" ]; then
            die "Cannot identify internal disk for revert"
        fi

        if [ -z "$apfs_container" ]; then
            local APFS_PARTITION
            APFS_PARTITION=$(remote_mac_exec diskutil list "$internal_disk" | grep -i "APFS" | grep -oE 'disk[0-9]+s[0-9]+' | head -1 || true)
            if [ -n "${APFS_PARTITION:-}" ]; then
                apfs_container=$(remote_mac_exec diskutil info "$APFS_PARTITION" 2>/dev/null | grep -i "container" | grep -oE 'disk[0-9]+' | head -1 || true)
            fi
            if [ -z "${apfs_container:-}" ]; then
                apfs_container=$(remote_mac_exec diskutil list | grep -i "APFS" | grep -oE 'disk[0-9]+' | head -1 || true)
            fi
        fi

        # Find ESP - prefer journal, then detect
        if [ -z "$esp_device" ]; then
            esp_device=$(remote_mac_exec diskutil list "$internal_disk" 2>/dev/null | grep "$ESP_NAME" | grep -oE 'disk[0-9]+s[0-9]+' | head -1 || true)
        fi

        if [ -n "${esp_device:-}" ]; then
            log "Removing ESP partition /dev/$esp_device..."
            remote_mac_sudo diskutil unmount "/dev/$esp_device" 2>/dev/null || true
            dry_run_exec "Erase ESP partition /dev/$esp_device" remote_mac_sudo diskutil eraseVolume free none "/dev/$esp_device" 2>/dev/null || warn "Could not remove ESP partition /dev/$esp_device"
        else
            warn "No $ESP_NAME partition found"
        fi

        # Restore macOS boot device
        local MACOS_VOLUME
        MACOS_VOLUME=$(remote_mac_exec diskutil info "${apfs_container:-}" 2>/dev/null | grep "Mount Point" | awk '{print $NF}' || echo "/")
        if [ -d "$MACOS_VOLUME" ] && [ "$MACOS_VOLUME" != "/" ]; then
            dry_run_exec "Restore macOS boot device" remote_mac_sudo bless --mount "$MACOS_VOLUME" --setBoot 2>/dev/null && log "macOS boot device restored" || warn "Could not restore macOS boot device"
        else
            dry_run_exec "Restore macOS boot device" remote_mac_sudo bless --mount / --setBoot 2>/dev/null && log "macOS boot device restored" || warn "Could not restore macOS boot device"
        fi

        # Restore APFS container to fill freed space (use original size if available)
        if [ -n "${apfs_container:-}" ]; then
            if [ -n "${original_size:-}" ]; then
                log "Restoring APFS container to ${original_size}GB, then expanding..."
                dry_run_exec "Resize APFS container to ${original_size}GB" remote_mac_sudo diskutil apfs resizeContainer "$apfs_container" "${original_size}g" 2>/dev/null || true
            fi

            local CURRENT_APFS_GB
            CURRENT_APFS_GB=$(remote_mac_exec diskutil info "$apfs_container" 2>/dev/null | grep "Disk Size" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1 || true)
            log "Current APFS container: ${CURRENT_APFS_GB:-unknown}GB — expanding to fill free space..."
            dry_run_exec "Expand APFS container to fill free space" remote_mac_sudo diskutil apfs resizeContainer "$apfs_container" 0 2>/dev/null && \
                log "APFS container expanded to fill freed space" || \
                warn "Could not expand APFS container (space may need manual recovery)"
        fi

        # Destroy journal after successful revert
        if command -v journal_destroy >/dev/null 2>&1; then
            journal_destroy
        fi

        log "Revert complete"
        exit 0
    fi
}
