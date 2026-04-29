#!/bin/bash
#
# lib/deploy.sh - Deployment method implementations
#
# Provides deploy_internal_partition, deploy_usb, deploy_manual, and
# deploy_vm_test functions for different deployment scenarios.
#
# Dependencies: lib/colors.sh, lib/logging.sh, lib/detect.sh, lib/disk.sh,
#               lib/autoinstall.sh, lib/bless.sh
#

[ "${_DEPLOY_SH_SOURCED:-0}" -eq 1 ] && return 0
_DEPLOY_SH_SOURCED=1

source "${LIB_DIR:-./lib}/colors.sh"
source "${LIB_DIR:-./lib}/logging.sh"
source "${LIB_DIR:-./lib}/detect.sh"
source "${LIB_DIR:-./lib}/disk.sh"
source "${LIB_DIR:-./lib}/autoinstall.sh"
source "${LIB_DIR:-./lib}/bless.sh"
source "${LIB_DIR:-./lib}/retry.sh" 2>/dev/null || true
source "${LIB_DIR:-./lib}/verify.sh" 2>/dev/null || true
source "${LIB_DIR:-./lib}/rollback.sh" 2>/dev/null || true
source "${LIB_DIR:-./lib}/remote_mac.sh" 2>/dev/null || true
source "${LIB_DIR:-./lib}/tui.sh"
source "${LIB_DIR:-./lib}/dryrun.sh"

: "${SCRIPT_DIR:=$(cd "$(dirname "$0")" && pwd)}"
STORAGE_LAYOUT="${STORAGE_LAYOUT:-1}"
NETWORK_TYPE="${NETWORK_TYPE:-1}"
INTERNAL_DISK="${INTERNAL_DISK:-}"
APFS_CONTAINER="${APFS_CONTAINER:-}"
TARGET_DEVICE="${TARGET_DEVICE:-}"

# Internal partition deployment phase functions
# These correspond to PHASES_INTERNAL="analyze shrink_apfs create_esp create_root extract_iso copy_pkgs generate_config verify_bless"

_phase_analyze() {
    analyze_disk_layout INTERNAL_DISK APFS_CONTAINER
    snapshot_disk_layout "$INTERNAL_DISK"
    journal_save_originals INTERNAL_DISK "$INTERNAL_DISK" APFS_CONTAINER "$APFS_CONTAINER"
}

_phase_shrink_apfs() {
    printf '\r%b  %b▸%b Resizing APFS container...           \r' "$CLR" "$CYAN" "$NC" >&2
    shrink_apfs_if_needed "$APFS_CONTAINER" "$INTERNAL_DISK" _APFS_RESIZED _APFS_ORIGINAL_SIZE
    journal_set "APFS_RESIZED" "$_APFS_RESIZED"
    journal_set "ORIGINAL_APFS_SIZE" "${_APFS_ORIGINAL_SIZE:-}"
    if [ "$_APFS_RESIZED" -eq 1 ]; then
        # Verify against the TARGET size, not original
        local _verify_target_gb="${MACOS_TARGET_GB:-50}"
        # Minimum macOS is 50GB; use that as default target
        if [ "${MACOS_SIZE_MODE:-auto}" = "max_linux" ]; then
            _verify_target_gb=50
        elif [ -n "${MACOS_SIZE_GB:-}" ]; then
            _verify_target_gb="$MACOS_SIZE_GB"
        fi
        if ! verify_apfs_resize "$APFS_CONTAINER" "$_verify_target_gb"; then
            warn "APFS resize verification failed (expected ~${_verify_target_gb}GB), but continuing"
        fi
    fi
    printf '\r%b  %b✓%b APFS resize complete                   \n' "$CLR" "$GREEN" "$NC" >&2
}

_phase_create_esp() {
    printf '\r%b  %b▸%b Creating ESP partition...            \r' "$CLR" "$CYAN" "$NC" >&2
    local _esp_output_file
    _esp_output_file=$(mktemp /tmp/macpro-esp-output.XXXXXX)
    create_esp_partition "$INTERNAL_DISK" _ESP_CREATED _ESP_DEVICE > "$_esp_output_file"
    ESP_MOUNT=$(head -1 "$_esp_output_file")
    _ESP_DEVICE=$(tail -1 "$_esp_output_file")
    rm -f "$_esp_output_file"
    journal_set "ESP_CREATED" "$_ESP_CREATED"
    journal_set "ESP_DEVICE" "${_ESP_DEVICE:-}"
    export ESP_MOUNT
    if ! verify_esp_mount "$ESP_MOUNT" "$_ESP_DEVICE"; then
        error "ESP mount verification failed after create_esp_partition"
        return 1
    fi
    printf '\r%b  %b✓%b ESP partition created                   \n' "$CLR" "$GREEN" "$NC" >&2
}

