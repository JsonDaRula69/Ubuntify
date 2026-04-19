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
source "${LIB_DIR:-./lib}/tui.sh"
source "${LIB_DIR:-./lib}/dryrun.sh"

: "${SCRIPT_DIR:=$(cd "$(dirname "$0")" && pwd)}"
STORAGE_LAYOUT="${STORAGE_LAYOUT:-1}"
NETWORK_TYPE="${NETWORK_TYPE:-1}"
INTERNAL_DISK="${INTERNAL_DISK:-}"
APFS_CONTAINER="${APFS_CONTAINER:-}"
TARGET_DEVICE="${TARGET_DEVICE:-}"

# Internal partition deployment phase functions
# These correspond to PHASES_INTERNAL="analyze shrink_apfs create_esp extract_iso copy_pkgs generate_config verify_bless"

_phase_analyze() {
    analyze_disk_layout INTERNAL_DISK APFS_CONTAINER
    snapshot_disk_layout "$INTERNAL_DISK"
    journal_save_originals INTERNAL_DISK "$INTERNAL_DISK" APFS_CONTAINER "$APFS_CONTAINER"
}

_phase_shrink_apfs() {
    shrink_apfs_if_needed "$APFS_CONTAINER" "$INTERNAL_DISK" _APFS_RESIZED _APFS_ORIGINAL_SIZE
    journal_set "APFS_RESIZED" "$_APFS_RESIZED"
    journal_set "ORIGINAL_APFS_SIZE" "${_APFS_ORIGINAL_SIZE:-}"
    if [ "$_APFS_RESIZED" -eq 1 ] && [ -n "${_APFS_ORIGINAL_SIZE:-}" ]; then
        local TARGET_MACOS_GB
        TARGET_MACOS_GB=$(echo "$_APFS_ORIGINAL_SIZE" | awk '{print int($1)}')
        if ! verify_apfs_resize "$APFS_CONTAINER" "$TARGET_MACOS_GB"; then
            warn "APFS resize verification failed (expected ~${TARGET_MACOS_GB}GB), but continuing"
        fi
    fi
}

_phase_create_esp() {
    local ESP_MOUNT
    ESP_MOUNT=$(create_esp_partition "$INTERNAL_DISK" _ESP_CREATED _ESP_DEVICE)
    journal_set "ESP_CREATED" "$_ESP_CREATED"
    journal_set "ESP_DEVICE" "${_ESP_DEVICE:-}"
    export ESP_MOUNT
    if ! verify_esp_mount "$ESP_MOUNT"; then
        warn "ESP mount verification failed, attempting self-heal..."
        local attempt=1
        while [ "$attempt" -le 3 ]; do
            retry_diskutil mount "/dev/$_ESP_DEVICE" 2>/dev/null || true
            sleep 2
            if verify_esp_mount "$ESP_MOUNT"; then
                log "ESP mount successful after retry $attempt"
                return 0
            fi
            attempt=$((attempt + 1))
        done
        error "ESP mount verification failed after self-heal attempts"
        return 1
    fi
}

