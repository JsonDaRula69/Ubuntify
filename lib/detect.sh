#!/bin/bash
#
# lib/detect.sh - Detection functions for ISO and USB devices
#
# Provides detect_iso to find Ubuntu ISO files and detect_usb_devices/
# select_usb_device for USB device discovery and selection.
#
# Dependencies: lib/colors.sh, lib/utils.sh
#

source "${LIB_DIR:-./lib}/colors.sh"
source "${LIB_DIR:-./lib}/utils.sh"

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "$0")" && pwd)}"

detect_iso() {
    local iso_path=""

    # Try to find ISO in common locations
    for loc in "$SCRIPT_DIR"/ubuntu-macpro.iso "$SCRIPT_DIR"/prereqs/*.iso "$HOME"/*.iso; do
        if [ -f "$loc" ]; then
            iso_path="$loc"
            break
        fi
    done

    if [ -z "$iso_path" ]; then
        echo "ISO file not found automatically."
        read -rp "Enter path to Ubuntu ISO: " iso_path
    fi

    if [ ! -f "$iso_path" ]; then
        die "ISO not found: $iso_path"
    fi

    # Verify ISO size
    local ISO_SIZE
    ISO_SIZE=$(stat -f%z "$iso_path" 2>/dev/null || echo "0")
    if [ "$ISO_SIZE" -lt 1000000000 ]; then
        die "ISO appears too small ($ISO_SIZE bytes) — may be corrupted"
    fi

    echo "$iso_path"
}

detect_usb_devices() {
    local devices=""
    while IFS= read -r line; do
        if echo "$line" | grep -qE '/dev/disk[0-9]+.*external'; then
            local dev
            dev=$(echo "$line" | grep -oE '/dev/disk[0-9]+' | head -1)
            if [ -n "$dev" ]; then
                local info
                info=$(diskutil info "$dev" 2>/dev/null | grep -E "Device Identifier|Media Name|Total Size" | head -3)
                devices="${devices}${dev}|${info}\n"
            fi
        fi
    done <<< "$(diskutil list 2>/dev/null | grep -E 'external.*physical' || true)"

    echo -e "$devices"
}

select_usb_device() {
    local -n _TARGET_DEVICE=$1

    local usb_devices
    usb_devices=$(detect_usb_devices)

    if [ -z "$usb_devices" ] || [ "$usb_devices" = "\n" ]; then
        die "No USB devices detected. Please insert a USB drive and try again."
    fi

    echo "Available USB devices:"
    echo ""

    local i=0
    local device_list=()
    while IFS='|' read -r device info; do
        if [ -n "$device" ]; then
            i=$((i + 1))
            device_list+=("$device")
            echo "  $i) $device"
            echo "     $info"
            echo ""
        fi
    done <<< "$(echo -e "$usb_devices" | grep -v '^$')"

    if [ ${#device_list[@]} -eq 0 ]; then
        die "No USB devices found"
    fi

    while true; do
        read -rp "Select USB device [1-$i]: " choice
        if [ "$choice" -ge 1 ] && [ "$choice" -le "$i" ] 2>/dev/null; then
            _TARGET_DEVICE="${device_list[$((choice-1))]}"
            break
        fi
        echo "Invalid choice. Please enter a number between 1 and $i."
    done

    # Get device size
    local device_size
    device_size=$(diskutil info "$_TARGET_DEVICE" 2>/dev/null | grep "Total Size" | grep -oE '[0-9]+\.[0-9]+ GB' | head -1 || echo "unknown")
    log "Selected USB device: $_TARGET_DEVICE ($device_size)"

    echo ""
    echo "WARNING: All data on $_TARGET_DEVICE will be erased!"
    read -rp "Type 'yes' to confirm: " confirm
    if [ "$confirm" != "yes" ]; then
        die "USB device selection cancelled"
    fi
}