_phase_create_root() {
    if [ "${STORAGE_LAYOUT:-1}" != "1" ]; then
        log "Full disk mode — skipping root partition creation (installer handles partitioning)"
        return 0
    fi
    printf '\r%b  %b▸%b Creating root partition...            \r' "$CLR" "$CYAN" "$NC" >&2
    local _root_output_file
    _root_output_file=$(mktemp /tmp/macpro-root-output.XXXXXX)
    create_root_partition "$INTERNAL_DISK" _ROOT_CREATED _ROOT_DEVICE _ROOT_SIZE_BYTES > "$_root_output_file" 2>&1
    rm -f "$_root_output_file"
    journal_set "ROOT_CREATED" "${_ROOT_CREATED:-0}"
    journal_set "ROOT_DEVICE" "${_ROOT_DEVICE:-}"
    journal_set "ROOT_SIZE_BYTES" "${_ROOT_SIZE_BYTES:-0}"
    export ROOT_SIZE_BYTES="${_ROOT_SIZE_BYTES:-0}"
    if [ "${_ROOT_CREATED}" -ne 1 ]; then
        die "Failed to create root partition"
    fi
    printf '\r%b  %b✓%b Root partition created (%s)            \n' "$CLR" "$GREEN" "$NC" "$_ROOT_DEVICE" >&2
}

_phase_extract_iso() {
    local ESP_MOUNT="/Volumes/${ESP_NAME:-CIDATA}"
    if [ -n "${1:-}" ]; then
        ESP_MOUNT="$1"
    fi
    log_info "Extracting Ubuntu ISO to ESP... (this may take 2-5 minutes)"
    log_info "  ISO: $ISO_PATH"
    log_info "  Target: $ESP_MOUNT"

    if ! verify_esp_mount "$ESP_MOUNT" "${JOURNAL_ESP_DEVICE:-}"; then
        error "ESP not mounted before ISO extraction — attempting re-mount"
    fi

    local host="${TARGET_HOST:-macpro}"
    printf '\r%b  %b▸%b Transferring ISO to %s...   \r' "$CLR" "$CYAN" "$NC" "$host" >&2
    local REMOTE_ISO="/tmp/ubuntu-macpro.iso"
    if ! remote_mac_cp "$ISO_PATH" "$REMOTE_ISO"; then
        die "Failed to transfer ISO to $host"
    fi
    printf '\r%b  %b▸%b Extracting ISO on remote host...      \r' "$CLR" "$CYAN" "$NC" >&2
    if ! remote_mac_sudo --timeout 600 xorriso -osirrox on -indev "$REMOTE_ISO" -extract / "$ESP_MOUNT" 2>/dev/null; then
        printf '\r%b  %b✗%b Remote ISO extraction failed           \n' "$CLR" "$RED" "$NC" >&2
        remote_mac_exec rm -f "$REMOTE_ISO" 2>/dev/null || true
        die "Failed to extract ISO contents on remote host"
    fi
    remote_mac_exec rm -f "$REMOTE_ISO" 2>/dev/null || true
    printf '\r%b  %b✓%b ISO extraction complete                \n' "$CLR" "$GREEN" "$NC" >&2
    if ! verify_iso_extraction "$ESP_MOUNT"; then
        die "ISO extraction verification failed on remote host — cannot retry (remote ISO deleted)"
    fi
}

_phase_copy_pkgs() {
    local ESP_MOUNT="/Volumes/${ESP_NAME:-CIDATA}"
    if [ -n "${1:-}" ]; then
        ESP_MOUNT="$1"
    fi
    local pkgs_copied=0

    if ! remote_mac_dir_exists "$ESP_MOUNT/macpro-pkgs" || \
       ! remote_mac_exec "ls $ESP_MOUNT/macpro-pkgs/*.deb >/dev/null 2>&1"; then
        printf '\r%b  %b▸%b Copying driver packages to ESP...     \r' "$CLR" "$CYAN" "$NC" >&2
        remote_mac_sudo mkdir -p "$ESP_MOUNT/macpro-pkgs"
        remote_mac_cp_contents "$SCRIPT_DIR/packages/" "$ESP_MOUNT/macpro-pkgs/" 2>/dev/null && pkgs_copied=1 || warn "Some packages may be missing"
        if [ "$pkgs_copied" -eq 1 ]; then
            printf '\r%b  %b✓%b Driver packages copied                 \n' "$CLR" "$GREEN" "$NC" >&2
        fi
    fi

    if [ -d "$SCRIPT_DIR/packages/dkms-patches" ]; then
        local DKMS_DST="$ESP_MOUNT/macpro-pkgs/dkms-patches"
        if ! remote_mac_dir_exists "$DKMS_DST"; then
            printf '\r%b  %b▸%b Copying DKMS patches to ESP...        \r' "$CLR" "$CYAN" "$NC" >&2
            remote_mac_sudo mkdir -p "$DKMS_DST"
            remote_mac_cp_dir "$SCRIPT_DIR/packages/dkms-patches/" "$DKMS_DST/" || die "Failed to copy DKMS patches — WiFi driver cannot compile without them"
            printf '\r%b  %b✓%b DKMS patches copied                    \n' "$CLR" "$GREEN" "$NC" >&2
        fi
    fi

    if ! remote_mac_exec "ls $ESP_MOUNT/macpro-pkgs/*.deb >/dev/null 2>&1"; then
        error "Package verification failed: no .deb files found on remote host after copy"
        return 1
    fi
}

