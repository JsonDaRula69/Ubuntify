#!/bin/bash
set -e
set -o pipefail
set -u
export PATH="/usr/local/bin:/usr/local/sbin:$PATH"

# CLI flags
DRY_RUN=0
VERBOSE=0
AGENT_MODE=0
CONFIRM_YES=0
JSON_OUTPUT=0
REMOTE_HOST=""
REMOTE_OPERATION=""

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly ESP_NAME="CIDATA"
readonly ESP_SIZE="5g"

# Library path - can be overridden for testing
readonly LIB_DIR="${LIB_DIR:-$SCRIPT_DIR/lib}"

# Source all library modules (new TUI architecture)
source "$LIB_DIR/colors.sh"
source "$LIB_DIR/logging.sh"
source "$LIB_DIR/tui.sh"
source "$LIB_DIR/dryrun.sh"
source "$LIB_DIR/retry.sh"
source "$LIB_DIR/verify.sh"
source "$LIB_DIR/rollback.sh"
source "$LIB_DIR/detect.sh"
source "$LIB_DIR/disk.sh"
source "$LIB_DIR/autoinstall.sh"
source "$LIB_DIR/bless.sh"
source "$LIB_DIR/deploy.sh"
source "$LIB_DIR/revert.sh"

# Source remote.sh if it exists (for Manage mode)
if [ -f "$LIB_DIR/remote.sh" ]; then
    source "$LIB_DIR/remote.sh"
fi

export DRY_RUN
export AGENT_MODE
export JSON_OUTPUT
export CONFIRM_YES

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

show_help() {
    echo "Usage: sudo ./prepare-deployment.sh [OPTIONS]"
    echo ""
    echo "Mac Pro 2013 Ubuntu Server Deployment Tool v0.2.10"
    echo ""
    echo "Options:"
    echo "  --dry-run             Show what would be done without making changes"
    echo "  --verbose             Enable verbose logging"
    echo "  --revert              Revert previous deployment changes"
    echo "  --help                Show this help message"
    echo ""
    echo "Agent Mode (non-interactive, for LLM agents):"
    echo "  --agent               Enable agent mode (non-interactive, JSON output)"
    echo "  --yes                 Auto-confirm all prompts (use with --agent)"
    echo "  --json                Output structured JSON (auto-set by --agent)"
    echo "  --method 1|2|3|4     Deployment method (1=ESP, 2=USB, 3=manual, 4=VM)"
    echo "  --storage 1|2         Storage layout (1=dual-boot, 2=full-disk)"
    echo "  --network 1|2         Network type (1=WiFi, 2=Ethernet)"
    echo "  --host HOST           Remote host for Manage mode (default: macpro-linux)"
    echo "  --operation OP        Manage mode operation (see README)"
    echo "  --wifi-ssid SSID      Override WiFi SSID from deploy.conf"
    echo "  --wifi-password PASS  Override WiFi password from deploy.conf"
    echo "  --webhook-host HOST   Override webhook host from deploy.conf"
    echo "  --webhook-port PORT   Override webhook port from deploy.conf"
    echo ""
    echo "Modes:"
    echo "  Deploy   - Local operations: Build ISO, deploy to ESP/USB/VM, monitor"
    echo "  Manage   - Remote SSH operations (requires lib/remote.sh)"
    echo ""
    echo "Without flags, the TUI menu will start."
    echo ""
    echo "Exit Codes:"
    echo "  0  Success"
    echo "  1  General error"
    echo "  2  Usage error (missing/invalid arguments)"
    echo "  3  Config error"
    echo "  7  Network error"
    echo "  8  Disk error"
    echo "  11 Dry-run completed (no changes made)"
    echo "  12 Agent mode: missing required parameter"
    echo "  13 Agent mode: confirmation denied"
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)           DRY_RUN=1; shift ;;
        --verbose)           VERBOSE=1; shift ;;
        --agent)             AGENT_MODE=1; JSON_OUTPUT=1; shift ;;
        --yes)               CONFIRM_YES=1; shift ;;
        --json)              JSON_OUTPUT=1; shift ;;
        --method)            DEPLOY_METHOD="$2"; shift 2 ;;
        --method=*)          DEPLOY_METHOD="${1#*=}"; shift ;;
        --storage)           STORAGE_LAYOUT="$2"; shift 2 ;;
        --storage=*)         STORAGE_LAYOUT="${1#*=}"; shift ;;
        --network)           NETWORK_TYPE="$2"; shift 2 ;;
        --network=*)         NETWORK_TYPE="${1#*=}"; shift ;;
        --host)              REMOTE_HOST="$2"; shift 2 ;;
        --host=*)            REMOTE_HOST="${1#*=}"; shift ;;
        --operation)         REMOTE_OPERATION="$2"; shift 2 ;;
        --operation=*)       REMOTE_OPERATION="${1#*=}"; shift ;;
        --wifi-ssid)         WIFI_SSID="$2"; shift 2 ;;
        --wifi-ssid=*)       WIFI_SSID="${1#*=}"; shift ;;
        --wifi-password)     WIFI_PASSWORD="$2"; shift 2 ;;
        --wifi-password=*)   WIFI_PASSWORD="${1#*=}"; shift ;;
        --webhook-host)      WEBHOOK_HOST="$2"; shift 2 ;;
        --webhook-host=*)    WEBHOOK_HOST="${1#*=}"; shift ;;
        --webhook-port)      WEBHOOK_PORT="$2"; shift 2 ;;
        --webhook-port=*)    WEBHOOK_PORT="${1#*=}"; shift ;;
        --revert)            handle_revert_flag "--revert"; exit $? ;;
        --help|-h)           show_help ;;
        *)                   echo "Unknown option: $1"; show_help ;;
    esac
