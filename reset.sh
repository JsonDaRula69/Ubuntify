#!/bin/bash
# reset.sh
# Reverts all changes made by prepare_ubuntu_install_final.sh
# Ubuntu 24.04.1 LTS - Mac Pro 2013 Preparation Reset Script

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Root check
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (use sudo)"
    exit 1
fi

LOG_FILE="/var/log/ubuntu_undo_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# ═══════════════════════════════════════════════════════════════════════════
# FUNCTION DEFINITIONS
# ═══════════════════════════════════════════════════════════════════════════

confirm_action() {
    echo ""
    echo -e "${YELLOW}⚠ This script will UNDO all preparation for Ubuntu installation${NC}"
    echo -e "${YELLOW}⚠ The following will be removed:${NC}"
    echo "  • UBUNTU-TEMP partition will be unmounted"
    echo "  • All files copied to UBUNTU-TEMP will be deleted"
    echo "  • Created boot configurations will be removed"
    echo "  • Temporary files and checkpoint directories will be cleaned"
    echo ""
    echo -e "${RED}⚠ WARNING: This action cannot be fully undone${NC}"
    echo -e "${RED}⚠ You will need to repartition if you want to restart preparation${NC}"
    echo ""
    read -p "Continue with undo? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
}

cleanup_temp_files() {
    echo ""
    echo -e "${BLUE}=== Cleaning Temporary Files ===${NC}"
    echo ""
    
    if [[ -d "/tmp/broadcom-drivers" ]]; then
        echo "  Removing /tmp/broadcom-drivers..."
        rm -rf "/tmp/broadcom-drivers"
        echo -e "  ${GREEN}✓ Removed /tmp/broadcom-drivers${NC}"
    else
        echo -e "  ${GREEN}✓ /tmp/broadcom-drivers not present${NC}"
    fi
    
    if [[ -f "/tmp/ubuntu_part.txt" ]]; then
        echo "  Removing /tmp/ubuntu_part.txt..."
        rm -f "/tmp/ubuntu_part.txt"
        echo -e "  ${GREEN}✓ Removed /tmp/ubuntu_part.txt${NC}"
    else
        echo -e "  ${GREEN}✓ /tmp/ubuntu_part.txt not present${NC}"
    fi
    
    if [[ -f "/tmp/enable_ubuntu_boot.sh" ]]; then
        echo "  Removing /tmp/enable_ubuntu_boot.sh..."
        rm -f "/tmp/enable_ubuntu_boot.sh"
        echo -e "  ${GREEN}✓ Removed /tmp/enable_ubuntu_boot.sh${NC}"
    else
        echo -e "  ${GREEN}✓ /tmp/enable_ubuntu_boot.sh not present${NC}"
    fi
    
    if [[ -d "/tmp/ubuntu_prep_checkpoints" ]]; then
        echo "  Removing /tmp/ubuntu_prep_checkpoints..."
        rm -rf "/tmp/ubuntu_prep_checkpoints"
        echo -e "  ${GREEN}✓ Removed /tmp/ubuntu_prep_checkpoints${NC}"
    else
        echo -e "  ${GREEN}✓ /tmp/ubuntu_prep_checkpoints not present${NC}"
    fi
    
    echo ""
    echo -e "${GREEN}✓ Temporary files cleaned${NC}"
}

find_ubuntu_partition() {
    echo ""
    echo -e "${BLUE}=== Finding UBUNTU-TEMP Partition ===${NC}"
    echo ""
    
    UBUNTU_PARTITION=""
    for disk in $(diskutil list 2>/dev/null | grep "^/dev/disk" | awk '{print $1}'); do
        disk_num="${disk#/dev/disk}"
        diskutil list "$disk" 2>/dev/null | grep "UBUNTU-TEMP" > "/tmp/ubuntu_part_find.txt"
        if [[ -s "/tmp/ubuntu_part_find.txt" ]]; then
            part_identifier=$(grep -oE 'disk[0-9]+s[0-9]+' < "/tmp/ubuntu_part_find.txt" | head -1)
            if [[ -n "$part_identifier" ]]; then
                part_suffix=$(echo "$part_identifier" | grep -oE 's[0-9]+')
                if [[ -n "$part_suffix" ]]; then
                    UBUNTU_PARTITION="disk${disk_num}${part_suffix}"
                    break
                fi
            fi
        fi
    done
    
    rm -f "/tmp/ubuntu_part_find.txt" 2>/dev/null || true
    
    if [[ -n "$UBUNTU_PARTITION" ]]; then
        echo -e "${GREEN}✓ Found UBUNTU-TEMP partition: $UBUNTU_PARTITION${NC}"
    else
        echo -e "${YELLOW}⚠ UBUNTU-TEMP partition not found${NC}"
    fi
}