_phase_generate_config() {
    printf '\r%b  %b▸%b Generating autoinstall configuration...\r' "$CLR" "$CYAN" "$NC" >&2
    local ESP_MOUNT="/Volumes/${ESP_NAME:-CIDATA}"
    if [ -n "${1:-}" ]; then
        ESP_MOUNT="$1"
    fi
    local STORAGE_TYPE_ARG="dualboot"
    local NETWORK_TYPE_ARG="wifi"
    [ "${STORAGE_LAYOUT:-1}" = "2" ] && STORAGE_TYPE_ARG="fulldisk"
    [ "${NETWORK_TYPE:-1}" = "2" ] && NETWORK_TYPE_ARG="ethernet"

    local _local_staging="${OUTPUT_DIR:-~/.Ubuntify}/staging"
    mkdir -p "$_local_staging/cidata"
    generate_autoinstall "$_local_staging/autoinstall.yaml" "$STORAGE_TYPE_ARG" "$NETWORK_TYPE_ARG"
    if [ "${STORAGE_LAYOUT:-1}" = "1" ]; then
        generate_dualboot_storage "$_local_staging/autoinstall.yaml" "$_local_staging/cidata/user-data" "$INTERNAL_DISK" "${ROOT_SIZE_BYTES:-0}"
    else
        cp "$_local_staging/autoinstall.yaml" "$_local_staging/cidata/user-data"
    fi
    # Prepend #cloud-config header for NoCloud datasource (required by cloud-init)
    local _tmp_user_data="$_local_staging/cidata/user-data.tmp"
    { echo "#cloud-config"; cat "$_local_staging/cidata/user-data"; } > "$_tmp_user_data"
    mv -f "$_tmp_user_data" "$_local_staging/cidata/user-data"
    echo "instance-id: macpro-linux-i1" > "$_local_staging/cidata/meta-data"
    touch "$_local_staging/cidata/vendor-data"
    write_grub_config "$_local_staging"
    if ! verify_yaml_syntax "$_local_staging/autoinstall.yaml"; then
        error "YAML syntax verification failed for autoinstall.yaml"
        return 1
    fi
    if ! verify_autoinstall_schema "$_local_staging/autoinstall.yaml"; then
        error "Autoinstall schema validation failed for autoinstall.yaml"
        return 1
    fi
    log "Transferring autoinstall config to remote ESP..."
    # NoCloud datasource requires user-data/meta-data at ROOT of CIDATA-labeled volume,
    # NOT in a /cidata/ subdirectory. Cloud-init scans root of labeled filesystem only.
    # Also copy /autoinstall.yaml to ESP root as Subiquity fallback (precedence: #4 after NoCloud #3)
    remote_mac_sudo mkdir -p "$ESP_MOUNT/cidata"
    remote_mac_cp "$_local_staging/cidata/user-data" "$ESP_MOUNT/cidata/user-data"
    remote_mac_cp "$_local_staging/cidata/meta-data" "$ESP_MOUNT/cidata/meta-data"
    remote_mac_cp "$_local_staging/cidata/vendor-data" "$ESP_MOUNT/cidata/vendor-data"
    # Copy NoCloud files to ESP root (cloud-init requires them here for labeled-volume detection)
    remote_mac_cp "$_local_staging/cidata/user-data" "$ESP_MOUNT/user-data"
    remote_mac_cp "$_local_staging/cidata/meta-data" "$ESP_MOUNT/meta-data"
    remote_mac_cp "$_local_staging/cidata/vendor-data" "$ESP_MOUNT/vendor-data"
    # Copy autoinstall.yaml to ESP root for Subiquity fallback method #4
    # MUST use the generated user-data (with all placeholders substituted), NOT the raw template.
    # The raw template still has __ROOT_SIZE_BYTES__ etc. which breaks curtin if Subiquity reads it.
    # Strip the #cloud-config header — Subiquity fallback doesn't need it.
    local _ai_fallback="$_local_staging/autoinstall-fallback.yaml"
    tail -n +2 "$_local_staging/cidata/user-data" > "$_ai_fallback"
    remote_mac_cp "$_ai_fallback" "$ESP_MOUNT/autoinstall.yaml"
    rm -f "$_ai_fallback"
    if [ "${STORAGE_LAYOUT:-1}" = "1" ]; then
        if ! remote_mac_exec grep -q 'preserve: true' "$ESP_MOUNT/user-data" 2>/dev/null; then
            die "Generated user-data lacks preserved partition entries — macOS partitions would be wiped"
        fi
    fi
    printf '\r%b  %b✓%b Configuration generated                \n' "$CLR" "$GREEN" "$NC" >&2
}