done

if [ "$VERBOSE" -eq 1 ]; then
    LOG_LEVEL="$LOG_LEVEL_DEBUG"
fi

# ── Mode Selection ──

select_mode() {
    local choice
    choice=$(tui_menu "Mac Pro 2013 Ubuntu Deployment" "Select operation mode:" \
        "Deploy" "deploy" \
        "Manage" "manage" \
        "Revert Failed Deploy" "revert" \
        "Exit" "exit") || exit 0
    echo "$choice"
}

# ── Deploy Mode Sub-menus ──

deploy_menu() {
    local choice
    choice=$(tui_menu "Deploy Mode" "Select deployment operation:" \
        "Build ISO" "build_iso" \
        "Deploy" "deploy" \
        "Monitor" "monitor" \
        "Test in VM" "test_vm" \
        "Revert" "revert" \
        "Back to Main Menu" "back") || return 1
    echo "$choice"
}

menu_build_iso() {
    if [ ! -f "$SCRIPT_DIR/build-iso.sh" ]; then
        tui_msgbox "Error" "build-iso.sh not found in $SCRIPT_DIR"
        return 1
    fi

    if ! tui_confirm "Build ISO" "This will build the Ubuntu ISO with custom packages and autoinstall configuration.\n\nProceed?"; then
        return 1
    fi

    log_info "Starting ISO build process..."
    local log_path
    log_path="$(log_get_file_path)"
    "$SCRIPT_DIR/build-iso.sh" 2>&1 | tee -a "$log_path"
    local build_rc=${PIPESTATUS[0]:-$?}

    if [ "$build_rc" -ne 0 ]; then
        tui_msgbox "Build Failed" "ISO build failed (exit $build_rc).\n\nCheck log: $log_path"
    else
        tui_msgbox "Build Complete" "ISO built successfully.\n\nOutput: $SCRIPT_DIR/ubuntu-macpro.iso"
    fi
}

