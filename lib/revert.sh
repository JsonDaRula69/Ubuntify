#!/bin/bash
#
# lib/revert.sh - Cleanup and revert functions
#
# Provides revert_changes for cleaning up deployment artifacts
# and handle_revert_flag for the --revert command-line flag.
#
# Dependencies: lib/colors.sh, lib/logging.sh, lib/rollback.sh, lib/dryrun.sh, lib/remote_mac.sh
#

[ "${_REVERT_SH_SOURCED:-0}" -eq 1 ] && return 0
_REVERT_SH_SOURCED=1

source "${LIB_DIR:-./lib}/colors.sh"
source "${LIB_DIR:-./lib}/logging.sh"
source "${LIB_DIR:-./lib}/rollback.sh" 2>/dev/null || true
source "${LIB_DIR:-./lib}/dryrun.sh"
source "${LIB_DIR:-./lib}/remote_mac.sh"

: "${ESP_NAME:=CIDATA}"

# ---------------------------------------------------------------------------
# Disk State Detection Helpers
# ---------------------------------------------------------------------------

# _detect_internal_disk
# Detects the internal disk device on the target Mac Pro
_detect_internal_disk() {
    if [ -n "${INTERNAL_DISK:-}" ]; then
        return 0
    fi
    INTERNAL_DISK=$(remote_mac_exec diskutil list | grep -E 'internal.*physical' | head -1 | grep -oE '/dev/disk[0-9]+' || true)
    if [ -z "$INTERNAL_DISK" ]; then
        # Fallback: look for the disk with an APFS partition
        INTERNAL_DISK=$(remote_mac_exec "diskutil list 2>/dev/null | grep -i APFS | head -1 | grep -oE '/dev/disk[0-9]+'" || true)
    fi
}

# _detect_apfs_container
# Detects the APFS container reference from the internal disk
_detect_apfs_container() {
    if [ -n "${APFS_CONTAINER:-}" ]; then
        return 0
    fi
    local apfs_partition
    apfs_partition=$(remote_mac_exec diskutil list "${INTERNAL_DISK:-}" 2>/dev/null | grep -i "APFS" | grep -oE 'disk[0-9]+s[0-9]+' | head -1 || true)
    if [ -n "$apfs_partition" ]; then
        APFS_CONTAINER=$(remote_mac_exec diskutil info "$apfs_partition" 2>/dev/null | grep -i "container" | grep -oE 'disk[0-9]+' | head -1 || true)
    fi
    if [ -z "$APFS_CONTAINER" ]; then
        APFS_CONTAINER=$(remote_mac_exec "diskutil list 2>/dev/null | grep -i APFS | head -1 | grep -oE 'disk[0-9]+'" || true)
    fi
}

# _detect_esp_device
# Detects the CIDATA ESP partition device from the internal disk
_detect_esp_device() {
    if [ -n "${ESP_DEVICE:-}" ]; then
        return 0
    fi
    ESP_DEVICE=$(remote_mac_exec diskutil list "${INTERNAL_DISK:-}" 2>/dev/null | grep "$ESP_NAME" | grep -oE 'disk[0-9]+s[0-9]+' | head -1 || true)
}

# _get_apfs_size_bytes
# Returns the APFS container size in bytes via diskutil apfs list
# Args: container_ref
_get_apfs_size_bytes() {
    local container="$1"
    remote_mac_exec diskutil apfs list "$container" 2>/dev/null | grep "Size (Capacity Ceiling)" | awk '{print $4}' || true
}

# _get_disk_total_bytes
# Returns the total disk size in bytes via diskutil info
# Args: disk_device (e.g. /dev/disk0)
_get_disk_total_bytes() {
    local disk="$1"
    # diskutil info outputs "Total Size: ... (NNNNNN Bytes)" or "Disk Size: ..." (varies by macOS version)
    remote_mac_exec diskutil info "$disk" 2>/dev/null | grep -E "Total Size|Disk Size" | head -1 | grep -oE '\([0-9]+ Bytes\)' | grep -oE '[0-9]+' || true
}