unmount_partition() {
    echo ""
    echo -e "${BLUE}=== Unmounting UBUNTU-TEMP Partition ===${NC}"
    echo ""
    
    if mount | grep -q "UBUNTU-TEMP"; then
        echo "Unmounting UBUNTU-TEMP..."
        if diskutil unmount "/Volumes/UBUNTU-TEMP" 2>/dev/null; then
            echo -e "${GREEN}✓ UBUNTU-TEMP unmounted successfully${NC}"
        else
            echo -e "${YELLOW}⚠ Could not unmount UBUNTU-TEMP, forcing unmount...${NC}"
            if ! diskutil unmount force "/Volumes/UBUNTU-TEMP" 2>/dev/null; then
                echo -e "${RED}✗ Failed to unmount UBUNTU-TEMP${NC}"
                echo "  You may need to unmount manually:"
                echo "  sudo diskutil unmount force /Volumes/UBUNTU-TEMP"
            fi
        fi
    else
        echo -e "${GREEN}✓ UBUNTU-TEMP is not mounted${NC}"
    fi
}

wipe_partition_data() {
    echo ""
    echo -e "${BLUE}=== Wiping Partition Data ===${NC}"
    echo ""
    
    if [[ -z "$UBUNTU_PARTITION" ]]; then
        echo -e "${YELLOW}⚠ No UBUNTU-TEMP partition found, skipping wipe${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}This will ERASE all data on UBUNTU-TEMP partition${NC}"
    echo ""
    read -p "Erase partition data? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}⚠ Skipping partition wipe${NC}"
        echo "  Files remain on partition but boot configuration is reset"
        return 0
    fi
    
    echo ""
    echo "Mounting partition temporarily..."
    diskutil mount "$UBUNTU_PARTITION" 2>/dev/null || true
    
    local PARTITION_PATH="/Volumes/UBUNTU-TEMP"
    if [[ -d "$PARTITION_PATH" ]]; then
        echo "Removing Ubuntu files from partition..."
        
        rm -rf "${PARTITION_PATH}/casper" 2>/dev/null || true
        rm -rf "${PARTITION_PATH}/boot" 2>/dev/null || true
        rm -rf "${PARTITION_PATH}/EFI" 2>/dev/null || true
        rm -f "${PARTITION_PATH}/user-data" 2>/dev/null || true
        rm -f "${PARTITION_PATH}/meta-data" 2>/dev/null || true
        rm -rf "${PARTITION_PATH}/.disk" 2>/dev/null || true
        rm -rf "${PARTITION_PATH}/pool" 2>/dev/null || true
        rm -rf "${PARTITION_PATH}/dists" 2>/dev/null || true
        rm -rf "${PARTITION_PATH}/install" 2>/dev/null || true
        rm -f "${PARTITION_PATH}/md5sum.txt" 2>/dev/null || true
        rm -f "${PARTITION_PATH}/README.diskdefines" 2>/dev/null || true
        rm -f "${PARTITION_PATH}/ubuntu" 2>/dev/null || true
        
        echo -e "${GREEN}✓ Ubuntu files removed from partition${NC}"
        
        echo "Unmounting partition..."
        diskutil unmount "$UBUNTU_PARTITION" 2>/dev/null || true
    else
        echo -e "${YELLOW}⚠ Could not mount partition for file removal${NC}"
    fi
}

reset_boot_volume() {
    echo ""
    echo -e "${BLUE}=== Resetting Boot Volume ===${NC}"
    echo ""
    
    if [[ ! -d "/System/Library/CoreServices" ]]; then
        echo -e "${YELLOW}⚠ macOS system not found${NC}"
        echo "  Boot volume not changed"
        return 0
    fi
    
    echo "Setting macOS as default boot volume..."
    
    local bless_success=false
    
    if bless --mount "/" --setBoot 2>/dev/null; then
        echo -e "${GREEN}✓ macOS set as default boot volume${NC}"
        bless_success=true
    elif bless --mount "/System/Volumes/Data" --setBoot 2>/dev/null; then
        echo -e "${GREEN}✓ macOS set as default boot volume${NC}"
        bless_success=true
    else
        local macos_volume=""
        if [[ -f "/System/Volumes/Data/.mountpoint" ]]; then
            macos_volume=$(df / | tail -1 | awk '{print $1}')
        fi
        
        if [[ -n "$macos_volume" ]]; then
            if bless --mount "$macos_volume" --setBoot 2>/dev/null; then
                echo -e "${GREEN}✓ macOS set as default boot volume${NC}"
                bless_success=true
            fi
        fi
    fi
    
    if [[ "$bless_success" == false ]]; then
        echo -e "${YELLOW}⚠ Could not set boot volume automatically${NC}"
        echo "  Please set manually in System Preferences > Startup Disk"
        echo "  Or hold Option during boot to select macOS"
    fi
}