menu_deploy() {
    local method
    method=$(tui_menu "Select Deployment Method" "Choose how to deploy Ubuntu:" \
        "Internal partition (ESP)" "1" \
        "USB drive" "2" \
        "Full manual" "3" \
        "VM test (VirtualBox)" "4" \
        "Cancel" "cancel") || return 1

    if [ "$method" = "cancel" ]; then
        return 1
    fi

    DEPLOY_METHOD="$method"

    local storage=""
    local network=""

    if [ "$DEPLOY_METHOD" != "3" ] && [ "$DEPLOY_METHOD" != "4" ]; then
        storage=$(tui_menu "Select Storage Layout" "Choose partition scheme:" \
            "Dual-boot (preserve macOS)" "1" \
            "Full disk (replace macOS)" "2" \
            "Cancel" "cancel") || return 1
        [ "$storage" = "cancel" ] && return 1
        STORAGE_LAYOUT="$storage"

        network=$(tui_menu "Select Network Type" "Choose network configuration:" \
            "WiFi only (Broadcom BCM4360)" "1" \
            "Ethernet available" "2" \
            "Cancel" "cancel") || return 1
        [ "$network" = "cancel" ] && return 1
        NETWORK_TYPE="$network"
    fi

    local summary="Configuration summary:\n\n"
    case "$DEPLOY_METHOD" in
        1) summary+="Method: Internal partition (ESP)\n" ;;
        2) summary+="Method: USB drive\n" ;;
        3) summary+="Method: Full manual\n" ;;
        4) summary+="Method: VM test (VirtualBox)\n" ;;
    esac

    if [ "$DEPLOY_METHOD" != "3" ] && [ "$DEPLOY_METHOD" != "4" ]; then
        case "$STORAGE_LAYOUT" in
            1) summary+="Storage: Dual-boot (preserve macOS)\n" ;;
            2) summary+="Storage: Full disk (replace macOS)\n" ;;
        esac
        case "$NETWORK_TYPE" in
            1) summary+="Network: WiFi only\n" ;;
            2) summary+="Network: Ethernet available\n" ;;
        esac
    fi

    summary+="\nProceed with deployment?"

    if ! tui_confirm "Confirm Settings" "$summary"; then
        return 1
    fi

    log_info "Starting deployment with method $DEPLOY_METHOD..."

    local deploy_rc=0
    case "$DEPLOY_METHOD" in
        1)
            deploy_internal_partition || deploy_rc=$?
            ;;
        2)
            deploy_usb || deploy_rc=$?
            ;;
        3)
            deploy_manual || deploy_rc=$?
            ;;
        4)
            deploy_vm_test || deploy_rc=$?
            ;;
    esac

    if [ "$deploy_rc" -ne 0 ]; then
        tui_msgbox "Deployment Failed" "Deployment exited with error code $deploy_rc.\n\nCheck log: $(log_get_file_path)"
        return 1
    fi

    tui_msgbox "Deployment Complete" "Deployment preparation complete!\n\nLog: $(log_get_file_path)"
}

menu_monitor() {
    local monitor_dir="$SCRIPT_DIR/macpro-monitor"
    local log_file="/tmp/macpro-monitor.log"

    if [ ! -f "$monitor_dir/server.js" ]; then
        tui_msgbox "Error" "Monitor server not found at $monitor_dir/server.js"
        return 1
    fi

    local choice
    choice=$(tui_menu "Monitor" "Select monitor action:" \
        "Start monitor" "start" \
        "View logs" "logs" \
        "Stop monitor" "stop" \
        "Back" "back") || return 1

    case "$choice" in
        start)
            if [ -f "$monitor_dir/start.sh" ] && bash "$monitor_dir/start.sh" >/dev/null 2>&1; then
                tui_msgbox "Monitor Started" "Monitor is now running.\n\nDashboard: http://localhost:8080\nWebhook: http://localhost:8080/webhook"
            else
                tui_msgbox "Monitor Failed" "Failed to start monitor. Check logs."
            fi
            ;;
        logs)
            if [ -f "$monitor_dir/server.log" ]; then
                tui_tailbox "Monitor Logs" "$monitor_dir/server.log"
            else
                tui_msgbox "No Logs" "Monitor log not found"
            fi
            ;;
        stop)
            if [ -f "$monitor_dir/stop.sh" ]; then
                bash "$monitor_dir/stop.sh" >/dev/null 2>&1
                tui_msgbox "Monitor Stopped" "Monitor stopped."
            else
                tui_msgbox "Not Running" "Monitor is not running."
            fi
            ;;
    esac
}