# _has_revertable_state
# Returns 0 if deployment artifacts exist on the internal disk that can be reverted
# Returns 1 if the system appears clean (no CIDATA, no Linux partitions, APFS near full)
# Requires INTERNAL_DISK to be set (call _detect_internal_disk first)
_has_revertable_state() {
    if [ -z "${INTERNAL_DISK:-}" ]; then
        return 1
    fi

    # Check for CIDATA partition
    if remote_mac_exec diskutil list "$INTERNAL_DISK" 2>/dev/null | grep -q "$ESP_NAME"; then
        return 0
    fi

    # Check for Linux Filesystem partitions
    if remote_mac_exec "diskutil list $INTERNAL_DISK 2>/dev/null" 2>/dev/null | grep -q "Linux Filesystem"; then
        return 0
    fi

    # Check for Linux GPT entries (ghost partitions from diskutil eraseVolume)
    local gpt_linux
    gpt_linux=$(remote_mac_sudo "gpt -r show $INTERNAL_DISK 2>/dev/null | awk '/0FC63DAF|0657FD6D/{print \$3}'" || true)
    if [ -n "$gpt_linux" ]; then
        return 0
    fi

    # Check if APFS container is notably smaller than the disk (shrunk and not restored)
    _detect_apfs_container
    if [ -n "${APFS_CONTAINER:-}" ]; then
        local disk_total_bytes apfs_size_bytes
        disk_total_bytes=$(_get_disk_total_bytes "$INTERNAL_DISK")
        apfs_size_bytes=$(_get_apfs_size_bytes "$APFS_CONTAINER")
        # If APFS is more than 10GB smaller than the disk, it was likely shrunk
        if [ -n "$disk_total_bytes" ] && [ -n "$apfs_size_bytes" ]; then
            local size_gap=$((disk_total_bytes - apfs_size_bytes))
            # 10GB = 10,000,000,000 bytes
            if [ "$size_gap" -gt 10000000000 ] 2>/dev/null; then
                return 0
            fi
        fi
    fi

    return 1
}

# _remove_linux_partitions_and_ghosts
# Removes Linux Filesystem partitions via diskutil eraseVolume, then scrubs
# ghost GPT entries that diskutil eraseVolume leaves behind.
# Ghost entries (GUIDs 0FC63DAF/0657FD6D) cause curtin "Could not create partition N"
# errors on next deploy if not scrubbed.
# Args: internal_disk (e.g. /dev/disk0)
_remove_linux_partitions_and_ghosts() {
    local internal_disk="$1"

    local _linux_parts
    _linux_parts=$(remote_mac_exec "diskutil list $internal_disk 2>/dev/null | grep 'Linux Filesystem'" 2>/dev/null || true)
    if [ -n "$_linux_parts" ]; then
        log "Found leftover Linux partitions — removing..."
        echo "$_linux_parts" | while IFS= read -r _line; do
            local _linux_dev
            _linux_dev=$(echo "$_line" | grep -oE 'disk[0-9]+s[0-9]+' | head -1)
            if [ -n "$_linux_dev" ]; then
                dry_run_exec "Remove Linux partition /dev/${_linux_dev}" \
                    remote_mac_sudo diskutil eraseVolume free none "/dev/${_linux_dev}" 2>/dev/null || true
                log "Removed Linux partition /dev/${_linux_dev}"
            fi
        done
    fi

    # Scrub ghost GPT entries
    # diskutil eraseVolume hides Linux partitions from macOS but leaves stale GPT entries.
    # The Linux kernel finds these at boot, causing curtin "Could not create partition N" errors.
    local _gpt_linux_indices
    _gpt_linux_indices=$(remote_mac_sudo "gpt -r show $internal_disk 2>/dev/null | awk '/0FC63DAF|0657FD6D/{print \$3}'" || true)
    if [ -n "$_gpt_linux_indices" ]; then
        log "Found leftover Linux GPT entries — scrubbing..."
        for _idx in $_gpt_linux_indices; do
            # Safety: only remove indices > 2 (preserves EFI=1 + APFS=2)
            if ! [[ "$_idx" =~ ^[0-9]+$ ]] || [ "$_idx" -le 2 ]; then
                warn "Skipping invalid GPT index $_idx — must be numeric and > 2"
                continue
            fi
            dry_run_exec "Remove Linux GPT entry index $_idx" \
                remote_mac_sudo "gpt remove -i $_idx $internal_disk" 2>/dev/null || true
            log "Removed GPT entry index $_idx from $internal_disk"
        done
    fi
}

