#!/bin/bash
#
# lib/deploy.sh - Deployment method implementations
#
# Provides deploy_internal_partition, deploy_usb, deploy_manual, and
# deploy_vm_test functions for different deployment scenarios.
#
# Dependencies: lib/colors.sh, lib/utils.sh, lib/detect.sh, lib/disk.sh,
#               lib/autoinstall.sh, lib/bless.sh
#

source "${LIB_DIR:-./lib}/colors.sh"
source "${LIB_DIR:-./lib}/utils.sh"
source "${LIB_DIR:-./lib}/detect.sh"
source "${LIB_DIR:-./lib}/disk.sh"
source "${LIB_DIR:-./lib}/autoinstall.sh"
source "${LIB_DIR:-./lib}/bless.sh"

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "$0")" && pwd)}"
STORAGE_LAYOUT="${STORAGE_LAYOUT:-1}"
NETWORK_TYPE="${NETWORK_TYPE:-1}"
INTERNAL_DISK="${INTERNAL_DISK:-}"
APFS_CONTAINER="${APFS_CONTAINER:-}"
TARGET_DEVICE="${TARGET_DEVICE:-}"

preflight_checks() {
    log "Running preflight checks..."

    command -v xorriso >/dev/null 2>1 || die "xorriso not found. Install with: brew install xorriso"
    command -v sgdisk >/dev/null 2>1 || die "sgdisk not found. Install with: brew install gptfdisk"
    command -v comm >/dev/null 2>1 || die "comm not found. Install with: brew install coreutils"
    command -v python3 >/dev/null 2>1 || die "python3 not found. Install with: brew install python3"

    log "Running on: $(sw_vers -productName) $(sw_vers -productVersion)"

    # Check SIP status
    local SIP_STATUS
    SIP_STATUS=$(csrutil status 2>/dev/null | grep -o 'enabled\|disabled' | head -1 || echo "unknown")
    if [ "$SIP_STATUS" = "enabled" ]; then
        info "SIP is enabled — bless will be attempted but may fail"
    fi

    # Check FileVault
    local FV_STATUS
    FV_STATUS=$(fdesetup status 2>/dev/null | grep -o 'On\|Off' | head -1 || echo "unknown")
    if [ "$FV_STATUS" = "On" ]; then
        warn "FileVault is ON — may interfere with APFS resize"
    fi
}

deploy_internal_partition() {
    log "Starting internal partition deployment..."

    local _ESP_CREATED=0
    local _APFS_RESIZED=0
    local _APFS_ORIGINAL_SIZE=""
    local _ESP_DEVICE=""

    local ISO_PATH
    ISO_PATH=$(detect_iso)
    log "Using ISO: $ISO_PATH"

    preflight_checks
    analyze_disk_layout INTERNAL_DISK APFS_CONTAINER
    shrink_apfs_if_needed "$APFS_CONTAINER" "$INTERNAL_DISK" _APFS_RESIZED _APFS_ORIGINAL_SIZE

    local ESP_MOUNT
    ESP_MOUNT=$(create_esp_partition "$INTERNAL_DISK" _ESP_CREATED _ESP_DEVICE)
    log "ESP mounted at: $ESP_MOUNT"

    export _ESP_CREATED _APFS_RESIZED _APFS_ORIGINAL_SIZE _ESP_DEVICE

    extract_iso_to_esp "$ISO_PATH" "$ESP_MOUNT"

    # Copy driver packages if not present
    if ! ls "$ESP_MOUNT/macpro-pkgs/"*.deb 1>/dev/null 2>1; then
        log "Copying driver packages to ESP..."
        mkdir -p "$ESP_MOUNT/macpro-pkgs"
        cp "$SCRIPT_DIR/packages/"*.deb "$ESP_MOUNT/macpro-pkgs/" 2>/dev/null || warn "Some packages may be missing"
    fi

    if [ -d "$SCRIPT_DIR/packages/dkms-patches" ] && [ ! -d "$ESP_MOUNT/macpro-pkgs/dkms-patches" ]; then
        mkdir -p "$ESP_MOUNT/macpro-pkgs/dkms-patches"
        cp "$SCRIPT_DIR/packages/dkms-patches/"* "$ESP_MOUNT/macpro-pkgs/dkms-patches/" 2>/dev/null || true
    fi

    # Generate autoinstall.yaml based on selections
    local STORAGE_TYPE_ARG="dualboot"
    local NETWORK_TYPE_ARG="wifi"
    [ "$STORAGE_LAYOUT" = "2" ] && STORAGE_TYPE_ARG="fulldisk"
    [ "$NETWORK_TYPE" = "2" ] && NETWORK_TYPE_ARG="ethernet"
    generate_autoinstall "$ESP_MOUNT/autoinstall.yaml" "$STORAGE_TYPE_ARG" "$NETWORK_TYPE_ARG"

    # Create cidata structure
    log "Creating cidata structure..."
    mkdir -p "$ESP_MOUNT/cidata"

    if [ "$STORAGE_LAYOUT" = "1" ]; then
        # Dual-boot: generate dynamic storage config
        generate_dualboot_storage "$ESP_MOUNT/autoinstall.yaml" "$ESP_MOUNT/cidata/user-data" "$INTERNAL_DISK"
    else
        # Full-disk: use template as-is
        cp "$ESP_MOUNT/autoinstall.yaml" "$ESP_MOUNT/cidata/user-data"
    fi

    # Validate preserve entries for dual-boot
    if [ "$STORAGE_LAYOUT" = "1" ]; then
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
    verify_esp_contents "$ESP_MOUNT"

    # Attempt bless
    local BLESS_OK
    BLESS_OK=$(attempt_bless "$ESP_MOUNT" "$_ESP_DEVICE")

    if [ "$BLESS_OK" -eq 0 ]; then
        warn "All automated boot device methods failed (SIP blocks NVRAM writes)"
        show_blind_boot_instructions
    else
        show_success_instructions
    fi
}