_phase_verify_bless() {
    printf '\r%b  %b▸%b Verifying ESP contents and boot...    \r' "$CLR" "$CYAN" "$NC" >&2
    local ESP_MOUNT="/Volumes/${ESP_NAME:-CIDATA}"
    if [ -n "${1:-}" ]; then
        ESP_MOUNT="$1"
    fi
    verify_esp_contents "$ESP_MOUNT"
    if [ -z "${_ESP_DEVICE:-}" ]; then
        warn "ESP device not detected — skipping bless (boot selection must be done manually)"
        log "Recovery Mode workaround: boot to Recovery (Cmd+R), run 'csrutil enable --without nvram', then retry"
        return 1
    fi
    attempt_bless "$ESP_MOUNT" "$_ESP_DEVICE" >/dev/null
    if ! verify_bless_result "$ESP_MOUNT"; then
        warn "Bless verification failed — manual boot selection required"
        log "Recovery Mode workaround: boot to Recovery (Cmd+R), run 'csrutil enable --without nvram', then retry"
        return 1
    fi

    if [ -n "${APFS_CONTAINER:-}" ]; then
        if ! check_recovery_health "$APFS_CONTAINER"; then
            warn "CRITICAL: macOS Recovery partition is no longer healthy after deployment!"
            warn "Recovery may not appear in the boot picker. To repair: boot to Internet Recovery (Cmd+Option+R)."
            warn "Deployment succeeded but system recovery options are degraded."
        else
            log "Recovery partition verified healthy after deployment"
        fi
    fi

    printf '\r%b  %b✓%b Boot verification complete             \n' "$CLR" "$GREEN" "$NC" >&2
    return 0
}

preflight_checks() {
    log "Running preflight checks..."

    log "Remote mode: checking target host connectivity..."
    if ! remote_mac_exec echo "SSH connectivity OK" >/dev/null 2>&1; then
        die "Cannot connect to target host '${TARGET_HOST:-macpro}' via SSH. Verify SSH config and network."
    fi
    log "Remote mode: checking tools on target..."
    remote_mac_exec command -v xorriso >/dev/null 2>&1 || warn "xorriso not found on target. Install with: brew install xorriso"
    remote_mac_exec command -v sgdisk >/dev/null 2>&1 || warn "sgdisk not found on target. Install with: brew install gptfdisk"
    remote_mac_exec command -v python3 >/dev/null 2>&1 || warn "python3 not found on target"

    log "Running on target: $(remote_mac_exec sw_vers -productName 2>/dev/null || echo 'unknown') $(remote_mac_exec sw_vers -productVersion 2>/dev/null || echo 'unknown')"

    local FV_STATUS
    FV_STATUS=$(remote_mac_exec fdesetup status 2>/dev/null | grep -o 'On\|Off' | head -1 || echo "unknown")
    if [ "$FV_STATUS" = "On" ]; then
        warn "FileVault is ON on target — may interfere with APFS resize"
    fi

    if type verify_headless_readiness >/dev/null 2>&1; then
        local vhr_host=""
        if [ -n "${TARGET_HOST:-}" ]; then
            vhr_host="$TARGET_HOST"
        fi
        verify_headless_readiness "$vhr_host" || warn "Headless readiness issues detected on target — deployment may require manual intervention"
    fi
}

deploy_internal_partition() {
    log "Starting internal partition deployment..."

    journal_init "1" || die "Cannot initialize deployment journal"

    # State vars (global for rollback access)
    _ESP_CREATED=0
    _APFS_RESIZED=0
    _APFS_ORIGINAL_SIZE=""
    _ESP_DEVICE=""

    export _ESP_CREATED _APFS_RESIZED _APFS_ORIGINAL_SIZE _ESP_DEVICE

    local ISO_PATH
    ISO_PATH=$(detect_iso)
    log "Using ISO: $ISO_PATH"

    preflight_checks

    run_phased "1" "$PHASES_INTERNAL" \
        _phase_analyze \
        _phase_shrink_apfs \
        _phase_create_esp \
        _phase_create_root \
        _phase_extract_iso \
        _phase_copy_pkgs \
        _phase_generate_config \
        _phase_verify_bless

    local phased_result=$?

    if [ $phased_result -eq 0 ]; then
        _DEPLOY_COMPLETED=1
        log "Deployment complete!"
        log "Boot selection: Hold Option key at startup, select CIDATA"
        show_success_instructions
    fi

    return $phased_result
}

deploy_usb() {
    log "Starting USB deployment..."

    journal_init "2" || die "Cannot initialize deployment journal"

    if [ -z "${INTERNAL_DISK:-}" ]; then
        analyze_disk_layout INTERNAL_DISK APFS_CONTAINER
    fi

    local ISO_PATH
    ISO_PATH=$(detect_iso)
    log "Using ISO: $ISO_PATH"
    export ISO_PATH

    run_phased "2" "$PHASES_USB" \
        _phase_detect_usb \
        _phase_partition_usb \
        _phase_extract_iso_usb \
        _phase_copy_pkgs_usb \
        _phase_generate_config_usb \
        _phase_verify_usb

    local phased_result=$?

    if [ $phased_result -eq 0 ]; then
        _DEPLOY_COMPLETED=1
        log "USB deployment complete!"
        show_usb_instructions
    fi

    return $phased_result
}