# ---------------------------------------------------------------------------
# Main Revert Function
# ---------------------------------------------------------------------------

revert_changes() {
    # Load journal state at start
    journal_read

    error "Reverting deployment changes..."
    local REVERT_ERRORS=0

    # Determine deploy method from journal or fallback to variable
    local deploy_method="${JOURNAL_DEPLOY_METHOD:-${DEPLOY_METHOD:-}}"

    # If no deploy method known, try disk-detection fallback
    if [ -z "$deploy_method" ]; then
        _detect_internal_disk
        _detect_esp_device
        if [ -n "${ESP_DEVICE:-}" ]; then
            log "Detected CIDATA partition on internal disk — inferring internal deploy method"
            deploy_method="1"
        elif [ -n "${JOURNAL_USB_DEVICE:-}" ]; then
            deploy_method="2"
        elif [ -n "${JOURNAL_VM_NAME:-}" ]; then
            deploy_method="4"
        else
            # No method detected — check for any leftover artifacts on disk
            if [ -n "${INTERNAL_DISK:-}" ] && _has_revertable_state; then
                deploy_method="1"
                log "Found deployment artifacts on disk — assuming internal deploy method"
            else
                log "No deployment method detected and no deployment artifacts found — system appears clean"
                return 0
            fi
        fi
    fi

    if [ "$deploy_method" = "1" ] || [ "$deploy_method" = "internal" ]; then
        # Internal partition method cleanup
        _detect_internal_disk
        if [ -z "${INTERNAL_DISK:-}" ]; then
            die "Cannot identify internal disk for revert"
        fi
        _detect_apfs_container

        # Full-disk guard: if no APFS container found, macOS was erased — cannot revert
        if [ -z "${APFS_CONTAINER:-}" ]; then
            die "No APFS container found — macOS may have been erased. Cannot revert automatically. Use macOS Recovery (hold Cmd+Option+R at startup) to reinstall macOS."
        fi

        # Prefer journal values over runtime variables, then disk detection
        local esp_created="${JOURNAL_ESP_CREATED:-${_ESP_CREATED:-0}}"
        local esp_device="${JOURNAL_ESP_DEVICE:-}"
        local root_created="${JOURNAL_ROOT_CREATED:-${_ROOT_CREATED:-0}}"
        local root_device="${JOURNAL_ROOT_DEVICE:-}"
        local apfs_resized="${JOURNAL_APFS_RESIZED:-${_APFS_RESIZED:-0}}"
        local apfs_container="${JOURNAL_ORIGINAL_APFS_CONTAINER:-${APFS_CONTAINER:-}}"
        local original_size="${JOURNAL_ORIGINAL_APFS_SIZE:-${_APFS_ORIGINAL_SIZE:-}}"

        # Detect ESP device if not known from journal
        if [ -z "$esp_device" ]; then
            esp_device=$(remote_mac_exec diskutil list "$INTERNAL_DISK" 2>/dev/null | grep "$ESP_NAME" | grep -oE 'disk[0-9]+s[0-9]+' | head -1 || true)
            if [ -n "$esp_device" ]; then
                esp_created="1"
            fi
        fi

        # Detect root partition if journal says created but device unknown
        if [ "$root_created" = "1" ] && [ -z "$root_device" ]; then
            root_device=$(remote_mac_exec diskutil list "$INTERNAL_DISK" 2>/dev/null | grep -A1 "$ESP_NAME" | grep -oE 'disk[0-9]+s[0-9]+' | tail -1 || true)
        fi

        # Nothing-to-revert: skip if nothing was done and nothing on disk
        if [ "$esp_created" != "1" ] && [ "$root_created" != "1" ] && [ "$apfs_resized" != "1" ] && [ -z "$esp_device" ]; then
            if ! _has_revertable_state; then
                log "No deployment changes detected — system appears clean"
                return 0
            fi
            log "Found deployment artifacts on disk despite no journal record — cleaning up"
        fi

        # Step 1: ESP removal with self-healing
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
            else
                log "ESP partition removed"
            fi
        elif [ "$esp_created" = "1" ]; then
            warn "ESP was marked as created but device not found for removal"
            REVERT_ERRORS=1
        fi
        _ESP_CREATED=0

        # Step 2b: Remove pre-created root partition if it exists
        if [ -n "$root_device" ]; then
            log "Removing root partition /dev/$root_device..."
            remote_mac_sudo diskutil unmount "/dev/$root_device" 2>/dev/null || true
            dry_run_exec "Remove root partition /dev/$root_device" \
                remote_mac_sudo diskutil eraseVolume free none "/dev/$root_device" 2>/dev/null || true
            # Verify root removed
            if remote_mac_exec diskutil list 2>/dev/null | grep -q "$root_device"; then
                warn "Root partition /dev/$root_device still present after erase"
                REVERT_ERRORS=1
            else
                log "Root partition removed"
            fi
        fi

        # Step 3: Remove leftover Linux partitions and scrub ghost GPT entries
        _remove_linux_partitions_and_ghosts "$INTERNAL_DISK"

        # Step 4: Expand APFS container if resized
        if [ "$apfs_resized" = "1" ] && [ -n "$apfs_container" ]; then
            log "Expanding APFS container to fill available space..."

            # APFS resize guard: check current size before attempting resize
            # diskutil apfs resizeContainer rejects same-size resize
            local current_apfs_bytes disk_total_bytes
            current_apfs_bytes=$(_get_apfs_size_bytes "$apfs_container")
            disk_total_bytes=$(_get_disk_total_bytes "$INTERNAL_DISK")

            local should_resize=1
            if [ -n "$current_apfs_bytes" ] && [ -n "$disk_total_bytes" ]; then
                local size_gap=$((disk_total_bytes - current_apfs_bytes))
                # 10GB = 10,000,000,000 bytes
                if [ "$size_gap" -lt 10000000000 ] 2>/dev/null; then
                    log "APFS container already near full disk size (${size_gap:-0} bytes gap) — skipping expansion"
                    should_resize=0
                fi
            fi

            if [ "$should_resize" = "1" ]; then
                dry_run_exec "Expand APFS container to fill free space" \
                    remote_mac_sudo diskutil apfs resizeContainer "$apfs_container" 0 2>/dev/null || true
                # Verify expansion — diskutil apfs resizeContainer can return non-zero on success
                sleep 2
                local _verify_size
                _verify_size=$(_get_apfs_size_bytes "$apfs_container")

                # Verify container expanded beyond original size (with ±1GB tolerance)
                # diskutil uses decimal GB (10^9), not binary GiB (2^30)
                local _original_bytes
                _original_bytes=$(awk -v gb="${original_size:-0}" 'BEGIN { printf "%.0f", gb * 1000000000 }')
                local _min_bytes=$(( ${_original_bytes:-0} - 1000000000 ))
                if [ -n "$_verify_size" ]; then
                    if [ "$_verify_size" -ge "${_min_bytes:-0}" ] 2>/dev/null; then
                        log "APFS container expanded to fill freed space"
                    else
                        warn "APFS container may not have expanded (current: ${_verify_size:-unknown} bytes, minimum expected: ${_min_bytes:-unknown} bytes)"
                        REVERT_ERRORS=1
                    fi
                else
                    warn "Could not verify APFS container size after expansion"
                    REVERT_ERRORS=1
                fi
            fi
            _APFS_RESIZED=0
        fi

        # Step 5: Restore macOS boot device
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
    elif [ "$deploy_method" = "2" ] || [ "$deploy_method" = "usb" ] || [ "$deploy_method" = "3" ] || [ "$deploy_method" = "manual" ]; then
        # USB/manual method cleanup - use rollback_usb from rollback.sh
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

# ---------------------------------------------------------------------------
# EXIT Trap Handler
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Manual --revert Flag Handler
# ---------------------------------------------------------------------------

handle_revert_flag() {
    if [ "${1:-}" != "--revert" ]; then
        return 1
    fi
    log "Manual revert requested..."

    # Load journal state first
    if command -v journal_read >/dev/null 2>&1; then
        journal_read
    fi

    # Detect disk state for fallback values
    _detect_internal_disk
    if [ -z "${INTERNAL_DISK:-}" ]; then
        die "Cannot identify internal disk for revert"
    fi
    _detect_apfs_container

    # Full-disk guard: if no APFS container found, macOS was erased
    if [ -z "${APFS_CONTAINER:-}" ]; then
        die "No APFS container found — macOS may have been erased. Cannot revert automatically. Use macOS Recovery (hold Cmd+Option+R at startup) to reinstall macOS."
    fi

    # Detect deploy method from journal or disk state
    local deploy_method="${JOURNAL_DEPLOY_METHOD:-}"
    if [ -z "$deploy_method" ]; then
        _detect_esp_device
        if [ -n "${ESP_DEVICE:-}" ]; then
            deploy_method="1"
            log "Detected CIDATA partition — inferring internal deploy method"
        elif [ -n "${JOURNAL_USB_DEVICE:-}" ]; then
            deploy_method="2"
        elif [ -n "${JOURNAL_VM_NAME:-}" ]; then
            deploy_method="4"
        else
            # Check for any deployment artifacts on disk
            if _has_revertable_state; then
                deploy_method="1"
                log "Found deployment artifacts — assuming internal deploy method"
            else
                log "No deployment changes detected — system appears clean"
                # Destroy stale journal if present
                if command -v journal_destroy >/dev/null 2>&1; then
                    journal_destroy
                    for _jrvar in $(set 2>/dev/null | grep '^JOURNAL_' | cut -d= -f1); do
                        unset "$_jrvar" 2>/dev/null || true
                    done
                    unset _jrvar
                fi
                exit 0
            fi
        fi
        # Set journal value so revert_changes can use it
        JOURNAL_DEPLOY_METHOD="$deploy_method"
    fi

    # Populate journal fallback values from disk detection
    # (revert_changes reads these after journal_read, which won't overwrite if file has no entry)
    if [ -z "${JOURNAL_ORIGINAL_APFS_CONTAINER:-}" ] && [ -n "${APFS_CONTAINER:-}" ]; then
        JOURNAL_ORIGINAL_APFS_CONTAINER="$APFS_CONTAINER"
    fi
    if [ -z "${JOURNAL_ESP_DEVICE:-}" ] && [ -n "${ESP_DEVICE:-}" ]; then
        JOURNAL_ESP_DEVICE="$ESP_DEVICE"
        JOURNAL_ESP_CREATED="1"
    fi

    # Nothing-to-revert: double-check disk state for internal method
    if [ "$deploy_method" = "1" ] || [ "$deploy_method" = "internal" ]; then
        if ! _has_revertable_state && [ -z "${JOURNAL_ESP_CREATED:-}" ] && [ -z "${JOURNAL_APFS_RESIZED:-}" ]; then
            log "No deployment changes detected — system appears clean"
            if command -v journal_destroy >/dev/null 2>&1; then
                journal_destroy
                for _jrvar in $(set 2>/dev/null | grep '^JOURNAL_' | cut -d= -f1); do
                    unset "$_jrvar" 2>/dev/null || true
                done
                unset _jrvar
            fi
            exit 0
        fi
    fi

    # Call unified revert function
    revert_changes
    local revert_rc=$?

    # Destroy journal after revert — never resume a reverted deployment
    if command -v journal_destroy >/dev/null 2>&1; then
        journal_destroy
        # Clear all JOURNAL_ vars from shell environment
        # (shell env vars persist after file removal, so both must be cleared)
        for _jrvar in $(set 2>/dev/null | grep '^JOURNAL_' | cut -d= -f1); do
            unset "$_jrvar" 2>/dev/null || true
        done
        unset _jrvar
    fi

    if [ "$revert_rc" -eq 0 ]; then
        log "Revert complete"
    else
        warn "Revert completed with some errors — manual cleanup may be needed"
    fi
    exit 0
}
