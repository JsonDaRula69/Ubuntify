#!/bin/bash
#
# lib/disk.sh - Disk and partition management functions
#
# Provides analyze_disk_layout, shrink_apfs_if_needed, create_esp_partition,
# and extract_iso_to_esp for managing Mac disk partitions and ESP creation.
#
# Dependencies: lib/colors.sh, lib/utils.sh
#

source "${LIB_DIR:-./lib}/colors.sh"
source "${LIB_DIR:-./lib}/utils.sh"

ESP_NAME="${ESP_NAME:-CIDATA}"
ESP_SIZE="${ESP_SIZE:-5g}"
STORAGE_LAYOUT="${STORAGE_LAYOUT:-1}"

analyze_disk_layout() {
    local -n _INTERNAL_DISK=$1
    local -n _APFS_CONTAINER=$2

    log "Analyzing disk layout..."

    local APFS_PARTITION
    local FREE_SPACE

    _INTERNAL_DISK=$(diskutil list | grep -E 'internal.*physical' | head -1 | grep -oE '/dev/disk[0-9]+' || true)
    [ -n "$_INTERNAL_DISK" ] || die "Cannot identify internal disk"

    log "Internal disk: $_INTERNAL_DISK"
    diskutil list "$_INTERNAL_DISK"
    echo ""

    # Find APFS container
    APFS_PARTITION=$(diskutil list "$_INTERNAL_DISK" | grep -i "APFS" | grep -oE 'disk[0-9]+s[0-9]+' | head -1 || true)
    if [ -n "$APFS_PARTITION" ]; then
        _APFS_CONTAINER=$(diskutil info "$APFS_PARTITION" 2>/dev/null | grep -i "container" | grep -oE 'disk[0-9]+' | head -1 || true)
    fi
    if [ -z "$_APFS_CONTAINER" ]; then
        _APFS_CONTAINER=$(diskutil list | grep -i "APFS" | grep -oE 'disk[0-9]+' | head -1 || true)
    fi
    if [ -n "$_APFS_CONTAINER" ]; then
        FREE_SPACE=$(diskutil apfs list 2>/dev/null | grep -A5 "Capacity" | grep "Available" | grep -oE '[0-9]+.*B' | head -1 || true)
        log "APFS partition: /dev/${APFS_PARTITION:-unknown}"
        log "APFS container: /dev/$_APFS_CONTAINER"
        log "Free space: ${FREE_SPACE:-unknown}"
    fi
    echo ""
}

