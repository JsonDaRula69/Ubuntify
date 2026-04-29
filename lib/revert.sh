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
                    mount_point="/Volumes/CIDATA"
                    remote_mac_exec mkdir -p "$mount_point" 2>/dev/null || true
                    remote_mac_sudo mount_msdos "/dev/$esp_device" "$mount_point" 2>/dev/null || \
                        remote_mac_sudo diskutil mount "/dev/$esp_device" 2>/dev/null || true
                fi

                remote_mac_sudo diskutil unmount "/dev/$esp_device" 2>/dev/null || true
                dry_run_exec "Remove ESP partition /dev/$esp_device" \
                    remote_mac_sudo diskutil eraseVolume free none "/dev/$esp_device" 2>/dev/null || true
                # Verify ESP actually removed — diskutil eraseVolume can return non-zero on success
                if remote_mac_exec diskutil list 2>/dev/null | grep -q "$esp_device"; then
                    warn "ESP partition /dev/$esp_device still present after erase"
                    REVERT_ERRORS=1
                fi
            else
                warn "ESP device not found for removal"
                REVERT_ERRORS=1
            fi
            _ESP_CREATED=0
        fi

        # Remove leftover Linux partitions created by Subiquity/curtin
        # diskutil eraseVolume hides from macOS but leaves stale GPT entries;
        # the Linux kernel finds them at boot — use gpt remove to scrub.
        local _gpt_linux_indices
        _gpt_linux_indices=$(remote_mac_sudo "gpt -r show $INTERNAL_DISK 2>/dev/null | awk '/0FC63DAF|0657FD6D/{print \$3}'" || true)
        if [ -n "$_gpt_linux_indices" ]; then
            log "Found leftover Linux GPT entries — removing..."
            for _idx in $_gpt_linux_indices; do
                if ! [[ "$_idx" =~ ^[0-9]+$ ]] || [ "$_idx" -le 2 ]; then
                    warn "Skipping invalid GPT index $_idx — must be numeric and > 2"
                    continue
                fi
                dry_run_exec "Remove Linux GPT entry index $_idx" \
                    remote_mac_sudo "gpt remove -i $_idx $INTERNAL_DISK" 2>/dev/null || true
                log "Removed GPT entry index $_idx from $INTERNAL_DISK"
            done
        fi

        if [ "$apfs_resized" = "1" ] && [ -n "$apfs_container" ]; then
            log "Expanding APFS container to fill available space..."
            dry_run_exec "Expand APFS container to fill free space" \
                remote_mac_sudo diskutil apfs resizeContainer "$apfs_container" 0 2>/dev/null || true
            # Verify expansion — diskutil apfs resizeContainer can return non-zero on success
            sleep 2
            local _revert_size
            _revert_size=$(remote_mac_exec diskutil apfs list "$apfs_container" 2>/dev/null | grep "Size (Capacity Ceiling)" | awk '{print $4}' || true)
            if [ -z "$_revert_size" ]; then
                warn "Could not verify APFS container size after expansion"
                REVERT_ERRORS=1
            fi
            _APFS_RESIZED=0
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

    if [ "$EXIT_CODE" -eq 0 ]; then
        return
    fi

    # Deployment completed successfully — do NOT rollback
    if [ "${_DEPLOY_COMPLETED:-0}" -eq 1 ]; then
        if [ "$EXIT_CODE" -ge 128 ]; then
            local signal_num=$((EXIT_CODE - 128))
            log "Deployment completed — ignoring signal $signal_num (deploy already succeeded)"
        else
            log "Deployment completed — ignoring exit code $EXIT_CODE (deploy already succeeded)"
        fi
        return
    fi

    if [ "${AGENT_MODE:-0}" -eq 1 ] && [ -n "${REMOTE_OPERATION:-}" ]; then
        if [ "$EXIT_CODE" -ge 128 ]; then
            local signal_num=$((EXIT_CODE - 128))
            warn "Agent operation interrupted by signal $signal_num (exit code $EXIT_CODE)"
        fi
        return
    fi

    if [ "${_DEPLOY_STARTED:-0}" -ne 1 ]; then
        if [ "$EXIT_CODE" -ge 128 ]; then
            local signal_num=$((EXIT_CODE - 128))
            warn "Interrupted by signal $signal_num (exit code $EXIT_CODE) — no deployment to roll back"
        else
            warn "Exit code $EXIT_CODE — no deployment to roll back"
        fi
        return
    fi

    log "Cleanup triggered (exit code $EXIT_CODE)"

    if command -v rollback_from_journal >/dev/null 2>&1; then
        rollback_from_journal
    else
        revert_changes
        if command -v journal_destroy >/dev/null 2>&1; then
            journal_destroy
        fi
    fi

    if [ "$EXIT_CODE" -ge 128 ]; then
        local signal_num=$((EXIT_CODE - 128))
        warn "Deployment interrupted by signal $signal_num (exit code $EXIT_CODE)"
    else
        error "Deployment failed (exit code $EXIT_CODE)."
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
            dry_run_exec "Erase ESP partition /dev/$esp_device" remote_mac_sudo diskutil eraseVolume free none "/dev/$esp_device" 2>/dev/null || true
            if remote_mac_exec diskutil list 2>/dev/null | grep -q "$esp_device"; then
                warn "ESP partition /dev/$esp_device still present after erase"
            fi
        else
            warn "No $ESP_NAME partition found"
        fi

        # Remove leftover Linux partitions created by Subiquity/curtin
        local _linux_parts_rev
        _linux_parts_rev=$(remote_mac_exec "diskutil list $internal_disk 2>/dev/null | grep 'Linux Filesystem'" 2>/dev/null || true)
        if [ -n "$_linux_parts_rev" ]; then
            log "Found leftover Linux partitions — removing..."
            echo "$_linux_parts_rev" | while IFS= read -r _line; do
                _linux_dev=$(echo "$_line" | grep -oE 'disk[0-9]+s[0-9]+' | head -1)
                if [ -n "$_linux_dev" ]; then
                    dry_run_exec "Remove Linux partition /dev/${_linux_dev}" \
                        remote_mac_sudo diskutil eraseVolume free none "/dev/${_linux_dev}" 2>/dev/null || true
                    log "Removed Linux partition /dev/${_linux_dev}"
                fi
            done
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
