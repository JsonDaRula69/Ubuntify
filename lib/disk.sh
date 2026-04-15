#!/bin/bash
#
# lib/disk.sh - Disk and partition management functions
#
# Provides analyze_disk_layout, shrink_apfs_if_needed, create_esp_partition,
# and extract_iso_to_esp for managing Mac disk partitions and ESP creation.
#
# Dependencies: lib/colors.sh, lib/logging.sh
#

[ "${_DISK_SH_SOURCED:-0}" -eq 1 ] && return 0
_DISK_SH_SOURCED=1

source "${LIB_DIR:-./lib}/colors.sh"
source "${LIB_DIR:-./lib}/logging.sh"
source "${LIB_DIR:-./lib}/dryrun.sh"

: "${ESP_NAME:=CIDATA}"
: "${ESP_SIZE:=5g}"
STORAGE_LAYOUT="${STORAGE_LAYOUT:-1}"

analyze_disk_layout() {
    local _internal_disk_name="$1"
    local _apfs_container_name="$2"

    log "Analyzing disk layout..."

    local APFS_PARTITION
    local FREE_SPACE
    local _internal_disk_val
    local _apfs_container_val

    _internal_disk_val=$(diskutil list | grep -E 'internal.*physical' | head -1 | grep -oE '/dev/disk[0-9]+' || true)
    [ -n "$_internal_disk_val" ] || die "Cannot identify internal disk"

    log "Internal disk: $_internal_disk_val"
    diskutil list "$_internal_disk_val"
    echo ""

    APFS_PARTITION=$(diskutil list "$_internal_disk_val" | grep -i "APFS" | grep -oE 'disk[0-9]+s[0-9]+' | head -1 || true)
    if [ -n "$APFS_PARTITION" ]; then
        _apfs_container_val=$(diskutil info "$APFS_PARTITION" 2>/dev/null | grep -i "container" | grep -oE 'disk[0-9]+' | head -1 || true)
    fi
    if [ -z "$_apfs_container_val" ]; then
        _apfs_container_val=$(diskutil list | grep -i "APFS" | grep -oE 'disk[0-9]+' | head -1 || true)
    fi
    if [ -n "$_apfs_container_val" ]; then
        FREE_SPACE=$(diskutil apfs list 2>/dev/null | grep -A5 "Capacity" | grep "Available" | grep -oE '[0-9]+.*B' | head -1 || true)
        log "APFS partition: /dev/${APFS_PARTITION:-unknown}"
        log "APFS container: /dev/$_apfs_container_val"
        log "Free space: ${FREE_SPACE:-unknown}"
    fi
    echo ""

    eval "$_internal_disk_name=\"\$_internal_disk_val\""
    eval "$_apfs_container_name=\"\$_apfs_container_val\""
}

shrink_apfs_if_needed() {
    local APFS_CONTAINER="$1"
    local INTERNAL_DISK="$2"
    local _apfs_resized_name="$3"
    local _apfs_original_size_name="$4"

    if [ "${STORAGE_LAYOUT:-}" != "1" ]; then
        log "Full disk mode selected — skipping APFS resize"
        eval "${_apfs_resized_name}=0"
        eval "${_apfs_original_size_name}=0"
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
    local _apfs_original_size_val
    _apfs_original_size_val=$(echo "$CURRENT_SIZE" | grep -oE '[0-9]+(\.[0-9]+)?' || true)
    eval "$_apfs_original_size_name=\"\$_apfs_original_size_val\""
    log "Current APFS size: ${CURRENT_SIZE:-unknown}"

    EXISTING_FREE_GB=$(diskutil list "$INTERNAL_DISK" 2>/dev/null | grep "(free" | grep -oE '[0-9]+(\.[0-9]+)? GB' | head -1 | grep -oE '[0-9]+(\.[0-9]+)?' || true)
    if [ -n "$EXISTING_FREE_GB" ] && echo "$EXISTING_FREE_GB" | awk '{exit !($1 >= 5)}'; then
        log "Free space already ${EXISTING_FREE_GB}GB — skipping APFS resize"
        eval "${_apfs_resized_name}=0"
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
        eval "${_apfs_resized_name}=0"
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

    dry_run_exec "Shrink APFS container to ${TARGET_MACOS_GB}GB" \
        diskutil apfs resizeContainer "$APFS_CONTAINER" "${TARGET_MACOS_GB}g" || die "APFS resize failed"
    eval "$_apfs_resized_name=1"
    log "APFS container resized to ${TARGET_MACOS_GB}GB"
}

