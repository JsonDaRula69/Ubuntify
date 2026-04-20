#!/bin/bash
#
# lib/rollback.sh - State journal, phase tracking, and rollback orchestration module
#
# Provides persistent state tracking across reboots and best-effort rollback
# for failed deployment phases. Bash 3.2-compatible, set -u safe.
#
# Dependencies: lib/logging.sh, lib/retry.sh
#

## Guard

[ "${_ROLLBACK_SH_SOURCED:-0}" -eq 1 ] && return 0
_ROLLBACK_SH_SOURCED=1

## Dependencies

source "${LIB_DIR:-./lib}/logging.sh"
source "${LIB_DIR:-./lib}/retry.sh"
source "${LIB_DIR:-./lib}/dryrun.sh"

## Constants

STATE_FILE="${STATE_FILE:-/var/tmp/macpro-deploy-state.env}"
STATE_DIR="${STATE_DIR:-/var/tmp/macpro-deploy}"
readonly GPT_BACKUP_FILE="${STATE_DIR}/gpt-backup.bin"
readonly ERROR_REPORT_FILE="${STATE_DIR}/error-report.txt"

## Phase Definitions

readonly PHASES_INTERNAL="analyze shrink_apfs create_esp extract_iso copy_pkgs generate_config verify_bless"
readonly PHASES_USB="detect_usb partition_usb extract_iso copy_pkgs generate_config verify"
readonly PHASES_VM="check_vbox find_iso build_iso create_vm start_monitor"

## Journal Functions

# journal_init [deploy_method]
# Initializes state tracking, handles resume vs fresh start
journal_init() {
    local deploy_method="${1:-}"

    # Create state directory
    mkdir -p "$STATE_DIR"

    # Check for existing state from incomplete run
    if [ -f "$STATE_FILE" ]; then
        journal_read

        local phase_name
        phase_name="${JOURNAL_PHASE:-unknown}"

        # Ask user: resume or start fresh?
        if tui_confirm "Incomplete Deployment" "Previous deployment incomplete at phase: ${phase_name}\n\nResume from where it left off, or start fresh?" 2>/dev/null; then
            log_info "Resuming deployment from phase: ${phase_name}"
            return 0
        else
            # User chose fresh start - backup old state
            local backup_file
            backup_file="${STATE_FILE}.$(date +%Y%m%d_%H%M%S).bak"
            mv "$STATE_FILE" "$backup_file" 2>/dev/null || true
            log_info "Starting fresh deployment (old state backed up to ${backup_file})"
        fi
    fi

    # Create fresh state file with timestamp
    local tmpfile
    tmpfile="${STATE_FILE}.tmp.$$"
    printf 'JOURNAL_STARTED="%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmpfile"

    if [ -n "$deploy_method" ]; then
        printf 'JOURNAL_DEPLOY_METHOD="%s"\n' "$deploy_method" >> "$tmpfile"
    fi

    # Atomic move
    mv "$tmpfile" "$STATE_FILE"

    return 0
}

# journal_read
# Sources STATE_FILE into current environment (JOURNAL_* vars)
journal_read() {
    if [ -f "$STATE_FILE" ]; then
        # shellcheck source=/dev/null
        source "$STATE_FILE"
    fi
    return 0
}

# journal_set key value
# Validates key name and atomically updates state file
# Key must match: ^[a-zA-Z_][a-zA-Z0-9_]*$
journal_set() {
    local key="$1"
    local value="$2"

    # Validate key to prevent eval injection
    if ! printf '%s' "$key" | grep -qE '^[a-zA-Z_][a-zA-Z0-9_]*$'; then
        error "journal_set: invalid key name: $key"
        return 1
    fi

    # First read current state
    journal_read

    # Create temp file on same filesystem for atomic write
    local tmpfile
    tmpfile="${STATE_FILE}.tmp.$$"

    # Rebuild state file with all existing JOURNAL_* vars plus new value
    # Use set to list all variables, filter for JOURNAL_ prefix
    {
        printf '# Mac Pro Deployment State Journal\n'
        printf '# Last updated: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '\n'

        # Export all current JOURNAL_* variables
        local var_name
        for var_name in $(set 2>/dev/null | grep '^JOURNAL_' | cut -d= -f1 | sort -u); do
            if [ "$var_name" != "JOURNAL_${key}" ]; then
                eval "local val=\"\${${var_name}}\""
                # Escape double quotes for safe write — use sed for bash 3.2 compat
                val=$(printf '%s' "$val" | sed 's/"/\\"/g')
                printf '%s="%s"\n' "$var_name" "$val"
            fi
        done

        # Write the new key-value pair
        printf 'JOURNAL_%s="%s"\n' "$key" "$value"
    } > "$tmpfile"

    # Atomic rename
    if mv "$tmpfile" "$STATE_FILE"; then
        return 0
    else
        error "journal_set: failed to update state file"
        rm -f "$tmpfile" 2>/dev/null || true
        return 1
    fi
}