deploy_usb() {
    log "Starting USB deployment..."

    local ISO_PATH
    ISO_PATH=$(detect_iso)
    log "Using ISO: $ISO_PATH"

    select_usb_device TARGET_DEVICE

    if ! diskutil info "$TARGET_DEVICE" 2>/dev/null | grep -qi "removable\|external\|usb"; then
        echo ""
        warn "WARNING: $TARGET_DEVICE does not appear to be a USB/removable device!"
        warn "Writing to an internal device could DESTROY all data on it."
        echo ""
        read -rp "Type 'I UNDERSTAND THE RISK' to continue, or anything else to cancel: " confirm_usb
        if [ "$confirm_usb" != "I UNDERSTAND THE RISK" ]; then
            die "Deployment cancelled — target device does not appear to be removable"
        fi
    fi

    log "Preparing USB device $TARGET_DEVICE..."

    # Unmount the device
    diskutil unmountDisk "$TARGET_DEVICE" 2>/dev/null || true
    sleep 2

    # Create GPT partition table and FAT32 partition
    log "Creating FAT32 partition on USB..."
    diskutil partitionDisk "$TARGET_DEVICE" GPT FAT32 "CIDATA" 100% 2>/dev/null || \
        die "Failed to partition USB device"

    # Find the new partition
    sleep 2
    local USB_PARTITION
    USB_PARTITION=$(diskutil list "$TARGET_DEVICE" | grep "CIDATA" | grep -oE 'disk[0-9]+s[0-9]+' | head -1 || true)
    [ -n "$USB_PARTITION" ] || die "Cannot identify USB partition"

    # Mount it
    diskutil mount "/dev/$USB_PARTITION" 2>/dev/null || true
    local USB_MOUNT="/Volumes/CIDATA"
    [ -d "$USB_MOUNT" ] || die "USB not mounted after format"

    log "USB mounted at: $USB_MOUNT"

    # Extract ISO contents
    extract_iso_to_esp "$ISO_PATH" "$USB_MOUNT"

    # Copy driver packages
    if ! ls "$USB_MOUNT/macpro-pkgs/"*.deb 1>/dev/null 2>1; then
        log "Copying driver packages to USB..."
        mkdir -p "$USB_MOUNT/macpro-pkgs"
        cp "$SCRIPT_DIR/packages/"*.deb "$USB_MOUNT/macpro-pkgs/" 2>/dev/null || warn "Some packages may be missing"
    fi

    if [ -d "$SCRIPT_DIR/packages/dkms-patches" ] && [ ! -d "$USB_MOUNT/macpro-pkgs/dkms-patches" ]; then
        mkdir -p "$USB_MOUNT/macpro-pkgs/dkms-patches"
        cp "$SCRIPT_DIR/packages/dkms-patches/"* "$USB_MOUNT/macpro-pkgs/dkms-patches/" 2>/dev/null || true
    fi

    # Generate autoinstall.yaml
    local STORAGE_TYPE_ARG="dualboot"
    local NETWORK_TYPE_ARG="wifi"
    [ "$STORAGE_LAYOUT" = "2" ] && STORAGE_TYPE_ARG="fulldisk"
    [ "$NETWORK_TYPE" = "2" ] && NETWORK_TYPE_ARG="ethernet"
    generate_autoinstall "$USB_MOUNT/autoinstall.yaml" "$STORAGE_TYPE_ARG" "$NETWORK_TYPE_ARG"

    # Create cidata structure
    log "Creating cidata structure..."
    mkdir -p "$USB_MOUNT/cidata"

    if [ "$STORAGE_LAYOUT" = "1" ]; then
        # For USB, we can't easily run Python against the Mac's disk from the USB
        # So we'll use the static autoinstall.yaml and note that user may need to
        # manually preserve partitions or use the full-disk option
        log "Note: For dual-boot from USB, ensure you have free space on the target disk"
        cp "$USB_MOUNT/autoinstall.yaml" "$USB_MOUNT/cidata/user-data"
    else
        cp "$USB_MOUNT/autoinstall.yaml" "$USB_MOUNT/cidata/user-data"
    fi

    [ -f "$USB_MOUNT/cidata/meta-data" ] || echo "instance-id: macpro-linux-i1" > "$USB_MOUNT/cidata/meta-data"
    [ -f "$USB_MOUNT/cidata/vendor-data" ] || touch "$USB_MOUNT/cidata/vendor-data"

    write_grub_config "$USB_MOUNT"
    verify_esp_contents "$USB_MOUNT"

    # Unmount USB
    diskutil unmountDisk "$TARGET_DEVICE" 2>/dev/null || true

    show_usb_instructions
}