menu_test_vm() {
    local vm_dir="$SCRIPT_DIR/vm-test"
    local choice
    choice=$(tui_menu "VM Test" "Select VM test action:" \
        "Build VM ISO" "build" \
        "Create VM" "create" \
        "Run VM" "run" \
        "SSH to VM" "ssh" \
        "Stop VM" "stop" \
        "View serial log" "serial" \
        "Back" "back") || return 1

    case "$choice" in
        build)
            if [ -f "$vm_dir/build-iso-vm.sh" ]; then
                log_info "Building VM ISO..."
                "$vm_dir/build-iso-vm.sh" 2>&1 | tee -a "$(log_get_file_path)" | tui_progress "Building VM ISO"
                tui_msgbox "Build Complete" "VM ISO built."
            else
                tui_msgbox "Error" "build-iso-vm.sh not found"
            fi
            ;;
        create)
            if [ -f "$vm_dir/create-vm.sh" ]; then
                log_info "Creating VM..."
                "$vm_dir/create-vm.sh"
                tui_msgbox "VM Created" "VirtualBox VM created.\n\nUse 'Run VM' to start."
            else
                tui_msgbox "Error" "create-vm.sh not found"
            fi
            ;;
        run)
            if [ -f "$vm_dir/test-vm.sh" ]; then
                log_info "Starting VM..."
                "$vm_dir/test-vm.sh" run
            else
                tui_msgbox "Error" "test-vm.sh not found"
            fi
            ;;
        ssh)
            if [ -f "$vm_dir/test-vm.sh" ]; then
                "$vm_dir/test-vm.sh" ssh
            else
                tui_msgbox "Error" "test-vm.sh not found"
            fi
            ;;
        stop)
            if [ -f "$vm_dir/test-vm.sh" ]; then
                "$vm_dir/test-vm.sh" stop
                tui_msgbox "VM Stopped" "VM has been powered off."
            else
                tui_msgbox "Error" "test-vm.sh not found"
            fi
            ;;
        serial)
            if [ -f /tmp/vmtest-serial.log ]; then
                tui_tailbox "Serial Log" "/tmp/vmtest-serial.log"
            else
                tui_msgbox "No Serial Log" "Serial log not found at /tmp/vmtest-serial.log"
            fi
            ;;
    esac
}

menu_revert() {
    local revert_msg="This will revert all deployment changes:
- Remove ESP partition if created
- Restore APFS container size if resized
- Restore macOS boot device"

    if command -v journal_read >/dev/null 2>&1; then
        journal_read
        if [ -n "${JOURNAL_PHASE:-}" ]; then
            revert_msg="${revert_msg}

Last incomplete phase: ${JOURNAL_PHASE}
Deploy method: ${JOURNAL_DEPLOY_METHOD:-unknown}"
        fi
    fi

    if ! tui_confirm "Revert Deployment" "${revert_msg}

Proceed?"; then
        return 1
    fi

    log_info "Reverting deployment changes..."
    if command -v rollback_from_journal >/dev/null 2>&1; then
        rollback_from_journal
    else
        revert_changes
    fi

    if command -v show_recovery_instructions >/dev/null 2>&1; then
        show_recovery_instructions
    fi

    if command -v journal_destroy >/dev/null 2>&1; then
        journal_destroy
    fi

    tui_msgbox "Revert Complete" "Deployment changes have been reverted."
}

run_deploy_mode() {
    while true; do
        local choice
        choice=$(deploy_menu) || break

        case "$choice" in
            build_iso)   menu_build_iso ;;
            deploy)      menu_deploy ;;
            monitor)     menu_monitor ;;
            test_vm)     menu_test_vm ;;
            revert)      menu_revert ;;
            back)        break ;;
        esac
    done
}

# ── Manage Mode Sub-menus ──

manage_menu() {
    local choice
    choice=$(tui_menu "Manage Mode" "Select management operation:" \
        "System Info" "sysinfo" \
        "Kernel Management" "kernel" \
        "WiFi/Driver" "wifi" \
        "Storage" "storage" \
        "APT Sources" "apt" \
        "Reboot" "reboot" \
        "Back to Main Menu" "back") || return 1
    echo "$choice"
}