_phase_extract_iso() {
    local ESP_MOUNT="/Volumes/${ESP_NAME:-CIDATA}"
    if [ -n "${1:-}" ]; then
        ESP_MOUNT="$1"
    fi
    log_info "Extracting Ubuntu ISO to ESP... (this may take 2-5 minutes)"
    log_info "  ISO: $ISO_PATH"
    log_info "  Target: $ESP_MOUNT"
    echo "[....] Extracting ISO contents..." >&2
    if ! retry_xorriso -osirrox on -indev "$ISO_PATH" -extract / "$ESP_MOUNT" 2>/dev/null; then
        echo "[FAIL] ISO extraction failed" >&2
        die "Failed to extract ISO contents"
    fi
    echo "[ OK ] ISO extraction complete" >&2
    if ! verify_iso_extraction "$ESP_MOUNT"; then
        warn "ISO extraction verification failed, cleaning and retrying..."
        echo "[....] Retrying ISO extraction..." >&2
        rm -rf "${ESP_MOUNT:?}"/* 2>/dev/null || true
        if ! retry_xorriso -osirrox on -indev "$ISO_PATH" -extract / "$ESP_MOUNT" 2>/dev/null; then
            echo "[FAIL] ISO extraction failed on retry" >&2
            error "ISO extraction verification failed after retry"
            return 1
        fi
        echo "[ OK ] ISO extraction complete (retry)" >&2
    fi
}

_phase_copy_pkgs() {
    local ESP_MOUNT="/Volumes/${ESP_NAME:-CIDATA}"
    if [ -n "${1:-}" ]; then
        ESP_MOUNT="$1"
    fi
    local pkgs_copied=0
    if ! ls "$ESP_MOUNT/macpro-pkgs/"*.deb 1>/dev/null 2>&1; then
        echo "[....] Copying driver packages to ESP..." >&2
        mkdir -p "$ESP_MOUNT/macpro-pkgs"
        cp "$SCRIPT_DIR/packages/"*.deb "$ESP_MOUNT/macpro-pkgs/" 2>/dev/null && pkgs_copied=1 || warn "Some packages may be missing"
        if [ "$pkgs_copied" -eq 1 ]; then
            echo "[ OK ] Driver packages copied ($(ls "$ESP_MOUNT/macpro-pkgs/"*.deb 2>/dev/null | wc -l | tr -d ' ') files)" >&2
        fi
    fi
    if [ -d "$SCRIPT_DIR/packages/dkms-patches" ] && [ ! -d "$ESP_MOUNT/macpro-pkgs/dkms-patches" ]; then
        echo "[....] Copying DKMS patches..." >&2
        mkdir -p "$ESP_MOUNT/macpro-pkgs/dkms-patches"
        cp "$SCRIPT_DIR/packages/dkms-patches/"* "$ESP_MOUNT/macpro-pkgs/dkms-patches/" || die "Failed to copy DKMS patches — WiFi driver cannot compile without them"
        echo "[ OK ] DKMS patches copied" >&2
    fi
    if [ "$pkgs_copied" -eq 1 ] && ! ls "$ESP_MOUNT/macpro-pkgs/"*.deb 1>/dev/null 2>&1; then
        error "Package verification failed: no .deb files found after copy"
        return 1
    fi
}

_phase_generate_config() {
    local ESP_MOUNT="/Volumes/${ESP_NAME:-CIDATA}"
    if [ -n "${1:-}" ]; then
        ESP_MOUNT="$1"
    fi
    local STORAGE_TYPE_ARG="dualboot"
    local NETWORK_TYPE_ARG="wifi"
    [ "${STORAGE_LAYOUT:-1}" = "2" ] && STORAGE_TYPE_ARG="fulldisk"
    [ "${NETWORK_TYPE:-1}" = "2" ] && NETWORK_TYPE_ARG="ethernet"
    generate_autoinstall "$ESP_MOUNT/autoinstall.yaml" "$STORAGE_TYPE_ARG" "$NETWORK_TYPE_ARG"
    log "Creating cidata structure..."
    mkdir -p "$ESP_MOUNT/cidata"
    if [ "${STORAGE_LAYOUT:-1}" = "1" ]; then
        generate_dualboot_storage "$ESP_MOUNT/autoinstall.yaml" "$ESP_MOUNT/cidata/user-data" "$INTERNAL_DISK"
    else
        cp "$ESP_MOUNT/autoinstall.yaml" "$ESP_MOUNT/cidata/user-data"
    fi
    # Validate preserve entries for dual-boot
    if [ "${STORAGE_LAYOUT:-1}" = "1" ]; then
        if ! grep -q 'preserve: true' "$ESP_MOUNT/cidata/user-data" 2>/dev/null; then
            die "Generated user-data lacks preserve:true entries — macOS partitions would be wiped"
        fi
        local PRESERVE_COUNT
        PRESERVE_COUNT=$(grep -c 'preserve: true' "$ESP_MOUNT/cidata/user-data" 2>/dev/null || echo "0")
        log "Preserve entries in user-data: $PRESERVE_COUNT"
    fi
    [ -f "$ESP_MOUNT/cidata/meta-data" ] || echo "instance-id: macpro-linux-i1" > "$ESP_MOUNT/cidata/meta-data"
    [ -f "$ESP_MOUNT/cidata/vendor-data" ] || touch "$ESP_MOUNT/cidata/vendor-data"
    write_grub_config "$ESP_MOUNT"
    # Verification
    if ! verify_cidata_structure "$ESP_MOUNT"; then
        error "CIDATA structure verification failed"
        return 1
    fi
    if ! verify_yaml_syntax "$ESP_MOUNT/autoinstall.yaml"; then
        error "YAML syntax verification failed for autoinstall.yaml"
        return 1
    fi
    if ! verify_autoinstall_schema "$ESP_MOUNT/autoinstall.yaml"; then
        error "Autoinstall schema validation failed for autoinstall.yaml"
        return 1
    fi
}

_phase_verify_bless() {
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
    # attempt_bless tries systemsetup/bless methods; result is verified independently
    attempt_bless "$ESP_MOUNT" "$_ESP_DEVICE" >/dev/null
    # verify_bless_result re-checks via bless --info --getboot (independent verification)
    if ! verify_bless_result "$ESP_MOUNT"; then
        warn "Bless verification failed — manual boot selection required"
        log "Recovery Mode workaround: boot to Recovery (Cmd+R), run 'csrutil enable --without nvram', then retry"
        return 1
    fi
    return 0
}

preflight_checks() {
    log "Running preflight checks..."

    command -v xorriso >/dev/null 2>&1 || die "xorriso not found. Install with: brew install xorriso"
    command -v sgdisk >/dev/null 2>&1 || die "sgdisk not found. Install with: brew install gptfdisk"
    command -v comm >/dev/null 2>&1 || die "comm not found. Install with: brew install coreutils"
    command -v python3 >/dev/null 2>&1 || die "python3 not found. Install with: brew install python3"

    log "Running on: $(sw_vers -productName) $(sw_vers -productVersion)"

     # SIP status check removed per project assumption: SIP always enabled.
     # Bless failure handling provides generic guidance.

    # Check FileVault
    local FV_STATUS
    FV_STATUS=$(fdesetup status 2>/dev/null | grep -o 'On\|Off' | head -1 || echo "unknown")
    if [ "$FV_STATUS" = "On" ]; then
        warn "FileVault is ON — may interfere with APFS resize"
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
        _phase_extract_iso \
        _phase_copy_pkgs \
        _phase_generate_config \
        _phase_verify_bless

    local phased_result=$?

    if [ $phased_result -eq 0 ]; then
        journal_destroy
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
        journal_destroy
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
        journal_destroy
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
        ISO_PATH=$(tui_input "ISO Path" "Enter path to standard Ubuntu Server ISO" "$ISO_PATH")
    fi

    if [ ! -f "$ISO_PATH" ]; then
        die "ISO not found: $ISO_PATH"
    fi

    log "Using ISO: $ISO_PATH"

    select_usb_device TARGET_DEVICE

    if ! diskutil info "$TARGET_DEVICE" 2>/dev/null | grep -qi "removable\|external\|usb"; then
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

    # Unmount and write ISO
    log "Writing ISO to USB (this may take several minutes)..."
    retry_diskutil unmountDisk "$TARGET_DEVICE" 2>/dev/null || true
    sleep 2

    dry_run_exec "Write ISO to USB with dd" \
        sudo dd if="$ISO_PATH" of="$TARGET_DEVICE" bs=1m || die "Failed to write ISO to USB"

    sync
    log "ISO written successfully"

    retry_diskutil eject "$TARGET_DEVICE" 2>/dev/null || true

    show_manual_instructions
}

# Instruction display functions
# USB deployment phase functions
# These correspond to PHASES_USB="detect_usb partition_usb extract_iso copy_pkgs generate_config verify"

_phase_detect_usb() {
    select_usb_device TARGET_DEVICE
    journal_set "TARGET_DEVICE" "$TARGET_DEVICE"
    if ! diskutil info "$TARGET_DEVICE" 2>/dev/null | grep -qi "removable\|external\|usb"; then
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
    retry_diskutil unmountDisk "$TARGET_DEVICE" 2>/dev/null || true
    sleep 2
    log "Creating FAT32 partition on USB..."
    dry_run_exec "Partition USB device $TARGET_DEVICE" \
        retry_diskutil partitionDisk "$TARGET_DEVICE" GPT FAT32 "CIDATA" 100% 2>/dev/null || die "Failed to partition USB device"
    sleep 2
    local USB_PARTITION
    USB_PARTITION=$(diskutil list "$TARGET_DEVICE" | grep "CIDATA" | grep -oE 'disk[0-9]+s[0-9]+' | head -1 || true)
    [ -n "$USB_PARTITION" ] || die "Cannot identify USB partition"
    retry_diskutil mount "/dev/$USB_PARTITION" 2>/dev/null || true
    local USB_MOUNT="/Volumes/CIDATA"
    [ -d "$USB_MOUNT" ] || die "USB not mounted after format"
    log "USB mounted at: $USB_MOUNT"
    export USB_MOUNT
}

_phase_extract_iso_usb() {
    local USB_MOUNT="/Volumes/CIDATA"
    if [ -n "${1:-}" ]; then
        USB_MOUNT="$1"
    fi
    echo "[....] Extracting Ubuntu ISO to USB... (this may take 2-5 minutes)" >&2
    if ! retry_xorriso -osirrox on -indev "$ISO_PATH" -extract / "$USB_MOUNT" 2>/dev/null; then
        echo "[FAIL] ISO extraction failed" >&2
        die "Failed to extract ISO contents"
    fi
    echo "[ OK ] ISO extraction complete" >&2
    if ! verify_iso_extraction "$USB_MOUNT"; then
        warn "ISO extraction verification failed, cleaning and retrying..."
        echo "[....] Retrying ISO extraction..." >&2
        rm -rf "${USB_MOUNT:?}"/* 2>/dev/null || true
        if ! retry_xorriso -osirrox on -indev "$ISO_PATH" -extract / "$USB_MOUNT" 2>/dev/null; then
            echo "[FAIL] ISO extraction failed on retry" >&2
            error "ISO extraction verification failed after retry"
            return 1
        fi
        echo "[ OK ] ISO extraction complete (retry)" >&2
    fi
}

_phase_copy_pkgs_usb() {
    local USB_MOUNT="/Volumes/CIDATA"
    if [ -n "${1:-}" ]; then
        USB_MOUNT="$1"
    fi
    local pkgs_copied=0
    if ! ls "$USB_MOUNT/macpro-pkgs/"*.deb 1>/dev/null 2>&1; then
        echo "[....] Copying driver packages to USB..." >&2
        mkdir -p "$USB_MOUNT/macpro-pkgs"
        cp "$SCRIPT_DIR/packages/"*.deb "$USB_MOUNT/macpro-pkgs/" 2>/dev/null && pkgs_copied=1 || warn "Some packages may be missing"
        if [ "$pkgs_copied" -eq 1 ]; then
            echo "[ OK ] Driver packages copied ($(ls "$USB_MOUNT/macpro-pkgs/"*.deb 2>/dev/null | wc -l | tr -d ' ') files)" >&2
        fi
    fi
    if [ -d "$SCRIPT_DIR/packages/dkms-patches" ] && [ ! -d "$USB_MOUNT/macpro-pkgs/dkms-patches" ]; then
        echo "[....] Copying DKMS patches..." >&2
        mkdir -p "$USB_MOUNT/macpro-pkgs/dkms-patches"
        cp "$SCRIPT_DIR/packages/dkms-patches/"* "$USB_MOUNT/macpro-pkgs/dkms-patches/" || die "Failed to copy DKMS patches — WiFi driver cannot compile without them"
        echo "[ OK ] DKMS patches copied" >&2
    fi
    if [ "$pkgs_copied" -eq 1 ] && ! ls "$USB_MOUNT/macpro-pkgs/"*.deb 1>/dev/null 2>&1; then
        error "Package verification failed: no .deb files found after copy"
        return 1
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
    generate_autoinstall "$USB_MOUNT/autoinstall.yaml" "$STORAGE_TYPE_ARG" "$NETWORK_TYPE_ARG"
    log "Creating cidata structure..."
    mkdir -p "$USB_MOUNT/cidata"
    if [ "${STORAGE_LAYOUT:-1}" = "1" ]; then
        generate_dualboot_storage "$USB_MOUNT/autoinstall.yaml" "$USB_MOUNT/cidata/user-data" "$INTERNAL_DISK"
    else
        cp "$USB_MOUNT/autoinstall.yaml" "$USB_MOUNT/cidata/user-data"
    fi
    [ -f "$USB_MOUNT/cidata/meta-data" ] || echo "instance-id: macpro-linux-i1" > "$USB_MOUNT/cidata/meta-data"
    [ -f "$USB_MOUNT/cidata/vendor-data" ] || touch "$USB_MOUNT/cidata/vendor-data"
    write_grub_config "$USB_MOUNT"
    if ! verify_cidata_structure "$USB_MOUNT"; then
        error "CIDATA structure verification failed"
        return 1
    fi
    if ! verify_yaml_syntax "$USB_MOUNT/autoinstall.yaml"; then
        error "YAML syntax verification failed for autoinstall.yaml"
        return 1
    fi
    if ! verify_autoinstall_schema "$USB_MOUNT/autoinstall.yaml"; then
        error "Autoinstall schema validation failed for autoinstall.yaml"
        return 1
    fi
}

_phase_verify_usb() {
    local USB_MOUNT="/Volumes/CIDATA"
    if [ -n "${1:-}" ]; then
        USB_MOUNT="$1"
    fi
    verify_esp_contents "$USB_MOUNT"
    retry_diskutil unmountDisk "$TARGET_DEVICE" 2>/dev/null || true
}

show_blind_boot_instructions() {
    echo ""
    echo "========================================="
    echo " READY TO REBOOT - MANUAL BOOT REQUIRED"
    echo "========================================="
    echo ""
    echo "Boot device NOT set automatically (SIP blocks NVRAM)."
    echo "Manual keyboard selection required at boot."
    echo ""
    echo "BOOT PROCEDURE:"
    echo ""
    echo "  1. Run: sudo shutdown -r now"
    echo "  2. After startup chime, press and HOLD Option key"
    echo "  3. Release Option — Startup Manager shows disk icons"
    echo "  4. Select CIDATA (Ubuntu installer) using arrow keys"
    echo "  5. Press Enter to boot"
    echo ""
    echo "  Left:  Macintosh HD (macOS)"
    echo "  Right: CIDATA (Ubuntu installer)"
    echo ""
    echo "POST-INSTALL:"
    echo "  After Ubuntu installs, run 'sudo boot-macos' to return to macOS"
    echo ""
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
    echo "To start: sudo shutdown -r now"
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