# journal_set_phase phase_name
# Records phase completion with timestamp
journal_set_phase() {
    local phase_name="$1"
    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    journal_set "PHASE" "$phase_name"
    journal_set "PHASE_completed_${phase_name}" "$timestamp"

    return 0
}

# journal_get_phase
# Returns current phase name (or empty if none)
journal_get_phase() {
    journal_read
    echo "${JOURNAL_PHASE:-}"
    return 0
}

# journal_is_complete phase_name
# Returns 0 if phase completed, 1 otherwise
journal_is_complete() {
    local phase_name="$1"

    journal_read

    local completed_var
    completed_var="JOURNAL_PHASE_completed_${phase_name}"

    if [ -n "${!completed_var:-}" ]; then
        return 0
    else
        return 1
    fi
}

# journal_save_originals key value [key value...]
# Saves multiple original values before modification
journal_save_originals() {
    while [ $# -ge 2 ]; do
        local key="$1"
        local value="$2"
        journal_set "ORIGINAL_${key}" "$value"
        shift 2
    done

    return 0
}

# journal_destroy
# Removes all state files (cleanup after successful completion)
journal_destroy() {
    dry_run_exec "Removing state file $STATE_FILE" rm -f "$STATE_FILE"
    dry_run_exec "Removing state directory $STATE_DIR" rm -rf "$STATE_DIR"
    log_info "State journal destroyed"
    return 0
}

## Disk Snapshot Functions

# snapshot_disk_layout internal_disk
# Saves GPT backup before any disk modifications
snapshot_disk_layout() {
    local internal_disk="$1"

    log_info "Creating disk layout snapshot for ${internal_disk}"

    # Save binary GPT backup (this is a WRITE operation)
    if ! dry_run_exec "Saving GPT backup for ${internal_disk} to ${GPT_BACKUP_FILE}" \
        sgdisk -b "$GPT_BACKUP_FILE" "$internal_disk"; then
        warn "snapshot_disk_layout: sgdisk backup failed for ${internal_disk}"
        return 1
    fi

    # Save text version for reference
    dry_run_exec "Saving GPT layout text for ${internal_disk}" \
        sh -c "sgdisk -p '$internal_disk' > '${STATE_DIR}/gpt-layout.txt' 2>/dev/null" || true

    # Save diskutil list output
    diskutil list "$internal_disk" > "${STATE_DIR}/diskutil-list.txt" 2>/dev/null || true

    journal_set "GPT_BACKUP" "yes"
    log_info "Disk layout saved to ${GPT_BACKUP_FILE}"

    return 0
}

# snapshot_usb_layout usb_device
# Saves USB partition table before modification
snapshot_usb_layout() {
    local usb_device="$1"

    log_info "Creating USB layout snapshot for ${usb_device}"

    # Save binary backup
    sgdisk -b "${STATE_DIR}/usb-gpt-backup.bin" "$usb_device" 2>/dev/null || true

    # Save diskutil list
    diskutil list "$usb_device" > "${STATE_DIR}/usb-diskutil-list.txt" 2>/dev/null || true

    journal_set "USB_GPT_BACKUP" "yes"
    journal_set "USB_DEVICE" "$usb_device"

    log_info "USB layout saved to ${STATE_DIR}/"

    return 0
}

## Phase Runner

# run_phased deploy_method phase_list phase1_func phase2_func ...
# Executes phases in order, skipping completed ones
run_phased() {
    local deploy_method="$1"
    local phase_list="$2"
    shift 2

    # Store phase functions
    local -a phase_funcs
    local func_idx=0
    while [ $# -gt 0 ]; do
        phase_funcs[$func_idx]="$1"
        func_idx=$((func_idx + 1))
        shift
    done

    # Split phase list into array
    local -a phases
    local phase_idx=0
    local phase
    for phase in ${phase_list:-}; do
        phases[$phase_idx]="$phase"
        phase_idx=$((phase_idx + 1))
    done

    local total_phases=${#phases[@]}
    local current_idx=0

    while [ $current_idx -lt $total_phases ]; do
        local phase_name="${phases[$current_idx]}"
        local phase_func="${phase_funcs[$current_idx]}"
        local phase_num=$((current_idx + 1))

        # Check if already completed
        if journal_is_complete "$phase_name"; then
            log_info "Skipping completed phase: ${phase_name}"
            current_idx=$((current_idx + 1))
            continue
        fi

        log_info "=== Phase ${phase_num}/${total_phases}: ${phase_name} ==="

        if is_dry_run; then
            log_info "[DRY-RUN] Would execute phase: ${phase_name}"
            current_idx=$((current_idx + 1))
            continue
        fi

        # Run the phase function
        local exit_code=0
        # Validate phase function name to prevent command injection
        if ! printf '%s' "$phase_func" | grep -qE '^[a-zA-Z_][a-zA-Z0-9_]*$'; then
            log_error "run_phased: invalid phase function name: $phase_func"
            exit_code=1
        elif ! command -v "$phase_func" >/dev/null 2>&1 && ! type "$phase_func" >/dev/null 2>&1; then
            log_error "run_phased: undefined phase function: $phase_func"
            exit_code=1
        elif $phase_func; then
            exit_code=0
        else
            exit_code=$?
        fi

        if [ $exit_code -eq 0 ]; then
            journal_set_phase "$phase_name"
            log_info "Phase ${phase_name} completed successfully"
        else
            handle_phase_failure "$phase_name" "$exit_code"
            return 1
        fi

        current_idx=$((current_idx + 1))
    done

    return 0
}

# handle_phase_failure phase_name exit_code
# Handles phase failure with error collection and rollback
handle_phase_failure() {
    local phase_name="$1"
    local exit_code="$2"

    error "Phase ${phase_name} failed with exit code ${exit_code}"

    if is_dry_run; then
        log_info "[DRY-RUN] Would attempt rollback from phase ${phase_name}"
        return 1
    fi

    # Collect error context if verify.sh is available
    if command -v collect_error_context >/dev/null 2>&1; then
        collect_error_context "$phase_name" "failure" "Phase failed with exit code ${exit_code}" "$exit_code"
    fi

    # Attempt rollback
    rollback_from_journal

    # Generate and show error report
    error_report "$phase_name" "execution" "$exit_code" "attempted"
    show_error_report

    return 1
}

## Rollback Functions

# rollback_internal
# Reverts internal partition deployment changes (best-effort)
rollback_internal() {
    log_info "Starting internal partition rollback"

    journal_read

    local rollback_status=""

    # Step 1: Restore boot device
    local original_boot="${JOURNAL_ORIGINAL_BOOT_DEVICE:-}"
    if [ -n "$original_boot" ]; then
        log_info "Attempting to restore boot device to ${original_boot}"
        if dry_run_exec "Restoring boot device to ${original_boot}" \
            bless --mount "$original_boot" --setBoot 2>/dev/null; then
            rollback_status="${rollback_status}boot_restored "
            log_info "Boot device restored successfully"
        else
            # SIP likely blocking
            warn "rollback_internal: bless failed (SIP may be enabled)"
            warn "rollback_internal: Workaround: Boot to Recovery Mode (Cmd+R), run 'csrutil enable --without nvram', then retry"
            rollback_status="${rollback_status}boot_failed(SIP) "
        fi
    fi

    # Step 2: Remove ESP if created
    local esp_created="${JOURNAL_ESP_CREATED:-}"
    local esp_device="${JOURNAL_ESP_DEVICE:-}"

    if [ "$esp_created" = "1" ] && [ -n "$esp_device" ]; then
        log_info "Removing created ESP partition ${esp_device}"

        # Unmount first
        dry_run_exec "Unmounting ESP /dev/${esp_device}" \
            diskutil unmount "/dev/${esp_device}" 2>/dev/null || true

        # Erase to free space
        if dry_run_exec "Erasing ESP partition ${esp_device} to free space" \
            retry_diskutil eraseVolume free none "/dev/${esp_device}" 2>/dev/null; then
            rollback_status="${rollback_status}esp_removed "
            log_info "ESP partition removed"
        else
            warn "rollback_internal: failed to remove ESP partition ${esp_device}"
            rollback_status="${rollback_status}esp_failed "
        fi
    fi

    # Step 3: Restore APFS size if resized
    local apfs_resized="${JOURNAL_APFS_RESIZED:-}"
    local original_size="${JOURNAL_ORIGINAL_APFS_SIZE:-}"
    local apfs_container="${JOURNAL_APFS_CONTAINER:-}"

    if [ "$apfs_resized" = "1" ] && [ -n "$apfs_container" ]; then
        if [ -n "$original_size" ]; then
            log_info "Restoring APFS container to ${original_size}GB"
            if dry_run_exec "Restoring APFS container to ${original_size}GB" \
                retry_diskutil apfs resizeContainer "$apfs_container" "${original_size}g" 2>/dev/null; then
                rollback_status="${rollback_status}apfs_restored "
                log_info "APFS container restored"
            else
                warn "rollback_internal: failed to restore APFS size"
                rollback_status="${rollback_status}apfs_failed "
            fi
        fi

        # Expand to fill any freed space (best effort)
        log_info "Expanding APFS to fill available space"
        dry_run_exec "Expanding APFS to fill available space" \
            retry_diskutil apfs resizeContainer "$apfs_container" 0 2>/dev/null || true
    fi

    log_info "Internal partition rollback completed (status: ${rollback_status:-none})"

    case "$rollback_status" in
        *failed*)
            warn "Rollback had partial failures"
            return 1
            ;;
    esac
    return 0
}

# rollback_usb
# Reverts USB device changes
rollback_usb() {
    log_info "Starting USB rollback"
    local errors=0

    journal_read

    local usb_backup="${JOURNAL_USB_GPT_BACKUP:-}"
    local usb_device="${JOURNAL_USB_DEVICE:-}"
    local backup_file="${STATE_DIR}/usb-gpt-backup.bin"

    if [ "$usb_backup" = "yes" ] && [ -n "$usb_device" ] && [ -f "$backup_file" ]; then
        log_info "Restoring USB partition table from backup"
        if dry_run_exec "Restoring USB partition table from backup" \
            sgdisk -l "$backup_file" "$usb_device" 2>/dev/null; then
            log_info "USB partition table restored"
        else
            warn "rollback_usb: failed to restore USB partition table"
            errors=$((errors + 1))
        fi
    else
        warn "rollback_usb: no USB backup available, manual reformat may be needed"
    fi

    # Unmount USB
    if [ -n "$usb_device" ]; then
        dry_run_exec "Unmounting USB device ${usb_device}" \
            diskutil unmountDisk "$usb_device" 2>/dev/null || true
    fi

    [ $errors -eq 0 ]
}

# rollback_vm
# Cleans up VM test environment
rollback_vm() {
    log_info "Starting VM rollback"

    if ! command -v VBoxManage >/dev/null 2>&1; then
        warn "rollback_vm: VBoxManage not available"
        return 1
    fi

    dry_run_exec "Powering off VM macpro-vmtest" \
        VBoxManage controlvm macpro-vmtest poweroff 2>/dev/null || true
    if ! is_dry_run; then
        sleep 1
    fi

    dry_run_exec "Unregistering and deleting VM macpro-vmtest" \
        VBoxManage unregistervm macpro-vmtest --delete 2>/dev/null || true

    log_info "VM test environment cleaned up"
    return 0
}

# rollback_from_journal
# Reads journal and dispatches to appropriate rollback function
rollback_from_journal() {
    log_info "Initiating rollback from journal"

    journal_read

    local deploy_method="${JOURNAL_DEPLOY_METHOD:-}"

    case "$deploy_method" in
        internal|1)
            rollback_internal
            ;;
        usb|2|manual|3)
            rollback_usb
            ;;
        vm|4)
            rollback_vm
            ;;
        *)
            # Try to infer from journal state
            if [ -n "${JOURNAL_USB_DEVICE:-}" ]; then
                log_info "Inferred USB rollback from journal state"
                rollback_usb
            elif [ -n "${JOURNAL_APFS_CONTAINER:-}" ]; then
                log_info "Inferred internal rollback from journal state"
                rollback_internal
            else
                warn "rollback_from_journal: cannot determine rollback type from journal"
            fi
            ;;
    esac

    log_info "Rollback completed"
    return 0
}