menu_system_info() {
    if command -v remote_get_info >/dev/null 2>&1 && \
       command -v remote_health_check >/dev/null 2>&1; then
        log_info "Retrieving system information..."
        local info
        info=$(remote_get_info)
        local health
        health=$(remote_health_check)
        tui_msgbox "System Information" "${info}\n\n---\n\nHealth Check:\n${health}"
    else
        tui_msgbox "Not Implemented" "Remote management functions not available.\n\nEnsure lib/remote.sh exists and provides:\n- remote_get_info\n- remote_health_check"
    fi
}

menu_kernel() {
    local choice
    choice=$(tui_menu "Kernel Management" "Select kernel operation:" \
        "Status" "status" \
        "Pin kernel" "pin" \
        "Unpin kernel" "unpin" \
        "Update kernel" "update" \
        "Security updates only" "security" \
        "Back" "back") || return 1

    case "$choice" in
        status)
            if command -v remote_kernel_status >/dev/null 2>&1; then
                local status
                status=$(remote_kernel_status)
                tui_msgbox "Kernel Status" "$status"
            else
                tui_msgbox "Not Implemented" "remote_kernel_status not available"
            fi
            ;;
        pin)
            if command -v remote_kernel_repin >/dev/null 2>&1; then
                if tui_confirm "Pin Kernel" "This will pin the current kernel.\n\nProceed?"; then
                    remote_kernel_repin
                    tui_msgbox "Kernel Pinned" "Kernel has been pinned."
                fi
            else
                tui_msgbox "Not Implemented" "remote_kernel_repin not available"
            fi
            ;;
        unpin)
            if command -v remote_kernel_unpin >/dev/null 2>&1; then
                if tui_confirm "Unpin Kernel" "This will unpin the kernel.\n\nProceed?"; then
                    remote_kernel_unpin
                    tui_msgbox "Kernel Unpinned" "Kernel has been unpinned."
                fi
            else
                tui_msgbox "Not Implemented" "remote_kernel_unpin not available"
            fi
            ;;
        update)
            if tui_confirm "Update Kernel" "This will run the full kernel update process per How-to-Update.md.\n\nThis is a complex operation with potential to brick the system if WiFi breaks.\n\nProceed?"; then
                if command -v remote_kernel_update >/dev/null 2>&1; then
                    remote_kernel_update
                else
                    tui_msgbox "Not Implemented" "remote_kernel_update not available.\n\nSee How-to-Update.md for manual steps."
                fi
            fi
            ;;
        security)
            if tui_confirm "Security Updates" "This will apply security updates excluding kernel packages.\n\nProceed?"; then
                if command -v remote_non_kernel_update >/dev/null 2>&1; then
                    remote_non_kernel_update
                    tui_msgbox "Updates Complete" "Security updates have been applied."
                else
                    tui_msgbox "Not Implemented" "remote_non_kernel_update not available"
                fi
            fi
            ;;
    esac
}

menu_wifi() {
    local choice
    choice=$(tui_menu "WiFi/Driver" "Select WiFi operation:" \
        "Status" "status" \
        "Rebuild driver" "rebuild" \
        "Back" "back") || return 1

    case "$choice" in
        status)
            if command -v remote_driver_status >/dev/null 2>&1; then
                local status
                status=$(remote_driver_status)
                tui_msgbox "WiFi/Driver Status" "$status"
            else
                tui_msgbox "Not Implemented" "remote_driver_status not available"
            fi
            ;;
        rebuild)
            if tui_confirm "Rebuild Driver" "This will rebuild the Broadcom WiFi driver via DKMS.\n\nProceed?"; then
                if command -v remote_driver_rebuild >/dev/null 2>&1; then
                    remote_driver_rebuild
                    tui_msgbox "Driver Rebuilt" "WiFi driver has been rebuilt."
                else
                    tui_msgbox "Not Implemented" "remote_driver_rebuild not available"
                fi
            fi
            ;;
    esac
}