format_partition() {
    echo ""
    echo -e "${BLUE}=== Formatting UBUNTU-TEMP Partition${NC}"
    echo ""
    
    if [[ -z "$UBUNTU_PARTITION" ]]; then
        echo -e "${YELLOW}⚠ No UBUNTU-TEMP partition found${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}This will FORMAT the UBUNTU-TEMP partition${NC}"
    echo -e "${YELLOW}(Partition structure remains, all data erased)${NC}"
    echo ""
    
    echo "Formatting $UBUNTU_PARTITION as FAT32..."
    
    diskutil unmount "$UBUNTU_PARTITION" 2>/dev/null || true
    
    if diskutil eraseVolume "FAT32" "UBUNTU-TEMP" "$UBUNTU_PARTITION" 2>/dev/null; then
        echo -e "${GREEN}✓ Partition formatted as FAT32${NC}"
        echo -e "${GREEN}✓ Partition: UBUNTU-TEMP is ready for reuse${NC}"
        echo ""
        echo "You can now re-run prepare_ubuntu_install_final.sh"
    else
        echo -e "${RED}✗ Failed to format partition${NC}"
        echo "  Try manually:"
        echo "  diskutil eraseVolume FAT32 UBUNTU-TEMP $UBUNTU_PARTITION"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# OPTIONAL: Remove APFS Snapshot (if created during preparation)
# ═══════════════════════════════════════════════════════════════════════════

remove_snapshot() {
    echo ""
    echo -e "${BLUE}=== Checking for APFS Snapshots ===${NC}"
    echo ""
    
    # List snapshots
    SNAPSHOTS=$(diskutil apfs listSnapshots / 2>/dev/null | grep "Snapshot" | head -5)
    
    if [[ -n "$SNAPSHOTS" ]]; then
        echo "Found APFS snapshots:"
        echo "$SNAPSHOTS"
        echo ""
        read -p "Delete preparation-related snapshots? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            # Delete snapshots created during preparation
            diskutil apfs deleteSnapshot / -uuid $(diskutil apfs listSnapshots / 2>/dev/null | grep -B1 "ubuntu\|prep\|backup" | grep -oE '[A-F0-9-]{36}' | head -1) 2>/dev/null || true
            echo -e "${GREEN}✓ Snapshots cleaned${NC}"
        fi
    else
        echo -e "${GREEN}✓ No APFS snapshots found${NC}"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN EXECUTION
# ═══════════════════════════════════════════════════════════════════════════

clear
cat << 'EOF'
╔══════════════════════════════════════════════════════════╗
║     Ubuntu Preparation - UNDO Script                    ║
║     Mac Pro 2013 - Broadcom BCM4360 Setup Reset          ║
║                                                          ║
║     This script reverses all changes made by             ║
║     prepare_ubuntu_install_final.sh                     ║
╚══════════════════════════════════════════════════════════╝

EOF

echo "Log file: $LOG_FILE"
echo ""

# Show what will be undone
confirm_action

# Execute undo steps in reverse order
find_ubuntu_partition
unmount_partition
reset_boot_volume
cleanup_temp_files
wipe_partition_data

# Format partition for reuse
format_partition

# Optional: snapshot cleanup
remove_snapshot

echo ""
echo -e "${GREEN}${BOLD}══════════════════════════${NC}"
echo -e "${GREEN}${BOLD}   RESET COMPLETE                 ${NC}"
echo -e "${GREEN}${BOLD}══════════════════════════${NC}"
echo ""
echo "All preparation steps have been reversed."
echo ""
echo "What was undone:"
echo "  ✓ UBUNTU-TEMP partition unmounted"
echo "  ✓ Boot volume reset to macOS"
echo "  ✓ Temporary files removed"
echo "  ✓ Partition data wiped"
echo "  ✓ UBUNTU-TEMP partition formatted (FAT32)"
echo ""
echo "Next steps:"
echo "  Run: sudo ./prepare_ubuntu_install_final.sh"
echo ""
echo "To view this session's log:"
echo "  $LOG_FILE"
echo ""