create_esp_partition() {
    local INTERNAL_DISK="$1"
    local _esp_created_name="$2"
    local _esp_device_name="$3"

    log "Creating ESP partition for Ubuntu installer..."

    # Remove leftover CIDATA ESP from a previous failed run
    local EXISTING_ESP
    EXISTING_ESP=$(diskutil list "$INTERNAL_DISK" 2>/dev/null | grep "$ESP_NAME" | grep -oE 'disk[0-9]+s[0-9]+' | head -1 || true)
    if [ -n "$EXISTING_ESP" ]; then
        log "Removing existing $ESP_NAME partition /dev/$EXISTING_ESP..."
        dry_run_exec "Remove existing ESP partition /dev/$EXISTING_ESP" \
            retry_diskutil unmount "/dev/$EXISTING_ESP" 2>/dev/null || true
        dry_run_exec "Erase ESP partition /dev/$EXISTING_ESP to free space" \
            retry_diskutil eraseVolume free none "/dev/$EXISTING_ESP" 2>/dev/null || warn "Could not remove existing ESP"
        sleep 1
    fi

    local BEFORE_PARTS AFTER_PARTS ESP_MOUNT
    BEFORE_PARTS=$(diskutil list "$INTERNAL_DISK" | grep -oE 'disk[0-9]+s[0-9]+' | sort)
    if [ "${DRY_RUN:-0}" -eq 1 ]; then
        echo "[DRY-RUN] Would: addPartition → identify → newfs_msdos → mount ESP"
        eval "$_esp_created_name=1"
        eval "$_esp_device_name=\"disk0sN\""
        echo "/Volumes/${ESP_NAME}"
        return 0
    fi
    if retry_diskutil addPartition "$INTERNAL_DISK" %C12A7328-F81F-11D2-BA4B-00A0C93EC93B% %noformat% "$ESP_SIZE"; then
        sleep 2
        AFTER_PARTS=$(diskutil list "$INTERNAL_DISK" | grep -oE 'disk[0-9]+s[0-9]+' | sort)
        _esp_device_val=$(comm -13 <(echo "$BEFORE_PARTS") <(echo "$AFTER_PARTS") | head -1)
        if [ -z "$_esp_device_val" ]; then
            die "Cannot identify newly created ESP partition"
        fi
        log "ESP partition candidate: /dev/$_esp_device_val"
        newfs_msdos -F 32 -v "$ESP_NAME" "/dev/$_esp_device_val" || die "Failed to format ESP as FAT32"
        sleep 1
        retry_diskutil mount "/dev/$_esp_device_val" 2>/dev/null || true
        eval "$_esp_created_name=1"
        eval "$_esp_device_name=\"\$_esp_device_val\""
        ESP_MOUNT="/Volumes/$ESP_NAME"
        if [ ! -d "$ESP_MOUNT" ]; then
            ESP_MOUNT=$(diskutil info "/dev/$_esp_device_val" 2>/dev/null | grep "Mount Point" | awk '{$1=$2=""; print substr($0,3)}' | sed 's/^[[:space:]]*//' || true)
        fi
        [ -d "$ESP_MOUNT" ] || die "ESP not mounted after format"
        echo "$ESP_MOUNT"
    else
        eval "$_esp_created_name=0"
        eval "$_esp_device_name=\"\""
        die "Failed to create ESP partition with EFI System Partition type"
    fi
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

    dry_run_exec "Extract ISO to ESP" \
        retry_xorriso -osirrox on -indev "$ISO_PATH" \
        -extract / "$ESP_MOUNT" 2>/dev/null || \
        die "Failed to extract ISO contents"

    dry_run_exec "Clean up unnecessary files" \
        rm -rf "$ESP_MOUNT/pool" "$ESP_MOUNT/dists" "$ESP_MOUNT/.disk" "$ESP_MOUNT/boot/grub" 2>/dev/null || true

    # Verify required files
    [ -f "$ESP_MOUNT/EFI/boot/bootx64.efi" ] || [ -f "$ESP_MOUNT/EFI/boot/BOOTX64.EFI" ] || die "BOOTX64.EFI missing"
    [ -f "$ESP_MOUNT/casper/vmlinuz" ] || die "casper/vmlinuz missing"
    [ -f "$ESP_MOUNT/casper/initrd" ] || die "casper/initrd missing"
    if ! ls "$ESP_MOUNT/casper/"*.squashfs 1>/dev/null 2>&1; then
        die "No .squashfs files in casper/"
    fi

    echo "$ESP_MOUNT"
}