# VM test deployment phase functions
# These correspond to PHASES_VM="check_vbox find_iso build_iso create_vm start_monitor"

_phase_check_vbox() {
    if ! command -v VBoxManage >/dev/null 2>&1; then
        die "VirtualBox not found. Install from https://www.virtualbox.org/ or: brew install --cask virtualbox"
    fi
    journal_set "VBOX_AVAILABLE" "yes"
}

_phase_find_iso() {
    local BASE_ISO=""
    for loc in "$SCRIPT_DIR"/prereqs/ubuntu-24.04*.iso "$HOME"/Downloads/ubuntu-24.04*.iso; do
        if [ -f "$loc" ]; then
            BASE_ISO="$loc"
            break
        fi
    done
    if [ -z "$BASE_ISO" ]; then
        die "Stock Ubuntu Server ISO not found in prereqs/. Download from https://ubuntu.com/download/server"
    fi
    log "Using base ISO: $BASE_ISO"
    export BASE_ISO
    journal_set "BASE_ISO" "$BASE_ISO"
}

_phase_build_iso() {
    local VM_DIR="${SCRIPT_DIR}/tests/vm"
    local VM_ISO="${OUTPUT_DIR}/ubuntu-vmtest.iso"
    export VM_ISO
    if [ ! -f "$VM_ISO" ]; then
        log "Building VM test ISO..."
        sudo "${SCRIPT_DIR}/lib/build-iso.sh" --vm || die "VM ISO build failed"
    else
        log "VM test ISO already exists: $VM_ISO"
        if tui_confirm "Rebuild ISO?" "VM test ISO already exists. Rebuild?"; then
            sudo "${SCRIPT_DIR}/lib/build-iso.sh" --vm || die "VM ISO build failed"
        fi
    fi
    [ -f "$VM_ISO" ] || die "VM test ISO not found after build"
    journal_set "VM_ISO" "$VM_ISO"
}

_phase_create_vm() {
    local VM_DIR="${SCRIPT_DIR}/tests/vm"
    local VM_ISO="${1:-${OUTPUT_DIR}/ubuntu-vmtest.iso}"
    local VM_NAME="macpro-vmtest"
    export VM_NAME
    if VBoxManage list vms 2>/dev/null | grep -q "\"$VM_NAME\""; then
        log "VM '$VM_NAME' already exists"
        if tui_confirm "Recreate VM?" "VM '$VM_NAME' already exists. Recreate?"; then
            "$VM_DIR/create-vm.sh" --force || die "VM creation failed"
        fi
    else
        log "Creating VirtualBox VM..."
        "$VM_DIR/create-vm.sh" || die "VM creation failed"
    fi
    journal_set "VM_CREATED" "yes"
}

_phase_start_monitor() {
    if ! lsof -i :8080 >/dev/null 2>&1; then
        log "Starting monitoring server..."
        (cd "$SCRIPT_DIR/macpro-monitor" && ./start.sh) || warn "Monitor start failed (non-critical)"
        sleep 2
    fi
    journal_set "MONITOR_STARTED" "yes"
}

deploy_vm_test() {
    log "Starting VM test deployment..."

    journal_init "4" || die "Cannot initialize deployment journal"

    run_phased "4" "$PHASES_VM" \
        _phase_check_vbox \
        _phase_find_iso \
        _phase_build_iso \
        _phase_create_vm \
        _phase_start_monitor

    local phased_result=$?

    if [ $phased_result -eq 0 ]; then
        _DEPLOY_COMPLETED=1
        echo ""
        log "VM test environment ready!"
        echo ""
        echo "  Next steps:"
        echo "    1. Monitor: open http://localhost:8080 in a browser"
        echo "    2. Run test: cd tests/vm && ./test-vm.sh"
        echo "    3. SSH into VM (when ready): ssh -p 2222 ubuntu@localhost"
        echo "    4. Serial console log: tail -f /tmp/vmtest-serial.log"
        echo "    5. Stop VM: cd tests/vm && ./test-vm.sh stop"
        echo "    6. Grab logs: cd tests/vm && ./test-vm.sh logs"
        echo ""
    else
        warn "VM test deployment failed, cleaning up..."
        rollback_vm
    fi

    return $phased_result
}