menu_storage() {
    local choice
    choice=$(tui_menu "Storage" "Select storage operation:" \
        "Disk usage" "usage" \
        "Erase macOS and expand" "erase" \
        "Back" "back") || return 1

    case "$choice" in
        usage)
            if command -v remote_get_info >/dev/null 2>&1; then
                local usage
                usage=$(remote_get_info)
                tui_msgbox "Disk Usage" "$usage"
            else
                tui_msgbox "Not Implemented" "remote_get_info not available"
            fi
            ;;
        erase)
            if tui_confirm "ERASE macOS" "WARNING: This will DELETE all macOS partitions\nand expand Ubuntu to use the full disk.\n\nThis CANNOT be undone.\n\nProceed?"; then
                if command -v remote_erase_macos >/dev/null 2>&1; then
                    remote_erase_macos
                    tui_msgbox "macOS Erased" "macOS partitions have been removed and Ubuntu expanded."
                else
                    tui_msgbox "Not Implemented" "remote_erase_macos not available.\n\nSee Post-Install.md Operation 1 for manual steps."
                fi
            fi
            ;;
    esac
}

menu_apt() {
    local choice
    choice=$(tui_menu "APT Sources" "Select APT operation:" \
        "Enable sources" "enable" \
        "Disable sources" "disable" \
        "Back" "back") || return 1

    case "$choice" in
        enable)
            if command -v remote_apt_enable >/dev/null 2>&1; then
                remote_apt_enable
                tui_msgbox "APT Enabled" "APT sources have been enabled."
            else
                tui_msgbox "Not Implemented" "remote_apt_enable not available"
            fi
            ;;
        disable)
            if command -v remote_apt_disable >/dev/null 2>&1; then
                remote_apt_disable
                tui_msgbox "APT Disabled" "APT sources have been disabled."
            else
                tui_msgbox "Not Implemented" "remote_apt_disable not available"
            fi
            ;;
    esac
}

menu_reboot_remote() {
    if tui_confirm "Reboot" "This will reboot the remote Mac Pro.\n\nProceed?"; then
        if command -v remote_reboot >/dev/null 2>&1; then
            remote_reboot
            tui_msgbox "Reboot Initiated" "Reboot command sent to remote system."
        else
            tui_msgbox "Not Implemented" "remote_reboot not available"
        fi
    fi
}

run_manage_mode() {
    while true; do
        local choice
        choice=$(manage_menu) || break

        case "$choice" in
            sysinfo)   menu_system_info ;;
            kernel)    menu_kernel ;;
            wifi)      menu_wifi ;;
            storage)   menu_storage ;;
            apt)       menu_apt ;;
            reboot)    menu_reboot_remote ;;
            back)      break ;;
        esac
    done
}

# ── Legacy Menu Functions (for backward compatibility with lib modules) ──

select_deployment_method() {
    DEPLOY_METHOD=$(tui_menu "Select Deployment Method" "Choose how to deploy:" \
        "Internal partition (ESP)" "1" \
        "USB drive" "2" \
        "Full manual" "3" \
        "VM test (VirtualBox)" "4")
}

select_storage_layout() {
    STORAGE_LAYOUT=$(tui_menu "Select Storage Layout" "Choose partition scheme:" \
        "Dual-boot (preserve macOS)" "1" \
        "Full disk (replace macOS)" "2")
}

select_network_type() {
    NETWORK_TYPE=$(tui_menu "Select Network Type" "Choose network configuration:" \
        "WiFi only (Broadcom BCM4360)" "1" \
        "Ethernet available" "2")
}

confirm_settings() {
    local summary="Configuration summary:\n\n"
    case "$DEPLOY_METHOD" in
        1) summary+="Method: Internal partition (ESP)\n" ;;
        2) summary+="Method: USB drive\n" ;;
        3) summary+="Method: Full manual\n" ;;
        4) summary+="Method: VM test (VirtualBox)\n" ;;
    esac

    if [ "$DEPLOY_METHOD" != "3" ] && [ "$DEPLOY_METHOD" != "4" ]; then
        case "$STORAGE_LAYOUT" in
            1) summary+="Storage: Dual-boot (preserve macOS)\n" ;;
            2) summary+="Storage: Full disk (replace macOS)\n" ;;
        esac
        case "$NETWORK_TYPE" in
            1) summary+="Network: WiFi only\n" ;;
            2) summary+="Network: Ethernet available\n" ;;
        esac
    fi

    summary+="\nProceed with deployment?"

    if ! tui_confirm "Confirm Settings" "$summary"; then
        exit 0
    fi
}