## Error Reporting

# error_report phase step exit_code rollback_status
# Generates structured error report
error_report() {
    local phase="$1"
    local step="$2"
    local exit_code="$3"
    local rollback_status="$4"

    {
        echo "=== Mac Pro Deployment Error Report ==="
        echo "Timestamp: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
        echo ""
        echo "=== Failure Details ==="
        echo "Failed Phase: ${phase}"
        echo "Failed Step: ${step}"
        echo "Exit Code: ${exit_code}"
        echo "Rollback Status: ${rollback_status}"
        echo ""
        echo "=== System State ==="
        echo "Disk Space:"
        df -h 2>/dev/null | head -10 || echo "df failed"
        echo ""
        echo "Mount Points:"
        mount 2>/dev/null | grep -E "(disk|ESP|CIDATA|/Volumes)" || echo "No relevant mounts"
        echo ""
        echo "SIP Status:"
        csrutil status 2>/dev/null || echo "csrutil failed"
        echo ""
        echo "=== Manual Recovery Steps ==="
        show_recovery_instructions
        echo ""
        echo "=== End of Error Report ==="
    } > "$ERROR_REPORT_FILE"

    return 0
}

# show_error_report
# Displays error report to user
show_error_report() {
    if [ ! -f "$ERROR_REPORT_FILE" ]; then
        warn "No error report available"
        return 0
    fi

    if command -v tui_msgbox >/dev/null 2>&1; then
        tui_msgbox "Deployment Error" "$(cat "$ERROR_REPORT_FILE")"
    else
        echo ""
        echo "=== DEPLOYMENT ERROR ==="
        cat "$ERROR_REPORT_FILE"
        echo ""
    fi

    return 0
}

