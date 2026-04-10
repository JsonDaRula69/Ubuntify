#!/bin/bash
set -e
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly ISO_PATH="${1:-${SCRIPT_DIR}/ubuntu-macpro.iso}"
readonly ESP_NAME="UBUNTU_ESP"
readonly ESP_SIZE="2g"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly NC='\033[0m'

log()   { echo -e "${GREEN}[deploy]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
die()   { error "$1"; exit 1; }

# ── Recovery: reset boot device to macOS on fatal error ──
cleanup_on_error() {
    local EXIT_CODE=$?
    if [ "$EXIT_CODE" -ne 0 ]; then
        echo ""
        error "Script exited with code $EXIT_CODE — attempting to restore macOS boot device..."
        # Re-set macOS as boot device so machine doesn't get stuck
        # on a broken ESP after a failed deploy
        local MACOS_VOLUME="/"
        if [ -d "$MACOS_VOLUME" ]; then
            bless --mount "$MACOS_VOLUME" --setBoot 2>/dev/null && \
                warn "macOS boot device restored via bless" || \
                error "Could not restore macOS boot device — manual intervention required"
        fi
        error "Deployment failed. macOS boot device should still be active."
    fi
}
trap cleanup_on_error EXIT

echo "========================================="
echo " Mac Pro 2013 Headless Ubuntu Deploy"
echo " Remote installation via bless"
echo "========================================="
echo ""

# ── Preflight checks ──

[ -f "$ISO_PATH" ] || die "ISO not found: $ISO_PATH (pass path as argument)"

log "Running on: $(sw_vers -productName) $(sw_vers -productVersion)"
log "ISO: $ISO_PATH"
echo ""

# ── Step 1: Analyze current disk layout ──

log "Step 1: Analyzing disk layout..."
INTERNAL_DISK=$(diskutil list | grep -E 'internal.*physical' | head -1 | grep -oE '/dev/disk[0-9]+' || true)
[ -n "$INTERNAL_DISK" ] || die "Cannot identify internal disk"

log "Internal disk: $INTERNAL_DISK"
diskutil list "$INTERNAL_DISK"
echo ""

# Check APFS container and free space
APFS_CONTAINER=$(diskutil apfs list | grep -A2 "Container.*${INTERNAL_DISK}" | grep -oE 'disk[0-9]+s[0-9]+' | head -1 || true)
if [ -n "$APFS_CONTAINER" ]; then
    APFS_INFO=$(diskutil apfs list 2>/dev/null)
    FREE_SPACE=$(echo "$APFS_INFO" | grep -A5 "Capacity" | grep "Available" | grep -oE '[0-9]+.*B' | head -1 || true)
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

# ── Step 3: Shrink APFS container ──

log "Step 3: Shrinking APFS container..."

CURRENT_SIZE=$(diskutil info "$APFS_CONTAINER" 2>/dev/null | grep "Disk Size" | grep -oE '[0-9]+\.[0-9]+ GB' || true)
log "Current APFS size: ${CURRENT_SIZE:-unknown}"

MIN_MACOS_GB=80
TARGET_MACOS_GB=100
log "Target macOS size: ${TARGET_MACOS_GB}GB (minimum: ${MIN_MACOS_GB}GB)"

if [ -n "$APFS_CONTAINER" ]; then
    FREE_GB_STR=$(diskutil apfs list "$APFS_CONTAINER" 2>/dev/null | grep -A1 "Available" | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)
    if [ -n "$FREE_GB_STR" ]; then
        REQUIRED_GB=$((TARGET_MACOS_GB + 5))
        if [ "$(echo "$FREE_GB_STR" | awk -v req="$REQUIRED_GB" '{print ($1 > req) ? "yes" : "no"}')" = "no" ]; then
            die "Insufficient free space (${FREE_GB_STR}GB free, need ${REQUIRED_GB}GB for resize with margin)"
        fi
        log "Free space check passed: ${FREE_GB_STR}GB available, ${REQUIRED_GB}GB required"
    else
        warn "Could not determine free space — proceeding without validation"
    fi
fi

diskutil apfs resizeContainer "$APFS_CONTAINER" "${TARGET_MACOS_GB}g" 0 0 0 || die "APFS resize failed"
log "APFS container resized"
echo ""

# ── Step 4: Create ESP partition ──

log "Step 4: Creating ESP partition for Ubuntu installer..."

FREE_START=$(diskutil list "$INTERNAL_DISK" | grep -E '\(free\)' -B1 | head -1 | grep -oE '[0-9]+\.[0-9]+ GB' || true)
log "Free space after resize: ${FREE_START:-unknown}"

# Find the newly created partition using before/after diffing
# This is safer than 'tail -1' which could pick the wrong partition on re-run
BEFORE_PARTS=$(diskutil list "$INTERNAL_DISK" | grep -oE 'disk[0-9]+s[0-9]+' | sort)
diskutil addPartition "$INTERNAL_DISK" %noformat% %noformat% "$ESP_SIZE" || die "Failed to create ESP partition"
sleep 2
AFTER_PARTS=$(diskutil list "$INTERNAL_DISK" | grep -oE 'disk[0-9]+s[0-9]+' | sort)
ESP_DEVICE=$(comm -13 <(echo "$BEFORE_PARTS") <(echo "$AFTER_PARTS") | head -1)
[ -n "$ESP_DEVICE" ] || die "Cannot identify newly created ESP partition"

log "ESP partition candidate: /dev/$ESP_DEVICE"

# Format as FAT32 with the ESP name using GPT (required for UEFI, not MBR)
diskutil eraseVolume FAT32 "$ESP_NAME" "/dev/$ESP_DEVICE" || \
    die "Failed to format ESP partition as FAT32"
sleep 1

ESP_MOUNT="/Volumes/$ESP_NAME"
[ -d "$ESP_MOUNT" ] || die "ESP not mounted at $ESP_MOUNT"
log "ESP mounted at: $ESP_MOUNT"
echo ""

# ── Step 5: Mount ISO and extract contents to ESP ──

log "Step 5: Extracting ISO contents to ESP..."

ISO_MOUNT="/tmp/ubuntu-iso-mount"
mkdir -p "$ISO_MOUNT"
hdiutil attach "$ISO_PATH" -mountpoint "$ISO_MOUNT" -readonly -quiet || die "Failed to mount ISO"
log "ISO mounted at: $ISO_MOUNT"

# Copy EFI boot files — CRITICAL: do not silently ignore failures
log "Copying EFI boot structure..."
mkdir -p "$ESP_MOUNT/EFI/boot"
cp "$ISO_MOUNT/EFI/boot/"* "$ESP_MOUNT/EFI/boot/" || die "Failed to copy EFI boot files — cannot boot without them"

# Verify the EFI bootloader exists immediately after copy
[ -f "$ESP_MOUNT/EFI/boot/BOOTX64.EFI" ] || die "BOOTX64.EFI missing after copy — ISO may lack EFI support"

# Copy casper (kernel + initrd + filesystem)
log "Copying casper directory (~850MB)..."
mkdir -p "$ESP_MOUNT/casper"
cp "$ISO_MOUNT/casper/"* "$ESP_MOUNT/casper/" || warn "Some casper files failed to copy (non-fatal if kernel+initrd present)"
# Verify kernel and initrd — these are strictly required
[ -f "$ESP_MOUNT/casper/vmlinuz" ] || die "casper/vmlinuz missing — cannot boot"
[ -f "$ESP_MOUNT/casper/initrd" ] || die "casper/initrd missing — cannot boot"

# Copy the autoinstall.yaml and macpro-pkgs
log "Copying autoinstall configuration..."
cp "$ISO_MOUNT/autoinstall.yaml" "$ESP_MOUNT/autoinstall.yaml" 2>/dev/null || \
    cp "$SCRIPT_DIR/autoinstall.yaml" "$ESP_MOUNT/autoinstall.yaml" || \
    die "Failed to copy autoinstall.yaml"
[ -f "$ESP_MOUNT/autoinstall.yaml" ] || die "autoinstall.yaml missing after copy"

log "Copying driver compilation packages..."
mkdir -p "$ESP_MOUNT/macpro-pkgs"
cp "$ISO_MOUNT/macpro-pkgs/"* "$ESP_MOUNT/macpro-pkgs/" 2>/dev/null || \
    cp "$SCRIPT_DIR/packages/"*.deb "$ESP_MOUNT/macpro-pkgs/" 2>/dev/null || \
    warn "Some driver packages may be missing"
# Verify at least the critical driver package exists
if ! ls "$ESP_MOUNT/macpro-pkgs/"broadcom-sta-dkms_*.deb 1>/dev/null 2>&1; then
    warn "broadcom-sta-dkms .deb not found in macpro-pkgs/ — WiFi driver compilation will fail"
fi

# Copy cidata for ds=nocloud
log "Creating cidata structure..."
mkdir -p "$ESP_MOUNT/cidata"
cp "$ISO_MOUNT/cidata/"* "$ESP_MOUNT/cidata/" 2>/dev/null || true
[ -f "$ESP_MOUNT/cidata/user-data" ] || cp "$SCRIPT_DIR/autoinstall.yaml" "$ESP_MOUNT/cidata/user-data"
[ -f "$ESP_MOUNT/cidata/meta-data" ] || echo "instance-id: macpro-linux-i1" > "$ESP_MOUNT/cidata/meta-data"
[ -f "$ESP_MOUNT/cidata/vendor-data" ] || touch "$ESP_MOUNT/cidata/vendor-data"

# Copy pool directory (packages available during install) — non-critical
log "Copying package pool..."
mkdir -p "$ESP_MOUNT/pool"
cp -r "$ISO_MOUNT/pool/"* "$ESP_MOUNT/pool/" 2>/dev/null || warn "pool directory copy failed (non-critical)"

# Copy dists directory (release metadata) — non-critical
log "Copying release metadata..."
mkdir -p "$ESP_MOUNT/dists"
cp -r "$ISO_MOUNT/dists/"* "$ESP_MOUNT/dists/" 2>/dev/null || warn "dists directory copy failed (non-critical)"

# Copy .disk directory — non-critical
log "Copying disk metadata..."
mkdir -p "$ESP_MOUNT/.disk"
cp "$ISO_MOUNT/.disk/"* "$ESP_MOUNT/.disk/" 2>/dev/null || warn ".disk directory copy failed (non-critical)"

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

hdiutil detach "$ISO_MOUNT" -quiet 2>/dev/null || true
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
bless --setBoot --mount "$ESP_MOUNT" --nextonly || \
    die "bless failed — cannot set boot device. Check SIP status."

log "Verifying boot device..."
bless --info "$ESP_MOUNT" 2>/dev/null || warn "Could not verify boot device with bless --info"
log "Boot device set via bless (--nextonly: will revert to macOS if installer fails)"
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
echo "If the installer fails, the NEXT reboot will"
echo "fall back to macOS automatically."
echo ""
echo "On next reboot, the Mac Pro will boot into"
echo "Ubuntu Server autoinstall and begin installation."
echo ""
echo "To monitor: start webhook monitor on MacBook"
echo "  cd macpro-monitor && ./start.sh"
echo ""
echo "To cancel: reset NVRAM boot device"
echo "  bless --mount / --setBoot  # reset to macOS"
echo ""
if [ -t 0 ]; then
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