# ── Agent Mode ──

# Maps --operation names to remote.sh functions
_AGENT_OPERATIONS="sysinfo kernel_status kernel_pin kernel_unpin kernel_update "
_AGENT_OPERATIONS="${AGENT_OPERATIONS}security_update driver_status driver_rebuild "
_AGENT_OPERATIONS="${AGENT_OPERATIONS}disk_usage erase_macos apt_enable apt_disable reboot boot_macos"

_validate_agent_deploy() {
    [ -z "${DEPLOY_METHOD:-}" ] && agent_error "Missing --method (1=ESP, 2=USB, 3=manual, 4=VM)" "$E_AGENT_PARAM"
    if [ "$DEPLOY_METHOD" != "3" ] && [ "$DEPLOY_METHOD" != "4" ]; then
        [ -z "${STORAGE_LAYOUT:-}" ] && agent_error "Missing --storage (1=dual-boot, 2=full-disk)" "$E_AGENT_PARAM"
        [ -z "${NETWORK_TYPE:-}" ] && agent_error "Missing --network (1=WiFi, 2=Ethernet)" "$E_AGENT_PARAM"
    fi
    case "$DEPLOY_METHOD" in
        1|2|3|4) ;;
        *) agent_error "Invalid --method: $DEPLOY_METHOD (must be 1-4)" "$E_USAGE" ;;
    esac
    if [ -n "${STORAGE_LAYOUT:-}" ]; then
        case "$STORAGE_LAYOUT" in
            1|2) ;;
            *) agent_error "Invalid --storage: $STORAGE_LAYOUT (must be 1 or 2)" "$E_USAGE" ;;
        esac
    fi
    if [ -n "${NETWORK_TYPE:-}" ]; then
        case "$NETWORK_TYPE" in
            1|2) ;;
            *) agent_error "Invalid --network: $NETWORK_TYPE (must be 1 or 2)" "$E_USAGE" ;;
        esac
    fi
}

_agent_deploy() {
    _validate_agent_deploy
    agent_output "settings" "Deploy Configuration" "" \
        "method" "$DEPLOY_METHOD" \
        "storage" "${STORAGE_LAYOUT:-N/A}" \
        "network" "${NETWORK_TYPE:-N/A}" \
        "wifiSsid" "${WIFI_SSID:-}" \
        "dryRun" "${DRY_RUN:-0}"

    local deploy_rc=0
    case "$DEPLOY_METHOD" in
        1) deploy_internal_partition || deploy_rc=$? ;;
        2) deploy_usb || deploy_rc=$? ;;
        3) deploy_manual || deploy_rc=$? ;;
        4) deploy_vm_test || deploy_rc=$? ;;
    esac

    if [ "$deploy_rc" -eq 0 ]; then
        agent_output "result" "Deploy" "success" "exitCode" "0"
        return 0
    else
        agent_output "result" "Deploy" "failed" "exitCode" "$deploy_rc"
        return "$deploy_rc"
    fi
}

_agent_manage() {
    local op="${REMOTE_OPERATION:-}"
    [ -z "$op" ] && agent_error "Missing --operation for manage mode. Available: $_AGENT_OPERATIONS" "$E_AGENT_PARAM"

    local host="${REMOTE_HOST:-macpro-linux}"

    case "$op" in
        sysinfo)         remote_get_info "$host" ;;
        kernel_status)   remote_kernel_status "$host" ;;
        kernel_pin)      remote_kernel_repin "$host" ;;
        kernel_unpin)    remote_kernel_unpin "$host" ;;
        kernel_update)   remote_kernel_update "$host" ;;
        security_update) remote_non_kernel_update "$host" ;;
        driver_status)   remote_driver_status "$host" ;;
        driver_rebuild)  remote_driver_rebuild "$host" ;;
        disk_usage)      remote_get_info "$host" ;;
        erase_macos)     remote_erase_macos "$host" ;;
        apt_enable)      remote_apt_enable "$host" ;;
        apt_disable)     remote_apt_disable "$host" ;;
        reboot)          remote_reboot "$host" ;;
        boot_macos)      remote_boot_macos "$host" ;;
        *) agent_error "Unknown operation: $op. Available: $_AGENT_OPERATIONS" "$E_USAGE" ;;
    esac
}