deploy_manual() {
    log "Starting full manual USB deployment..."

    show_header
    echo "Full Manual Mode"
    echo ""
    echo "This will create a bootable USB with the standard Ubuntu ISO."
    echo "You'll handle all installation choices manually (partitioning, network, etc.)"
    echo ""

    # Look for standard Ubuntu ISO
    local ISO_PATH=""
    for loc in "$SCRIPT_DIR"/prereqs/ubuntu-24.04*.iso "$SCRIPT_DIR"/prereqs/*.iso "$HOME"/Downloads/ubuntu-24.04*.iso; do
        if [ -f "$loc" ]; then
            ISO_PATH="$loc"
            break
        fi
    done

    if [ -z "$ISO_PATH" ]; then
        tui_input "ISO Path" "Enter path to standard Ubuntu Server ISO" "$ISO_PATH"
        ISO_PATH="$_TUI_RESULT"
    fi

    if [ ! -f "$ISO_PATH" ]; then
        die "ISO not found: $ISO_PATH"
    fi

    log "Using ISO: $ISO_PATH"

    select_usb_device TARGET_DEVICE

    if ! remote_mac_exec diskutil info "$TARGET_DEVICE" 2>/dev/null | grep -qi "removable\|external\|usb"; then
        echo ""
        warn "WARNING: $TARGET_DEVICE does not appear to be a USB/removable device!"
        warn "Writing to an internal device could DESTROY all data on it."
        echo ""
        if ! tui_confirm "WARNING" "This will ERASE ALL DATA on the selected USB drive.\n\nProceed?"; then
            die "Deployment cancelled — target device does not appear to be removable"
        fi
    fi

    echo ""
    warn "CRITICAL WARNING: dd writes directly to the device and ERASES all data."
    warn "This operation has NO ROLLBACK. The USB will be completely wiped."
    echo ""
    echo "WARNING: This will ERASE all data on $TARGET_DEVICE"
    echo "The ISO will be written directly to the device (dd style)"
    if ! tui_confirm "Confirm" "Ready to write ISO to USB. Proceed?"; then
        die "Manual deployment cancelled"
    fi

    log "Writing ISO to USB (this may take several minutes)..."
    remote_mac_retry_diskutil unmountDisk "$TARGET_DEVICE" 2>/dev/null || true
    sleep 2

    dry_run_exec "Write ISO to USB with dd" \
        remote_mac_sudo --timeout 900 dd if="$ISO_PATH" of="$TARGET_DEVICE" bs=1m || die "Failed to write ISO to USB"

    remote_mac_exec sync
    log "ISO written successfully"

    remote_mac_retry_diskutil eject "$TARGET_DEVICE" 2>/dev/null || true

    show_manual_instructions
}

# Instruction display functions
# USB deployment phase functions
# These correspond to PHASES_USB="detect_usb partition_usb extract_iso copy_pkgs generate_config verify"

_phase_detect_usb() {
    select_usb_device TARGET_DEVICE
    journal_set "TARGET_DEVICE" "$TARGET_DEVICE"
    if ! remote_mac_exec diskutil info "$TARGET_DEVICE" 2>/dev/null | grep -qi "removable\|external\|usb"; then
        echo ""
        warn "WARNING: $TARGET_DEVICE does not appear to be a USB/removable device!"
        warn "Writing to an internal device could DESTROY all data on it."
        echo ""
        if ! tui_confirm "WARNING" "This will ERASE ALL DATA on the selected USB drive.\n\nProceed?"; then
            die "Deployment cancelled — target device does not appear to be removable"
        fi
    fi
}

_phase_partition_usb() {
    log "Preparing USB device $TARGET_DEVICE..."
    remote_mac_retry_diskutil unmountDisk "$TARGET_DEVICE" 2>/dev/null || true
    sleep 2
    log "Creating FAT32 partition on USB..."
    dry_run_exec "Partition USB device $TARGET_DEVICE" \
        remote_mac_retry_diskutil partitionDisk "$TARGET_DEVICE" GPT FAT32 "CIDATA" 100% 2>/dev/null || die "Failed to partition USB device"
    sleep 2
    local USB_PARTITION
    USB_PARTITION=$(remote_mac_exec diskutil list "$TARGET_DEVICE" | grep "CIDATA" | grep -oE 'disk[0-9]+s[0-9]+' | head -1 || true)
    [ -n "$USB_PARTITION" ] || die "Cannot identify USB partition"
    remote_mac_exec mkdir -p /Volumes/CIDATA 2>/dev/null || true
    remote_mac_sudo mount_msdos "/dev/$USB_PARTITION" /Volumes/CIDATA 2>/dev/null || \
        remote_mac_retry_diskutil mount "/dev/$USB_PARTITION" 2>/dev/null || true
    local USB_MOUNT="/Volumes/CIDATA"
    remote_mac_dir_exists "$USB_MOUNT" || die "USB not mounted after format"
    log "USB mounted at: $USB_MOUNT"
    export USB_MOUNT
}

_phase_extract_iso_usb() {
    local USB_MOUNT="/Volumes/CIDATA"
    if [ -n "${1:-}" ]; then
        USB_MOUNT="$1"
    fi
    echo "[....] Extracting Ubuntu ISO to USB... (this may take 2-5 minutes)" >&2

    local host="${TARGET_HOST:-macpro}"
    log_info "Transferring ISO to $host..."
    local REMOTE_ISO="/tmp/ubuntu-macpro.iso"
    if ! remote_mac_cp "$ISO_PATH" "$REMOTE_ISO"; then
        die "Failed to transfer ISO to $host"
    fi
    log_info "ISO transferred. Extracting on remote host..."
    echo "[....] Extracting ISO contents on $host..." >&2
    if ! remote_mac_sudo --timeout 600 xorriso -osirrox on -indev "$REMOTE_ISO" -extract / "$USB_MOUNT" 2>/dev/null; then
        echo "[FAIL] Remote ISO extraction failed" >&2
        remote_mac_exec rm -f "$REMOTE_ISO" 2>/dev/null || true
        die "Failed to extract ISO contents on remote host"
    fi
    remote_mac_exec rm -f "$REMOTE_ISO" 2>/dev/null || true
    echo "[ OK ] Remote ISO extraction complete" >&2
    if ! verify_iso_extraction "$USB_MOUNT"; then
        die "ISO extraction verification failed on remote host — cannot retry (remote ISO deleted)"
    fi
}

_phase_copy_pkgs_usb() {
    local USB_MOUNT="/Volumes/CIDATA"
    if [ -n "${1:-}" ]; then
        USB_MOUNT="$1"
    fi
    local pkgs_copied=0

    if ! remote_mac_dir_exists "$USB_MOUNT/macpro-pkgs" || \
       ! remote_mac_exec "ls $USB_MOUNT/macpro-pkgs/*.deb >/dev/null 2>&1"; then
        echo "[....] Copying driver packages to USB on remote host..." >&2
        remote_mac_sudo mkdir -p "$USB_MOUNT/macpro-pkgs"
        remote_mac_cp_contents "$SCRIPT_DIR/packages/" "$USB_MOUNT/macpro-pkgs/" 2>/dev/null && pkgs_copied=1 || warn "Some packages may be missing"
        if [ "$pkgs_copied" -eq 1 ]; then
            echo "[ OK ] Driver packages copied" >&2
        fi
    fi
    if [ -d "$SCRIPT_DIR/packages/dkms-patches" ]; then
        local DKMS_DST="$USB_MOUNT/macpro-pkgs/dkms-patches"
        if ! remote_mac_dir_exists "$DKMS_DST"; then
            echo "[....] Copying DKMS patches to remote host..." >&2
            remote_mac_sudo mkdir -p "$DKMS_DST"
            remote_mac_cp_dir "$SCRIPT_DIR/packages/dkms-patches/" "$DKMS_DST/" || die "Failed to copy DKMS patches — WiFi driver cannot compile without them"
            echo "[ OK ] DKMS patches copied" >&2
        fi
    fi
    if [ "$pkgs_copied" -eq 1 ]; then
        if ! remote_mac_exec "ls $USB_MOUNT/macpro-pkgs/*.deb >/dev/null 2>&1"; then
            error "Package verification failed: no .deb files found on remote host after copy"
            return 1
        fi
    fi
}

_phase_generate_config_usb() {
    local USB_MOUNT="/Volumes/CIDATA"
    if [ -n "${1:-}" ]; then
        USB_MOUNT="$1"
    fi
    local STORAGE_TYPE_ARG="dualboot"
    local NETWORK_TYPE_ARG="wifi"
    [ "${STORAGE_LAYOUT:-1}" = "2" ] && STORAGE_TYPE_ARG="fulldisk"
    [ "${NETWORK_TYPE:-1}" = "2" ] && NETWORK_TYPE_ARG="ethernet"

    local _local_staging="${OUTPUT_DIR:-~/.Ubuntify}/staging"
    mkdir -p "$_local_staging/cidata"
    generate_autoinstall "$_local_staging/autoinstall.yaml" "$STORAGE_TYPE_ARG" "$NETWORK_TYPE_ARG"
    if [ "${STORAGE_LAYOUT:-1}" = "1" ]; then
        generate_dualboot_storage "$_local_staging/autoinstall.yaml" "$_local_staging/cidata/user-data" "$INTERNAL_DISK" "${ROOT_SIZE_BYTES:-0}"
    else
        cp "$_local_staging/autoinstall.yaml" "$_local_staging/cidata/user-data"
    fi
    # NoCloud requires #cloud-config header; Subiquity precedence: root media > NoCloud
    # removing /autoinstall.yaml from USB forces Subiquity to use cidata/ exclusively
    local _tmp_user_data="$_local_staging/cidata/user-data.tmp"
    { echo "#cloud-config"; cat "$_local_staging/cidata/user-data"; } > "$_tmp_user_data"
    mv -f "$_tmp_user_data" "$_local_staging/cidata/user-data"
    echo "instance-id: macpro-linux-i1" > "$_local_staging/cidata/meta-data"
    touch "$_local_staging/cidata/vendor-data"
    write_grub_config "$_local_staging"
    if ! verify_yaml_syntax "$_local_staging/autoinstall.yaml"; then
        error "YAML syntax verification failed for autoinstall.yaml"
        return 1
    fi
    if ! verify_autoinstall_schema "$_local_staging/autoinstall.yaml"; then
        error "Autoinstall schema validation failed for autoinstall.yaml"
        return 1
    fi
    log "Transferring autoinstall config to remote USB..."
    remote_mac_sudo mkdir -p "$USB_MOUNT/cidata"
    remote_mac_cp "$_local_staging/cidata/user-data" "$USB_MOUNT/cidata/user-data"
    remote_mac_cp "$_local_staging/cidata/meta-data" "$USB_MOUNT/cidata/meta-data"
    remote_mac_cp "$_local_staging/cidata/vendor-data" "$USB_MOUNT/cidata/vendor-data"
    # Copy NoCloud files to USB root (cloud-init requires them here for labeled-volume detection)
    remote_mac_cp "$_local_staging/cidata/user-data" "$USB_MOUNT/user-data"
    remote_mac_cp "$_local_staging/cidata/meta-data" "$USB_MOUNT/meta-data"
    remote_mac_cp "$_local_staging/cidata/vendor-data" "$USB_MOUNT/vendor-data"
    # Subiquity fallback — use generated user-data (substituted), NOT raw template
    local _ai_fallback_usb="$_local_staging/autoinstall-fallback.yaml"
    tail -n +2 "$_local_staging/cidata/user-data" > "$_ai_fallback_usb"
    remote_mac_cp "$_ai_fallback_usb" "$USB_MOUNT/autoinstall.yaml"
    rm -f "$_ai_fallback_usb"
    if ! verify_cidata_structure "$USB_MOUNT"; then
        error "CIDATA structure verification failed on remote host"
        return 1
    fi
}

_phase_verify_usb() {
    local USB_MOUNT="/Volumes/CIDATA"
    if [ -n "${1:-}" ]; then
        USB_MOUNT="$1"
    fi
    verify_esp_contents "$USB_MOUNT"
    remote_mac_retry_diskutil unmountDisk "$TARGET_DEVICE" 2>/dev/null || true
}

show_success_instructions() {
    echo ""
    echo "========================================="
    echo " READY TO REBOOT"
    echo "========================================="
    echo ""
    echo "Boot device set successfully!"
    echo ""
    echo "On next reboot, Mac Pro will boot into Ubuntu installer."
    echo ""
    echo "To start: sudo reboot"
    echo ""
    echo "POST-INSTALL:"
    echo "  After Ubuntu installs, run 'sudo boot-macos' to return to macOS"
    echo ""
}

show_usb_instructions() {
    echo ""
    echo "========================================="
    echo " USB DRIVE READY"
    echo "========================================="
    echo ""
    echo "Bootable USB created successfully!"
    echo ""
    echo "BOOT PROCEDURE:"
    echo ""
    echo "  1. Insert USB into Mac Pro"
    echo "  2. Hold Option key at startup"
    echo "  3. Select 'CIDATA' (EFI Boot) from boot menu"
    echo "  4. GRUB will auto-select autoinstall after 3 seconds"
    echo ""
    echo "STORAGE LAYOUT:"
    if [ "$STORAGE_LAYOUT" = "1" ]; then
        echo "    Dual-boot mode selected — ensure you have free space"
        echo "    on the internal disk for Ubuntu installation."
    else
        echo "    Full-disk mode selected — ALL DATA WILL BE ERASED"
    fi
    echo ""
    echo "NETWORK:"
    if [ "$NETWORK_TYPE" = "1" ]; then
        echo "    WiFi mode — driver will compile automatically during install"
    else
        echo "    Ethernet mode — network available immediately"
    fi
    echo ""
    echo "After install, efibootmgr from Ubuntu will manage boot order."
    echo ""
}

show_manual_instructions() {
    echo ""
    echo "========================================="
    echo " MANUAL USB READY"
    echo "========================================="
    echo ""
    echo "Standard Ubuntu USB created successfully!"
    echo ""
    echo "BOOT PROCEDURE:"
    echo ""
    echo "  1. Insert USB into Mac Pro"
    echo "  2. Hold Option key at startup"
    echo "  3. Select 'EFI Boot' from boot menu"
    echo "  4. Follow Ubuntu installer prompts"
    echo ""
    echo "POST-INSTALL SETUP (run these on the new Ubuntu system):"
    echo ""
    echo "  1. Copy packages from this Mac to the Ubuntu system:"
    echo "     scp -r $SCRIPT_DIR/packages ubuntu@<new-ip>:~/"
    echo ""
    echo "  2. On the Ubuntu system, install WiFi driver:"
    echo "     cd ~/packages"
    echo "     sudo apt install dkms"
    echo "     sudo dpkg -i broadcom-sta-dkms_*.deb"
    echo ""
    echo "  3. Configure netplan for WiFi (edit /etc/netplan/01-wifi.yaml):"
    echo "     network:"
    echo "       version: 2"
    echo "       wifis:"
    echo "         wl0:"
    echo "           dhcp4: true"
    echo "           access-points:"
    echo "             YOUR_SSID:"
    echo "               password: YOUR_PASSWORD"
    echo ""
    echo "  4. Apply netplan and reboot:"
    echo "     sudo netplan apply"
    echo ""
    echo "  5. Configure GRUB for Mac Pro GPU:"
    echo "     sudo nano /etc/default/grub"
    echo "     # Add to GRUB_CMDLINE_LINUX_DEFAULT: nomodeset amdgpu.si.modeset=0"
    echo "     sudo update-grub"
    echo ""
    echo "  6. Install UFW:"
    echo "     sudo apt install ufw"
    echo "     sudo ufw default deny incoming"
    echo "     sudo ufw allow ssh"
    echo "     sudo ufw enable"
    echo ""
}
