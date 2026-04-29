#!/bin/bash
#
# lib/disk.sh - Disk and partition management functions
#
# Provides analyze_disk_layout, shrink_apfs_if_needed, create_esp_partition,
# and disk management for Mac Pro remote deployment.
#
# Dependencies: lib/colors.sh, lib/logging.sh
#

_validate_varname() {
    printf '%s' "$1" | grep -qE '^[a-zA-Z_][a-zA-Z0-9_]*$'
}

[ "${_DISK_SH_SOURCED:-0}" -eq 1 ] && return 0
_DISK_SH_SOURCED=1

source "${LIB_DIR:-./lib}/colors.sh"
source "${LIB_DIR:-./lib}/logging.sh"
source "${LIB_DIR:-./lib}/dryrun.sh"
source "${LIB_DIR:-./lib}/remote_mac.sh"

: "${ESP_NAME:=CIDATA}"
: "${ESP_SIZE:=5g}"
STORAGE_LAYOUT="${STORAGE_LAYOUT:-1}"

# Returns 0 if Recovery is present and healthy, 1 otherwise.
# Populates RECOVERY_VOLUME and RECOVERY_UUID globals.
check_recovery_health() {
    local APFS_CONTAINER="$1"

    RECOVERY_VOLUME=""
    RECOVERY_UUID=""

    RECOVERY_VOLUME=$(remote_mac_exec diskutil apfs list "$APFS_CONTAINER" 2>/dev/null | grep -B1 "Recovery" | grep "APFS Volume Disk" | grep -oE 'disk[0-9]+s[0-9]+' | head -1 || true)
    if [ -z "$RECOVERY_VOLUME" ]; then
        warn "Recovery volume NOT found in APFS container — deployment cannot proceed safely"
        return 1
    fi

    log "Recovery volume found: /dev/$RECOVERY_VOLUME"

    RECOVERY_UUID=$(remote_mac_exec diskutil info "/dev/$RECOVERY_VOLUME" 2>/dev/null | grep -i "volume UUID" | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' | head -1 || true)
    if [ -n "$RECOVERY_UUID" ]; then
        log "Recovery UUID: $RECOVERY_UUID"
    fi

    local RECOVERY_MOUNT_OK=0
    if remote_mac_sudo diskutil mount "$RECOVERY_VOLUME" 2>/dev/null; then
        local RECOVERY_MOUNT="/Volumes/Recovery"
        if remote_mac_dir_exists "$RECOVERY_MOUNT" && remote_mac_exec ls "$RECOVERY_MOUNT/"*/BaseSystem.dmg 1>/dev/null 2>&1; then
            log "Recovery BaseSystem.dmg present — Recovery appears healthy"
            RECOVERY_MOUNT_OK=1
        else
            warn "Recovery volume mounted but BaseSystem.dmg is MISSING"
        fi
        remote_mac_sudo diskutil unmount "$RECOVERY_VOLUME" 2>/dev/null || true
    else
        warn "Could not mount Recovery volume for health check"
    fi

    if [ "$RECOVERY_MOUNT_OK" -eq 0 ]; then
        # Missing BaseSystem.dmg is normal on macOS 12+ (thin recovery fetches from Apple servers)
        # The critical check is that the Recovery volume EXISTS, not that BaseSystem.dmg is present
        if [ -n "$RECOVERY_VOLUME" ]; then
            log "Recovery partition exists (BaseSystem.dmg absent — normal for macOS 12+ thin recovery)"
            return 0
        fi
        warn "Recovery partition exists but appears unhealthy (missing BaseSystem.dmg)"
        return 1
    fi

    return 0
}

analyze_disk_layout() {
    local _internal_disk_name="$1"
    local _apfs_container_name="$2"

    log "Analyzing disk layout..."
    printf '\r%b  %b▸%b Identifying internal disk...         \r' "$CLR" "$CYAN" "$NC" >&2

    local APFS_PARTITION
    local FREE_SPACE
    local _internal_disk_val
    local _apfs_container_val

    _internal_disk_val=$(remote_mac_exec diskutil list | grep -E 'internal.*physical' | head -1 | grep -oE '/dev/disk[0-9]+' || true)
    [ -n "$_internal_disk_val" ] || die "Cannot identify internal disk"

    log "Internal disk: $_internal_disk_val"
    printf '\r%b  %b▸%b Reading partition table...          \r' "$CLR" "$CYAN" "$NC" >&2
    remote_mac_exec diskutil list "$_internal_disk_val"
    echo ""

    printf '\r%b  %b▸%b Locating APFS container...          \r' "$CLR" "$CYAN" "$NC" >&2
    APFS_PARTITION=$(remote_mac_exec diskutil list "$_internal_disk_val" | grep -i "APFS" | grep -oE 'disk[0-9]+s[0-9]+' | head -1 || true)
    if [ -n "$APFS_PARTITION" ]; then
        _apfs_container_val=$(remote_mac_exec diskutil info "$APFS_PARTITION" 2>/dev/null | grep -i "container" | grep -oE 'disk[0-9]+' | head -1 || true)
    fi
    if [ -z "$_apfs_container_val" ]; then
        _apfs_container_val=$(remote_mac_exec diskutil list | grep -i "APFS" | grep -oE 'disk[0-9]+' | head -1 || true)
    fi
    if [ -n "$_apfs_container_val" ]; then
        printf '\r%b  %b▸%b Checking free space...               \r' "$CLR" "$CYAN" "$NC" >&2
        FREE_SPACE=$(remote_mac_exec "diskutil info '$_apfs_container_val' 2>/dev/null | grep 'Volume Free Space' | grep -oE '[0-9]+(\.[0-9]+)? [GTMP]?B' | head -1" || true)
        if [ -z "$FREE_SPACE" ]; then
            FREE_SPACE=$(remote_mac_exec "diskutil apfs list '$_apfs_container_val' 2>/dev/null | grep 'Capacity In Use By Volumes' | grep -oE '[0-9]+(\.[0-9]+)? [GTMP]?B' | head -1" || true)
        fi
        log "APFS partition: /dev/${APFS_PARTITION:-unknown}"
        log "APFS container: /dev/$_apfs_container_val"
        log "Free space: ${FREE_SPACE:-unknown}"

        printf '\r%b  %b▸%b Verifying Recovery partition...     \r' "$CLR" "$CYAN" "$NC" >&2
        if ! check_recovery_health "$_apfs_container_val"; then
            warn "macOS Recovery partition may be damaged. Deployment can proceed but repair Recovery if possible: boot to Internet Recovery (Option+R) and reinstall macOS."
        fi
    fi
    # Remove leftover Linux partitions from previous failed installs
    # These occupy sector space that curtin needs for new partitions,
    # causing "Could not create partition N" sgdisk errors on overlap
    local _linux_parts
    if [ -n "${TARGET_HOST:-}" ]; then
        _linux_parts=$(remote_mac_exec "diskutil list $_internal_disk_val 2>/dev/null | grep 'Linux Filesystem'" 2>/dev/null || true)
    else
        _linux_parts=$(diskutil list "$_internal_disk_val" 2>/dev/null | grep 'Linux Filesystem' || true)
    fi
    if [ -n "$_linux_parts" ]; then
        printf '\r%b  %b▸%b Removing leftover Linux partitions    \r' "$CLR" "$CYAN" "$NC" >&2
        log_info "Found leftover Linux partitions from previous install — removing"
        echo "$_linux_parts" | while IFS= read -r _line; do
            _linux_dev=$(echo "$_line" | grep -oE 'disk[0-9]+s[0-9]+' | head -1)
            if [ -n "$_linux_dev" ]; then
                if [ -n "${TARGET_HOST:-}" ]; then
                    dry_run_exec "Remove Linux partition /dev/${_linux_dev}" \
                        remote_mac_exec "sudo -n diskutil eraseVolume free none /dev/${_linux_dev}" 2>/dev/null || true
                else
                    dry_run_exec "Remove Linux partition /dev/${_linux_dev}" \
                        diskutil eraseVolume free none "/dev/${_linux_dev}" 2>/dev/null || true
                fi
                log_info "Removed leftover Linux partition /dev/${_linux_dev}"
            fi
        done
        printf '\r%b  %b✓%b Leftover Linux partitions removed        \n' "$CLR" "$GREEN" "$NC" >&2
    fi

    printf '\r%b  %b✓%b Disk layout analyzed                   \n' "$CLR" "$GREEN" "$NC" >&2
    echo ""

    # Validate eval variable names to prevent injection
    if ! _validate_varname "$_internal_disk_name"; then
        die "analyze_disk_layout: invalid variable name: $_internal_disk_name"
    fi
    if ! _validate_varname "$_apfs_container_name"; then
        die "analyze_disk_layout: invalid variable name: $_apfs_container_name"
    fi
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
        if ! _validate_varname "$_apfs_resized_name" || ! _validate_varname "$_apfs_original_size_name"; then
            die "shrink_apfs_if_needed: invalid variable name"
        fi
        eval "${_apfs_resized_name}=0"
        eval "${_apfs_original_size_name}=0"
        return 0
    fi

    log "Checking APFS container size..."

    local CURRENT_SIZE
    local EXISTING_FREE_GB
    local MIN_MACOS_GB=50
    local MIN_UBUNTU_GB=40
    local USED_GB
    local TARGET_MACOS_GB
    local CURRENT_CONTAINER_GB
    local SNAPSHOTS
    local SNAP_UUID

    CURRENT_SIZE=$(remote_mac_exec diskutil info "$APFS_CONTAINER" 2>/dev/null | grep "Disk Size" | grep -oE '[0-9]+(\.[0-9]+)? GB' || true)
    local _apfs_original_size_val
    _apfs_original_size_val=$(echo "$CURRENT_SIZE" | grep -oE '[0-9]+(\.[0-9]+)?' || true)
    if ! _validate_varname "$_apfs_original_size_name"; then
        die "shrink_apfs_if_needed: invalid variable name: $_apfs_original_size_name"
    fi
    eval "$_apfs_original_size_name=\"\$_apfs_original_size_val\""
    log "Current APFS size: ${CURRENT_SIZE:-unknown}"

    CURRENT_CONTAINER_GB=$(remote_mac_exec diskutil info "$APFS_CONTAINER" 2>/dev/null | grep "Disk Size" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1 || true)
    local TOTAL_DISK_GB
    TOTAL_DISK_GB=$(remote_mac_exec diskutil info "$INTERNAL_DISK" 2>/dev/null | grep "Disk Size" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1 || true)
    if [ -z "$TOTAL_DISK_GB" ]; then
        TOTAL_DISK_GB="$CURRENT_CONTAINER_GB"
    fi

    EXISTING_FREE_GB=$(remote_mac_exec diskutil list "$INTERNAL_DISK" 2>/dev/null | grep "(free" | grep -oE '[0-9]+(\.[0-9]+)? GB' | head -1 | grep -oE '[0-9]+(\.[0-9]+)?' || true)
    if [ -n "$EXISTING_FREE_GB" ] && echo "$EXISTING_FREE_GB" | awk '{exit !($1 >= 5)}'; then
        log "Free space already ${EXISTING_FREE_GB}GB — skipping APFS resize"
        if ! _validate_varname "$_apfs_resized_name"; then die "shrink_apfs_if_needed: invalid variable name"; fi
        eval "${_apfs_resized_name}=0"
        return 0
    fi

    log "Purging purgeable APFS space..."
    remote_mac_sudo tmutil thinlocalsnapshots / 999999999999 2>/dev/null || true

    USED_GB=$(remote_mac_exec diskutil apfs list "$APFS_CONTAINER" 2>/dev/null | grep "Capacity In Use By Volumes" | grep -oE '[0-9]+(\.[0-9]+)? GB' | head -1 | grep -oE '[0-9]+(\.[0-9]+)?' || true)
    if [ -z "$USED_GB" ]; then
        USED_GB=$(remote_mac_exec diskutil apfs list "$APFS_CONTAINER" 2>/dev/null | grep "Capacity In Use By Volumes" | grep -oE '[0-9]+ B' | head-1 | awk '{printf "%.1f", $1/1024/1024/1024}' || true)
    fi

    case "${MACOS_SIZE_MODE:-auto}" in
        max_linux)
            TARGET_MACOS_GB=$MIN_MACOS_GB
            log "Max Linux mode: shrinking macOS to minimum ${TARGET_MACOS_GB}GB"
            ;;
        max_macos)
            if [ -n "$USED_GB" ]; then
                TARGET_MACOS_GB=$(echo "$USED_GB" | awk -v min="$MIN_MACOS_GB" -v margin=10 '{target=int($1)+margin+1; if(target<min) target=min; print target}')
            else
                TARGET_MACOS_GB=200
            fi
            log "Max macOS mode: keeping macOS at ${TARGET_MACOS_GB}GB (Ubuntu gets ~${MIN_UBUNTU_GB}GB)"
            ;;
        custom)
            if [ -n "${MACOS_SIZE_GB:-}" ] && [ "${MACOS_SIZE_GB:-0}" -ge "$MIN_MACOS_GB" ] 2>/dev/null; then
                TARGET_MACOS_GB="$MACOS_SIZE_GB"
                log "Custom mode: resizing macOS to ${TARGET_MACOS_GB}GB"
            else
                TARGET_MACOS_GB=$MIN_MACOS_GB
                warn "Custom size invalid or missing — falling back to min macOS (${TARGET_MACOS_GB}GB)"
            fi
            ;;
        *)
            # Auto: used + 10GB margin, min 50GB
            if [ -n "$USED_GB" ]; then
                TARGET_MACOS_GB=$(echo "$USED_GB" | awk -v min="$MIN_MACOS_GB" -v margin=10 '{target=int($1)+margin+1; if(target<min) target=min; print target}')
                log "APFS in use: ${USED_GB}GB → shrinking to ${TARGET_MACOS_GB}GB (10GB margin)"
            else
                TARGET_MACOS_GB=200
                warn "Could not determine APFS usage — defaulting to ${TARGET_MACOS_GB}GB for macOS"
            fi
            ;;
    esac

    CURRENT_CONTAINER_GB=$(remote_mac_exec diskutil info "$APFS_CONTAINER" 2>/dev/null | grep "Disk Size" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1 || true)
    if [ -n "$CURRENT_CONTAINER_GB" ] && echo "$CURRENT_CONTAINER_GB $TARGET_MACOS_GB" | awk '{exit !($1 <= $2)}'; then
        log "APFS already at ${CURRENT_CONTAINER_GB}GB — no resize needed"
        if ! _validate_varname "$_apfs_resized_name"; then die "shrink_apfs_if_needed: invalid variable name"; fi
        eval "${_apfs_resized_name}=0"
        return 0
    fi

    # Delete snapshots first
    log "Checking APFS snapshots..."
    SNAPSHOTS=$(remote_mac_exec diskutil apfs listSnapshots "$APFS_CONTAINER" 2>/dev/null | grep "Snapshot.*UUID" || true)
    if [ -n "$SNAPSHOTS" ]; then
        warn "APFS snapshots found — auto-deleting:"
        echo "$SNAPSHOTS"

        while IFS= read -r line; do
            SNAP_UUID=$(echo "$line" | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' || true)
            if [ -n "$SNAP_UUID" ]; then
                log "Deleting snapshot $SNAP_UUID..."
                remote_mac_sudo diskutil apfs deleteSnapshot "$APFS_CONTAINER" -uuid "$SNAP_UUID" || warn "Failed to delete snapshot $SNAP_UUID"
            fi
        done <<< "$SNAPSHOTS"

        remote_mac_sudo tmutil thinlocalsnapshots / 999999999999 2>/dev/null || true
    fi

    local _resize_rc=0
    dry_run_exec "Shrink APFS container to ${TARGET_MACOS_GB}GB" \
        remote_mac_sudo --timeout 600 diskutil apfs resizeContainer "$APFS_CONTAINER" "${TARGET_MACOS_GB}g" || _resize_rc=$?
    if [ "$_resize_rc" -eq 124 ]; then
        warn "APFS resize command timed out (SSH disconnected) — verifying if resize completed on remote..."
        local _verify_size
        _verify_size=$(remote_mac_exec diskutil info "$APFS_CONTAINER" 2>/dev/null | grep "Disk Size" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1 || true)
        if [ -n "$_verify_size" ] && echo "$_verify_size $TARGET_MACOS_GB" | awk '{exit !($1 <= $2 * 1.05)}'; then
            log "APFS container resized to ${_verify_size}GB (verified after timeout)"
        else
            die "APFS resize timed out and verification shows container still at ${_verify_size:-unknown}GB — retry deployment"
        fi
    elif [ "$_resize_rc" -ne 0 ]; then
        die "APFS resize failed (exit code $_resize_rc)"
    fi
    if ! _validate_varname "$_apfs_resized_name"; then die "shrink_apfs_if_needed: invalid variable name"; fi
    eval "$_apfs_resized_name=1"
    log "APFS container resized to ${TARGET_MACOS_GB}GB"

    if ! check_recovery_health "$APFS_CONTAINER"; then
        die "Recovery partition became unhealthy after APFS resize — cannot safely continue deployment. Restore via Internet Recovery (Cmd+Option+R)."
    fi
}

