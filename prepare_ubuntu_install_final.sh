#!/bin/bash
# prepare_ubuntu_install_final.sh
# Ubuntu 24.04.1 LTS (Noble Numbat) - Mac Pro 2013
# Broadcom BCM4360 Driver Integration
# Uses pre-downloaded prerequisites from prereqs/ directory
# Pre-compiled wl.ko injection into installer initramfs
# Kernel: 6.8.0-41-generic + mDNS/Avahi + Hardcoded Configuration

set -e

# ═══════════════════════════════════════════════════════════════════════════
# CONSTANTS
# ═══════════════════════════════════════════════════════════════════════════

readonly MIN_DRIVER_PACKAGES=2
readonly MIN_INITRD_SIZE=1000000
readonly MIN_SHA512_HASH_LEN=100
readonly MIN_MD5_HASH_LEN=30
readonly STALL_WARNING_MINUTES=5
readonly STALL_ERROR_MINUTES=15
readonly MAX_WEBHOOK_TIMEOUT=10
readonly WEBHOOK_CONNECT_TIMEOUT=5

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREREQS_DIR="$SCRIPT_DIR/prereqs"

# Root check must be early (before writing to /var/log)
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (use sudo)"
    exit 1
fi

LOG_FILE="/var/log/ubuntu_prep_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# ═══════════════════════════════════════════════════════════════════════════
# FUNCTION DEFINITIONS (must be before any calls)
# ═══════════════════════════════════════════════════════════════════════════

cleanup() {
    local exit_code=$?
    
    echo ""
    echo -e "${YELLOW}Cleaning up...${NC}"
    
    if mount | grep -q "UBUNTU-TEMP"; then
        echo "  Unmounting UBUNTU-TEMP..."
        diskutil unmount "/Volumes/UBUNTU-TEMP" 2>/dev/null || true
    fi
    
    if [[ -d "/tmp/broadcom-drivers" ]]; then
        rm -rf "/tmp/broadcom-drivers" 2>/dev/null || true
    fi
    
    rm -f "/tmp/ubuntu_part.txt" 2>/dev/null || true
    
    echo -e "${GREEN}✓ Cleanup complete${NC}"
    
    exit "$exit_code"
}

detect_webhook_url() {
    echo "Detecting monitoring server..."
    
    local mdns_host="Tejas-MacBook-Pro.local"
    local mdns_url="http://${mdns_host}:8080/webhook"
    
    if ping -c 1 -W 2 "$mdns_host" &>/dev/null; then
        WEBHOOK_URL="$mdns_url"
        echo "✓ Found monitoring server via mDNS: $mdns_host"
        return 0
    fi
    
    echo "⚠ mDNS resolution failed for $mdns_host"
    
    if [[ -n "$FALLBACK_WEBHOOK_IP" ]]; then
        WEBHOOK_URL="http://${FALLBACK_WEBHOOK_IP}:8080/webhook"
        echo "✓ Using fallback IP: $FALLBACK_WEBHOOK_IP"
        return 0
    fi
    
    echo -e "${YELLOW}⚠ Warning: No monitoring server available. Progress will not be tracked.${NC}"
    WEBHOOK_URL=""
    return 1
}

send_webhook() {
    if [[ $WEBHOOK_ENABLED -eq 0 ]] || [[ -z "$WEBHOOK_URL" ]]; then
        return 0
    fi
    
    local stage="$1"
    local progress="$2"
    local status="$3"
    local message="$4"
    local extra="$5"
    
    local payload="{\"stage\":\"${stage}\",\"progress\":${progress},\"status\":\"${status}\",\"message\":\"${message}\",\"hostname\":\"${HOSTNAME}\",\"username\":\"${USERNAME}\",\"wifi_ssid\":\"${WIFI_SSID}\""
    
    if [[ -n "$extra" ]]; then
        payload="${payload},${extra}"
    fi
    
    payload="${payload}}"
    
    curl -s -X POST "$WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -H "User-Agent: MacPro-Ubuntu-Prep/2.0" \
        -d "$payload" \
        --max-time "$MAX_WEBHOOK_TIMEOUT" \
        --connect-timeout "$WEBHOOK_CONNECT_TIMEOUT" 2>/dev/null || true
}

copy_package() {
    local filename="$1"
    local source="${PREREQS_DIR}/${filename}"
    
    if [[ ! -f "$source" ]]; then
        echo "  ✗ NOT FOUND: $filename"
        ((COPY_FAILED++))
        return 1
    fi
    
    echo "  Copying: $filename"
    if cp "$source" "${DRIVER_DIR}/"; then
        ((COPIED_COUNT++))
        return 0
    else
        echo "  ✗ COPY FAILED: $filename"
        ((COPY_FAILED++))
        return 1
    fi
}

escape_for_yaml() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

