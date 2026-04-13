#!/bin/bash
#
# lib/revert.sh - Cleanup and revert functions
#
# Provides revert_changes for cleaning up deployment artifacts
# and handle_revert_flag for the --revert command-line flag.
#
# Dependencies: lib/colors.sh, lib/utils.sh
#

source "${LIB_DIR:-./lib}/colors.sh"
source "${LIB_DIR:-./lib}/utils.sh"

ESP_NAME="${ESP_NAME:-CIDATA}"

revert_changes() {
    echo ""
    error "Reverting deployment changes..."
    local REVERT_ERRORS=0

    if [ "${DEPLOY_METHOD:-}" = "1" ]; then
        # Internal partition method cleanup
        if [ -z "${INTERNAL_DISK:-}" ]; then
            INTERNAL_DISK=$(diskutil list | grep -E 'internal.*physical' | head -1 | grep -oE '/dev/disk[0-9]+' || true)
        fi

        if [ "${_ESP_CREATED:-0}" -eq 1 ] && [ -n "${INTERNAL_DISK:-}" ]; then
            local ESP_REVERT_DEV
            ESP_REVERT_DEV=$(diskutil list "$INTERNAL_DISK" 2>/dev/null | grep "$ESP_NAME" | grep -oE 'disk[0-9]+s[0-9]+' | head -1 || true)
            if [ -n "$ESP_REVERT_DEV" ]; then
                log "Removing ESP partition /dev/$ESP_REVERT_DEV..."
                diskutil unmount "/dev/$ESP_REVERT_DEV" 2>/dev/null || true
                diskutil eraseVolume free none "/dev/$ESP_REVERT_DEV" 2>/dev/null || {
                    warn "Could not remove ESP partition /dev/$ESP_REVERT_DEV"
                    REVERT_ERRORS=1
                }
            fi
            _ESP_CREATED=0
        fi

        if [ "${_APFS_RESIZED:-0}" -eq 1 ] && [ -n "${APFS_CONTAINER:-}" ] && [ -n "${_APFS_ORIGINAL_SIZE:-}" ]; then
            log "Restoring APFS container to ${_APFS_ORIGINAL_SIZE}GB..."
            diskutil apfs resizeContainer "$APFS_CONTAINER" "${_APFS_ORIGINAL_SIZE}g" 2>/dev/null || {
                warn "Could not restore APFS container size"
                REVERT_ERRORS=1
            }
            _APFS_RESIZED=0
        fi

        local MACOS_VOLUME="/"
        if [ -n "${APFS_CONTAINER:-}" ]; then
            MACOS_VOLUME=$(diskutil info "$APFS_CONTAINER" 2>/dev/null | grep "Mount Point" | awk '{print $NF}' || echo "/")
        fi
        if [ -d "$MACOS_VOLUME" ] && [ "$MACOS_VOLUME" != "/" ]; then
            bless --mount "$MACOS_VOLUME" --setBoot 2>/dev/null && \
                log "macOS boot device restored" || {
                warn "Could not restore macOS boot device"
                REVERT_ERRORS=1
            }
        else
            bless --mount / --setBoot 2>/dev/null && \
                log "macOS boot device restored (root fallback)" || {
                warn "Could not restore macOS boot device"
                REVERT_ERRORS=1
            }
        fi
    elif [ "${DEPLOY_METHOD:-}" = "2" ] && [ -n "${TARGET_DEVICE:-}" ]; then
        # USB method cleanup - unmount but don't erase USB
        log "Unmounting USB device $TARGET_DEVICE..."
        diskutil unmountDisk "$TARGET_DEVICE" 2>/dev/null || true
    elif [ "${DEPLOY_METHOD:-}" = "4" ]; then
        # VM test cleanup — just power off VM if running
        if command -v VBoxManage >/dev/null 2>1; then
            VBoxManage controlvm macpro-vmtest poweroff 2>/dev/null || true
        fi
    fi

    if [ "$REVERT_ERRORS" -eq 0 ]; then
        log "Revert complete"
    else
        error "Revert incomplete — some changes may require manual cleanup"
    fi
}

cleanup_on_error() {
    [ "${_CLEANUP_DONE:-0}" -eq 1 ] && return
    _CLEANUP_DONE=1
    local EXIT_CODE=$?
    if [ "$EXIT_CODE" -ne 0 ]; then
        revert_changes
        error "Deployment failed (exit code $EXIT_CODE)."
    fi
}

handle_revert_flag() {
    # Handle --revert flag for manual rollback
    if [ "${1:-}" = "--revert" ]; then
        log "Manual revert requested..."
        INTERNAL_DISK=$(diskutil list | grep -E 'internal.*physical' | head -1 | grep -oE '/dev/disk[0-9]+' || true)
        if [ -z "${INTERNAL_DISK:-}" ]; then
            die "Cannot identify internal disk for revert"
        fi

        local APFS_PARTITION
        APFS_PARTITION=$(diskutil list "$INTERNAL_DISK" | grep -i "APFS" | grep -oE 'disk[0-9]+s[0-9]+' | head -1 || true)
        if [ -n "${APFS_PARTITION:-}" ]; then
            APFS_CONTAINER=$(diskutil info "$APFS_PARTITION" 2>/dev/null | grep -i "container" | grep -oE 'disk[0-9]+' | head -1 || true)
        fi
        if [ -z "${APFS_CONTAINER:-}" ]; then
            APFS_CONTAINER=$(diskutil list | grep -i "APFS" | grep -oE 'disk[0-9]+' | head -1 || true)
        fi

        # Find and remove the CIDATA ESP partition
        local ESP_CANDIDATE
        ESP_CANDIDATE=$(diskutil list "$INTERNAL_DISK" 2>/dev/null | grep "$ESP_NAME" | grep -oE 'disk[0-9]+s[0-9]+' | head -1 || true)
        if [ -n "${ESP_CANDIDATE:-}" ]; then
            log "Removing ESP partition /dev/$ESP_CANDIDATE..."
            diskutil unmount "/dev/$ESP_CANDIDATE" 2>/dev/null || true
            diskutil eraseVolume free none "/dev/$ESP_CANDIDATE" 2>/dev/null || warn "Could not remove /dev/$ESP_CANDIDATE"
        else
            warn "No $ESP_NAME partition found"
        fi

        # Restore macOS boot device
        local MACOS_VOLUME
        MACOS_VOLUME=$(diskutil info "${APFS_CONTAINER:-}" 2>/dev/null | grep "Mount Point" | awk '{print $NF}' || echo "/")
        if [ -d "$MACOS_VOLUME" ] && [ "$MACOS_VOLUME" != "/" ]; then
            bless --mount "$MACOS_VOLUME" --setBoot 2>/dev/null && log "macOS boot device restored" || warn "Could not restore macOS boot device"
        else
            bless --mount / --setBoot 2>/dev/null && log "macOS boot device restored" || warn "Could not restore macOS boot device"
        fi

        log "Revert complete"
        exit 0
    fi
}