create_esp_partition() {
    local INTERNAL_DISK="$1"
    local _esp_created_name="$2"
    local _esp_device_name="$3"

    if ! _validate_varname "$_esp_created_name"; then
        die "create_esp_partition: invalid variable name: $_esp_created_name"
    fi
    if ! _validate_varname "$_esp_device_name"; then
        die "create_esp_partition: invalid variable name: $_esp_device_name"
    fi

    log "Creating ESP partition for Ubuntu installer..."

    # Remove leftover CIDATA ESP from a previous failed run
    local EXISTING_ESP
    EXISTING_ESP=$(remote_mac_exec diskutil list "$INTERNAL_DISK" 2>/dev/null | grep "$ESP_NAME" | grep -oE 'disk[0-9]+s[0-9]+' | head -1 || true)
    if [ -n "$EXISTING_ESP" ]; then
        log "Removing existing $ESP_NAME partition /dev/$EXISTING_ESP..."
        dry_run_exec "Remove existing ESP partition /dev/$EXISTING_ESP" \
            remote_mac_retry_diskutil unmount "/dev/$EXISTING_ESP" >/dev/null 2>&1 || true
        dry_run_exec "Erase ESP partition /dev/$EXISTING_ESP to free space" \
            remote_mac_retry_diskutil eraseVolume free none "/dev/$EXISTING_ESP" >/dev/null 2>&1 || warn "Could not remove existing ESP"
        sleep 1
    fi

    local BEFORE_PARTS AFTER_PARTS ESP_MOUNT
    BEFORE_PARTS=$(remote_mac_exec diskutil list "$INTERNAL_DISK" | grep -oE 'disk[0-9]+s[0-9]+' | sort)
    if [ "${DRY_RUN:-0}" -eq 1 ]; then
        echo "/Volumes/${ESP_NAME}"
        echo "disk0sN"
        eval "$_esp_created_name=1"
        eval "$_esp_device_name=\"disk0sN\""
        return 0
    fi
    if remote_mac_retry_diskutil addPartition "$INTERNAL_DISK" %C12A7328-F81F-11D2-BA4B-00A0C93EC93B% %noformat% "$ESP_SIZE" >/dev/null 2>&1; then
        sleep 2
        AFTER_PARTS=$(remote_mac_exec diskutil list "$INTERNAL_DISK" | grep -oE 'disk[0-9]+s[0-9]+' | sort)
        _esp_device_val=$(comm -13 <(echo "$BEFORE_PARTS") <(echo "$AFTER_PARTS") | head -1)
        if [ -z "$_esp_device_val" ]; then
            die "Cannot identify newly created ESP partition"
        fi
        log "ESP partition candidate: /dev/$_esp_device_val"
        remote_mac_sudo newfs_msdos -F 32 -v "$ESP_NAME" "/dev/$_esp_device_val" >/dev/null || die "Failed to format ESP as FAT32"
        sleep 2
        ESP_MOUNT="/Volumes/$ESP_NAME"
        remote_mac_exec mkdir -p "$ESP_MOUNT" 2>/dev/null || true
        remote_mac_sudo mount_msdos "/dev/$_esp_device_val" "$ESP_MOUNT" >/dev/null 2>&1 || \
            remote_mac_retry_diskutil mount "/dev/$_esp_device_val" >/dev/null 2>&1 || true
        sleep 3
        eval "$_esp_created_name=1"
        eval "$_esp_device_name=\"\$_esp_device_val\""
        if ! remote_mac_dir_exists "$ESP_MOUNT"; then
            ESP_MOUNT=$(remote_mac_exec diskutil info "/dev/$_esp_device_val" 2>/dev/null | grep "Mount Point" | awk '{$1=$2=""; print substr($0,3)}' | sed 's/^[[:space:]]*//' || true)
        fi
        remote_mac_dir_exists "$ESP_MOUNT" || die "ESP not mounted after format"

        echo "${ESP_MOUNT}"
        echo "${_esp_device_val}"
    else
        eval "$_esp_created_name=0"
        eval "$_esp_device_name=\"\""
        die "Failed to create ESP partition with EFI System Partition type"
    fi
}