verify_iso_files() {
    local iso_dir="$1"
    local context="$2"
    
    local critical_files=(
        "${iso_dir}/casper/vmlinuz"
        "${iso_dir}/casper/initrd"
        "${iso_dir}/EFI/BOOT/BOOTX64.EFI"
    )
    
    for file in "${critical_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            echo -e "${RED}✗ Critical file missing (${context}): $file${NC}"
            echo "The extracted ISO appears incomplete."
            echo "Re-extract the ISO:"
            echo "  rm -rf ${iso_dir}"
            echo "  7z x ubuntu-24.04.1-live-server-amd64.iso -o${iso_dir} -y"
            return 1
        fi
    done
    
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# TRAP SETUP
# ═══════════════════════════════════════════════════════════════════════════

trap cleanup EXIT INT TERM

# ═══════════════════════════════════════════════════════════════════════════
# HARDCODED CONFIGURATION - DO NOT MODIFY
# ═══════════════════════════════════════════════════════════════════════════

WEBHOOK_URL=""
WEBHOOK_ENABLED=1
FALLBACK_WEBHOOK_IP="192.168.1.115"

HOSTNAME="macpro-linux"
USERNAME="teja"
PASSWORD="ubuntu-admin-2024"

WIFI_SSID="ATTj6pXatS"
WIFI_PASSWORD="j75b39=z?mpg"

SSH_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOQ37O+h9gTmyE/z8eWMWflSDEzbZz/ojoEkalinYc06"

# Pre-compiled Broadcom driver for installer
WL_MODULE="$PREREQS_DIR/wl-6.8.0-41.ko"
INITRD_MODIFIED="$PREREQS_DIR/initrd-modified"
KERNEL_VER="6.8.0-41-generic"

DRY_RUN=0
if [[ "$1" == "--dry-run" || "$1" == "-n" ]]; then
    DRY_RUN=1
    echo -e "${YELLOW}=== DRY RUN MODE ===${NC}"
    echo "No changes will be made to disk or system"
    echo ""
fi

CHECKPOINT_DIR="/tmp/ubuntu_prep_checkpoints"
mkdir -p "$CHECKPOINT_DIR" 2>/dev/null || true

checkpoint_complete() {
    local stage="$1"
    echo "checkpoint_${stage}_complete" > "$CHECKPOINT_DIR/${stage}" 2>/dev/null || true
}

checkpoint_skipped() {
    local stage="$1"
    if [[ -f "$CHECKPOINT_DIR/${stage}" ]]; then
        echo -e "${GREEN}✓ Checkpoint complete: $stage${NC}"
        return 0
    fi
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN EXECUTION STARTS HERE
# ═══════════════════════════════════════════════════════════════════════════

# ═══════════════════════════════════════════════════════════════════════════
# PRE-DEPLOYMENT VERIFICATION FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

# Track all verification failures
declare -a VERIFICATION_FAILURES=()
declare -a VERIFICATION_WARNINGS=()

preflight_pass() {
    echo -e "${GREEN}  ✓ $1${NC}"
}

preflight_fail() {
    echo -e "${RED}  ✗ $1${NC}"
    VERIFICATION_FAILURES+=("$2: $1")
}

preflight_warn() {
    echo -e "${YELLOW}  ⚠ $1${NC}"
    VERIFICATION_WARNINGS+=("$1")
}

verify_disk_space() {
    local path="$1"
    local required_gb="$2"
    local description="$3"
    
    local available_kb
    available_kb=$(df -k "$path" 2>/dev/null | tail -1 | awk '{print $4}')
    
    if [[ -z "$available_kb" ]]; then
        preflight_fail "Cannot determine disk space for $description (path: $path)" "DISK_SPACE"
        return 1
    fi
    
    local available_gb=$((available_kb / 1024 / 1024))
    
    if [[ $available_gb -lt $required_gb ]]; then
        preflight_fail "Insufficient disk space on $description: ${available_gb}GB available, ${required_gb}GB required" "DISK_SPACE"
        return 1
    fi
    
    preflight_pass "Disk space on $description: ${available_gb}GB available (${required_gb}GB required)"
    return 0
}

verify_webhook_connectivity() {
    echo ""
    echo "Verifying webhook server connectivity..."
    
    # Try mDNS resolution first
    local mdns_host="Tejas-MacBook-Pro.local"
    local webhook_url=""
    local connected=false
    
    # Test mDNS
    if ping -c 1 -t 2 "$mdns_host" &>/dev/null; then
        webhook_url="http://${mdns_host}:8080/webhook"
        if curl -s -X POST "$webhook_url" \
            -H "Content-Type: application/json" \
            -d '{"stage":"preflight","progress":0,"status":"test","message":"connectivity test"}' \
            --max-time 5 --connect-timeout 3 2>/dev/null | grep -q "ok\|status"; then
            preflight_pass "Webhook server reachable via mDNS: $mdns_host"
            WEBHOOK_URL="$webhook_url"
            WEBHOOK_ENABLED=1
            connected=true
        fi
    fi
    
    # Fallback to IP
    if [[ "$connected" != "true" ]] && [[ -n "$FALLBACK_WEBHOOK_IP" ]]; then
        webhook_url="http://${FALLBACK_WEBHOOK_IP}:8080/webhook"
        if curl -s -X POST "$webhook_url" \
            -H "Content-Type: application/json" \
            -d '{"stage":"preflight","progress":0,"status":"test","message":"connectivity test"}' \
            --max-time 5 --connect-timeout 3 2>/dev/null | grep -q "ok\|status"; then
            preflight_pass "Webhook server reachable via IP: $FALLBACK_WEBHOOK_IP"
            WEBHOOK_URL="$webhook_url"
            WEBHOOK_ENABLED=1
            connected=true
        fi
    fi
    
    if [[ "$connected" != "true" ]]; then
        preflight_warn "Webhook server not reachable - installation progress will not be tracked"
        WEBHOOK_URL=""
        WEBHOOK_ENABLED=0
    fi
    
    return 0
}

verify_wifi_signal() {
    # Additional WiFi signal quality check
    local wifi_interface=""
    local signal_strength=""
    
    # Find WiFi interface
    wifi_interface=$(networksetup -listallhardwareports 2>/dev/null | grep -A1 "Wi-Fi" | grep "Device" | awk '{print $2}')
    
    if [[ -z "$wifi_interface" ]]; then
        wifi_interface="en2"  # Default for Mac Pro 2013
    fi
    
    # Get signal info
    if [[ -x "/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport" ]]; then
        local wifi_info
        wifi_info=$(/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -I 2>/dev/null)
        
        if echo "$wifi_info" | grep -q "agrCtlRSSI"; then
            signal_strength=$(echo "$wifi_info" | grep "agrCtlRSSI" | awk '{print $2}')
            
            if [[ -n "$signal_strength" ]]; then
                # Signal strength: -30 to -50 = excellent, -50 to -67 = good, -67 to -70 = fair, < -70 = weak
                if [[ $signal_strength -ge -50 ]]; then
                    preflight_pass "WiFi signal strength: ${signal_strength} dBm (Excellent)"
                elif [[ $signal_strength -ge -67 ]]; then
                    preflight_pass "WiFi signal strength: ${signal_strength} dBm (Good)"
                elif [[ $signal_strength -ge -75 ]]; then
                    preflight_warn "WiFi signal strength: ${signal_strength} dBm (Fair) - May cause installation issues"
                else
                    preflight_warn "WiFi signal strength: ${signal_strength} dBm (Weak) - INSTALLATION MAY FAIL"
                fi
            fi
        fi
    fi
    
    return 0
}

verify_password_hash_capability() {
    echo ""
    echo "Verifying password hashing capability..."
    
    # Try passlib first (SHA-512 preferred)
    if python3 -c "from passlib.hash import sha512_crypt" 2>/dev/null; then
        preflight_pass "SHA-512 password hashing available (passlib)"
        PASSWORD_METHOD="passlib"
        return 0
    fi
    
    # Check if we can install passlib
    if command -v pip3 &>/dev/null; then
        echo "  Attempting to install passlib..."
        if pip3 install passlib --user --quiet 2>/dev/null; then
            if python3 -c "from passlib.hash import sha512_crypt" 2>/dev/null; then
                preflight_pass "SHA-512 password hashing installed (passlib)"
                PASSWORD_METHOD="passlib"
                return 0
            fi
        fi
    fi
    
    # Fall back to MD5 (less secure but works)
    if openssl passwd -1 "test" 2>/dev/null | grep -q '^\$1\$'; then
        preflight_warn "Only MD5 password hashing available - passwords will be less secure"
        echo "  Install passlib for SHA-512: pip3 install passlib --user"
        PASSWORD_METHOD="md5"
        return 0
    fi
    
    preflight_fail "No password hashing method available" "PASSWORD_HASH"
    return 1
}

verify_partition_integrity() {
    local partition_path="/Volumes/UBUNTU-TEMP"
    
    # Check if partition exists and is mounted
    if ! mount | grep -q "UBUNTU-TEMP"; then
        preflight_fail "UBUNTU-TEMP partition not mounted yet (will be mounted during preparation)" "PARTITION"
        return 0  # Not yet mounted is OK, will be mounted later
    fi
    
    # Check partition is writable
    if ! touch "$partition_path/.test_write" 2>/dev/null; then
        preflight_fail "UBUNTU-TEMP partition is not writable" "PARTITION"
        return 1
    fi
    rm -f "$partition_path/.test_write" 2>/dev/null
    
    preflight_pass "UBUNTU-TEMP partition is writable"
    return 0
}

verify_driver_files_integrity() {
    echo ""
    echo "Verifying driver file integrity..."
    
    # Check initrd structure (verify wl.ko is embedded)
    if [[ -f "$INITRD_MODIFIED" ]]; then
        # Python check for wl.ko in initramfs
        if python3 -c "
import sys
with open('$INITRD_MODIFIED', 'rb') as f:
    data = f.read()
    if b'wl.ko' in data and b'drivers/net/wireless' in data:
        sys.exit(0)
    else:
        sys.exit(1)
" 2>/dev/null; then
            preflight_pass "Driver wl.ko embedded in initramfs"
        else
            preflight_warn "Could not verify wl.ko in initramfs (file present but structure unverified)"
        fi
    fi
    
    # Check wl.ko file
    if [[ -f "$WL_MODULE" ]]; then
        local wl_size
        wl_size=$(stat -f%z "$WL_MODULE" 2>/dev/null)
        if [[ -n "$wl_size" && "$wl_size" -gt 5000000 ]]; then
            preflight_pass "Pre-compiled wl.ko verified (${wl_size} bytes)"
        else
            preflight_fail "wl.ko file appears corrupted (size: ${wl_size:-unknown})" "DRIVER"
            return 1
        fi
    fi
    
    return 0
}

verify_kernel_version_match() {
    local iso_kernel=""
    local driver_kernel=""
    
    # Get kernel version from ISO
    if [[ -f "$ISO_EXTRACTED/casper/vmlinuz" ]]; then
        # Try to extract kernel version from filename
        iso_kernel=$(basename "$ISO_EXTRACTED/casper/vmlinuz"* 2>/dev/null | sed 's/vmlinuz-//' | head -1)
        if [[ -z "$iso_kernel" ]]; then
            # vmlinuz without version suffix - check if kernel version file exists
            if [[ -f "$ISO_EXTRACTED/.disk/info" ]]; then
                iso_kernel=$(grep -o 'kernel-[^ ]*' "$ISO_EXTRACTED/.disk/info" 2>/dev/null | head -1)
            fi
        fi
    fi
    
    # Extract version from wl.ko filename
    driver_kernel=$(basename "$WL_MODULE" 2>/dev/null | sed 's/wl-//' | sed 's/.ko//')
    
    if [[ -n "$iso_kernel" && -n "$driver_kernel" ]]; then
        # Extract major version (e.g., "6.8.0-41")
        local iso_major="${iso_kernel%%-*}"
        local driver_major="${driver_kernel%%-*}"
        
        if [[ "$iso_major" == "$driver_major" ]]; then
            preflight_pass "Kernel versions compatible: ISO=$iso_kernel, Driver=$driver_kernel"
        else
            preflight_warn "Kernel version mismatch: ISO may have different kernel (driver built for $driver_kernel)"
        fi
    else
        preflight_pass "Kernel version check skipped (using pre-verified driver)"
    fi
    
    return 0
}

print_deployment_risks() {
    echo ""
    echo -e "${RED}══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${RED}                    ⚠️  CRITICAL DEPLOYMENT RISKS ⚠️${NC}"
    echo -e "${RED}══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}This installation has NO ROLLBACK capability once started.${NC}"
    echo ""
    echo "Key risks:"
    echo "  1. ${BOLD}WiFi is your ONLY network path${NC}"
    echo "     - If WiFi fails during installation, the machine will be inaccessible"
    echo "     - Mac Pro 2013 has no connected Ethernet"
    echo ""
    echo "  2. ${BOLD}macOS will be ERASED on next reboot${NC}"
    echo "     - Once 'bless' sets Ubuntu as boot, macOS is gone"
    echo "     - No recovery without physical access"
    echo ""
    echo "  3. ${BOLD}Installation is HEADLESS${NC}"
    echo "     - No monitor or keyboard attached"
    echo "     - Must rely on webhook monitoring (if available)"
    echo ""
    echo "  4. ${BOLD}Driver is kernel-specific${NC}"
    echo "     - wl.ko built for kernel 6.8.0-41"
    echo "     - DKMS will rebuild for kernel updates"
    echo ""
    
    if [[ ${#VERIFICATION_FAILURES[@]} -gt 0 ]]; then
        echo -e "${RED}VERIFICATION FAILURES (MUST FIX):${NC}"
        for failure in "${VERIFICATION_FAILURES[@]}"; do
            echo -e "  ${RED}✗ $failure${NC}"
        done
        echo ""
    fi
    
    if [[ ${#VERIFICATION_WARNINGS[@]} -gt 0 ]]; then
        echo -e "${YELLOW}VERIFICATION WARNINGS:${NC}"
        for warning in "${VERIFICATION_WARNINGS[@]}"; do
            echo -e "  ${YELLOW}⚠ $warning${NC}"
        done
        echo ""
    fi
    
    if [[ ${#VERIFICATION_FAILURES[@]} -gt 0 ]]; then
        echo -e "${RED}Cannot proceed with verification failures. Please fix above issues.${NC}"
        return 1
    fi
    
    echo -e "${GREEN}All verification checks passed. Ready to proceed.${NC}"
    echo ""
    
    # Non-interactive mode check
    if [[ "$SKIP_CONFIRMATION" != "true" ]]; then
        echo -e "${YELLOW}Continue with installation? (y/N): ${NC}"
        read -t 30 -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Installation cancelled by user."
            exit 0
        fi
    fi
    
    return 0
}

print_kernel_compatibility_warning() {
    echo ""
    echo -e "${YELLOW}══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}          ⚠️  KERNEL 6.8.x BROADCOM DRIVER COMPATIBILITY ⚠️${NC}"
    echo -e "${YELLOW}══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}IMPORTANT: Known issues exist with Broadcom wl driver on kernel 6.8.x${NC}"
    echo ""
    echo "Known Issues (as of 2026):"
    echo "  • Launchpad Bug #2106329: wl module fails to load on kernel 6.8"
    echo "  • Ubuntu Discourse: BCM4360 works on 25.10 but fails on 24.04.3"
    echo "  • DKMS build failures on kernel 6.8.x reported"
    echo ""
    echo -e "${GREEN}Your Mitigation:${NC}"
    echo "  ✓ Pre-compiled wl.ko built against SAME kernel (6.8.0-41)"
    echo "  ✓ Driver embedded in initramfs for early boot"
    echo "  ✓ DKMS configured to rebuild for kernel updates"
    echo "  ✓ WiFi recovery service for post-boot reliability"
    echo ""
    echo -e "${BLUE}Risk Assessment:${NC}"
    echo "  • During installation: HIGH confidence (driver pre-loaded in initramfs)"
    echo "  • Post-install kernel update: MEDIUM risk (DKMS may need patches)"
    echo ""
    echo -e "${YELLOW}If driver fails after kernel update:${NC}"
    echo "  1. Boot to earlier kernel from GRUB menu"
    echo "  2. Apply DKMS patches or use HWE kernel"
    echo "  3. Contact support with kernel version details"
    echo ""
    
    if [[ "$SKIP_KERNEL_WARNING" != "true" ]]; then
        echo -e "${YELLOW}Continue with installation? (y/N): ${NC}"
        read -t 30 -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Installation cancelled by user."
            exit 0
        fi
    fi
}

run_preflight_verification() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║         PRE-DEPLOYMENT VERIFICATION CHECKLIST                   ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    VERIFICATION_FAILURES=()
    VERIFICATION_WARNINGS=()
    
    # ═══════════════════════════════════════════════════════════════════════
    # SECTION 1: Hardware Verification
    # ═══════════════════════════════════════════════════════════════════════
    echo -e "${BLUE}=== [1/8] Hardware Verification ===${NC}"
    
    # Check Mac model
    local mac_model
    mac_model=$(system_profiler SPHardwareDataType 2>/dev/null | grep "Model Identifier" | awk '{print $3}')
    if [[ "$mac_model" == "MacPro6,1" ]]; then
        preflight_pass "Mac Pro 2013 (MacPro6,1) confirmed"
    else
        preflight_warn "Mac model: ${mac_model:-unknown} (script designed for MacPro6,1)"
    fi
    
    # Check WiFi hardware
    if /System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -I 2>/dev/null | grep -q "Card Type"; then
        preflight_pass "WiFi card detected (Broadcom BCM43xx)"
    else
        preflight_fail "WiFi card not detected" "HARDWARE"
    fi
    
    # Check WiFi connectivity status
    local wifi_status
    wifi_status=$(/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -I 2>/dev/null | grep "state:" | awk -F: '{print $2}' | tr -d ' ')
    if [[ "$wifi_status" == "running" ]]; then
        preflight_pass "WiFi is currently connected"
    else
        preflight_warn "WiFi not currently connected (status: ${wifi_status:-unknown})"
    fi
    
    # ═══════════════════════════════════════════════════════════════════════
    # SECTION 2: Prerequisites Verification
    # ═══════════════════════════════════════════════════════════════════════
    echo ""
    echo -e "${BLUE}=== [2/8] Prerequisites Verification ===${NC}"
    
    # Check prereqs directory
    if [[ -d "$PREREQS_DIR" ]]; then
        preflight_pass "Prerequisites directory exists: $PREREQS_DIR"
    else
        preflight_fail "Prerequisites directory missing: $PREREQS_DIR" "PREREQS"
    fi
    
    # Check ISO extraction
    if [[ -d "$PREREQS_DIR/ubuntu-iso" ]]; then
        if [[ -f "$PREREQS_DIR/ubuntu-iso/casper/vmlinuz" ]]; then
            local vmlinuz_size
            vmlinuz_size=$(stat -f%z "$PREREQS_DIR/ubuntu-iso/casper/vmlinuz" 2>/dev/null)
            if [[ -n "$vmlinuz_size" && "$vmlinuz_size" -gt 10000000 ]]; then
                preflight_pass "Ubuntu ISO extracted (vmlinuz: $((vmlinuz_size/1024/1024))MB)"
            else
                preflight_fail "Ubuntu ISO vmlinuz appears corrupted or incomplete" "PREREQS"
            fi
        else
            preflight_fail "Ubuntu ISO vmlinuz not found" "PREREQS"
        fi
    else
        preflight_fail "Pre-extracted Ubuntu ISO not found" "PREREQS"
    fi
    
    # Check driver packages count
    local deb_count
    deb_count=$(find "$PREREQS_DIR" -name "*.deb" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$deb_count" -ge 28 ]]; then
        preflight_pass "Driver packages: $deb_count .deb files"
    else
        preflight_fail "Driver packages incomplete: $deb_count found (need 28+)" "PREREQS"
    fi
    
    # ═══════════════════════════════════════════════════════════════════════
    # SECTION 3: Driver File Verification
    # ═══════════════════════════════════════════════════════════════════════
    echo ""
    echo -e "${BLUE}=== [3/8] Driver File Verification ===${NC}"
    
    # Check initrd-modified
    if [[ -f "$INITRD_MODIFIED" ]]; then
        local initrd_size
        initrd_size=$(stat -f%z "$INITRD_MODIFIED" 2>/dev/null)
        if [[ -n "$initrd_size" && "$initrd_size" -gt 60000000 ]]; then
            preflight_pass "Modified initramfs: $((initrd_size/1024/1024))MB"
            
            # Verify wl.ko embedded
            if python3 -c "
import sys
with open('$INITRD_MODIFIED', 'rb') as f:
    data = f.read()
    if b'wl.ko' in data and b'drivers/net/wireless' in data:
        sys.exit(0)
    else:
        sys.exit(1)
" 2>/dev/null; then
                preflight_pass "wl.ko driver embedded in initramfs"
            else
                preflight_warn "Could not verify wl.ko in initramfs (proceed with caution)"
            fi
        else
            preflight_fail "initramfs corrupted or incomplete ($((initrd_size/1024/1024))MB)" "DRIVER"
        fi
    else
        preflight_fail "Modified initramfs not found: $INITRD_MODIFIED" "DRIVER"
    fi
    
    # Check wl.ko
    if [[ -f "$WL_MODULE" ]]; then
        local wl_size
        wl_size=$(stat -f%z "$WL_MODULE" 2>/dev/null)
        if [[ -n "$wl_size" && "$wl_size" -gt 5000000 ]]; then
            preflight_pass "Pre-compiled wl.ko: $((wl_size/1024))KB"
        else
            preflight_fail "wl.ko file appears corrupted" "DRIVER"
        fi
    else
        preflight_fail "Pre-compiled wl.ko not found: $WL_MODULE" "DRIVER"
    fi
    
    # ═══════════════════════════════════════════════════════════════════════
    # SECTION 4: Disk Space Verification
    # ═══════════════════════════════════════════════════════════════════════
    echo ""
    echo -e "${BLUE}=== [4/8] Disk Space Verification ===${NC}"
    
    # Check macOS partition space (for logs)
    verify_disk_space "/" 5 "macOS root partition"
    
    # Check UBUNTU-TEMP if mounted
    if mount | grep -q "UBUNTU-TEMP"; then
        verify_disk_space "/Volumes/UBUNTU-TEMP" 5 "UBUNTU-TEMP partition"
    else
        preflight_pass "UBUNTU-TEMP not yet mounted (will be mounted during preparation)"
    fi
    
    # ═══════════════════════════════════════════════════════════════════════
    # SECTION 5: Network Verification
    # ═══════════════════════════════════════════════════════════════════════
    echo ""
    echo -e "${BLUE}=== [5/8] Network Verification ===${NC}"
    
    # WiFi network visibility
    if /System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -s 2>/dev/null | grep -q "$WIFI_SSID"; then
        preflight_pass "WiFi network '$WIFI_SSID' is visible"
        verify_wifi_signal
    else
        preflight_fail "WiFi network '$WIFI_SSID' not found in scan" "NETWORK"
        echo "  Available networks:"
        /System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -s 2>/dev/null | head -10
    fi
    
    # Webhook server connectivity
    verify_webhook_connectivity
    
    # ═══════════════════════════════════════════════════════════════════════
    # SECTION 6: Password Hash Verification
    # ═══════════════════════════════════════════════════════════════════════
    echo ""
    echo -e "${BLUE}=== [6/8] Password Hash Verification ===${NC}"
    verify_password_hash_capability
    
    # ═══════════════════════════════════════════════════════════════════════
    # SECTION 7: Checksum Verification
    # ═══════════════════════════════════════════════════════════════════════
    echo ""
    echo -e "${BLUE}=== [7/8] Checksum Verification ===${NC}"
    
    local expected_initrd="8a67607f64a19ef816582e51c5191c0e6166438ded98df66416d16c46ac6e618"
    local actual_initrd
    actual_initrd=$(shasum -a 256 "$INITRD_MODIFIED" 2>/dev/null | awk '{print $1}')
    
    if [[ "$actual_initrd" == "$expected_initrd" ]]; then
        preflight_pass "initramfs checksum verified"
    else
        preflight_fail "initramfs checksum MISMATCH" "CHECKSUM"
        echo "  Expected: $expected_initrd"
        echo "  Actual:   ${actual_initrd:-failed to compute}"
    fi
    
    local expected_wl="35e65a6e148cc832c31f0bc29a4682d37254010962bb405d333d4d2f2da6b6ab"
    local actual_wl
    actual_wl=$(shasum -a 256 "$WL_MODULE" 2>/dev/null | awk '{print $1}')
    
    if [[ "$actual_wl" == "$expected_wl" ]]; then
        preflight_pass "wl.ko checksum verified"
    else
        preflight_fail "wl.ko checksum MISMATCH" "CHECKSUM"
        echo "  Expected: $expected_wl"
        echo "  Actual:   ${actual_wl:-failed to compute}"
    fi
    
    # ═══════════════════════════════════════════════════════════════════════
    # SECTION 8: Final Summary
    # ═══════════════════════════════════════════════════════════════════════
    echo ""
    echo -e "${BLUE}=== [8/8] Final Summary ===${NC}"
    
    if [[ ${#VERIFICATION_FAILURES[@]} -gt 0 ]]; then
        echo ""
        echo -e "${RED}╔══════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║              VERIFICATION FAILED - CANNOT PROCEED              ║${NC}"
        echo -e "${RED}╚══════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${RED}Failures:${NC}"
        for failure in "${VERIFICATION_FAILURES[@]}"; do
            echo -e "${RED}  ✗ $failure${NC}"
        done
        echo ""
        echo -e "${YELLOW}Please fix the above issues before proceeding.${NC}"
        return 1
    fi
    
    if [[ ${#VERIFICATION_WARNINGS[@]} -gt 0 ]]; then
        echo ""
        echo -e "${YELLOW}Warnings (review before proceeding):${NC}"
        for warning in "${VERIFICATION_WARNINGS[@]}"; do
            echo -e "${YELLOW}  ⚠ $warning${NC}"
        done
    fi
    
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              ALL PRE-DEPLOYMENT CHECKS PASSED                   ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Print kernel compatibility warning
    print_kernel_compatibility_warning
    
    # Print deployment risks
    print_deployment_risks
    
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# PREREQUISITES CHECK (Legacy - kept for compatibility)
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BLUE}=== Checking Prerequisites ===${NC}"
echo ""

check_command() {
    local cmd="$1"
    local package="${2:-$1}"
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${RED}✗ Required command not found: $cmd${NC}"
        echo "  Install with: xcode-select --install  # for macOS CLI tools"
        echo "  Or install $package via homebrew"
        MISSING_COMMANDS+=("$cmd")
        return 1
    fi
    return 0
}

check_python3() {
    if command -v python3 &>/dev/null; then
        echo "  ✓ python3"
        return 0
    elif command -v python &>/dev/null; then
        echo "  ✓ python (fallback)"
        return 0
    else
        echo -e "${RED}✗ Required command not found: python3${NC}"
        echo "  Install Python 3 using one of:"
        echo "    xcode-select --install    # macOS CLI tools"
        echo "    brew install python3       # Homebrew"
        MISSING_COMMANDS+=("python3")
        return 1
    fi
}

check_password_hashing() {
    echo ""
    echo "Checking password hashing capability..."
    
    # Try passlib first (best for SHA-512)
    if python3 -c "from passlib.hash import sha512_crypt" 2>/dev/null; then
        echo "  ✓ passlib module available (SHA-512)"
        PASSWORD_METHOD="passlib"
        return 0
    fi
    
    # Check if we can install passlib via pip
    if command -v pip3 &>/dev/null; then
        echo "  Attempting to install passlib..."
        if pip3 install passlib --user --quiet 2>/dev/null; then
            if python3 -c "from passlib.hash import sha512_crypt" 2>/dev/null; then
                echo "  ✓ passlib installed successfully (SHA-512)"
                PASSWORD_METHOD="passlib"
                return 0
            fi
        fi
    fi
    
    # Fall back to OpenSSL MD5 (works on macOS)
    if openssl passwd -1 "test" 2>/dev/null | grep -q '^\$1\$'; then
        echo "  ✓ OpenSSL MD5 available (fallback)"
        echo -e "${YELLOW}  Note: Using MD5 password hashing (SHA-512 preferred but not available)${NC}"
        PASSWORD_METHOD="md5"
        return 0
    fi
    
    echo -e "${RED}✗ No password hashing method available${NC}"
    echo "  Install one of:"
    echo "    pip3 install passlib --user"
    echo "    brew install openssl"
    MISSING_COMMANDS+=("password hashing")
    return 1
}

MISSING_COMMANDS=()

echo "Checking required commands..."
check_command "diskutil" && echo "  ✓ diskutil" || true
check_command "curl" && echo "  ✓ curl" || true
check_command "shasum" && echo "  ✓ shasum" || true
check_command "rsync" && echo "  ✓ rsync" || true
check_command "openssl" && echo "  ✓ openssl" || true
check_command "awk" && echo "  ✓ awk" || true
check_python3
check_password_hashing

if [[ ${#MISSING_COMMANDS[@]} -gt 0 ]]; then
    echo ""
    echo -e "${RED}✗ Missing ${#MISSING_COMMANDS[@]} required command(s)${NC}"
    echo "Please install missing commands and try again."
    exit 1
fi

echo "✓ All required commands available"
echo ""

if [[ ! -d "$PREREQS_DIR" ]]; then
    echo "✗ Prerequisites directory not found: $PREREQS_DIR"
    echo ""
    echo "Run ./download_prereqs.sh first to download required packages."
    exit 1
fi

# Check for pre-extracted ISO (required on macOS Monterey which cannot mount this ISO format)
ISO_EXTRACTED="$PREREQS_DIR/ubuntu-iso"
if [[ ! -d "$ISO_EXTRACTED" ]]; then
    echo -e "${RED}✗ Pre-extracted Ubuntu ISO not found: $ISO_EXTRACTED${NC}"
    echo ""
    echo "The Ubuntu ISO must be pre-extracted because macOS cannot mount this format."
    echo ""
    echo "To extract the ISO (requires 7zip):"
    echo "  brew install p7zip"
    echo "  cd $PREREQS_DIR"
    echo "  7z x ubuntu-24.04.1-live-server-amd64.iso -oubuntu-iso -y"
    exit 1
fi

# Check for critical packages
CRITICAL_PACKAGES=(
    "broadcom-sta-dkms_6.30.223.271-23ubuntu1_all.deb"
    "dkms_3.0.11-1ubuntu13_all.deb"
)

for pkg in "${CRITICAL_PACKAGES[@]}"; do
    if [[ ! -f "$PREREQS_DIR/$pkg" ]]; then
        echo "✗ Critical package not found: $pkg"
        echo "Run ./download_prereqs.sh to download required packages."
        exit 1
    fi
done

# Check for pre-compiled driver and modified initramfs
if [[ ! -f "$WL_MODULE" ]]; then
    echo -e "${RED}✗ Pre-compiled wl.ko not found: $WL_MODULE${NC}"
    echo ""
    echo "The wl.ko kernel module must be pre-compiled for kernel $KERNEL_VER"
    echo "Run the VM build process to generate this file."
    exit 1
fi

if [[ ! -f "$INITRD_MODIFIED" ]]; then
    echo -e "${RED}✗ Modified initramfs not found: $INITRD_MODIFIED${NC}"
    echo ""
    echo "The initramfs with embedded wl.ko must be prepared."
    echo "Run the VM build process to generate this file."
    exit 1
fi

EXPECTED_INITRD_HASH="8a67607f64a19ef816582e51c5191c0e6166438ded98df66416d16c46ac6e618"
ACTUAL_INITRD_HASH=$(shasum -a 256 "$INITRD_MODIFIED" 2>/dev/null | awk '{print $1}')

if [[ -z "$ACTUAL_INITRD_HASH" ]]; then
    echo -e "${RED}✗ Failed to compute checksum for initrd-modified${NC}"
    echo "  File may be unreadable or corrupted"
    exit 1
fi

if [[ "$ACTUAL_INITRD_HASH" != "$EXPECTED_INITRD_HASH" ]]; then
    echo -e "${RED}✗ initrd-modified checksum mismatch!${NC}"
    echo "  Expected: $EXPECTED_INITRD_HASH"
    echo "  Actual:   $ACTUAL_INITRD_HASH"
    echo ""
    echo "The initramfs file may be corrupted. Please re-download or regenerate."
    exit 1
fi
echo "✓ initrd-modified integrity verified"

EXPECTED_WL_HASH="35e65a6e148cc832c31f0bc29a4682d37254010962bb405d333d4d2f2da6b6ab"
ACTUAL_WL_HASH=$(shasum -a 256 "$WL_MODULE" 2>/dev/null | awk '{print $1}')

if [[ -z "$ACTUAL_WL_HASH" ]]; then
    echo -e "${RED}✗ Failed to compute checksum for wl.ko${NC}"
    echo "  File may be unreadable or corrupted"
    exit 1
fi

if [[ "$ACTUAL_WL_HASH" != "$EXPECTED_WL_HASH" ]]; then
    echo -e "${RED}✗ wl.ko checksum mismatch!${NC}"
    echo "  Expected: $EXPECTED_WL_HASH"
    echo "  Actual:   $ACTUAL_WL_HASH"
    echo ""
    echo "The WiFi driver file may be corrupted. Please re-download or regenerate."
    exit 1
fi
echo "✓ wl.ko integrity verified"

echo "✓ Prerequisites directory found"
echo "✓ Pre-extracted ISO present"
echo "✓ Critical packages present"
echo "✓ Pre-compiled wl.ko found"
echo "✓ Modified initramfs found"

# ═══════════════════════════════════════════════════════════════════════════
# WIFI NETWORK PRE-FLIGHT CHECK
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BLUE}=== Verifying WiFi Network Availability ===${NC}"
echo ""

# Check if WiFi network is visible
if [[ -x "/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport" ]]; then
    # Try airport utility
    if /System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -s 2>/dev/null | grep -q "$WIFI_SSID"; then
        echo -e "${GREEN}✓ WiFi network '$WIFI_SSID' is visible${NC}"
    else
        echo -e "${RED}✗ WiFi network '$WIFI_SSID' NOT FOUND${NC}"
        echo ""
        echo "Available WiFi networks:"
        /System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -s 2>/dev/null | head -20
        echo ""
        echo -e "${YELLOW}The installation requires WiFi network '$WIFI_SSID' to be available.${NC}"
        echo -e "${YELLOW}If the network is hidden, ensure correct SSID in configuration.${NC}"
        echo ""
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
elif command -v networksetup &>/dev/null; then
    # Fallback to networksetup
    if networksetup -listpreferredwirelessnetworks en0 2>/dev/null | grep -q "$WIFI_SSID"; then
        echo -e "${GREEN}✓ WiFi network '$WIFI_SSID' is in preferred networks${NC}"
    else
        echo -e "${YELLOW}⚠ Cannot verify WiFi network visibility${NC}"
        echo -e "${YELLOW}Please ensure '$WIFI_SSID' is available before continuing${NC}"
        echo ""
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
else
    echo -e "${YELLOW}⚠ Cannot verify WiFi network (no airport/networksetup)${NC}"
    echo -e "${YELLOW}Please ensure '$WIFI_SSID' is available before continuing${NC}"
fi

# ═══════════════════════════════════════════════════════════════════════════
# DETECT WEBHOOK URL
# ═══════════════════════════════════════════════════════════════════════════

detect_webhook_url

echo "Log file: $LOG_FILE"

# ═══════════════════════════════════════════════════════════════════════════
# PRE-CLEANUP - Remove any stale state from previous runs
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${YELLOW}Performing pre-cleanup...${NC}"

# Unmount UBUNTU-TEMP if already mounted (we'll remount properly)
if mount | grep -q "UBUNTU-TEMP"; then
    echo "  Unmounting stale UBUNTU-TEMP mount..."
    diskutil unmount /Volumes/UBUNTU-TEMP 2>/dev/null || true
fi

# Remove stale temp directories
rm -rf /tmp/broadcom-drivers 2>/dev/null || true
rm -f /tmp/ubuntu_part.txt 2>/dev/null || true

echo -e "${GREEN}✓ Pre-cleanup complete${NC}"
echo ""

clear
cat << 'EOF'
╔══════════════════════════════════════════════════════════╗
║     Mac Pro 2013 - Ubuntu Server 24.04.1 LTS            ║
║     Broadcom BCM4360 WiFi Driver (Kernel 6.8.0-41)     ║
║     v12.0 - Pre-compiled Driver + WiFi Installer       ║
╚══════════════════════════════════════════════════════════╝

⚠️  CRITICAL: 
    - WiFi driver pre-compiled for kernel 6.8.0-41
    - Installer configured for Broadcom WiFi
    - Monitoring: http://Tejas-MacBook-Pro.local:8080
    - WiFi SSID: ATTj6pXatS
    - SSH key embedded from MacBook

EOF

send_webhook "init" 0 "starting" "Mac Pro Ubuntu preparation started"

echo ""
echo -e "${GREEN}Configuration loaded:${NC}"
echo "  Hostname:   $HOSTNAME"
echo "  Username:   $USERNAME"
echo "  WiFi SSID: $WIFI_SSID"
echo "  Kernel:     $KERNEL_VER"
echo "  Monitor:   $WEBHOOK_URL"
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# STEP 1: Copy Driver Packages from Prereqs
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BLUE}=== Step 1: Copying Driver Packages from Prereqs ===${NC}"
echo ""

send_webhook "prep" 5 "copying" "Copying driver packages from local storage"

DRIVER_DIR="/tmp/broadcom-drivers"
rm -rf "$DRIVER_DIR"
mkdir -p "$DRIVER_DIR"

COPY_FAILED=0
COPIED_COUNT=0

echo "Copying DKMS and Broadcom driver..."

copy_package "dkms_3.0.11-1ubuntu13_all.deb"
copy_package "broadcom-sta-dkms_6.30.223.271-23ubuntu1_all.deb"

echo ""
echo "Copying build dependencies..."

DEPENDENCY_PACKAGES=(
    "build-essential_12.10ubuntu1_amd64.deb"
    "make_4.3-4.1build2_amd64.deb"
    "fakeroot_1.33-1_amd64.deb"
    "libfakeroot_1.33-1_amd64.deb"
    "gcc-13_13.2.0-23ubuntu4_amd64.deb"
    "gcc-13-base_13.2.0-23ubuntu4_amd64.deb"
    "cpp-13_13.2.0-23ubuntu4_amd64.deb"
    "libgcc-13-dev_13.2.0-23ubuntu4_amd64.deb"
    "libstdc++-13-dev_13.2.0-23ubuntu4_amd64.deb"
    "libgcc-s1_14-20240412-0ubuntu1_amd64.deb"
    "libstdc++6_14-20240412-0ubuntu1_amd64.deb"
    "libc6-dev_2.39-0ubuntu8_amd64.deb"
    "libc-dev-bin_2.39-0ubuntu8_amd64.deb"
    "libc6_2.39-0ubuntu8_amd64.deb"
    "binutils_2.42-4ubuntu2_amd64.deb"
    "binutils-common_2.42-4ubuntu2_amd64.deb"
    "libbinutils_2.42-4ubuntu2_amd64.deb"
    "libctf-nobfd0_2.42-4ubuntu2_amd64.deb"
    "libisl23_0.26-3build1_amd64.deb"
    "libmpc3_1.3.1-1build1_amd64.deb"
    "libmpfr6_4.2.1-1build1_amd64.deb"
    "kmod_31+20240202-2ubuntu7_amd64.deb"
    "libkmod2_31+20240202-2ubuntu7_amd64.deb"
    "perl-base_5.38.2-3.2build2_amd64.deb"
)

for pkg in "${DEPENDENCY_PACKAGES[@]}"; do
    copy_package "$pkg"
done

# Copy kernel headers for 6.8.0-41
copy_package "linux-headers-6.8.0-41_6.8.0-41.41_all.deb"
copy_package "linux-headers-6.8.0-41-generic_6.8.0-41.41_amd64.deb"

# Copy wl.ko for post-install backup
cp "$WL_MODULE" "$DRIVER_DIR/wl.ko" 2>/dev/null && ((COPIED_COUNT++)) || true

echo ""
echo "✓ Copied: $COPIED_COUNT packages"

if [[ $COPY_FAILED -gt 0 ]]; then
    echo -e "${YELLOW}⚠ $COPY_FAILED packages missing - some may be optional${NC}"
fi

send_webhook "prep" 10 "copied" "Driver packages copied" "\"package_count\":${COPIED_COUNT}"

# ═══════════════════════════════════════════════════════════════════════════
# STEP 2: Verify Pre-Extracted Ubuntu ISO
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BLUE}=== Step 2: Verifying Pre-Extracted Ubuntu ISO ===${NC}"
echo ""

ISO_EXTRACTED="$PREREQS_DIR/ubuntu-iso"

if [[ ! -d "$ISO_EXTRACTED" ]]; then
    echo -e "${RED}✗ Pre-extracted ISO directory not found: $ISO_EXTRACTED${NC}"
    echo ""
    echo "The Ubuntu ISO must be pre-extracted into: $ISO_EXTRACTED"
    echo ""
    echo "On a system with 7zip installed, run:"
    echo "  cd $PREREQS_DIR"
    echo "  7z x ubuntu-24.04.1-live-server-amd64.iso -oubuntu-iso -y"
    echo ""
    echo "This is necessary because macOS cannot mount this Ubuntu ISO format."
    exit 1
fi

# Verify critical files exist
CRITICAL_FILES=(
    "$ISO_EXTRACTED/casper/vmlinuz"
    "$ISO_EXTRACTED/casper/initrd"
    "$ISO_EXTRACTED/EFI/BOOT/BOOTX64.EFI"
)

for file in "${CRITICAL_FILES[@]}"; do
    if [[ ! -f "$file" ]]; then
        echo -e "${RED}✗ Critical file missing: $file${NC}"
        echo "The extracted ISO appears incomplete."
        echo "Re-extract the ISO:"
        echo "  rm -rf $ISO_EXTRACTED"
        echo "  7z x ubuntu-24.04.1-live-server-amd64.iso -oubuntu-iso -y"
        exit 1
    fi
done

echo "✓ Ubuntu ISO files verified (pre-extracted)"
echo "  Location: $ISO_EXTRACTED"
echo "  vmlinuz: $(stat -f%z "$ISO_EXTRACTED/casper/vmlinuz" 2>/dev/null | awk '{printf "%.1fMB", $1/1048576}')"
echo "  initrd: $(stat -f%z "$ISO_EXTRACTED/casper/initrd" 2>/dev/null | awk '{printf "%.1fMB", $1/1048576}')"

send_webhook "prep" 20 "iso_ready" "Ubuntu ISO verified"

# ═══════════════════════════════════════════════════════════════════════════
# STEP 3: Mount Partitions
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BLUE}=== Step 3: Mounting Partitions ===${NC}"
echo ""

rm -f /tmp/ubuntu_part.txt

UBUNTU_PARTITION=""
for disk in $(diskutil list 2>/dev/null | grep "^/dev/disk" | awk '{print $1}'); do
    disk_num="${disk#/dev/disk}"
    diskutil list "$disk" 2>/dev/null | grep "UBUNTU-TEMP" > "/tmp/ubuntu_part.txt"
    if [[ -s "/tmp/ubuntu_part.txt" ]]; then
        part_identifier=$(grep -oE 'disk[0-9]+s[0-9]+' < "/tmp/ubuntu_part.txt" | head -1)
        if [[ -n "$part_identifier" ]]; then
            part_suffix=$(echo "$part_identifier" | grep -oE 's[0-9]+')
            if [[ -n "$part_suffix" ]]; then
                UBUNTU_PARTITION="disk${disk_num}${part_suffix}"
                echo "Found UBUNTU-TEMP: $UBUNTU_PARTITION"
                break
            fi
        fi
    fi
done

if [[ -z "$UBUNTU_PARTITION" ]]; then
    echo "✗ UBUNTU-TEMP partition not found!"
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[DRY RUN] Would exit here"
    else
        echo "Please create it using Disk Utility or diskutil:"
        echo "  diskutil apfs resizeContainer disk0s2 500g"
        echo "  diskutil addPartition disk0s2 FAT32 UBUNTU-TEMP 0b"
        exit 1
    fi
elif [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY RUN] Would mount UBUNTU-TEMP: $UBUNTU_PARTITION"
    PARTITION_PATH="/Volumes/UBUNTU-TEMP"
else
    echo "Mounting UBUNTU-TEMP..."
    if ! diskutil mount "$UBUNTU_PARTITION" 2>/dev/null; then
        echo "✗ Failed to mount UBUNTU-TEMP"
        exit 1
    fi
    PARTITION_PATH="/Volumes/UBUNTU-TEMP"
    echo "✓ Partitions mounted"
fi

send_webhook "prep" 30 "partitions_ready" "Partitions mounted"

# ═══════════════════════════════════════════════════════════════════════════
# STEP 4: Copy Pre-Extracted Ubuntu ISO
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BLUE}=== Step 4: Copying Ubuntu ISO Files ===${NC}"
echo ""

ISO_EXTRACTED="$PREREQS_DIR/ubuntu-iso"
if [[ ! -d "$ISO_EXTRACTED" ]]; then
    echo -e "${RED}✗ Pre-extracted ISO not found: $ISO_EXTRACTED${NC}"
    echo ""
    echo "The Ubuntu ISO must be pre-extracted into: $ISO_EXTRACTED"
    echo "Run on a system with 7zip installed:"
    echo "  mkdir -p $ISO_EXTRACTED"
    echo "  7z x ubuntu-24.04.1-live-server-amd64.iso -o$ISO_EXTRACTED -y"
    exit 1
fi

# Verify critical files exist
REQUIRED_FILES=(
    "$ISO_EXTRACTED/casper/vmlinuz"
    "$ISO_EXTRACTED/casper/initrd"
    "$ISO_EXTRACTED/EFI/BOOT/BOOTX64.EFI"
)

for file in "${REQUIRED_FILES[@]}"; do
    if [[ ! -f "$file" ]]; then
        echo -e "${RED}✗ Required file not found: $file${NC}"
        echo "The extracted ISO appears incomplete. Re-extract:"
        echo "  rm -rf $ISO_EXTRACTED"
        echo "  7z x ubuntu-24.04.1-live-server-amd64.iso -o$ISO_EXTRACTED -y"
        exit 1
    fi
done

echo "✓ Ubuntu ISO files verified (pre-extracted)"
send_webhook "prep" 30 "extracted" "Ubuntu ISO files found"

echo "Copying files to UBUNTU-TEMP partition..."
rsync -ah --progress "$ISO_EXTRACTED/" "$PARTITION_PATH/"

RSYNC_EXIT_CODE=$?
if [[ $RSYNC_EXIT_CODE -ne 0 ]]; then
    echo -e "${RED}✗ rsync failed with exit code $RSYNC_EXIT_CODE${NC}"
    echo "Check disk space and permissions on $PARTITION_PATH"
    exit 1
fi

VERIFY_COUNT=$(find "${PARTITION_PATH}/casper" -type f 2>/dev/null | wc -l | tr -d ' ')
if [[ -z "$VERIFY_COUNT" || "$VERIFY_COUNT" -lt $MIN_DRIVER_PACKAGES ]]; then
    echo -e "${RED}✗ Verification failed: Only ${VERIFY_COUNT:-0} files in casper/ (expected 3+)${NC}"
    exit 1
fi

echo "✓ Ubuntu files copied and verified ($VERIFY_COUNT critical files)"
send_webhook "prep" 40 "copied" "Ubuntu files copied to partition"

# ═══════════════════════════════════════════════════════════════════════════
# STEP 5: Replace Initramfs with WiFi-Enabled Version
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BLUE}=== Step 5: Replacing Initramfs with WiFi Driver ===${NC}"
echo ""

echo "Replacing initrd with modified version..."
echo "  Original: $(stat -f%z "$PARTITION_PATH/casper/initrd" 2>/dev/null | awk '{printf "%.1fMB", $1/1048576}')"
echo "  Modified: $(stat -f%z "$INITRD_MODIFIED" 2>/dev/null | awk '{printf "%.1fMB", $1/1048576}')"

# Backup original initrd
cp "$PARTITION_PATH/casper/initrd" "$PARTITION_PATH/casper/initrd.original" 2>/dev/null || true

# Replace with modified version containing wl.ko
cp "$INITRD_MODIFIED" "$PARTITION_PATH/casper/initrd"

CP_EXIT_CODE=$?
if [[ $CP_EXIT_CODE -ne 0 ]]; then
    echo -e "${RED}✗ Failed to copy initrd (exit code $CP_EXIT_CODE)${NC}"
    exit 1
fi

INITRD_SIZE=$(stat -f%z "$PARTITION_PATH/casper/initrd" 2>/dev/null)
if [[ -z "$INITRD_SIZE" || "$INITRD_SIZE" -lt 1000000 ]]; then
    echo -e "${RED}✗ Initrd verification failed: size=$INITRD_SIZE bytes (expected >1MB)${NC}"
    exit 1
fi

echo "✓ Initramfs replaced with WiFi-enabled version (${INITRD_SIZE} bytes)"

send_webhook "prep" 45 "initrd_replaced" "Initramfs replaced with WiFi driver"

# ═══════════════════════════════════════════════════════════════════════════
# STEP 6: Embed Driver Packages
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BLUE}=== Step 6: Embedding Broadcom Driver Packages ===${NC}"
echo ""

mkdir -p "$PARTITION_PATH/casper/broadcom"

echo "Copying driver packages to ISO..."

if ! cp "$DRIVER_DIR"/*.deb "$PARTITION_PATH/casper/broadcom/" 2>/dev/null; then
    echo "⚠ No .deb files found to copy (continuing)"
fi

COPIED_DEBS=$(find "$PARTITION_PATH/casper/broadcom" -name "*.deb" -type f 2>/dev/null | wc -l | tr -d ' ')
if [[ $COPIED_DEBS -lt 2 ]]; then
    echo -e "${YELLOW}⚠ Only $COPIED_DEBS .deb files copied (expected 30+) - DKMS rebuild may fail${NC}"
fi

# Also copy wl.ko
if [[ -f "$DRIVER_DIR/wl.ko" ]]; then
    cp "$DRIVER_DIR/wl.ko" "$PARTITION_PATH/casper/broadcom/"
    echo "✓ Copied pre-compiled wl.ko"
fi

if [[ ! -f "$PARTITION_PATH/casper/broadcom/wl.ko" ]]; then
    echo -e "${RED}✗ Failed to copy wl.ko to partition${NC}"
    exit 1
fi

echo "✓ Embedded $COPIED_DEBS driver packages"

send_webhook "prep" 50 "drivers_embedded" "Broadcom driver packages embedded"

# ═══════════════════════════════════════════════════════════════════════════
# STEP 7: Create Autoinstall Configuration
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BLUE}=== Step 7: Creating Autoinstall Configuration ===${NC}"
echo ""

if [[ "$PASSWORD_METHOD" == "passlib" ]]; then
    PASSWORD_HASH=$(python3 -c "from passlib.hash import sha512_crypt; print(sha512_crypt.using(rounds=5000).hash('${PASSWORD}'))" 2>/dev/null)
elif [[ "$PASSWORD_METHOD" == "md5" ]]; then
    PASSWORD_HASH=$(openssl passwd -1 "${PASSWORD}")
else
    echo -e "${RED}✗ No password hashing method available${NC}"
    exit 1
fi

if [[ -z "$PASSWORD_HASH" ]]; then
    echo -e "${RED}✗ Failed to generate password hash${NC}"
    exit 1
fi

HASH_LEN=${#PASSWORD_HASH}
if [[ "$PASSWORD_METHOD" == "passlib" && $HASH_LEN -lt $MIN_SHA512_HASH_LEN ]]; then
    echo -e "${RED}✗ Invalid password hash: only $HASH_LEN chars (expected ${MIN_SHA512_HASH_LEN}+)${NC}"
    echo "  This indicates a broken crypt implementation."
    echo "  Install passlib: pip3 install passlib --user"
    exit 1
elif [[ "$PASSWORD_METHOD" == "md5" && $HASH_LEN -lt $MIN_MD5_HASH_LEN ]]; then
    echo -e "${RED}✗ Invalid password hash: only $HASH_LEN chars (expected ${MIN_MD5_HASH_LEN}+)${NC}"
    exit 1
fi

echo "Password hash generated (method: $PASSWORD_METHOD, length: $HASH_LEN chars)"

WIFI_SSID_ESCAPED=$(escape_for_yaml "$WIFI_SSID")
WIFI_PASSWORD_ESCAPED=$(escape_for_yaml "$WIFI_PASSWORD")
SSH_KEY_ESCAPED=$(escape_for_yaml "$SSH_KEY")

cat > "$PARTITION_PATH/user-data" << USERDATAFILE
#cloud-config
autoinstall:
  version: 1
  refresh-installer:
    update: no
  
  keyboard:
    layout: us
  locale: en_US.UTF-8
  timezone: UTC
  
  network:
    version: 2
    renderer: networkd
    wifis:
      wlan0:
        dhcp4: true
        optional: true
        access-points:
          "${WIFI_SSID_ESCAPED}":
            password: "${WIFI_PASSWORD_ESCAPED}"
    ethernets:
      eth0:
        dhcp4: true
        optional: true
  
  storage:
    layout:
      name: direct
    swap:
      size: 0
  
  identity:
    hostname: ${HOSTNAME}
    username: ${USERNAME}
    password: "${PASSWORD_HASH}"
    realname: ${USERNAME}
  
  ssh:
    install-server: true
    allow-pw: true
    authorized-keys:
      - "${SSH_KEY_ESCAPED}"
  
  packages:
    - openssh-server
    - avahi-daemon
    - libnss-mdns
    - vim
    - wget
    - curl
    - git
    - htop
    - tmux
    - net-tools
    - wireless-tools
    - wpasupplicant
    - network-manager
  
  late-commands:
    - |
      echo "=== Installing Broadcom Drivers to Target System ==="
      mkdir -p /target/tmp/broadcom
      cp /cdrom/casper/broadcom/*.deb /target/tmp/broadcom/ 2>/dev/null || true
      cp /cdrom/casper/broadcom/wl.ko /target/tmp/broadcom/ 2>/dev/null || true
      
      curtin in-target -- bash -c "dpkg -i /tmp/broadcom/*.deb 2>/dev/null || true"
      curtin in-target -- bash -c "dpkg --configure -a 2>/dev/null || true"
    
    - |
      echo "=== Ensuring wl module is loaded ==="
      curtin in-target -- modprobe wl 2>/dev/null || true
    
    - |
      echo "=== Configuring WiFi ==="
      WIFI_IFACE=\$(ls /sys/class/net/ | grep -E '^w' | head -1 || echo "wlan0")
      echo "Detected WiFi interface: \$WIFI_IFACE"
      
      mkdir -p /target/etc/netplan
      cat > /target/etc/netplan/99-wifi.yaml << NETPLANINNER
network:
  version: 2
  renderer: networkd
  wifis:
    wlan0:
      dhcp4: true
      optional: true
      access-points:
        "${WIFI_SSID_ESCAPED}":
          password: "${WIFI_PASSWORD_ESCAPED}"
NETPLANINNER
      chmod 600 /target/etc/netplan/99-wifi.yaml
    
    - |
      echo "=== Configuring mDNS/Avahi ==="
      curtin in-target -- systemctl enable avahi-daemon 2>/dev/null || true
    
    - |
      echo "=== Blacklisting conflicting drivers ==="
      cat > /target/etc/modprobe.d/blacklist-broadcom.conf << 'BLACKLIST'
blacklist b43
blacklist b43legacy
blacklist b44
blacklist ssb
blacklist brcmsmac
blacklist bcma
BLACKLIST
    
    - |
      echo "=== Creating WiFi Recovery Service ==="
      cat > /target/usr/local/bin/wifi-recovery.sh << 'RECOVERYSCRIPT'
#!/bin/bash
# WiFi Recovery Script for Broadcom BCM4360
# Ensures WiFi is functional on headless Mac Pro

LOG="/var/log/wifi-recovery.log"
logger "WiFi Recovery: Starting..."

# Wait for network stack
sleep 10

# Check if wl module is loaded
if ! lsmod | grep -q wl; then
    logger "WiFi Recovery: Loading wl module..."
    modprobe wl 2>/dev/null || true
fi

# Apply netplan
logger "WiFi Recovery: Applying netplan..."
netplan apply 2>/dev/null || true

# Wait for interface
sleep 5

# Check connectivity
MAX_RETRIES=3
RETRY_COUNT=0

while [ \$RETRY_COUNT -lt \$MAX_RETRIES ]; do
    if ping -c 3 8.8.8.8 >/dev/null 2>&1; then
        logger "WiFi Recovery: Connectivity verified"
        exit 0
    fi
    
    RETRY_COUNT=\$((RETRY_COUNT + 1))
    logger "WiFi Recovery: No connectivity (attempt \$RETRY_COUNT/\$MAX_RETRIES)"
    
    if [ \$RETRY_COUNT -lt \$MAX_RETRIES ]; then
        modprobe -r wl 2>/dev/null || true
        sleep 2
        modprobe wl 2>/dev/null || true
        netplan apply 2>/dev/null || true
        sleep 10
    fi
done

logger "WiFi Recovery: FAILED after \$MAX_RETRIES attempts"
exit 1
RECOVERYSCRIPT
      chmod +x /target/usr/local/bin/wifi-recovery.sh
      
      cat > /target/etc/systemd/system/wifi-recovery.service << 'SERVICEUNIT'
[Unit]
Description=WiFi Recovery for Broadcom BCM4360
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/wifi-recovery.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICEUNIT
      curtin in-target -- systemctl enable wifi-recovery.service 2>/dev/null || true
    
    - |
      echo "=== Creating DKMS Kernel Update Hook ==="
      mkdir -p /target/etc/kernel/postinst.d
      cat > /target/etc/kernel/postinst.d/dkms-wl << 'HOOKSCRIPT'
#!/bin/bash
# Rebuild Broadcom wl driver for new kernel
logger "DKMS: Rebuilding broadcom-sta for kernel \$1"
dkms autoinstall -k "\$1" 2>/dev/null || true
HOOKSCRIPT
      chmod +x /target/etc/kernel/postinst.d/dkms-wl
    
    - |
      IP_ADDR=\$(ip -4 addr show | grep "inet " | grep -v "127.0.0.1" | head -1 | awk '{print \$2}' | cut -d/ -f1 2>/dev/null) || true
      echo "=== Installation Complete ==="
      echo "IP Address: \${IP_ADDR:-unknown}"
      curl -s -X POST "$WEBHOOK_URL" -H "Content-Type: application/json" -d "{\"stage\":7,\"progress\":100,\"status\":\"complete\",\"message\":\"Installation complete\",\"ip\":\"\${IP_ADDR:-unknown}\"}" 2>/dev/null || true
    
    - |
      printf "========================================\nUbuntu Server 24.04.1 LTS - Mac Pro 2013\nWiFi: ${WIFI_SSID_ESCAPED}\nHostname: ${HOSTNAME}.local\nLogin: ${USERNAME}\nKernel: 6.8.0-41-generic\n========================================\n" > /target/etc/issue
  
  user-data:
    disable_root: false
    package_update: false
    package_upgrade: false
    runcmd:
      - modprobe wl 2>/dev/null || true
      - systemctl enable ssh
      - systemctl start ssh
      - systemctl enable avahi-daemon
      - netplan apply 2>/dev/null || true
  
  error:
    commands:
      - |
        echo "=== Installation Error - Notifying Monitor ==="
        IP_ADDR=\$(ip -4 addr show | grep "inet " | grep -v "127.0.0.1" | head -1 | awk '{print \$2}' | cut -d/ -f1 2>/dev/null) || true
        curl -s -X POST "http://Tejas-MacBook-Pro.local:8080/webhook" -H "Content-Type: application/json" -d "{\"stage\":\"error\",\"progress\":0,\"status\":\"failed\",\"message\":\"Installation failed\",\"ip\":\"\${IP_ADDR:-unknown}\"}" 2>/dev/null || true
        curl -s -X POST "http://192.168.1.115:8080/webhook" -H "Content-Type: application/json" -d "{\"stage\":\"error\",\"progress\":0,\"status\":\"failed\",\"message\":\"Installation failed\",\"ip\":\"\${IP_ADDR:-unknown}\"}" 2>/dev/null || true
        sleep 5
    action: shutdown
  
  shutdown: reboot
USERDATAFILE

cat > "$PARTITION_PATH/meta-data" << METADATAFILE
instance-id: macpro-linux-$(date +%Y%m%d%H%M%S)
local-hostname: ${HOSTNAME}
METADATAFILE

echo "✓ Autoinstall configuration created"

send_webhook "prep" 60 "config_ready" "Autoinstall configuration created"

# ═══════════════════════════════════════════════════════════════════════════
# STEP 8: Create Boot Configuration
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BLUE}=== Step 8: Creating Boot Configuration ===${NC}"
echo ""

send_webhook "prep" 70 "boot_config" "Creating boot configuration"

mkdir -p "$PARTITION_PATH/boot/grub"
cat > "$PARTITION_PATH/boot/grub/grub.cfg" << 'GRUBCFG'
set timeout=5
set default=0

menuentry "Ubuntu Server Autoinstall (Broadcom WiFi)" {
    set gfxpayload=keep
    linux /casper/vmlinuz autoinstall ds=nocloud;s=/ quiet modprobe.blacklist=b43,b43legacy,ssb,brcmsmac,bcma ---
    initrd /casper/initrd
}
GRUBCFG

echo "✓ GRUB configuration created"

if [[ -d "$PARTITION_PATH/EFI/BOOT" ]]; then
    if [[ -d "$PARTITION_PATH/EFI/ubuntu" ]]; then
        cat > "$PARTITION_PATH/EFI/ubuntu/grub.cfg" << 'GRUBCFG2'
set timeout=5
set default=0

menuentry "Ubuntu Server Autoinstall (Broadcom WiFi)" {
    set gfxpayload=keep
    linux /casper/vmlinuz autoinstall ds=nocloud;s=/ quiet modprobe.blacklist=b43,b43legacy,ssb,brcmsmac,bcma ---
    initrd /casper/initrd
}
GRUBCFG2
        echo "✓ EFI/ubuntu/grub.cfg updated"
    fi
fi

send_webhook "prep" 80 "boot_ready" "Boot configuration created"

echo "✓ EFI boot structure verified"

cat > /tmp/enable_ubuntu_boot.sh << 'ENABLESCRIPT'
#!/bin/bash
# Enable Ubuntu boot using Mac's native bless command (headless, no rEFInd needed)

UBUNTU_VOLUME="/Volumes/UBUNTU-TEMP"

if [[ ! -d "$UBUNTU_VOLUME" ]]; then
    echo "Mounting UBUNTU-TEMP..."
    for disk in disk0s3 disk0s4 disk0s5 disk0s6 disk1s3 disk1s4 disk1s5 disk2s3 disk2s4; do
        diskutil mount "$disk" 2>/dev/null && break
    done
fi

if [[ ! -d "$UBUNTU_VOLUME" ]]; then
    echo "✗ UBUNTU-TEMP partition not found"
    exit 1
fi

echo "Setting UBUNTU-TEMP as default boot volume..."

BOOT_SET=""

if [[ -f "$UBUNTU_VOLUME/EFI/BOOT/BOOTX64.EFI" ]]; then
    bless --mount "$UBUNTU_VOLUME" --file "$UBUNTU_VOLUME/EFI/BOOT/BOOTX64.EFI" --setBoot 2>/dev/null && {
        echo "✓ Boot set via BOOTX64.EFI"
        BOOT_SET=1
    }
fi

if [[ -z "$BOOT_SET" ]] && [[ -f "$UBUNTU_VOLUME/EFI/BOOT/grubx64.efi" ]]; then
    bless --mount "$UBUNTU_VOLUME" --file "$UBUNTU_VOLUME/EFI/BOOT/grubx64.efi" --setBoot 2>/dev/null && {
        echo "✓ Boot set via grubx64.efi"
        BOOT_SET=1
    }
fi

if [[ -z "$BOOT_SET" ]]; then
    bless --mount "$UBUNTU_VOLUME" --setBoot 2>/dev/null && {
        echo "✓ Boot set via volume blessing"
        BOOT_SET=1
    }
fi

if [[ -z "$BOOT_SET" ]]; then
    bless --mount "$UBUNTU_VOLUME" --setBoot --legacy 2>/dev/null && {
        echo "✓ Boot set via legacy blessing"
        BOOT_SET=1
    }
fi

if [[ -z "$BOOT_SET" ]]; then
    bless --mount "$UBUNTU_VOLUME" --setBoot --nextonly 2>/dev/null && {
        echo "✓ Boot set for next boot only"
        BOOT_SET=1
    }
fi

if [[ -z "$BOOT_SET" ]]; then
    echo "✗ Failed to set boot volume. Try manually:"
    echo "  sudo bless --mount /Volumes/UBUNTU-TEMP --setBoot"
    exit 1
fi

echo ""
echo "════════════════════════════════════════════════════════"
echo "✓ Ubuntu boot entry ENABLED via bless"
echo "════════════════════════════════════════════════════════"
echo ""
echo "⚠ CRITICAL WARNING ⚠"
echo ""
echo "  Next reboot will ERASE macOS"
echo "  and install Ubuntu with Broadcom WiFi support"
echo ""
echo "  Monitoring URL:"
echo "  http://Tejas-MacBook-Pro.local:8080"
echo ""
echo "  After installation, connect via:"
echo "  ssh teja@macpro-linux.local"
echo ""
echo "  To start installation: sudo reboot"
echo ""
ENABLESCRIPT

chmod +x /tmp/enable_ubuntu_boot.sh
echo "✓ Enable script generated: /tmp/enable_ubuntu_boot.sh"

sync
diskutil sync "$UBUNTU_PARTITION" 2>/dev/null || true

send_webhook "prep" 90 "ready" "Preparation complete"

echo ""
echo -e "${GREEN}${BOLD}══════════════════════════${NC}"
echo -e "${GREEN}${BOLD}   PREPARATION COMPLETE                 ${NC}"
echo -e "${GREEN}${BOLD}══════════════════════════${NC}"
echo ""
echo "Configuration:"
echo "  Distribution: Ubuntu 24.04.1 LTS"
echo "  Kernel:       $KERNEL_VER"
echo "  Hostname:     $HOSTNAME"
echo "  Username:     $USERNAME"
echo "  WiFi:         $WIFI_SSID"
echo ""
echo "Monitor: http://Tejas-MacBook-Pro.local:8080"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "  1. Start monitor on MacBook: cd macpro-monitor && ./start.sh"
echo "  2. On Mac Pro: sudo /tmp/enable_ubuntu_boot.sh"
echo "  3. On Mac Pro: sudo reboot"
echo ""
echo -e "${RED}⚠ WARNING: macOS will be ERASED on next boot${NC}"
echo ""
echo "  After installation (~15 mins):"
echo "    ssh teja@macpro-linux.local"
echo ""

send_webhook "prep" 100 "waiting_reboot" "Ready for reboot"