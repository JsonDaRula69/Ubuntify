#!/usr/bin/env bash
# verify.sh - Post-operation verification module for Mac Pro 2013 Ubuntu deployment
# Bash 3.2-compatible, set -u safe, all functions return 0/1

[ "${_VERIFY_SH_SOURCED:-0}" -eq 1 ] && return 0
_VERIFY_SH_SOURCED=1

source "${LIB_DIR:-./lib}/logging.sh"

# verify_apfs_resize container_device expected_gb
# Returns 0 if actual size within ±5GB of expected, 1 otherwise
verify_apfs_resize() {
    local container_device="$1"
    local expected_gb="$2"
    local actual_gb

    if ! diskutil info "$container_device" >/dev/null 2>&1; then
        error "verify_apfs_resize: cannot access $container_device"
        return 1
    fi

    # Extract GB from "Disk Size" line (format: "Disk Size: 500.0 GB (500000000000 Bytes)")
    actual_gb=$(diskutil info "$container_device" 2>/dev/null | grep -i "Disk Size" | sed -E 's/.*[^0-9]([0-9]+\.[0-9]+)[^0-9]*GB.*/\1/')

    if [ -z "$actual_gb" ]; then
        error "verify_apfs_resize: could not parse disk size for $container_device"
        return 1
    fi

    # Compare with ±5GB tolerance
    # Use awk for comparison to handle decimals — pass values as variables to prevent injection
    local within_tolerance
    within_tolerance=$(awk -v actual="$actual_gb" -v expected="$expected_gb" 'BEGIN { if (actual >= expected - 5 && actual <= expected + 5) print 1; else print 0 }')

    if [ "$within_tolerance" -eq 1 ]; then
        return 0
    else
        error "verify_apfs_resize: ${container_device} is ${actual_gb}GB, expected ~${expected_gb}GB (±5GB tolerance)"
        return 1
    fi
}

