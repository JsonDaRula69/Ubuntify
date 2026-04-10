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

echo "========================================="
echo " Mac Pro 2013 Ubuntu ISO Builder"
echo " Extract-and-repack approach"
echo "========================================="
echo ""

[ -f "$BASE_ISO" ] || { echo -e "${RED}ERROR${NC}: Base ISO not found: $BASE_ISO"; exit 1; }
[ -f "$AUTOINSTALL" ] || { echo -e "${RED}ERROR${NC}: autoinstall.yaml not found: $AUTOINSTALL"; exit 1; }
[ -d "$PKGS_DIR" ] || { echo -e "${RED}ERROR${NC}: packages/ directory not found: $PKGS_DIR"; exit 1; }

PKG_COUNT=$(ls "$PKGS_DIR"/*.deb 2>/dev/null | wc -l | tr -d ' ')
echo "Packages to include: $PKG_COUNT"
[ "$PKG_COUNT" -gt 0 ] || { echo -e "${RED}ERROR${NC}: No .deb files in packages/"; exit 1; }

echo ""
echo "[1/5] Cleaning and preparing staging area..."
rm -rf "$STAGING"
mkdir -p "$STAGING/iso_root"

echo "[2/5] Extracting original ISO contents..."
xorriso -osirrox on -indev "$BASE_ISO" -extract / "$STAGING/iso_root/"

echo "[3/5] Overlaying custom files..."

cp "$AUTOINSTALL" "$STAGING/iso_root/autoinstall.yaml"

cp "$AUTOINSTALL" "$STAGING/iso_root/cidata/user-data"
echo "instance-id: macpro-linux-i1" > "$STAGING/iso_root/cidata/meta-data"
touch "$STAGING/iso_root/cidata/vendor-data"

mkdir -p "$STAGING/iso_root/macpro-pkgs"
cp "$PKGS_DIR"/*.deb "$STAGING/iso_root/macpro-pkgs/"

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

echo "[4/5] Extracting boot parameters and rebuilding ISO..."

BOOT_PARAMS=$(xorriso -indev "$BASE_ISO" -report_el_torito as_mkisofs 2>/dev/null)

if [ -z "$BOOT_PARAMS" ]; then
    echo -e "${RED}ERROR${NC}: Failed to extract boot parameters from base ISO"
    exit 1
fi

echo "Extracted boot parameters:"
echo "$BOOT_PARAMS" | head -10 | sed 's/^/  /'
echo "  ... (preserving original boot structure)"

# Rebuild ISO using extracted boot parameters
# The -V "cidata" sets the volume label for NoCloud discovery
# BOOT_PARAMS preserves MBR, EFI partition image, and El Torito boot entries
# eval is needed because BOOT_PARAMS contains multiple quoted arguments
eval xorriso -as mkisofs \
    $BOOT_PARAMS \
    -V "cidata" \
    -o "${OUTPUT_ISO}" \
    "$STAGING/iso_root"

if [ ! -f "$OUTPUT_ISO" ]; then
    echo -e "${RED}ERROR${NC}: ISO creation failed"
    exit 1
fi

echo ""
echo "[5/5] Verifying ISO contents and boot images..."

echo "Verifying files:"
for file in /autoinstall.yaml /cidata/user-data /cidata/meta-data /macpro-pkgs/ /EFI/boot/grub.cfg /boot/grub/grub.cfg; do
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
echo "  Headless:     Use prepare-headless-deploy.sh to bless via SSH"
