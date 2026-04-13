#!/bin/bash
set -e
set -o pipefail
set -u
export PATH="/usr/local/bin:/usr/local/sbin:$PATH"

# CLI flags
DRY_RUN=0
VERBOSE=0

show_help() {
    echo "Usage: sudo ./prepare-deployment.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --dry-run    Show what would be done without making changes"
    echo "  --verbose    Enable verbose logging (set -x)"
    echo "  --revert     Revert previous deployment changes"
    echo "  --help       Show this help message"
    echo ""
    echo "Deployment methods (interactive menu):"
    echo "  1) Internal ESP partition  2) USB drive"
    echo "  3) Full manual            4) VM test (VirtualBox)"
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)   DRY_RUN=1; shift ;;
        --verbose)   VERBOSE=1; shift ;;
        --revert)    handle_revert_flag; exit $? ;;
        --help|-h)   show_help ;;
        *)           echo "Unknown option: $1"; show_help ;;
    esac
done

if [ "$VERBOSE" -eq 1 ]; then
    set -x
fi

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly ESP_NAME="CIDATA"
readonly ESP_SIZE="5g"
readonly LOG_FILE="/tmp/macpro-deploy-$(date +%Y%m%d_%H%M%S).log"

# Library path - can be overridden for testing
readonly LIB_DIR="${LIB_DIR:-$SCRIPT_DIR/lib}"

# Source all library modules
source "$LIB_DIR/colors.sh"
source "$LIB_DIR/utils.sh"
source "$LIB_DIR/detect.sh"
source "$LIB_DIR/disk.sh"
source "$LIB_DIR/autoinstall.sh"
source "$LIB_DIR/bless.sh"
source "$LIB_DIR/deploy.sh"
source "$LIB_DIR/revert.sh"

export DRY_RUN

CONF_FILE="${SCRIPT_DIR}/deploy.conf"
if [ ! -f "$CONF_FILE" ]; then
    warn "deploy.conf not found — using defaults from deploy.conf.example"
    CONF_FILE="${SCRIPT_DIR}/deploy.conf.example"
fi
parse_conf() {
    local conf="$1"
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        case "$key" in
            WIFI_SSID)     WIFI_SSID="$value" ;;
            WIFI_PASSWORD) WIFI_PASSWORD="$value" ;;
            WEBHOOK_HOST)  WEBHOOK_HOST="$value" ;;
            WEBHOOK_PORT)  WEBHOOK_PORT="$value" ;;
            *)             warn "Unknown config key: $key" ;;
        esac
    done < "$conf"
}
parse_conf "$CONF_FILE" || die "Failed to load $CONF_FILE"

export WIFI_SSID
export WIFI_PASSWORD
export WEBHOOK_HOST
export WEBHOOK_PORT

# Global state for cleanup (exported so lib modules can access)
export INTERNAL_DISK=""
export APFS_CONTAINER=""
export _ESP_CREATED=0
export _APFS_RESIZED=0
export _APFS_ORIGINAL_SIZE=""
export TARGET_DEVICE=""
export _CLEANUP_DONE=0

# User selections (exported for lib modules)
export DEPLOY_METHOD=""
export STORAGE_LAYOUT=""
export NETWORK_TYPE=""

# ── Menu Functions ──

select_deployment_method() {
    show_header
    echo "Select deployment method:"
    echo ""
    echo "  1) Internal partition (autoinstall from ESP)"
    echo "     - Copies Ubuntu installer to CIDATA partition on internal disk"
    echo "     - Requires: monitor or keyboard for boot selection (SIP blocks bless)"
    echo "     - Boots from internal disk, no USB needed after setup"
    echo ""
    echo "  2) USB drive (autoinstall from USB)"
    echo "     - Creates bootable USB with Ubuntu installer"
    echo "     - Requires: USB drive (4GB+), keyboard + monitor for boot selection"
    echo "     - Simpler, no internal disk modification before install"
    echo ""
    echo "  3) Full manual"
    echo "     - Creates bootable USB with standard Ubuntu ISO (no autoinstall)"
    echo "     - Requires: USB drive (4GB+), keyboard + monitor"
    echo "     - You handle all install choices manually"
    echo ""
    echo "  4) VM test (VirtualBox)"
    echo "     - Validates autoinstall flow in a VirtualBox VM on this Mac"
    echo "     - No Mac Pro hardware needed — tests DKMS compilation, driver loading"
    echo "     - Requires: VirtualBox, 4GB+ disk space"
    echo "     - Uses Ethernet (no WiFi HW in VM), single disk (no dual-boot)"
    echo ""

    while true; do
        read -rp "Enter choice [1-4]: " choice
        case "$choice" in
            1|2|3|4)
                DEPLOY_METHOD="$choice"
                break
                ;;
            *)
                echo "Invalid choice. Please enter 1, 2, 3, or 4."
                ;;
        esac
    done
}

