#!/bin/bash
set -e
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
readonly BASE_ISO="${PROJECT_DIR}/prereqs/ubuntu-24.04.4-live-server-amd64.iso"
readonly VM_AUTOINSTALL="${SCRIPT_DIR}/autoinstall-vm.yaml"
readonly PKGS_DIR="${PROJECT_DIR}/packages"
readonly OUTPUT_ISO="${SCRIPT_DIR}/ubuntu-vmtest.iso"
readonly STAGING="/tmp/vmtest-iso-staging"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

echo "========================================="
echo " VM Test ISO Builder"
echo " Builds Mac Pro autoinstall ISO for"
echo " VirtualBox testing (Ethernet, no WiFi HW)"
echo "========================================="
echo ""

[ -f "$BASE_ISO" ] || { echo -e "${RED}ERROR${NC}: Base ISO not found: $BASE_ISO"; exit 1; }
[ -f "$VM_AUTOINSTALL" ] || { echo -e "${RED}ERROR${NC}: VM autoinstall not found: $VM_AUTOINSTALL"; exit 1; }
[ -d "$PKGS_DIR" ] || { echo -e "${RED}ERROR${NC}: packages/ directory not found: $PKGS_DIR"; exit 1; }

PKG_COUNT=$(ls "$PKGS_DIR"/*.deb 2>/dev/null | wc -l | tr -d ' ')
echo "Packages to include: $PKG_COUNT"
[ "$PKG_COUNT" -gt 0 ] || { echo -e "${RED}ERROR${NC}: No .deb files in packages/"; exit 1; }

echo ""
echo "[1/5] Cleaning and preparing staging area..."
rm -rf "$STAGING" 2>/dev/null || sudo rm -rf "$STAGING"
mkdir -p "$STAGING/iso_root"

echo "[2/5] Extracting original ISO contents..."
xorriso -osirrox on -indev "$BASE_ISO" -extract / "$STAGING/iso_root/"
chmod -R u+w "$STAGING/iso_root"

echo "[3/5] Overlaying custom files..."

cp "$VM_AUTOINSTALL" "$STAGING/iso_root/autoinstall.yaml"

mkdir -p "$STAGING/iso_root/cidata"
cp "$VM_AUTOINSTALL" "$STAGING/iso_root/cidata/user-data"
echo "instance-id: vmtest-i1" > "$STAGING/iso_root/cidata/meta-data"
touch "$STAGING/iso_root/cidata/vendor-data"

mkdir -p "$STAGING/iso_root/macpro-pkgs"
cp "$PKGS_DIR"/*.deb "$STAGING/iso_root/macpro-pkgs/"

if [ -d "${PKGS_DIR}/dkms-patches" ] && [ "$(ls "${PKGS_DIR}/dkms-patches/"*.patch 2>/dev/null | wc -l)" -gt 0 ]; then
    mkdir -p "$STAGING/iso_root/macpro-pkgs/dkms-patches"
    cp "${PKGS_DIR}/dkms-patches/"*.patch "$STAGING/iso_root/macpro-pkgs/dkms-patches/"
    if [ -f "${PKGS_DIR}/dkms-patches/series" ]; then
        cp "${PKGS_DIR}/dkms-patches/series" "$STAGING/iso_root/macpro-pkgs/dkms-patches/"
    fi
    PATCH_COUNT=$(ls "${PKGS_DIR}/dkms-patches/"*.patch 2>/dev/null | wc -l | tr -d ' ')
    echo "DKMS patches: $PATCH_COUNT patches"
else
    echo -e "${YELLOW}WARN${NC}: No DKMS patches found"
fi

cat > "$STAGING/grub.cfg" << 'GRUBEOF'
set default=0
set timeout=3

menuentry "Ubuntu Server 24.04 VM Test Autoinstall" {
    set gfxpayload=keep
    linux /casper/vmlinuz autoinstall ds=nocloud console=ttyS0,115200 ---
    initrd /casper/initrd
}

menuentry "Ubuntu Server 24.04 (Manual Install)" {
    set gfxpayload=keep
    linux /casper/vmlinuz console=ttyS0,115200 ---
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

BOOT_PARAMS_FILE="$STAGING/boot_params.sh"
printf 'BOOT_ARRAY=( %s )\n' "$BOOT_PARAMS" > "$BOOT_PARAMS_FILE"
source "$BOOT_PARAMS_FILE"
xorriso -as mkisofs \
    "${BOOT_ARRAY[@]}" \
    -V "cidata" \
    -o "${OUTPUT_ISO}" \
    "$STAGING/iso_root"

if [ ! -f "$OUTPUT_ISO" ]; then
    echo -e "${RED}ERROR${NC}: ISO creation failed"
    exit 1
fi

echo ""
echo "[5/5] Verifying ISO contents..."

echo "Verifying files:"
for file in /autoinstall.yaml /cidata/user-data /cidata/meta-data /macpro-pkgs/ /macpro-pkgs/dkms-patches/ /EFI/boot/grub.cfg /boot/grub/grub.cfg; do
    if xorriso -indev "$OUTPUT_ISO" -ls "$file" >/dev/null 2>&1; then
        echo -e "  ${GREEN}OK${NC}: $file"
    else
        echo -e "  ${YELLOW}WARN${NC}: $file not found"
    fi
done

rm -rf "$STAGING"

SIZE=$(du -h "$OUTPUT_ISO" | cut -f1)
echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN} VM TEST ISO BUILD COMPLETE${NC}"
echo -e "${GREEN}=========================================${NC}"
echo "Output:   $OUTPUT_ISO"
echo "Size:     $SIZE"
echo "Packages: $PKG_COUNT debs in /macpro-pkgs/"
echo "Config:   VM test autoinstall (Ethernet + non-fatal WiFi)"
echo ""
echo "Next steps:"
echo "  cd vm-test && ./create-vm.sh"
echo "  ./test-vm.sh"