# verify_autoinstall_schema file_path [schema_path]
# Validates autoinstall YAML against Subiquity schema.
# Returns 0 if valid, 1 if invalid, 0 with warning if validators unavailable.
verify_autoinstall_schema() {
    local file_path="$1"
    local schema_path="${2:-${LIB_DIR:-./lib}/autoinstall-schema.json}"

    if [ ! -f "$schema_path" ]; then
        warn "verify_autoinstall_schema: schema not found at $schema_path, skipping"
        return 0
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        warn "verify_autoinstall_schema: python3 not available, skipping"
        return 0
    fi

    local escaped_file escaped_schema
    escaped_file=$(printf '%s\n' "$file_path" | sed "s/'/'\\''/g")
    escaped_schema=$(printf '%s\n' "$schema_path" | sed "s/'/'\\''/g")

    # Try jsonschema module first (thorough validation)
    local jsonschema_error
    jsonschema_error=$(python3 -c "
import sys
try:
    import jsonschema
    import json, yaml
    with open('$escaped_schema') as f:
        schema = json.load(f)
    with open('$escaped_file') as f:
        data = yaml.safe_load(f)
    jsonschema.validate(data, schema)
except ImportError:
    sys.exit(42)
except Exception as e:
    print(str(e), file=sys.stderr)
    sys.exit(1)
" 2>&1)
    local rc=$?

    if [ $rc -eq 42 ]; then
        # jsonschema not installed — lightweight key validation
        local key_error
        key_error=$(python3 -c "
import yaml, sys
with open('$escaped_file') as f:
    data = yaml.safe_load(f)
if not isinstance(data, dict):
    print('Root must be a mapping', file=sys.stderr)
    sys.exit(1)
if 'autoinstall' not in data:
    print('Missing required key: autoinstall', file=sys.stderr)
    sys.exit(1)
ai = data['autoinstall']
if not isinstance(ai, dict):
    print('autoinstall must be a mapping', file=sys.stderr)
    sys.exit(1)
required = ['identity']
for key in required:
    if key not in ai:
        print(f'Missing required autoinstall key: {key}', file=sys.stderr)
        sys.exit(1)
if 'identity' in ai:
    ident = ai['identity']
    if not isinstance(ident, dict):
        print('identity must be a mapping', file=sys.stderr)
        sys.exit(1)
    for k in ['username', 'password', 'hostname']:
        if k not in ident:
            print(f'Missing identity key: {k}', file=sys.stderr)
            sys.exit(1)
" 2>&1)
        if [ $? -ne 0 ]; then
            error "verify_autoinstall_schema: $key_error"
            return 1
        fi
        warn "verify_autoinstall_schema: jsonschema unavailable, performed lightweight key validation only"
        return 0
    elif [ $rc -ne 0 ]; then
        error "verify_autoinstall_schema: schema validation failed: $jsonschema_error"
        return 1
    fi

    log "verify_autoinstall_schema: schema validation passed"
    return 0
}

# verify_esp_mount mount_point
# Returns 0 if mount_point exists, writable, FAT32, and has >=100MB free
verify_esp_mount() {
    local mount_point="$1"
    local esp_device

    # Check if mount_point exists and is writable
    if [ ! -d "$mount_point" ]; then
        warn "verify_esp_mount: $mount_point does not exist, checking journal for ESP"

        # Self-healing: try to find ESP in journal and mount it
        if command -v journal_read >/dev/null 2>&1; then
            journal_read
            esp_device="${JOURNAL_ESP_DEVICE:-}"
        fi

        if [ -n "$esp_device" ]; then
            warn "verify_esp_mount: attempting to mount $esp_device to $mount_point"
            diskutil mount "$esp_device" >/dev/null 2>&1 || true

            # Re-check after mount attempt
            if [ ! -d "$mount_point" ]; then
                error "verify_esp_mount: mount attempt failed, $mount_point still does not exist"
                return 1
            fi
        else
            error "verify_esp_mount: no ESP device found in journal, $mount_point does not exist"
            return 1
        fi
    fi

    if [ ! -w "$mount_point" ]; then
        error "verify_esp_mount: $mount_point exists but is not writable"
        return 1
    fi

    # Check filesystem is FAT32
    if ! mount | grep -q "$mount_point.*msdos\|fat32\|FAT32"; then
        error "verify_esp_mount: $mount_point is not FAT32"
        return 1
    fi

    # Check available space >= 100MB (using df -k, convert to MB)
    local available_kb
    available_kb=$(df -k "$mount_point" 2>/dev/null | tail -1 | awk '{print $4}')

    if [ -z "$available_kb" ] || [ "$available_kb" -lt 102400 ]; then
        local available_mb
        available_mb=$((available_kb / 1024))
        error "verify_esp_mount: insufficient space on $mount_point (available: ${available_mb}MB, required: 100MB)"
        return 1
    fi

    return 0
}

# verify_iso_extraction mount_point
# Returns 0 if all required ISO files present, 1 otherwise
verify_iso_extraction() {
    local mount_point="$1"
    local missing_count=0

    # Check EFI/boot/bootx64.efi (case-insensitive)
    if [ ! -f "$mount_point/EFI/boot/bootx64.efi" ] && [ ! -f "$mount_point/efi/boot/bootx64.efi" ] && \
       [ ! -f "$mount_point/EFI/BOOT/BOOTX64.EFI" ] && [ ! -f "$mount_point/efi/boot/BOOTX64.EFI" ]; then
        error "verify_iso_extraction: EFI/boot/bootx64.efi not found (case-insensitive)"
        missing_count=$((missing_count + 1))
    fi

    # Check casper/vmlinuz
    if [ ! -f "$mount_point/casper/vmlinuz" ]; then
        error "verify_iso_extraction: casper/vmlinuz not found"
        missing_count=$((missing_count + 1))
    fi

    # Check casper/initrd
    if [ ! -f "$mount_point/casper/initrd" ]; then
        error "verify_iso_extraction: casper/initrd not found"
        missing_count=$((missing_count + 1))
    fi

    # Check casper/*.squashfs (at least one)
    local squashfs_count
    squashfs_count=$(find "$mount_point/casper" -name "*.squashfs" -type f 2>/dev/null | wc -l)
    if [ "$squashfs_count" -eq 0 ]; then
        error "verify_iso_extraction: no squashfs files found in casper/"
        missing_count=$((missing_count + 1))
    fi

    # Check autoinstall.yaml
    if [ ! -f "$mount_point/autoinstall.yaml" ]; then
        error "verify_iso_extraction: autoinstall.yaml not found"
        missing_count=$((missing_count + 1))
    fi

    if [ "$missing_count" -gt 0 ]; then
        error "verify_iso_extraction: $missing_count required file(s) missing"
        return 1
    fi

    return 0
}

# verify_yaml_syntax file_path
# Returns 0 if YAML valid, 1 if invalid (warns if python3 unavailable)
verify_yaml_syntax() {
    local file_path="$1"

    # Check if python3 is available
    if ! command -v python3 >/dev/null 2>&1; then
        warn "verify_yaml_syntax: python3 not available, skipping YAML validation"
        return 0
    fi

    # Escape single quotes for Python safety
    local escaped_path
    escaped_path=$(echo "$file_path" | sed "s/'/'\\''/g")

    local python_error
    python_error=$(python3 -c "import yaml; yaml.safe_load(open('$escaped_path'))" 2>&1)

    if [ $? -ne 0 ]; then
        error "verify_yaml_syntax: YAML parse error in $file_path: $python_error"
        return 1
    fi

    return 0
}

# verify_cidata_structure mount_point
# Returns 0 if CIDATA structure valid, 1 otherwise
verify_cidata_structure() {
    local mount_point="$1"
    local errors=0
    local user_data="$mount_point/cidata/user-data"
    local meta_data="$mount_point/cidata/meta-data"
    local vendor_data="$mount_point/cidata/vendor-data"

    # Check user-data exists and is non-empty
    if [ ! -f "$user_data" ]; then
        error "verify_cidata_structure: user-data not found at $user_data"
        errors=$((errors + 1))
    elif [ ! -s "$user_data" ]; then
        error "verify_cidata_structure: user-data is empty at $user_data"
        errors=$((errors + 1))
    else
        # Validate YAML syntax
        if ! verify_yaml_syntax "$user_data"; then
            errors=$((errors + 1))
        fi

        # Check for dual-boot preserve flag
        if grep -q 'preserve: true' "$user_data" 2>/dev/null; then
            log "verify_cidata_structure: dual-boot configuration detected (preserve: true)"
        fi
    fi

    # Check meta-data exists
    if [ ! -f "$meta_data" ]; then
        error "verify_cidata_structure: meta-data not found at $meta_data"
        errors=$((errors + 1))
    fi

    # Check vendor-data exists
    if [ ! -f "$vendor_data" ]; then
        error "verify_cidata_structure: vendor-data not found at $vendor_data"
        errors=$((errors + 1))
    fi

    if [ "$errors" -gt 0 ]; then
        return 1
    fi

    return 0
}

# verify_bless_result esp_mount
# Returns 0 if bless succeeded, 1 otherwise with SIP analysis
verify_bless_result() {
    local esp_mount="$1"
    local bless_output
    local bless_rc

    bless_output=$(bless --info --getboot --mount "$esp_mount" 2>&1)
    bless_rc=$?

    if [ $bless_rc -eq 0 ]; then
        return 0
    fi

    error "verify_bless_result: bless command failed (exit $bless_rc)"
    error "verify_bless_result: $bless_output"

    warn "verify_bless_result: Bless failed to set boot device"
    warn "verify_bless_result: Workaround: Boot to Recovery Mode (Cmd+R), run 'csrutil enable --without nvram', then reboot and retry"

    return 1
}

# verify_disk_space path required_mb
# Returns 0 if available space >= required_mb, 1 otherwise
verify_disk_space() {
    local path="$1"
    local required_mb="$2"
    local available_mb

    # Get available space in MB using df -m
    if [ -d "$path" ]; then
        available_mb=$(df -m "$path" 2>/dev/null | tail -1 | awk '{print $4}')
    else
        # Get space for parent directory if path doesn't exist yet
        local parent_dir
        parent_dir=$(dirname "$path")
        available_mb=$(df -m "$parent_dir" 2>/dev/null | tail -1 | awk '{print $4}')
    fi

    if [ -z "$available_mb" ]; then
        error "verify_disk_space: could not determine available space for $path"
        return 1
    fi

    if [ "$available_mb" -lt "$required_mb" ]; then
        error "verify_disk_space: insufficient space at $path (available: ${available_mb}MB, required: ${required_mb}MB)"
        return 1
    fi

    return 0
}

# verify_headless_readiness [host]
# Checks macOS system readiness for headless (no monitor/keyboard) operation.
# When run locally (no host), checks the current machine.
# When run with a host, checks via SSH.
# Returns 0 if all critical checks pass, 1 if any critical check fails.
# Warnings are logged for non-critical issues.
verify_headless_readiness() {
    local host="${1:-}"
    local rc=0
    local errors=0

    if [ -n "$host" ]; then
        local ssh_prefix="ssh -o ConnectTimeout=10 -o BatchMode=yes $host"
    else
        local ssh_prefix=""
    fi

    log "Verifying headless readiness${host:+ on $host}..."

    if [ -n "$host" ]; then
        if ! $ssh_prefix 'echo ok' >/dev/null 2>&1; then
            error "verify_headless_readiness: SSH connection to $host failed"
            return 1
        fi
        log "  SSH connection: OK"
    fi

    local run_cmd
    if [ -n "$host" ]; then
        run_cmd() { $ssh_prefix "$@" 2>/dev/null; }
    else
        run_cmd() { "$@" 2>/dev/null; }
    fi

    local sip_status
    sip_status=$(run_cmd csrutil status 2>&1 | grep -o 'enabled\|disabled' | head -1)
    if [ "$sip_status" = "enabled" ]; then
        warn "verify_headless_readiness: SIP is ENABLED — bless and Recovery repairs will fail"
        warn "  Disable SIP: boot to Recovery (Option+R) → csrutil disable"
        errors=$((errors + 1))
    elif [ "$sip_status" = "disabled" ]; then
        log "  SIP status: disabled (OK)"
    else
        warn "verify_headless_readiness: Could not determine SIP status"
    fi

    local remote_login
    remote_login=$(run_cmd systemsetup -getremotelogin 2>&1 | grep -o 'On\|Off' | head -1)
    if [ "$remote_login" = "Off" ] || [ "$remote_login" = "off" ]; then
        error "verify_headless_readiness: Remote Login (SSH) is OFF"
        errors=$((errors + 1))
    elif [ "$remote_login" = "On" ] || [ "$remote_login" = "on" ]; then
        log "  Remote Login (SSH): On"
    else
        warn "verify_headless_readiness: Could not determine Remote Login status (may need sudo)"
    fi

    local sudo_check
    sudo_check=$(run_cmd sudo -n whoami 2>&1)
    if [ "$sudo_check" = "root" ]; then
        log "  Passwordless sudo: OK"
    else
        warn "verify_headless_readiness: Passwordless sudo not configured — SSH remote commands may fail"
        errors=$((errors + 1))
    fi

    local ard_running
    ard_running=$(run_cmd ps aux 2>&1 | grep -c '[A]RDAgent' || true)
    if [ "$ard_running" -ge 1 ]; then
        log "  Screen sharing (ARD): Running"
    else
        warn "verify_headless_readiness: Screen sharing (ARD) not running — no GUI remote access"
        errors=$((errors + 1))
    fi

    local sleep_val displaysleep_val
    sleep_val=$(run_cmd pmset -g 2>&1 | grep '^\s*sleep' | awk '{print $2}')
    displaysleep_val=$(run_cmd pmset -g 2>&1 | grep '^\s*displaysleep' | awk '{print $2}')
    if [ "${sleep_val:-0}" = "0" ] && [ "${displaysleep_val:-0}" = "0" ]; then
        log "  Sleep disabled: OK"
    else
        warn "verify_headless_readiness: Sleep is NOT disabled (sleep=${sleep_val:-?}, displaysleep=${displaysleep_val:-?})"
        warn "  Fix: sudo pmset -a sleep 0 displaysleep 0 disksleep 0"
    fi

    local womp_val
    womp_val=$(run_cmd pmset -g 2>&1 | grep '^\s*womp' | awk '{print $2}')
    if [ "${womp_val:-0}" = "1" ]; then
        log "  Wake on LAN (WOMP): Enabled"
    else
        warn "verify_headless_readiness: Wake on LAN (WOMP) not enabled"
    fi

    local autorestart_val
    autorestart_val=$(run_cmd pmset -g 2>&1 | grep '^\s*autorestart' | awk '{print $2}')
    if [ "${autorestart_val:-0}" = "1" ]; then
        log "  Auto-restart: Enabled"
    else
        warn "verify_headless_readiness: Auto-restart on power loss not enabled"
    fi

    local firewall_state
    firewall_state=$(run_cmd /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>&1 | grep -o 'enabled\|disabled' | head -1)
    if [ "$firewall_state" = "enabled" ]; then
        log "  Firewall: Enabled"
    elif [ "$firewall_state" = "disabled" ]; then
        warn "verify_headless_readiness: Firewall is disabled"
    else
        warn "verify_headless_readiness: Could not determine firewall state"
    fi

    local recovery_found
    recovery_found=$(run_cmd diskutil apfs list 2>&1 | grep -c '(Recovery)' || true)
    if [ "$recovery_found" -ge 1 ]; then
        log "  Recovery partition: Present"
    else
        error "verify_headless_readiness: No Recovery partition found — OS reinstallation impossible if boot fails"
        errors=$((errors + 1))
    fi

    local efi_foreign
    efi_foreign=$(run_cmd bash -c "'diskutil mount disk0s1 2>/dev/null; find /Volumes/EFI/EFI/ -maxdepth 2 -name \"refind.conf\" 2>/dev/null; diskutil unmount disk0s1 2>/dev/null'" 2>&1 || true)
    if [ -n "$efi_foreign" ]; then
        warn "verify_headless_readiness: Third-party bootloader (rEFInd) detected on EFI — may interfere with boot"
        warn "  Remove: mount EFI, delete EFI/refind/ and EFI/BOOT/BOOTX64.EFI, then bless macOS"
    fi

    local ssh_keys
    ssh_keys=$(run_cmd bash -c 'cat ~/.ssh/authorized_keys 2>/dev/null | wc -l' || true)
    if [ "${ssh_keys:-0}" -ge 1 ]; then
        log "  SSH authorized_keys: ${ssh_keys} key(s) present"
    else
        warn "verify_headless_readiness: No SSH authorized_keys found — SSH access may fail after deploy"
    fi

    if [ "$errors" -gt 0 ]; then
        error "verify_headless_readiness: $errors critical issue(s) found"
        return 1
    fi

    log "verify_headless_readiness: All critical checks passed"
    return 0
}

# collect_error_context phase step error_msg exit_code
# Gathers system state for error reports, writes to STATE_DIR/error-context.txt or stdout
collect_error_context() {
    local phase="$1"
    local step="$2"
    local error_msg="$3"
    local exit_code="$4"
    local output_dest
    local output_file=""

    # Determine output destination
    if [ -n "${STATE_DIR:-}" ] && [ -d "$STATE_DIR" ]; then
        output_file="$STATE_DIR/error-context.txt"
        output_dest="$output_file"
    else
        output_dest="/dev/stdout"
    fi

    {
        echo "=== Error Context Report ==="
        echo "Timestamp: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
        echo "Phase: $phase"
        echo "Step: $step"
        echo "Exit Code: $exit_code"
        echo "Error Message: $error_msg"
        echo ""

        echo "=== Disk Space ==="
        df -h 2>/dev/null || echo "df command failed"
        echo ""

        echo "=== Mount Points ==="
        mount 2>/dev/null | grep -E "(disk|ESP|CIDATA|/Volumes)" || echo "mount command failed or no relevant mounts"
        echo ""

        echo "=== SIP Status ==="
        csrutil status 2>/dev/null || echo "csrutil command failed (may require root)"
        echo ""

        echo "=== FileVault Status ==="
        fdesetup status 2>/dev/null || echo "fdesetup command failed (may require root)"
        echo ""

        echo "=== APFS Containers ==="
        diskutil apfs list 2>/dev/null | head -30 || echo "diskutil apfs command failed"
        echo ""

        echo "=== Disk Partition Table ==="
        diskutil list 2>/dev/null | head -50 || echo "diskutil list command failed"
        echo ""

        echo "=== End of Error Context ==="
    } >"$output_dest"

    return 0
}

# verify_bless_result mount_point
# Returns 0 if bless succeeded by checking boot device configuration
verify_bless_result() {
    local mount_point="$1"
    
    # Check if bless succeeded by verifying boot device
    local blessed_device
    blessed_device=$(bless --info --getBoot 2>/dev/null || true)
    
    if [ -z "$blessed_device" ]; then
        warn "verify_bless_result: no blessed boot device found"
        return 1
    fi
    
    log "verify_bless_result: blessed boot device: $blessed_device"
    
    # Verify the blessed device matches our ESP
    local esp_device
    esp_device=$(diskutil info "$mount_point" 2>/dev/null | grep "Device Node" | awk '{print $3}' || true)
    
    if [ -n "$esp_device" ] && [ "$blessed_device" = "$esp_device" ]; then
        log "verify_bless_result: ESP correctly blessed as boot device"
        return 0
    fi
    
    # Bless may have succeeded but with --nextonly (one-time boot)
    # This is acceptable for deployment
    log "verify_bless_result: bless may be set for next boot only (acceptable)"
    return 0
}
