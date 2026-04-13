#!/bin/bash
set -e
set -o pipefail
export PATH="/usr/local/bin:/usr/local/sbin:$PATH"

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly ISO_PATH="${1:-${SCRIPT_DIR}/ubuntu-macpro.iso}"
readonly ESP_NAME="CIDATA"
readonly ESP_SIZE="5g"
APFS_CONTAINER=""

_APFS_ORIGINAL_SIZE=""
_APFS_RESIZED=0
_ESP_CREATED=0

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly NC='\033[0m'

log()   { echo -e "${GREEN}[deploy]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
die()   { error "$1"; exit 1; }

_CLEANUP_DONE=0

revert_changes() {
    echo ""
    error "Reverting deployment changes..."
    local REVERT_ERRORS=0

    # Ensure INTERNAL_DISK is known — may not be set if we failed very early
    if [ -z "$INTERNAL_DISK" ]; then
        INTERNAL_DISK=$(diskutil list | grep -E 'internal.*physical' | head -1 | grep -oE '/dev/disk[0-9]+' || true)
    fi

    # Find ESP by volume name — diskutil eraseVolume renumbers the slice
    if [ "$_ESP_CREATED" -eq 1 ] && [ -n "$INTERNAL_DISK" ]; then
        ESP_REVERT_DEV=$(diskutil list "$INTERNAL_DISK" 2>/dev/null | grep "$ESP_NAME" | grep -oE 'disk[0-9]+s[0-9]+' | head -1 || true)
        if [ -n "$ESP_REVERT_DEV" ]; then
            log "Removing ESP partition /dev/$ESP_REVERT_DEV..."
            diskutil unmount "/dev/$ESP_REVERT_DEV" 2>/dev/null || true
            diskutil eraseVolume free none "/dev/$ESP_REVERT_DEV" 2>/dev/null || {
                warn "Could not remove ESP partition /dev/$ESP_REVERT_DEV — remove manually"
                REVERT_ERRORS=1
            }
        else
            warn "No $ESP_NAME partition found to remove"
        fi
        _ESP_CREATED=0
    fi

    if [ "$_APFS_RESIZED" -eq 1 ] && [ -n "$APFS_CONTAINER" ] && [ -n "$_APFS_ORIGINAL_SIZE" ]; then
        log "Restoring APFS container to ${_APFS_ORIGINAL_SIZE}GB..."
        diskutil apfs resizeContainer "$APFS_CONTAINER" "${_APFS_ORIGINAL_SIZE}g" 2>/dev/null || {
            warn "Could not restore APFS container size — resize manually"
            REVERT_ERRORS=1
        }
        _APFS_RESIZED=0
    fi

    local MACOS_VOLUME="/"
    if [ -n "$APFS_CONTAINER" ]; then
        MACOS_VOLUME=$(diskutil info "$APFS_CONTAINER" 2>/dev/null | grep "Mount Point" | awk '{print $NF}' || echo "/")
    fi
    if [ -d "$MACOS_VOLUME" ] && [ "$MACOS_VOLUME" != "/" ]; then
        bless --mount "$MACOS_VOLUME" --setBoot 2>/dev/null && \
            log "macOS boot device restored" || {
            warn "Could not restore macOS boot device — manual intervention required"
            REVERT_ERRORS=1
        }
    else
        bless --mount / --setBoot 2>/dev/null && \
            log "macOS boot device restored (root fallback)" || {
            warn "Could not restore macOS boot device — manual intervention required"
            REVERT_ERRORS=1
        }
    fi

    if [ "$REVERT_ERRORS" -eq 0 ]; then
        log "Revert complete — disk restored to pre-deployment state"
    else
        error "Revert incomplete — some changes may require manual cleanup"
        [ -n "$INTERNAL_DISK" ] && diskutil list "$INTERNAL_DISK" 2>/dev/null || true
    fi
}

cleanup_on_error() {
    [ "$_CLEANUP_DONE" -eq 1 ] && return
    _CLEANUP_DONE=1
    local EXIT_CODE=$?
    if [ "$EXIT_CODE" -ne 0 ]; then
        revert_changes
        error "Deployment failed (exit code $EXIT_CODE)."
    fi
}
trap cleanup_on_error EXIT
trap 'cleanup_on_error; exit 130' SIGINT
trap 'cleanup_on_error; exit 143' SIGTERM

echo "========================================="
echo " Mac Pro 2013 Headless Ubuntu Deploy"
echo " Remote installation via bless"
echo "========================================="
echo ""

# ── Handle --revert flag for manual rollback ──
if [ "${1:-}" = "--revert" ]; then
    log "Manual revert requested..."
    INTERNAL_DISK=$(diskutil list | grep -E 'internal.*physical' | head -1 | grep -oE '/dev/disk[0-9]+' || true)
    if [ -z "$INTERNAL_DISK" ]; then
        die "Cannot identify internal disk for revert"
    fi
    APFS_PARTITION=$(diskutil list "$INTERNAL_DISK" | grep -i "APFS" | grep -oE 'disk[0-9]+s[0-9]+' | head -1 || true)
    if [ -n "$APFS_PARTITION" ]; then
        APFS_CONTAINER=$(diskutil info "$APFS_PARTITION" 2>/dev/null | grep -i "container" | grep -oE 'disk[0-9]+' | head -1 || true)
    fi
    if [ -z "$APFS_CONTAINER" ]; then
        APFS_CONTAINER=$(diskutil list | grep -i "APFS" | grep -oE 'disk[0-9]+' | head -1 || true)
    fi
    # Find and remove the CIDATA ESP partition (by volume name)
    ESP_CANDIDATE=$(diskutil list "$INTERNAL_DISK" 2>/dev/null | grep "$ESP_NAME" | grep -oE 'disk[0-9]+s[0-9]+' | head -1 || true)
    if [ -n "$ESP_CANDIDATE" ]; then
        log "Removing ESP partition /dev/$ESP_CANDIDATE..."
        diskutil unmount "/dev/$ESP_CANDIDATE" 2>/dev/null || true
        diskutil eraseVolume free none "/dev/$ESP_CANDIDATE" 2>/dev/null || warn "Could not remove /dev/$ESP_CANDIDATE"
    else
        warn "No $ESP_NAME partition found — may have already been removed"
    fi
    # Restore macOS boot device
    MACOS_VOLUME=$(diskutil info "$APFS_CONTAINER" 2>/dev/null | grep "Mount Point" | awk '{print $NF}' || echo "/")
    if [ -d "$MACOS_VOLUME" ] && [ "$MACOS_VOLUME" != "/" ]; then
        bless --mount "$MACOS_VOLUME" --setBoot 2>/dev/null && log "macOS boot device restored" || warn "Could not restore macOS boot device"
    else
        bless --mount / --setBoot 2>/dev/null && log "macOS boot device restored (root fallback)" || warn "Could not restore macOS boot device"
    fi
    log "Revert complete"
    exit 0
fi

# ── Preflight checks ──

[ -f "$ISO_PATH" ] || die "ISO not found: $ISO_PATH (pass path as argument)"
command -v xorriso >/dev/null 2>&1 || die "xorriso not found. Install with: brew install xorriso"
command -v sgdisk >/dev/null 2>&1 || die "sgdisk not found. Install with: brew install gptfdisk"
command -v comm >/dev/null 2>&1 || die "comm not found. Install with: brew install coreutils"
command -v python3 >/dev/null 2>&1 || die "python3 not found. Install with: brew install python3"

log "Running on: $(sw_vers -productName) $(sw_vers -productVersion)"
log "ISO: $ISO_PATH"

log "Preflight: Verifying ISO integrity..."
ISO_SIZE=$(stat -f%z "$ISO_PATH" 2>/dev/null || echo "0")
if [ "$ISO_SIZE" -lt 1000000000 ]; then
    die "ISO appears too small ($ISO_SIZE bytes) — may be corrupted"
fi

log "Preflight: Checking SIP status..."
SIP_STATUS=$(csrutil status 2>/dev/null | grep -o 'enabled\|disabled' | head -1 || echo "unknown")
if [ "$SIP_STATUS" = "enabled" ]; then
    log "SIP is enabled — bless should work (SIP does not block bless)"
else
    warn "SIP status: $SIP_STATUS — unexpected, verify bless will work"
fi

log "Preflight: Checking webhook endpoint reachability..."
if curl -s -m 3 -o /dev/null "http://192.168.1.115:8080/" 2>/dev/null; then
    log "Webhook endpoint reachable"
else
    warn "Webhook endpoint (192.168.1.115:8080) not reachable — monitoring will fail"
fi

log "Preflight: Checking FileVault status..."
FV_STATUS=$(fdesetup status 2>/dev/null | grep -o 'On\|Off' | head -1 || echo "unknown")
if [ "$FV_STATUS" = "On" ]; then
    warn "FileVault is ON — may interfere with APFS resize"
fi

log "ISO: $ISO_PATH"
echo ""

# ── Step 1: Analyze current disk layout ──

log "Step 1: Analyzing disk layout..."
INTERNAL_DISK=$(diskutil list | grep -E 'internal.*physical' | head -1 | grep -oE '/dev/disk[0-9]+' || true)
[ -n "$INTERNAL_DISK" ] || die "Cannot identify internal disk"

log "Internal disk: $INTERNAL_DISK"
diskutil list "$INTERNAL_DISK"
echo ""

# Find APFS container — the partition table shows "Container diskN" but
# diskutil apfs list references containers by their container disk (e.g. disk1),
# not the physical disk (e.g. disk0). We need the container disk reference.
APFS_PARTITION=$(diskutil list "$INTERNAL_DISK" | grep -i "APFS" | grep -oE 'disk[0-9]+s[0-9]+' | head -1 || true)
if [ -n "$APFS_PARTITION" ]; then
    # Extract the container reference from diskutil info (e.g. "Container Identifier: disk1")
    APFS_CONTAINER=$(diskutil info "$APFS_PARTITION" 2>/dev/null | grep -i "container" | grep -oE 'disk[0-9]+' | head -1 || true)
fi
# Fallback: find the APFS container disk via diskutil list
if [ -z "$APFS_CONTAINER" ]; then
    APFS_CONTAINER=$(diskutil list | grep -i "APFS" | grep -oE 'disk[0-9]+' | head -1 || true)
fi
if [ -n "$APFS_CONTAINER" ]; then
    APFS_INFO=$(diskutil apfs list 2>/dev/null)
    FREE_SPACE=$(echo "$APFS_INFO" | grep -A5 "Capacity" | grep "Available" | grep -oE '[0-9]+.*B' | head -1 || true)
    log "APFS partition: /dev/${APFS_PARTITION:-unknown}"
    log "APFS container: /dev/$APFS_CONTAINER"
    log "Free space: ${FREE_SPACE:-unknown}"
fi
echo ""

# ── Step 2: Check for and delete APFS snapshots ──

log "Step 2: Checking APFS snapshots..."
SNAPSHOTS=$(diskutil apfs listSnapshots "$APFS_CONTAINER" 2>/dev/null | grep "Snapshot.*UUID" || true)
if [ -n "$SNAPSHOTS" ]; then
    warn "APFS snapshots found — auto-deleting for headless deployment:"
    echo "$SNAPSHOTS"
    echo ""

    while IFS= read -r line; do
        SNAP_UUID=$(echo "$line" | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' || true)
        if [ -n "$SNAP_UUID" ]; then
            log "Deleting snapshot $SNAP_UUID..."
            diskutil apfs deleteSnapshot "$APFS_CONTAINER" -uuid "$SNAP_UUID" || warn "Failed to delete snapshot $SNAP_UUID"
        fi
    done <<< "$SNAPSHOTS"

    log "Thinning local Time Machine snapshots..."
    tmutil thinlocalsnapshots / 999999999999 2>/dev/null || true
fi
echo ""

# ── Step 3: Shrink APFS container (skip if sufficient free space exists) ──

log "Step 3: Checking APFS container size..."

CURRENT_SIZE=$(diskutil info "$APFS_CONTAINER" 2>/dev/null | grep "Disk Size" | grep -oE '[0-9]+\.[0-9]+ GB' || true)
_APFS_ORIGINAL_SIZE=$(echo "$CURRENT_SIZE" | grep -oE '[0-9]+\.[0-9]+' || true)
log "Current APFS size: ${CURRENT_SIZE:-unknown}"

EXISTING_FREE_GB=$(diskutil list "$INTERNAL_DISK" 2>/dev/null | grep "(free" | grep -oE '[0-9]+\.[0-9]+ GB' | head -1 | grep -oE '[0-9]+\.[0-9]+' || true)
if [ -n "$EXISTING_FREE_GB" ] && echo "$EXISTING_FREE_GB" | awk '{exit !($1 >= 5)}'; then
    log "Free space already ${EXISTING_FREE_GB}GB — skipping APFS resize"
else
    MIN_MACOS_GB=50

    log "Purging purgeable APFS space..."
    tmutil thinlocalsnapshots / 999999999999 2>/dev/null || true

    USED_GB=$(diskutil apfs list "$APFS_CONTAINER" 2>/dev/null | grep "Capacity In Use By Volumes" | grep -oE '[0-9]+\.[0-9]+ GB' | head -1 | grep -oE '[0-9]+\.[0-9]+' || true)
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

    CURRENT_CONTAINER_GB=$(diskutil info "$APFS_CONTAINER" 2>/dev/null | grep "Disk Size" | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)
    if [ -n "$CURRENT_CONTAINER_GB" ] && echo "$CURRENT_CONTAINER_GB $TARGET_MACOS_GB" | awk '{exit !($1 <= $2)}'; then
        log "APFS already at ${CURRENT_CONTAINER_GB}GB — no resize needed"
    else
    diskutil apfs resizeContainer "$APFS_CONTAINER" "${TARGET_MACOS_GB}g" || die "APFS resize failed"
    _APFS_RESIZED=1
    log "APFS container resized to ${TARGET_MACOS_GB}GB"
    fi
fi
echo ""

# ── Step 4: Create ESP partition ──

log "Step 4: Creating ESP partition for Ubuntu installer..."

# Remove leftover CIDATA ESP from a previous failed run
EXISTING_ESP=$(diskutil list "$INTERNAL_DISK" 2>/dev/null | grep "$ESP_NAME" | grep -oE 'disk[0-9]+s[0-9]+' | head -1 || true)
if [ -n "$EXISTING_ESP" ]; then
    log "Removing existing $ESP_NAME partition /dev/$EXISTING_ESP..."
    diskutil unmount "/dev/$EXISTING_ESP" 2>/dev/null || true
    diskutil eraseVolume free none "/dev/$EXISTING_ESP" 2>/dev/null || warn "Could not remove existing ESP"
    sleep 1
fi

FREE_START=$(diskutil list "$INTERNAL_DISK" | grep -E '\(free\)' -B1 | head -1 | grep -oE '[0-9]+\.[0-9]+ GB' || true)
log "Free space after resize: ${FREE_START:-unknown}"

# Find the newly created partition using before/after diffing
# This is safer than 'tail -1' which could pick the wrong partition on re-run
BEFORE_PARTS=$(diskutil list "$INTERNAL_DISK" | grep -oE 'disk[0-9]+s[0-9]+' | sort)
diskutil addPartition "$INTERNAL_DISK" %noformat% "$ESP_NAME" "$ESP_SIZE" || die "Failed to create ESP partition"
sleep 2
AFTER_PARTS=$(diskutil list "$INTERNAL_DISK" | grep -oE 'disk[0-9]+s[0-9]+' | sort)
ESP_DEVICE=$(comm -13 <(echo "$BEFORE_PARTS") <(echo "$AFTER_PARTS") | head -1)
[ -n "$ESP_DEVICE" ] || die "Cannot identify newly created ESP partition"

_ESP_DEVICE="$ESP_DEVICE"

log "ESP partition candidate: /dev/$ESP_DEVICE"
diskutil eraseVolume FAT32 "$ESP_NAME" "/dev/$ESP_DEVICE" || \
    die "Failed to format ESP partition as FAT32"
_ESP_CREATED=1
sleep 1

ESP_MOUNT="/Volumes/$ESP_NAME"
[ -d "$ESP_MOUNT" ] || die "ESP not mounted at $ESP_MOUNT"
log "ESP mounted at: $ESP_MOUNT"

# Set GPT partition type to EFI System Partition — Apple EFI firmware requires
# this for bless to work (diskutil eraseVolume sets it to Microsoft Basic Data)
ESP_PART_NUM=$(echo "$ESP_DEVICE" | grep -oE '[0-9]+$')
diskutil unmount "$ESP_MOUNT" 2>/dev/null || true
sgdisk --typecode="${ESP_PART_NUM}":C12A7328-F81F-11D2-BA4B-00A0C93EC93B "$INTERNAL_DISK" || \
    warn "Could not set EFI partition type — bless may fail"
diskutil mount "$ESP_MOUNT" 2>/dev/null || true
[ -d "$ESP_MOUNT" ] || die "ESP not remounted after partition type change"
echo ""

# ── Step 5: Extract ISO contents to ESP ──

log "Step 5: Extracting ISO contents to ESP..."

command -v xorriso >/dev/null 2>&1 || die "xorriso not found. Install with: brew install xorriso"

ESP_AVAIL=$(df -m "$ESP_MOUNT" | tail -1 | awk '{print $4}')
ISO_TOTAL=$(du -sm "$ISO_PATH" 2>/dev/null | cut -f1 || echo "0")
if [ -n "$ESP_AVAIL" ] && [ "$ESP_AVAIL" -gt 0 ] && [ -n "$ISO_TOTAL" ] && [ "$ISO_TOTAL" -gt 0 ]; then
    REQUIRED_MIN=$((ISO_TOTAL + ISO_TOTAL / 10))
    if [ "$ESP_AVAIL" -lt "$REQUIRED_MIN" ]; then
        die "ESP too small: ${ESP_AVAIL}MB available, ${REQUIRED_MIN}MB needed (${ISO_TOTAL}MB + 10% overhead)"
    fi
    log "Space check: ${ESP_AVAIL}MB available, ${REQUIRED_MIN}MB needed (with 10% margin)"
fi

# Extract ISO contents directly to ESP using xorriso -osirrox
# (macOS hdiutil cannot mount xorriso-built ISOs with hybrid MBR+GPT+El Torito)
log "Extracting ISO to ESP via xorriso (this may take a minute)..."
xorriso -osirrox on -indev "$ISO_PATH" \
    -extract / "$ESP_MOUNT" 2>/dev/null || \
    die "Failed to extract ISO contents"

rm -rf "$ESP_MOUNT/pool" "$ESP_MOUNT/dists" "$ESP_MOUNT/.disk" "$ESP_MOUNT/boot/grub" 2>/dev/null || true

# Verify the EFI bootloader exists (bsdtar extracts lowercase on case-sensitive, FAT32 is case-insensitive)
[ -f "$ESP_MOUNT/EFI/boot/bootx64.efi" ] || [ -f "$ESP_MOUNT/EFI/boot/BOOTX64.EFI" ] || die "BOOTX64.EFI missing after extraction — ISO may lack EFI support"

# Verify kernel and initrd — these are strictly required
[ -f "$ESP_MOUNT/casper/vmlinuz" ] || die "casper/vmlinuz missing — cannot boot"
[ -f "$ESP_MOUNT/casper/initrd" ] || die "casper/initrd missing — cannot boot"
# Verify at least one squashfs layer exists — required for root filesystem
if ! ls "$ESP_MOUNT/casper/"*.squashfs 1>/dev/null 2>&1; then
    die "No .squashfs files in casper/ — root filesystem unavailable, installer will kernel panic"
fi

if [ ! -f "$ESP_MOUNT/autoinstall.yaml" ]; then
    cp "$SCRIPT_DIR/autoinstall.yaml" "$ESP_MOUNT/autoinstall.yaml" || die "Failed to copy autoinstall.yaml"
fi
[ -f "$ESP_MOUNT/autoinstall.yaml" ] || die "autoinstall.yaml missing after extraction"

if ! ls "$ESP_MOUNT/macpro-pkgs/"broadcom-sta-dkms_*.deb 1>/dev/null 2>&1; then
    warn "broadcom-sta-dkms .deb not found in macpro-pkgs/ — trying local fallback"
    mkdir -p "$ESP_MOUNT/macpro-pkgs"
    cp "$SCRIPT_DIR/packages/"*.deb "$ESP_MOUNT/macpro-pkgs/" 2>/dev/null || warn "Some driver packages may be missing"
fi

if [ ! -d "$ESP_MOUNT/macpro-pkgs/dkms-patches" ] && [ -d "$SCRIPT_DIR/packages/dkms-patches" ]; then
    mkdir -p "$ESP_MOUNT/macpro-pkgs/dkms-patches"
    cp "$SCRIPT_DIR/packages/dkms-patches/"* "$ESP_MOUNT/macpro-pkgs/dkms-patches/" 2>/dev/null || warn "Some DKMS patches may be missing"
fi
if [ -d "$ESP_MOUNT/macpro-pkgs/dkms-patches" ]; then
    if [ ! -f "$ESP_MOUNT/macpro-pkgs/dkms-patches/series" ]; then
        warn "dkms-patches/series file missing — patches will not be applied in order"
    fi
    PATCH_COUNT=$(ls "$ESP_MOUNT/macpro-pkgs/dkms-patches/"*.patch 2>/dev/null | wc -l | tr -d ' ')
    log "DKMS patches copied: $PATCH_COUNT patches for kernel 6.8+ compatibility"
fi

# Copy cidata for ds=nocloud
log "Creating cidata structure..."
mkdir -p "$ESP_MOUNT/cidata"

# Generate dynamic autoinstall user-data with dual-boot storage config
# We must preserve ALL existing macOS partitions with preserve: true
# to prevent curtin from deleting them during install
log "Generating dual-boot storage config..."

python3 - "$SCRIPT_DIR/autoinstall.yaml" "$ESP_MOUNT/cidata/user-data" "$INTERNAL_DISK" << 'PYEOF' || die "Failed to generate dual-boot storage config"
import sys, subprocess, re, os

template_path = sys.argv[1]
output_path = sys.argv[2]
disk_dev = sys.argv[3]

with open(template_path) as f:
    content = f.read()

# Read GPT partition table using sgdisk
try:
    result = subprocess.run(['sgdisk', '-p', disk_dev], capture_output=True, text=True)
    part_lines = result.stdout.strip().split('\n')
except Exception as e:
    print(f"WARNING: Could not read partition table: {e}", file=sys.stderr)
    with open(output_path, 'w') as f:
        f.write(content)
    sys.exit(0)

# Parse existing partitions
preserved_yaml = ""
max_part_num = 0
part_count = 0

for line in part_lines:
    fields = line.split()
    if len(fields) < 7:
        continue
    try:
        part_num = int(fields[0])
        max_part_num = max(max_part_num, part_num)
    except (ValueError, IndexError):
        continue

    try:
        # Get detailed partition info
        info = subprocess.run(['sgdisk', '-i', str(part_num), disk_dev],
                             capture_output=True, text=True)
        info_text = info.stdout

        part_type_guid = ''
        part_uuid = ''
        first_sector = None
        last_sector = None

        for info_line in info_text.split('\n'):
            if 'Partition type GUID code:' in info_line or 'Partition type code:' in info_line:
                guid_match = re.search(r'([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})', info_line)
                if guid_match:
                    part_type_guid = guid_match.group(1).lower()
            elif 'Partition unique GUID:' in info_line or 'Partition GUID:' in info_line:
                guid_match = re.search(r'([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})', info_line)
                if guid_match:
                    part_uuid = guid_match.group(1).lower()
            elif 'First sector:' in info_line:
                sector_match = re.search(r'(\d+)', info_line.split(':')[-1])
                if sector_match:
                    first_sector = int(sector_match.group(1))
            elif 'Last sector:' in info_line:
                sector_match = re.search(r'(\d+)', info_line.split(':')[-1])
                if sector_match:
                    last_sector = int(sector_match.group(1))

        if first_sector is None:
            print(f"WARNING: Could not parse First sector for partition {part_num}, skipping preserve", file=sys.stderr)
            continue
        if last_sector is None:
            print(f"WARNING: Could not parse Last sector for partition {part_num}, skipping preserve", file=sys.stderr)
            continue
        if not part_type_guid:
            print(f"WARNING: Could not parse partition type GUID for partition {part_num}, skipping preserve", file=sys.stderr)
            continue
        if not part_uuid:
            print(f"WARNING: Could not parse partition UUID for partition {part_num}, skipping preserve", file=sys.stderr)
            continue

        offset_bytes = first_sector * 512
        size_bytes = (last_sector - first_sector + 1) * 512
        part_path = f"/dev/sda{part_num}"

        if size_bytes < 1048576:
            continue

        preserved_yaml += f"""    - device: root-disk
      size: {size_bytes}
      number: {part_num}
      preserve: true
      grub_device: false
      offset: {offset_bytes}
      partition_type: {part_type_guid}
      path: {part_path}
      uuid: {part_uuid}
      id: preserved-partition-{part_num}
      type: partition
"""
        part_count += 1
    except Exception as e:
        print(f"WARNING: Could not parse partition {part_num}: {e}", file=sys.stderr)
        continue

if not preserved_yaml:
    print("WARNING: No preserved partitions found — copying template as-is", file=sys.stderr)
    with open(output_path, 'w') as f:
        f.write(content)
    sys.exit(0)

next_num = max_part_num + 1

# Build the new storage section
new_storage = f"""  storage:
    config:
    - type: disk
      id: root-disk
      path: /dev/sda
      ptable: gpt
      preserve: true
      wipe: superblock
{preserved_yaml}    - type: partition
      id: efi-partition
      device: root-disk
      size: 512M
      flag: boot
      partition_type: c12a7328-f81f-11d2-ba4b-00a0c93ec93b
      grub_device: true
      number: {next_num}
    - type: format
      id: efi-format
      volume: efi-partition
      fstype: fat32
    - type: mount
      id: efi-mount
      device: efi-format
      path: /boot/efi
    - type: partition
      id: boot-partition
      device: root-disk
      size: 1G
      number: {next_num + 1}
    - type: format
      id: boot-format
      volume: boot-partition
      fstype: ext4
    - type: mount
      id: boot-mount
      device: boot-format
      path: /boot
    - type: partition
      id: root-partition
      device: root-disk
      size: -1
      number: {next_num + 2}
    - type: format
      id: root-format
      volume: root-partition
      fstype: ext4
    - type: mount
      id: root-mount
      device: root-format
      path: /
"""

# Replace the storage section in the template
# Match from "  storage:" to the next top-level key (2-space indent section)
pattern = r'  storage:\n    config:.*?(?=\n  [a-z]|\Z)'
replacement = new_storage.rstrip()
new_content = re.sub(pattern, replacement, content, count=1, flags=re.DOTALL)

if new_content == content:
    print("WARNING: Storage section not found in template — copying as-is", file=sys.stderr)
    with open(output_path, 'w') as f:
        f.write(content)
else:
    with open(output_path, 'w') as f:
        f.write(new_content)
    print(f"  Preserving {part_count} existing partitions (macOS + installer ESP)")
PYEOF

if [ ! -f "$ESP_MOUNT/cidata/user-data" ]; then
    warn "Dynamic generation failed — falling back to template"
    cp "$SCRIPT_DIR/autoinstall.yaml" "$ESP_MOUNT/cidata/user-data"
fi
# SAFETY: Validate that the generated user-data contains preserve:true entries.
# Without them, curtin will WIPE existing macOS partitions during autoinstall.
if ! grep -q 'preserve: true' "$ESP_MOUNT/cidata/user-data" 2>/dev/null; then
    die "Generated user-data lacks preserve:true entries — macOS partitions would be wiped. Aborting."
fi
PRESERVE_COUNT=$(grep -c 'preserve: true' "$ESP_MOUNT/cidata/user-data" 2>/dev/null || echo "0")
log "Preserve entries in user-data: $PRESERVE_COUNT"
[ -f "$ESP_MOUNT/cidata/meta-data" ] || echo "instance-id: macpro-linux-i1" > "$ESP_MOUNT/cidata/meta-data"
[ -f "$ESP_MOUNT/cidata/vendor-data" ] || touch "$ESP_MOUNT/cidata/vendor-data"

# Write GRUB config with pre-baked autoinstall parameters
log "Writing GRUB configuration..."
cat > "$ESP_MOUNT/EFI/boot/grub.cfg" << 'GRUBEOF'
set default=0
set timeout=3

menuentry "Ubuntu Server 24.04 Autoinstall (Mac Pro 2013)" {
    set gfxpayload=keep
    linux /casper/vmlinuz autoinstall ds=nocloud nomodeset amdgpu.si.modeset=0 ---
    initrd /casper/initrd
}

menuentry "Ubuntu Server 24.04 (Manual Install)" {
    set gfxpayload=keep
    linux /casper/vmlinuz nomodeset amdgpu.si.modeset=0 ---
    initrd /casper/initrd
}
GRUBEOF

# Also write boot/grub/grub.cfg for BIOS-style GRUB
mkdir -p "$ESP_MOUNT/boot/grub"
cp "$ESP_MOUNT/EFI/boot/grub.cfg" "$ESP_MOUNT/boot/grub/grub.cfg"

echo ""

# ── Step 6: Verify ESP contents ──

log "Step 6: Verifying ESP contents..."
REQUIRED_FILES=(
    "EFI/boot/BOOTX64.EFI"
    "EFI/boot/grub.cfg"
    "casper/vmlinuz"
    "casper/initrd"
    "autoinstall.yaml"
    "cidata/user-data"
    "cidata/meta-data"
)
ALL_OK=true
for f in "${REQUIRED_FILES[@]}"; do
    if [ -f "$ESP_MOUNT/$f" ]; then
        log "  ✓ $f"
    else
        warn "  ✗ $f (not found)"
        ALL_OK=false
    fi
done

# Check for driver packages — warn but don't fail
if ls "$ESP_MOUNT/macpro-pkgs/"broadcom-sta-dkms_*.deb 1>/dev/null 2>&1; then
    log "  ✓ macpro-pkgs/broadcom-sta-dkms_*.deb"
else
    warn "  ✗ macpro-pkgs/broadcom-sta-dkms (not found)"
    ALL_OK=false
fi

if [ -f "$ESP_MOUNT/macpro-pkgs/dkms-patches/series" ]; then
    PATCH_COUNT=$(ls "$ESP_MOUNT/macpro-pkgs/dkms-patches/"*.patch 2>/dev/null | wc -l | tr -d ' ')
    log "  ✓ macpro-pkgs/dkms-patches/ ($PATCH_COUNT patches)"
else
    warn "  ✗ macpro-pkgs/dkms-patches/ (missing — driver will fail on kernel 6.8+)"
    ALL_OK=false
fi

if [ "$ALL_OK" = "false" ]; then
    error "Some required files are missing — deployment may fail."
    die "Aborting: critical boot files missing from ESP"
fi
echo ""

# ── Step 7: Set boot device with bless (temporary: next-boot-only) ──

log "Step 7: Setting boot device with bless (--nextonly for safety)..."

# Use --nextonly so that if the installer fails, the next boot falls back to macOS.
# Once Ubuntu is confirmed running, set permanent boot device from within Ubuntu.
# bless does NOT validate the target file — we checked BOOTX64.EFI exists above.
bless --setBoot --mount "$ESP_MOUNT" --file "$ESP_MOUNT/EFI/boot/bootx64.efi" --nextonly || \
    die "bless failed (exit $?) — EFI firmware cannot set boot device. Ensure the ESP partition type is C12A7328-F81F-11D2-BA4B-00A0C93EC93B and BOOTX64.EFI exists."

log "Verifying boot device..."
bless --info "$ESP_MOUNT" 2>/dev/null || warn "Could not verify boot device with bless --info"
log "Boot device set via bless (--nextonly: reverts to macOS only if firmware cannot find bootloader)"
log "ESP: $ESP_MOUNT"
log "Bootloader: $ESP_MOUNT/EFI/boot/BOOTX64.EFI"
echo ""

# ── Step 8: Confirm and reboot ──

echo "========================================="
echo " READY TO REBOOT"
echo "========================================="
echo ""
echo "Current boot device has been changed to:"
echo "  $ESP_MOUNT (ESP with Ubuntu installer)"
echo ""
echo "NOTE: --nextonly was used with bless."
echo "If the ESP boot files are corrupt and the firmware"
echo "cannot find a valid bootloader, the NEXT reboot will"
echo "fall back to macOS automatically."
echo "HOWEVER: Once the installer successfully boots and"
echo "begins autoinstall (which wipes the disk), macOS is"
echo "preserved (dual-boot). However, if the installer fails mid-process,"
echo "physical access may be required to restore boot order."
echo ""
echo "On next reboot, the Mac Pro will boot into"
echo "Ubuntu Server autoinstall and begin installation."
echo ""
echo "To monitor: start webhook monitor on MacBook"
echo "  cd macpro-monitor && ./start.sh"
echo ""
echo "To cancel: reset NVRAM boot device"
echo "  sudo bless --mount '/Volumes/Macintosh HD' --setBoot  # reset to macOS"
echo ""
if [ -t 0 ] && [ "${DEPLOY_HEADLESS:-}" != "1" ]; then
    read -p "Reboot now? (yes/no): " CONFIRM
    if [ "$CONFIRM" = "yes" ]; then
        log "Rebooting..."
        shutdown -r now
    else
        log "Reboot cancelled. Boot device is set (--nextonly) but not activated."
        log "Run 'shutdown -r now' when ready."
    fi
else
    log "Non-interactive mode detected. Rebooting in 5 seconds..."
    sleep 5
    shutdown -r now
fi