_agent_build_iso() {
    if [ ! -f "$SCRIPT_DIR/build-iso.sh" ]; then
        agent_error "build-iso.sh not found in $SCRIPT_DIR" "$E_CONFIG"
    fi
    agent_output "progress" "Build ISO" "starting"
    "$SCRIPT_DIR/build-iso.sh"
    local rc=$?
    agent_output "result" "Build ISO" "$([ "$rc" -eq 0 ] && echo success || echo failed)" "exitCode" "$rc"
    return "$rc"
}

_agent_revert() {
    agent_output "progress" "Revert" "starting"
    if command -v rollback_from_journal >/dev/null 2>&1; then
        rollback_from_journal
    else
        revert_changes
    fi
    agent_output "result" "Revert" "complete"
}

run_agent_mode() {
    log_info "Agent mode activated (JSON=$JSON_OUTPUT, YES=$CONFIRM_YES)"

    # Determine what to do from CLI flags
    if [ -n "${REMOTE_OPERATION:-}" ]; then
        # Manage mode
        _agent_manage
    elif [ -n "${DEPLOY_METHOD:-}" ]; then
        # Deploy mode
        _agent_deploy
    elif [ "${DRY_RUN:-0}" -eq 1 ] && [ -z "${DEPLOY_METHOD:-}" ]; then
        # Dry-run without method — run full deploy dry-run
        DEPLOY_METHOD="${DEPLOY_METHOD:-1}"
        STORAGE_LAYOUT="${STORAGE_LAYOUT:-1}"
        NETWORK_TYPE="${NETWORK_TYPE:-1}"
        agent_output "settings" "Dry-Run Deploy (defaults)" "" \
            "method" "$DEPLOY_METHOD" \
            "storage" "$STORAGE_LAYOUT" \
            "network" "$NETWORK_TYPE"
        _agent_deploy
    else
        # No operation specified — output available operations and exit
        agent_output "error" "No Operation" \
            "Specify --method for deploy, --operation for manage, or --revert" \
            "availableDeployMethods" "1,2,3,4" \
            "availableManageOperations" "$_AGENT_OPERATIONS"
        return "$E_AGENT_PARAM"
    fi
}

# ── Main Entry Point ──

main() {
    # Initialize logging
    log_init

    # Set up error handling traps
    if ! command -v cleanup_on_error >/dev/null 2>&1; then
        cleanup_on_error() { true; }
    fi
    trap 'cleanup_on_error' EXIT
    trap 'cleanup_on_error; exit 130' SIGINT
    trap 'cleanup_on_error; exit 143' SIGTERM

    log_info "Mac Pro 2013 Ubuntu Deployment Tool v0.2.10 starting..."
    log_info "Log file: $(log_get_file_path)"
    log_info "TUI backend: $TUI_BACKEND"

    if [ "${AGENT_MODE:-0}" -eq 1 ]; then
        run_agent_mode
        local agent_rc=$?
        log_shutdown
        exit "$agent_rc"
    fi

    while true; do
        local mode
        mode=$(select_mode)

        case "$mode" in
            deploy)
                run_deploy_mode
                ;;
            manage)
                run_manage_mode
                ;;
            revert)
                if command -v handle_revert_flag >/dev/null 2>&1; then
                    handle_revert_flag "--revert"
                else
                    error "Revert module not loaded"
                fi
                ;;
            exit)
                log_info "Exiting..."
                break
                ;;
        esac
    done

    log_shutdown
}

main "$@"