shrink_apfs_if_needed() {
    local APFS_CONTAINER="$1"
    local INTERNAL_DISK="$2"
    local -n _APFS_RESIZED=$3
    local -n _APFS_ORIGINAL_SIZE=$4

    if [ "${STORAGE_LAYOUT:-}" != "1" ]; then
        log "Full disk mode selected — skipping APFS resize"
        return 0
    fi

    log "Checking APFS container size..."

    local CURRENT_SIZE
    local EXISTING_FREE_GB
    local MIN_MACOS_GB=50
    local USED_GB
    local TARGET_MACOS_GB
    local CURRENT_CONTAINER_GB
    local SNAPSHOTS
    local SNAP_UUID

    CURRENT_SIZE=$(diskutil info "$APFS_CONTAINER" 2>/dev/null | grep "Disk Size" | grep -oE '[0-9]+(\.[0-9]+)? GB' || true)
    _APFS_ORIGINAL_SIZE=$(echo "$CURRENT_SIZE" | grep -oE '[0-9]+(\.[0-9]+)?' || true)
    log "Current APFS size: ${CURRENT_SIZE:-unknown}"

    EXISTING_FREE_GB=$(diskutil list "$INTERNAL_DISK" 2>/dev/null | grep "(free" | grep -oE '[0-9]+(\.[0-9]+)? GB' | head -1 | grep -oE '[0-9]+(\.[0-9]+)?' || true)
    if [ -n "$EXISTING_FREE_GB" ] && echo "$EXISTING_FREE_GB" | awk '{exit !($1 >= 5)}'; then
        log "Free space already ${EXISTING_FREE_GB}GB — skipping APFS resize"
        return 0
    fi

    log "Purging purgeable APFS space..."
    tmutil thinlocalsnapshots / 999999999999 2>/dev/null || true

    USED_GB=$(diskutil apfs list "$APFS_CONTAINER" 2>/dev/null | grep "Capacity In Use By Volumes" | grep -oE '[0-9]+(\.[0-9]+)? GB' | head -1 | grep -oE '[0-9]+(\.[0-9]+)?' || true)
    if [ -z "$USED_GB" ]; then
        USED_GB=$(diskutil apfs list "$APFS_CONTAINER" 2>/dev/null | grep "Capacity In Use By Volumes" | grep -oE '[0-9]+ B' | head -1 | awk '{printf "%.1f", $1/1024/1024/1024}' || true)
    fi

    if [ -n "$USED_GB" ]; then
        TARGET_MACOS_GB=$(echo "$USED_GB" | awk -v min="$MIN_MACOS_GB" -v margin=10 '{target=int($1)+margin+1; if(target<min) target=min; print target}')
        log "APFS in use: ${USED_GB}GB → shrinking to ${TARGET_MACOS_GB}GB (10GB margin)"
    else
        TARGET_MACOS_GB=200
        warn "Could not determine APFS usage — defaulting to ${TARGET_MACOS_GB}GB for macOS"
    fi

    CURRENT_CONTAINER_GB=$(diskutil info "$APFS_CONTAINER" 2>/dev/null | grep "Disk Size" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1 || true)
    if [ -n "$CURRENT_CONTAINER_GB" ] && echo "$CURRENT_CONTAINER_GB $TARGET_MACOS_GB" | awk '{exit !($1 <= $2)}'; then
        log "APFS already at ${CURRENT_CONTAINER_GB}GB — no resize needed"
        return 0
    fi

    # Delete snapshots first
    log "Checking APFS snapshots..."
    SNAPSHOTS=$(diskutil apfs listSnapshots "$APFS_CONTAINER" 2>/dev/null | grep "Snapshot.*UUID" || true)
    if [ -n "$SNAPSHOTS" ]; then
        warn "APFS snapshots found — auto-deleting:"
        echo "$SNAPSHOTS"

        while IFS= read -r line; do
            SNAP_UUID=$(echo "$line" | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' || true)
            if [ -n "$SNAP_UUID" ]; then
                log "Deleting snapshot $SNAP_UUID..."
                diskutil apfs deleteSnapshot "$APFS_CONTAINER" -uuid "$SNAP_UUID" || warn "Failed to delete snapshot $SNAP_UUID"
            fi
        done <<< "$SNAPSHOTS"

        tmutil thinlocalsnapshots / 999999999999 2>/dev/null || true
    fi

    diskutil apfs resizeContainer "$APFS_CONTAINER" "${TARGET_MACOS_GB}g" || die "APFS resize failed"
    _APFS_RESIZED=1
    log "APFS container resized to ${TARGET_MACOS_GB}GB"
}

create_esp_partition() {
    local INTERNAL_DISK="$1"
    local -n _ESP_CREATED=$2
    local -n _ESP_DEVICE=$3

    log "Creating ESP partition for Ubuntu installer..."

    # Remove leftover CIDATA ESP from a previous failed run
    local EXISTING_ESP
    EXISTING_ESP=$(diskutil list "$INTERNAL_DISK" 2>/dev/null | grep "$ESP_NAME" | grep -oE 'disk[0-9]+s[0-9]+' | head -1 || true)
    if [ -n "$EXISTING_ESP" ]; then
        log "Removing existing $ESP_NAME partition /dev/$EXISTING_ESP..."
        diskutil unmount "/dev/$EXISTING_ESP" 2>/dev/null || true
        diskutil eraseVolume free none "/dev/$EXISTING_ESP" 2>/dev/null || warn "Could not remove existing ESP"
        sleep 1
    fi

    local BEFORE_PARTS AFTER_PARTS ESP_DEVICE ESP_MOUNT
    BEFORE_PARTS=$(diskutil list "$INTERNAL_DISK" | grep -oE 'disk[0-9]+s[0-9]+' | sort)
    diskutil addPartition "$INTERNAL_DISK" %C12A7328-F81F-11D2-BA4B-00A0C93EC93B% %noformat% "$ESP_SIZE" || \
        die "Failed to create ESP partition with EFI System Partition type"
    _ESP_CREATED=1
    sleep 2
    AFTER_PARTS=$(diskutil list "$INTERNAL_DISK" | grep -oE 'disk[0-9]+s[0-9]+' | sort)
    _ESP_DEVICE=$(comm -13 <(echo "$BEFORE_PARTS") <(echo "$AFTER_PARTS") | head -1)
    [ -n "$_ESP_DEVICE" ] || die "Cannot identify newly created ESP partition"

    log "ESP partition candidate: /dev/$_ESP_DEVICE"

    # Format as FAT32 with newfs_msdos
    newfs_msdos -F 32 -v "$ESP_NAME" "/dev/$_ESP_DEVICE" || die "Failed to format ESP as FAT32"
    sleep 1

    # Mount the freshly formatted ESP
    diskutil mount "/dev/$_ESP_DEVICE" 2>/dev/null || true
    ESP_MOUNT="/Volumes/$ESP_NAME"
    if [ ! -d "$ESP_MOUNT" ]; then
        ESP_MOUNT=$(diskutil info "/dev/$_ESP_DEVICE" 2>/dev/null | grep "Mount Point" | awk '{$1=$2=""; print substr($0,3)}' | sed 's/^[[:space:]]*//' || true)
    fi
    [ -d "$ESP_MOUNT" ] || die "ESP not mounted after format"

    echo "$ESP_MOUNT"
}

extract_iso_to_esp() {
    local ISO_PATH="$1"
    local ESP_MOUNT="$2"

    log "Extracting ISO contents to ESP..."

    local ESP_AVAIL ISO_TOTAL
    ESP_AVAIL=$(df -m "$ESP_MOUNT" | tail -1 | awk '{print $4}')
    ISO_TOTAL=$(du -sm "$ISO_PATH" 2>/dev/null | cut -f1 || echo "0")
    if [ -n "$ESP_AVAIL" ] && [ "$ESP_AVAIL" -gt 0 ] && [ -n "$ISO_TOTAL" ] && [ "$ISO_TOTAL" -gt 0 ]; then
        local REQUIRED_MIN=$((ISO_TOTAL + ISO_TOTAL / 10))
        if [ "$ESP_AVAIL" -lt "$REQUIRED_MIN" ]; then
            die "ESP too small: ${ESP_AVAIL}MB available, ${REQUIRED_MIN}MB needed"
        fi
        log "Space check: ${ESP_AVAIL}MB available, ${REQUIRED_MIN}MB needed"
    fi

    log "Extracting ISO to ESP via xorriso (this may take a minute)..."
    xorriso -osirrox on -indev "$ISO_PATH" \
        -extract / "$ESP_MOUNT" 2>/dev/null || \
        die "Failed to extract ISO contents"

    rm -rf "$ESP_MOUNT/pool" "$ESP_MOUNT/dists" "$ESP_MOUNT/.disk" "$ESP_MOUNT/boot/grub" 2>/dev/null || true

    # Verify required files
    [ -f "$ESP_MOUNT/EFI/boot/bootx64.efi" ] || [ -f "$ESP_MOUNT/EFI/boot/BOOTX64.EFI" ] || die "BOOTX64.EFI missing"
    [ -f "$ESP_MOUNT/casper/vmlinuz" ] || die "casper/vmlinuz missing"
    [ -f "$ESP_MOUNT/casper/initrd" ] || die "casper/initrd missing"
    if ! ls "$ESP_MOUNT/casper/"*.squashfs 1>/dev/null 2>1; then
        die "No .squashfs files in casper/"
    fi

    echo "$ESP_MOUNT"
}