select_storage_layout() {
    show_header
    echo "Select storage layout:"
    echo ""
    echo "  1) Dual-boot (preserve macOS)"
    echo "     - Keeps macOS partition intact"
    echo "     - Ubuntu installed in free space alongside macOS"
    echo "     - Can switch between macOS and Ubuntu via GRUB/efibootmgr"
    echo ""
    echo "  2) Full disk (replace macOS)"
    echo "     - Wipes entire disk, Ubuntu only"
    echo "     - Simpler partition layout"
    echo "     - No macOS recovery needed"
    echo ""

    while true; do
        read -rp "Enter choice [1-2]: " choice
        case "$choice" in
            1|2)
                STORAGE_LAYOUT="$choice"
                break
                ;;
            *)
                echo "Invalid choice. Please enter 1 or 2."
                ;;
        esac
    done
}

select_network_type() {
    show_header
    echo "Select network type:"
    echo ""
    echo "  1) WiFi only (Broadcom BCM4360)"
    echo "     - Must compile wl driver in early-commands before network access"
    echo "     - Requires broadcom-sta-dkms packages on installer media"
    echo "     - Slower boot (35+ second driver init)"
    echo ""
    echo "  2) Ethernet available"
    echo "     - Network works immediately via DHCP"
    echo "     - WiFi driver compiled for target system only (late-commands)"
    echo "     - Faster and more reliable during install"
    echo ""

    while true; do
        read -rp "Enter choice [1-2]: " choice
        case "$choice" in
            1|2)
                NETWORK_TYPE="$choice"
                break
                ;;
            *)
                echo "Invalid choice. Please enter 1 or 2."
                ;;
        esac
    done
}

confirm_settings() {
    show_header
    echo "Configuration summary:"
    echo ""

    case "$DEPLOY_METHOD" in
        1) echo "  Deployment method: Internal partition (ESP)" ;;
        2) echo "  Deployment method: USB drive" ;;
        3) echo "  Deployment method: Full manual" ;;
        4) echo "  Deployment method: VM test (VirtualBox)" ;;
    esac

    if [ "$DEPLOY_METHOD" != "3" ] && [ "$DEPLOY_METHOD" != "4" ]; then
        case "$STORAGE_LAYOUT" in
            1) echo "  Storage layout: Dual-boot (preserve macOS)" ;;
            2) echo "  Storage layout: Full disk (replace macOS)" ;;
        esac

        case "$NETWORK_TYPE" in
            1) echo "  Network type: WiFi only (Broadcom BCM4360)" ;;
            2) echo "  Network type: Ethernet available" ;;
        esac
    fi

    echo ""
    read -rp "Proceed with these settings? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        log "Deployment cancelled by user"
        exit 0
    fi
}

# ── Main Entry Point ──

main() {
    # Initialize log
    touch "$LOG_FILE" || LOG_FILE="/dev/null"

    # Show main menu
    show_header
    log "Deploy log: $LOG_FILE"
    echo ""

    select_deployment_method

    if [ "$DEPLOY_METHOD" != "3" ] && [ "$DEPLOY_METHOD" != "4" ]; then
        select_storage_layout
        select_network_type
    fi

    confirm_settings

    # Dispatch to appropriate deployment function
    case "$DEPLOY_METHOD" in
        1)
            deploy_internal_partition
            ;;
        2)
            deploy_usb
            ;;
        3)
            deploy_manual
            ;;
        4)
            deploy_vm_test
            ;;
        *)
            die "Unknown deployment method: $DEPLOY_METHOD"
            ;;
    esac

    log "Deployment preparation complete!"
}

# Set up error handling traps
trap cleanup_on_error EXIT
trap 'cleanup_on_error; exit 130' SIGINT
trap 'cleanup_on_error; exit 143' SIGTERM

main "$@"
