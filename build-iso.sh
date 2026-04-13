#!/bin/bash
set -e
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly BASE_ISO="${SCRIPT_DIR}/prereqs/ubuntu-24.04.4-live-server-amd64.iso"
readonly AUTOINSTALL="${SCRIPT_DIR}/autoinstall.yaml"
readonly PKGS_DIR="${SCRIPT_DIR}/packages"
readonly OUTPUT_ISO="${SCRIPT_DIR}/ubuntu-macpro.iso"
readonly STAGING="/tmp/macpro-iso-staging"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log()   { echo -e "${GREEN}[build]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
die()   { error "$1"; exit 1; }

cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ] && [ -d "$STAGING" ]; then
        echo ""
        warn "Build failed (exit $exit_code). Staging dir preserved for debugging: $STAGING"
        warn "Remove manually: rm -rf $STAGING"
    fi
}
trap cleanup EXIT

echo "========================================="
echo " Mac Pro 2013 Ubuntu ISO Builder"
echo " Extract-and-repack approach"
echo "========================================="
echo ""

[ -f "$BASE_ISO" ] || die "Base ISO not found: $BASE_ISO"
[ -f "$AUTOINSTALL" ] || die "autoinstall.yaml not found: $AUTOINSTALL"
[ -d "$PKGS_DIR" ] || die "packages/ directory not found: $PKGS_DIR"

PKG_COUNT=$(ls "$PKGS_DIR"/*.deb 2>/dev/null | wc -l | tr -d ' ')
log "Packages to include: $PKG_COUNT"
[ "$PKG_COUNT" -gt 0 ] || die "No .deb files in packages/"

if [ -d "${PKGS_DIR}/dkms-patches" ]; then
    if [ ! -f "${PKGS_DIR}/dkms-patches/series" ]; then
        die "DKMS patches directory exists but series file is missing — patches won't be applied in order"
    fi
    PATCH_COUNT=$(ls "${PKGS_DIR}/dkms-patches/"*.patch 2>/dev/null | wc -l | tr -d ' ')
    if [ "$PATCH_COUNT" -eq 0 ]; then
        die "DKMS patches directory has series file but no .patch files — driver compilation will fail on kernel 6.8+"
    fi
    while IFS= read -r patch_name; do
        [[ -z "$patch_name" || "$patch_name" =~ ^[[:space:]]*# ]] && continue
        if [ ! -f "${PKGS_DIR}/dkms-patches/${patch_name}" ]; then
            die "DKMS patch '${patch_name}' listed in series but file not found"
        fi
    done < "${PKGS_DIR}/dkms-patches/series"
    log "DKMS patches: $PATCH_COUNT patches validated for kernel 6.8+ compatibility"
else
    die "No DKMS patches found in ${PKGS_DIR}/dkms-patches/ — broadcom-sta will fail to compile on kernel 6.8+"
fi
echo ""
log "[1/5] Cleaning and preparing staging area..."
rm -rf "$STAGING" 2>/dev/null || sudo rm -rf "$STAGING"
mkdir -p "$STAGING/iso_root"

log "[2/5] Extracting original ISO contents..."
xorriso -osirrox on -indev "$BASE_ISO" -extract / "$STAGING/iso_root/"
chmod -R u+w "$STAGING/iso_root"

log "[3/5] Overlaying custom files..."

cp "$AUTOINSTALL" "$STAGING/iso_root/autoinstall.yaml"

mkdir -p "$STAGING/iso_root/cidata"
cp "$AUTOINSTALL" "$STAGING/iso_root/cidata/user-data"
echo "instance-id: macpro-linux-i1" > "$STAGING/iso_root/cidata/meta-data"
touch "$STAGING/iso_root/cidata/vendor-data"

mkdir -p "$STAGING/iso_root/macpro-pkgs"
cp "$PKGS_DIR"/*.deb "$STAGING/iso_root/macpro-pkgs/" || die "Failed to copy .deb packages"

mkdir -p "$STAGING/iso_root/macpro-pkgs/dkms-patches"
cp "${PKGS_DIR}/dkms-patches/"*.patch "$STAGING/iso_root/macpro-pkgs/dkms-patches/" || die "Failed to copy DKMS patches"
cp "${PKGS_DIR}/dkms-patches/series" "$STAGING/iso_root/macpro-pkgs/dkms-patches/" || die "Failed to copy DKMS series file"

cat > "$STAGING/grub.cfg" << 'GRUBEOF'
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

cp "$STAGING/grub.cfg" "$STAGING/iso_root/EFI/boot/grub.cfg"
cp "$STAGING/grub.cfg" "$STAGING/iso_root/boot/grub/grub.cfg"

log "[4/5] Extracting boot parameters and rebuilding ISO..."

BOOT_PARAMS=$(xorriso -indev "$BASE_ISO" -report_el_torito as_mkisofs 2>/dev/null | tr '\n' ' ')

if [ -z "$BOOT_PARAMS" ]; then
    die "Failed to extract boot parameters from base ISO"
fi

echo "Extracted boot parameters:"
echo "$BOOT_PARAMS" | head -10 | sed 's/^/  /'
echo "  ... (preserving original boot structure)"

# BOOT_PARAMS comes from xorriso reading the trusted base ISO;
# eval is required to properly expand its multi-word arguments as positional args to xorriso
eval "xorriso -as mkisofs \
    $BOOT_PARAMS \
    -V \"cidata\" \
    -o \"${OUTPUT_ISO}\" \
    \"${STAGING}/iso_root\""

if [ ! -f "$OUTPUT_ISO" ]; then
    die "ISO creation failed — output file not found"
fi

echo ""
log "[5/5] Verifying ISO contents and boot images..."

echo "Verifying files:"
for file in /autoinstall.yaml /cidata/user-data /cidata/meta-data /macpro-pkgs/ /macpro-pkgs/dkms-patches/ /EFI/boot/grub.cfg /boot/grub/grub.cfg; do
    if xorriso -indev "$OUTPUT_ISO" -ls "$file" >/dev/null 2>&1; then
        echo -e "  ${GREEN}OK${NC}: $file"
    else
        echo -e "  ${YELLOW}WARN${NC}: $file not found"
    fi
done

echo ""
echo "Boot parameters in output ISO:"
xorriso -indev "$OUTPUT_ISO" -report_el_torito plain 2>/dev/null | head -20 | sed 's/^/  /'

rm -rf "$STAGING"

SIZE=$(du -h "$OUTPUT_ISO" | cut -f1)
echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN} BUILD COMPLETE${NC}"
echo -e "${GREEN}=========================================${NC}"
echo "Output:   $OUTPUT_ISO"
echo "Size:     $SIZE"
echo "Packages: $PKG_COUNT debs in /macpro-pkgs/"
echo "Config:   /autoinstall.yaml"
echo "cidata:   /cidata/{user-data,meta-data,vendor-data}"
echo "GRUB:     /EFI/boot/grub.cfg + /boot/grub/grub.cfg"
echo "Volume:   cidata (NoCloud compliant)"
echo ""
echo "Boot methods:"
echo "  USB:          Boot from USB, auto-entry selected after 3s"
echo "  Deploy:       Use prepare-deployment.sh to deploy (ESP, USB, manual, or VM test)"