# show_recovery_instructions
# Outputs specific recovery steps based on journal state
show_recovery_instructions() {
    journal_read

    local esp_created="${JOURNAL_ESP_CREATED:-}"
    local esp_device="${JOURNAL_ESP_DEVICE:-}"
    local apfs_resized="${JOURNAL_APFS_RESIZED:-}"
    local phase="${JOURNAL_PHASE:-}"

    if [ -z "$phase" ]; then
        echo "No deployment state found - system should be unchanged."
        return 0
    fi

    echo "Current deployment state: ${phase}"
    echo ""

    if [ "$esp_created" = "1" ] && [ -n "$esp_device" ]; then
        echo "ESP partition was created (${esp_device})."
        echo "  - If bless failed: Hold Option key at boot and select 'macOS' to boot back to macOS"
        echo "  - If stuck on Ubuntu: Hold Option key at boot, select 'CIDATA' to continue install"
        echo ""
    fi

    if [ "$apfs_resized" = "1" ]; then
        echo "APFS container was resized."
        if [ "$esp_created" != "1" ]; then
            echo "  - To revert: sudo ./prepare-deployment.sh --revert"
        fi
        echo "  - macOS should still be intact and bootable"
        echo ""
    fi

    echo "General recovery options:"
    echo "  1. To revert all changes: sudo ./prepare-deployment.sh --revert"
    echo "  2. To boot macOS: Hold Option key at startup, select macOS"
    echo "  3. For Recovery Mode: Hold Cmd+R at startup"
    echo "  4. If SIP blocks bless: Recovery Mode → csrutil enable --without nvram → reboot → retry"

    return 0
}

## Export functions for sourcing

if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ]; then
    export -f journal_init journal_read journal_set journal_set_phase 2>/dev/null || true
    export -f journal_get_phase journal_is_complete journal_save_originals journal_destroy 2>/dev/null || true
    export -f snapshot_disk_layout snapshot_usb_layout 2>/dev/null || true
    export -f run_phased handle_phase_failure 2>/dev/null || true
    export -f rollback_internal rollback_usb rollback_vm rollback_from_journal 2>/dev/null || true
    export -f error_report show_error_report show_recovery_instructions 2>/dev/null || true
fi
