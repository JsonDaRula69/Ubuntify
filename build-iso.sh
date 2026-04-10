#!/bin/bash
set -e
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly BASE_ISO="/Users/djtchill/Desktop/Mac/prereqs/ubuntu-24.04.4-live-server-amd64.iso"
readonly AUTOINSTALL="${SCRIPT_DIR}/autoinstall.yaml"
readonly PKGS_DIR="${SCRIPT_DIR}/packages"
readonly OUTPUT_ISO="${SCRIPT_DIR}/ubuntu-macpro.iso"
readonly STAGING="/tmp/macpro-iso-staging"

echo "========================================="
echo " Mac Pro 2013 Ubuntu ISO Builder"
echo " Minimal modification approach"
echo "========================================="
echo ""

[ -f "$BASE_ISO" ] || { echo "ERROR: Base ISO not found: $BASE_ISO"; exit 1; }
[ -f "$AUTOINSTALL" ] || { echo "ERROR: autoinstall.yaml not found: $AUTOINSTALL"; exit 1; }
[ -d "$PKGS_DIR" ] || { echo "ERROR: packages/ directory not found: $PKGS_DIR"; exit 1; }

PKG_COUNT=$(ls "$PKGS_DIR"/*.deb 2>/dev/null | wc -l | tr -d ' ')
echo "Packages to include: $PKG_COUNT"
[ "$PKG_COUNT" -gt 0 ] || { echo "ERROR: No .deb files in packages/"; exit 1; }

echo ""
echo "[1/3] Preparing staging area..."
rm -rf "$STAGING"
mkdir -p "$STAGING/macpro-pkgs"

cp "$AUTOINSTALL" "$STAGING/autoinstall.yaml"
cp "$PKGS_DIR"/*.deb "$STAGING/macpro-pkgs/"

echo ""
echo "[2/3] Building ISO with xorriso..."
xorriso -indev "$BASE_ISO" \
    -outdev "$OUTPUT_ISO" \
    -map "$STAGING/autoinstall.yaml" /autoinstall.yaml \
    -map "$STAGING/macpro-pkgs/" /macpro-pkgs/ \
    -volid "Ubuntu2404MacPro" \
    -boot_image any keep \
    -commit

echo ""
echo "[3/3] Verifying..."
xorriso -indev "$OUTPUT_ISO" \
    -ls /autoinstall.yaml \
    -ls /macpro-pkgs/ \
    -rollback 2>/dev/null | head -20

rm -rf "$STAGING"

SIZE=$(du -h "$OUTPUT_ISO" | cut -f1)
echo ""
echo "========================================="
echo " BUILD COMPLETE"
echo "========================================="
echo "Output:   $OUTPUT_ISO"
echo "Size:     $SIZE"
echo "Packages: $PKG_COUNT debs in /macpro-pkgs/"
echo "Config:   /autoinstall.yaml"
echo ""
echo "Boot parameters (set in GRUB at boot time):"
echo "  autoinstall ds=nocloud"
echo "  nomodeset amdgpu.si.modeset=0"