deploy_vm_test() {
    log "Starting VM test deployment..."

    if ! command -v VBoxManage >/dev/null 2>1; then
        die "VirtualBox not found. Install from https://www.virtualbox.org/ or: brew install --cask virtualbox"
    fi

    local BASE_ISO
    BASE_ISO=""
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

    local VM_DIR="$SCRIPT_DIR/vm-test"
    local VM_ISO="$VM_DIR/ubuntu-vmtest.iso"

    if [ ! -f "$VM_ISO" ]; then
        log "Building VM test ISO..."
        sudo "$VM_DIR/build-iso-vm.sh" || die "VM ISO build failed"
    else
        log "VM test ISO already exists: $VM_ISO"
        read -rp "Rebuild? (y/N): " rebuild
        if [ "$rebuild" = "y" ] || [ "$rebuild" = "Y" ]; then
            sudo "$VM_DIR/build-iso-vm.sh" || die "VM ISO build failed"
        fi
    fi

    [ -f "$VM_ISO" ] || die "VM test ISO not found after build"

    local VM_NAME="macpro-vmtest"
    if VBoxManage list vms 2>/dev/null | grep -q "\"$VM_NAME\""; then
        log "VM '$VM_NAME' already exists"
        read -rp "Recreate? (y/N): " recreate
        if [ "$recreate" = "y" ] || [ "$recreate" = "Y" ]; then
            "$VM_DIR/create-vm.sh" --force || die "VM creation failed"
        fi
    else
        log "Creating VirtualBox VM..."
        "$VM_DIR/create-vm.sh" || die "VM creation failed"
    fi

    if ! lsof -i :8080 >/dev/null 2>1; then
        log "Starting monitoring server..."
        (cd "$SCRIPT_DIR/macpro-monitor" && ./start.sh) || warn "Monitor start failed (non-critical)"
        sleep 2
    fi

    echo ""
    log "VM test environment ready!"
    echo ""
    echo "  Next steps:"
    echo "    1. Monitor: open http://localhost:8080 in a browser"
    echo "    2. Run test: cd vm-test && ./test-vm.sh"
    echo "    3. SSH into VM (when ready): ssh -p 2222 teja@localhost"
    echo "    4. Serial console log: tail -f /tmp/vmtest-serial.log"
    echo "    5. Stop VM: cd vm-test && ./test-vm.sh stop"
    echo "    6. Grab logs: cd vm-test && ./test-vm.sh logs"
    echo ""
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
        read -rp "Enter path to standard Ubuntu Server ISO: " ISO_PATH
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
        read -rp "Type 'I UNDERSTAND THE RISK' to continue, or anything else to cancel: " confirm
        if [ "$confirm" != "I UNDERSTAND THE RISK" ]; then
            die "Deployment cancelled — target device does not appear to be removable"
        fi
    fi

    echo ""
    echo "WARNING: This will ERASE all data on $TARGET_DEVICE"
    echo "The ISO will be written directly to the device (dd style)"
    read -rp "Type 'yes' to proceed: " confirm
    if [ "$confirm" != "yes" ]; then
        die "Manual deployment cancelled"
    fi

    # Unmount and write ISO
    log "Writing ISO to USB (this may take several minutes)..."
    diskutil unmountDisk "$TARGET_DEVICE" 2>/dev/null || true
    sleep 2

    if ! sudo dd if="$ISO_PATH" of="$TARGET_DEVICE" bs=1m; then
        die "Failed to write ISO to USB"
    fi

    sync
    log "ISO written successfully"

    diskutil eject "$TARGET_DEVICE" 2>/dev/null || true

    show_manual_instructions
}

# Instruction display functions
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
