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

    if [ -n "${TARGET_HOST:-}" ]; then
        if ! remote_mac_exec diskutil info "$container_device" >/dev/null 2>&1; then
            error "verify_apfs_resize: cannot access $container_device on ${TARGET_HOST}"
            return 1
        fi
        actual_gb=$(remote_mac_exec diskutil info "$container_device" 2>/dev/null | grep -i "Disk Size" | sed -E 's/.*[^0-9]([0-9]+\.[0-9]+)[^0-9]*GB.*/\1/')
    else
        if ! diskutil info "$container_device" >/dev/null 2>&1; then
            error "verify_apfs_resize: cannot access $container_device"
            return 1
        fi
        actual_gb=$(diskutil info "$container_device" 2>/dev/null | grep -i "Disk Size" | sed -E 's/.*[^0-9]([0-9]+\.[0-9]+)[^0-9]*GB.*/\1/')
    fi

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

    local _py_pkgs_missing=""
    for _pkg in jsonschema pyyaml; do
        if ! python3 -c "import $_pkg" 2>/dev/null; then
            _py_pkgs_missing="${_py_pkgs_missing}${_py_pkgs_missing:+ }$_pkg"
        fi
    done
    if [ -n "$_py_pkgs_missing" ]; then
        log_info "Installing Python packages: $_py_pkgs_missing"
        if python3 -m pip install --quiet --break-system-packages $_py_pkgs_missing 2>/dev/null; then
            log_info "Python packages installed successfully"
        elif python3 -m pip install --quiet --user --break-system-packages $_py_pkgs_missing 2>/dev/null; then
            log_info "Python packages installed (user scope)"
        else
            warn "verify_autoinstall_schema: could not install Python packages ($_py_pkgs_missing), falling back to lightweight key validation"
        fi
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
    # Schema validates the autoinstall section, not the wrapper
    ai_data = data.get('autoinstall', data) if isinstance(data, dict) else data
    jsonschema.validate(ai_data, schema)
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

# verify_esp_mount mount_point [esp_device]
# Returns 0 if mount_point exists, writable, FAT32, and has >=100MB free
# In remote deployment mode, all checks run via SSH
# on the target Mac Pro. In local mode, checks run on this machine.
# macOS auto-unmounts FAT32 ESP volumes, so this function proactively
# re-mounts if the volume is not found.
verify_esp_mount() {
    local mount_point="$1"
    local esp_device="${2:-}"
    local mount_attempts=3
    local i=1

    # Determine if we're in remote mode — use SSH commands if so
    local is_remote=0
    if [ -n "${TARGET_HOST:-}" ]; then
        is_remote=1
    fi

    # Helper: run a command locally or remotely depending on mode
    _vem_run() {
        if [ "$is_remote" -eq 1 ]; then
            remote_mac_exec "$1"
        else
            eval "$1"
        fi
    }

    # Helper: check if directory exists locally or remotely
    _vem_dir_exists() {
        if [ "$is_remote" -eq 1 ]; then
            remote_mac_dir_exists "$1"
        else
            [ -d "$1" ]
        fi
    }

    # Resolve the actual mount point from the device (macOS may mount to
    # /Volumes/CIDATA 1 if /Volumes/CIDATA already existed from a stale mount)
    _vem_resolve_mount() {
        local dev="$1"
        local resolved=""
        if [ "$is_remote" -eq 1 ]; then
            resolved=$(remote_mac_exec "diskutil info '/dev/$dev' 2>/dev/null | grep 'Mount Point' | awk '{\$1=\$2=\"\"; print substr(\$0,3)}' | sed 's/^[[:space:]]*//'" 2>/dev/null || true)
        else
            resolved=$(diskutil info "/dev/$dev" 2>/dev/null | grep "Mount Point" | awk '{$1=$2=""; print substr($0,3)}' | sed 's/^[[:space:]]*//' || true)
        fi
        echo "$resolved"
    }

    # macOS diskarbitrationd auto-unmounts EFI-typed partitions;
    # mount_msdos with explicit mount point bypasses this
    _vem_ensure_mounted() {
        local dev="$1"
        local mp="$2"
        if _vem_dir_exists "$mp"; then
            return 0
        fi
        log "verify_esp_mount: $mp not found, attempting to mount /dev/$dev"
        if [ "$is_remote" -eq 1 ]; then
            remote_mac_exec mkdir -p "$mp" 2>/dev/null || true
            remote_mac_sudo mount_msdos "/dev/$dev" "$mp" 2>/dev/null || \
                remote_mac_retry_diskutil mount "/dev/$dev" 2>/dev/null || true
        else
            mkdir -p "$mp" 2>/dev/null || true
            sudo mount_msdos "/dev/$dev" "$mp" 2>/dev/null || \
                diskutil mount "/dev/$dev" >/dev/null 2>&1 || true
        fi
        sleep 3
        if _vem_dir_exists "$mp"; then
            return 0
        fi
        local resolved
        resolved=$(_vem_resolve_mount "$dev")
        if [ -n "$resolved" ] && _vem_dir_exists "$resolved"; then
            log "verify_esp_mount: ESP mounted at alternate path: $resolved"
            return 0
        fi
        return 1
    }

    # If we have an esp_device, proactively ensure the ESP is mounted
    if [ -n "$esp_device" ]; then
        while [ "$i" -le "$mount_attempts" ]; do
            if _vem_ensure_mounted "$esp_device" "$mount_point"; then
                break
            fi
            warn "verify_esp_mount: mount attempt $i/$mount_attempts failed"
            i=$((i + 1))
        done
    fi

    # Final check: directory must exist
    if ! _vem_dir_exists "$mount_point"; then
        if [ -n "$esp_device" ]; then
            local resolved
            resolved=$(_vem_resolve_mount "$esp_device")
            if [ -n "$resolved" ] && _vem_dir_exists "$resolved"; then
                log "verify_esp_mount: using resolved mount point: $resolved"
                mount_point="$resolved"
            else
                error "verify_esp_mount: $mount_point does not exist and mount attempts failed"
                return 1
            fi
        else
            if command -v journal_read >/dev/null 2>&1; then
                journal_read
                esp_device="${JOURNAL_ESP_DEVICE:-}"
            fi
            if [ -n "$esp_device" ]; then
                warn "verify_esp_mount: attempting to mount $esp_device from journal"
                if [ "$is_remote" -eq 1 ]; then
                    remote_mac_exec mkdir -p "$mount_point" 2>/dev/null || true
                    remote_mac_sudo mount_msdos "/dev/$esp_device" "$mount_point" 2>/dev/null || \
                        remote_mac_retry_diskutil mount "/dev/$esp_device" 2>/dev/null || true
                else
                    mkdir -p "$mount_point" 2>/dev/null || true
                    sudo mount_msdos "/dev/$esp_device" "$mount_point" 2>/dev/null || \
                        diskutil mount "/dev/$esp_device" >/dev/null 2>&1 || true
                fi
                sleep 3
                if ! _vem_dir_exists "$mount_point"; then
                    error "verify_esp_mount: $mount_point does not exist after mount attempt"
                    return 1
                fi
            else
                error "verify_esp_mount: $mount_point does not exist and no ESP device available"
                return 1
            fi
        fi
    fi

    # Check writability
    local write_test
    if [ "$is_remote" -eq 1 ]; then
        write_test=$(remote_mac_exec "test -w '$mount_point' && echo ok || echo fail" 2>/dev/null)
        if [ "$write_test" != "ok" ]; then
            error "verify_esp_mount: $mount_point exists but is not writable"
            return 1
        fi
    else
        if [ ! -w "$mount_point" ]; then
            error "verify_esp_mount: $mount_point exists but is not writable"
            return 1
        fi
    fi

    # Check filesystem is FAT32
    if [ "$is_remote" -eq 1 ]; then
        local fs_type
        fs_type=$(remote_mac_exec "diskutil info '/dev/$esp_device' 2>/dev/null | grep 'File System Type:' | awk '{print \$NF}'" || true)
        if [ -z "$fs_type" ] || echo "$fs_type" | grep -qi "unknown\|warning"; then
            local mount_info
            mount_info=$(remote_mac_exec "mount | grep '$mount_point' | grep -v 'Warning'" 2>/dev/null || true)
            if ! echo "$mount_info" | grep -qi "msdos\|fat32\|FAT32"; then
                error "verify_esp_mount: $mount_point is not FAT32 (got: ${mount_info:-unknown})"
                return 1
            fi
        elif ! echo "$fs_type" | grep -qi "fat32\|msdos"; then
            error "verify_esp_mount: $mount_point is not FAT32 (got: $fs_type)"
            return 1
        fi
    else
        if ! mount | grep -q "$mount_point.*msdos\|fat32\|FAT32"; then
            error "verify_esp_mount: $mount_point is not FAT32"
            return 1
        fi
    fi

    # Check available space >= 100MB
    local available_kb
    if [ "$is_remote" -eq 1 ]; then
        available_kb=$(remote_mac_exec "df -k '$mount_point' 2>/dev/null | tail -1 | awk '{print \$4}'" 2>/dev/null || true)
    else
        available_kb=$(df -k "$mount_point" 2>/dev/null | tail -1 | awk '{print $4}')
    fi

    if [ -z "$available_kb" ] || [ "$available_kb" -lt 102400 ]; then
        local available_mb
        available_mb=$((available_kb / 1024))
        error "verify_esp_mount: insufficient space on $mount_point (available: ${available_mb:-0}MB, required: 100MB)"
        return 1
    fi

    return 0
}

# verify_iso_extraction mount_point
# Returns 0 if all required ISO files present, 1 otherwise
# In remote mode, checks files on the target Mac Pro via SSH
verify_iso_extraction() {
    local mount_point="$1"
    local missing_count=0

    local is_remote=0
    if [ -n "${TARGET_HOST:-}" ]; then
        is_remote=1
    fi

    _vie_file_exists() {
        local path="$1"
        if [ "$is_remote" -eq 1 ]; then
            remote_mac_file_exists "$path"
        else
            [ -f "$path" ]
        fi
    }

    if ! _vie_file_exists "$mount_point/EFI/boot/bootx64.efi" && ! _vie_file_exists "$mount_point/efi/boot/bootx64.efi" && \
       ! _vie_file_exists "$mount_point/EFI/BOOT/BOOTX64.EFI" && ! _vie_file_exists "$mount_point/efi/boot/BOOTX64.EFI"; then
        error "verify_iso_extraction: EFI/boot/bootx64.efi not found (case-insensitive)"
        missing_count=$((missing_count + 1))
    fi

    if ! _vie_file_exists "$mount_point/casper/vmlinuz"; then
        error "verify_iso_extraction: casper/vmlinuz not found"
        missing_count=$((missing_count + 1))
    fi

    if ! _vie_file_exists "$mount_point/casper/initrd"; then
        error "verify_iso_extraction: casper/initrd not found"
        missing_count=$((missing_count + 1))
    fi

    local squashfs_count
    if [ "$is_remote" -eq 1 ]; then
        squashfs_count=$(remote_mac_exec "ls $mount_point/casper/*.squashfs 2>/dev/null | wc -l | tr -d ' '" || echo "0")
    else
        squashfs_count=$(find "$mount_point/casper" -name "*.squashfs" -type f 2>/dev/null | wc -l)
    fi
    if [ "$squashfs_count" -eq 0 ]; then
        error "verify_iso_extraction: no squashfs files found in casper/"
        missing_count=$((missing_count + 1))
    fi

    if ! _vie_file_exists "$mount_point/user-data"; then
        error "verify_iso_extraction: user-data not found at ESP root (NoCloud requires root-level files)"
        missing_count=$((missing_count + 1))
    fi

    if ! _vie_file_exists "$mount_point/autoinstall.yaml"; then
        error "verify_iso_extraction: autoinstall.yaml not found (Subiquity fallback)"
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

    local is_remote=0
    if [ -n "${TARGET_HOST:-}" ]; then
        is_remote=1
    fi

    _vcs_file_exists() {
        local path="$1"
        if [ "$is_remote" -eq 1 ]; then
            remote_mac_file_exists "$path"
        else
            [ -f "$path" ]
        fi
    }

    _vcs_file_nonempty() {
        local path="$1"
        if [ "$is_remote" -eq 1 ]; then
            local size
            size=$(remote_mac_exec "stat -f '%z' '$path' 2>/dev/null" || echo "0")
            [ "$size" -gt 0 ]
        else
            [ -s "$path" ]
        fi
    }

    if ! _vcs_file_exists "$user_data"; then
        error "verify_cidata_structure: user-data not found at $user_data"
        errors=$((errors + 1))
    elif ! _vcs_file_nonempty "$user_data"; then
        error "verify_cidata_structure: user-data is empty at $user_data"
        errors=$((errors + 1))
    else
        if ! verify_yaml_syntax "$user_data"; then
            errors=$((errors + 1))
        fi

        if [ "$is_remote" -eq 1 ]; then
            if remote_mac_exec "grep -q 'preserve: true' '$user_data' 2>/dev/null"; then
                log "verify_cidata_structure: dual-boot configuration detected (preserve: true)"
            fi
            if remote_mac_exec "grep -q 'preserved-partition' '$user_data' 2>/dev/null"; then
                log "verify_cidata_structure: partition preservation entries found"
            else
                warn "verify_cidata_structure: no preserved-partition entries found — macOS partitions may not be preserved"
            fi
        else
            if grep -q 'preserve: true' "$user_data" 2>/dev/null; then
                log "verify_cidata_structure: dual-boot configuration detected (preserve: true)"
            fi
            if grep -q 'preserved-partition' "$user_data" 2>/dev/null; then
                log "verify_cidata_structure: partition preservation entries found"
            else
                warn "verify_cidata_structure: no preserved-partition entries found — macOS partitions may not be preserved"
            fi
        fi
    fi

    local root_user_data="$mount_point/user-data"
    local root_meta_data="$mount_point/meta-data"
    local root_autoinstall="$mount_point/autoinstall.yaml"

    if ! _vcs_file_exists "$root_user_data"; then
        error "verify_cidata_structure: user-data not found at ESP root ($root_user_data) — NoCloud requires root-level files"
        errors=$((errors + 1))
    fi

    if ! _vcs_file_exists "$root_meta_data"; then
        error "verify_cidata_structure: meta-data not found at ESP root ($root_meta_data) — NoCloud requires root-level files"
        errors=$((errors + 1))
    fi

    if ! _vcs_file_exists "$root_autoinstall"; then
        warn "verify_cidata_structure: autoinstall.yaml not found at ESP root — Subiquity fallback unavailable"
    fi

    if ! _vcs_file_exists "$vendor_data"; then
        error "verify_cidata_structure: vendor-data not found at $vendor_data"
        errors=$((errors + 1))
    fi

    if [ "$errors" -gt 0 ]; then
        return 1
    fi

    return 0
}



# verify_disk_space path required_mb
# Returns 0 if available space >= required_mb, 1 otherwise
verify_disk_space() {
    local path="$1"
    local required_mb="$2"
    local available_mb

    # Get available space in MB using df -m
    if [ -n "${TARGET_HOST:-}" ]; then
        available_mb=$(remote_mac_exec "df -m '$path' 2>/dev/null | tail -1 | awk '{print \$4}'" || echo "")
        if [ -z "$available_mb" ]; then
            local parent_dir
            parent_dir=$(dirname "$path")
            available_mb=$(remote_mac_exec "df -m '$parent_dir' 2>/dev/null | tail -1 | awk '{print \$4}'" || echo "")
        fi
    else
        if [ -d "$path" ]; then
            available_mb=$(df -m "$path" 2>/dev/null | tail -1 | awk '{print $4}')
        else
            # Get space for parent directory if path doesn't exist yet
            local parent_dir
            parent_dir=$(dirname "$path")
            available_mb=$(df -m "$parent_dir" 2>/dev/null | tail -1 | awk '{print $4}')
        fi
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
    local errors=0
    local warnings=0

    # If no host specified, check the target host
    if [ -z "$host" ] && [ -n "${TARGET_HOST:-}" ]; then
        host="$TARGET_HOST"
    fi

    local run_cmd
    if [ -n "$host" ]; then
        run_cmd() {
            local _outf="/tmp/vhr_out_$$_${RANDOM}"
            local _errf="/tmp/vhr_err_$$_${RANDOM}"
            local _rc=0
            ssh $_REMOTE_MAC_SSH_OPTS "$host" "$@" >"$_outf" 2>"$_errf" &
            local _pid=$!
            local _elapsed=0
            while [ "$_elapsed" -lt 30 ]; do
                if ! kill -0 "$_pid" 2>/dev/null; then
                    break
                fi
                sleep 1
                _elapsed=$((_elapsed + 1))
            done
            if kill -0 "$_pid" 2>/dev/null; then
                kill "$_pid" 2>/dev/null; wait "$_pid" 2>/dev/null
                _rc=124
            else
                wait "$_pid" 2>/dev/null; _rc=$?
            fi
            cat "$_outf" 2>/dev/null; rm -f "$_outf"
            [ -s "$_errf" ] && log_debug "run_cmd stderr: $(cat "$_errf")"
            rm -f "$_errf" 2>/dev/null
            return $_rc
        }
        log "Verifying headless readiness on $host..."
        if ! remote_mac_test; then
            error "verify_headless_readiness: SSH connection to $host failed"
            return 1
        fi
        log "  SSH connection: OK"
    else
        run_cmd() { "$@" 2>/dev/null; }
        log "Verifying headless readiness (local)..."
    fi

    local sip_status
    sip_status=$(run_cmd csrutil status 2>&1 | grep -o 'enabled\|disabled' | head -1)
    if [ "$sip_status" = "enabled" ]; then
        # SIP is always enabled on Mac Pro 2013 — this is expected, not a warning
        # bless cannot modify NVRAM; use Option key or Startup Disk for boot selection
        log "  SIP status: enabled (expected)"
    elif [ "$sip_status" = "disabled" ]; then
        log "  SIP status: disabled (OK)"
    else
        log "  SIP status: unknown (continuing)"
    fi

    local remote_login
    remote_login=$(run_cmd sudo systemsetup -getremotelogin 2>&1 | grep -o 'On\|Off' | head -1)
    if [ "$remote_login" = "Off" ] || [ "$remote_login" = "off" ]; then
        error "verify_headless_readiness: Remote Login (SSH) is OFF"
        errors=$((errors + 1))
    elif [ "$remote_login" = "On" ] || [ "$remote_login" = "on" ]; then
        log "  Remote Login (SSH): On"
    else
        warn "verify_headless_readiness: Could not determine Remote Login status (needs sudo on remote)"
        warnings=$((warnings + 1))
    fi

    local sudo_check
    sudo_check=$(run_cmd sudo -n whoami 2>&1)
    if [ "$sudo_check" = "root" ]; then
        log "  Passwordless sudo: OK"
    else
        error "verify_headless_readiness: Passwordless sudo not configured — remote deployment will fail"
        errors=$((errors + 1))
    fi

    local ard_running
    ard_running=$(run_cmd ps aux 2>&1 | grep -c '[A]RDAgent' || true)
    if [ "$ard_running" -ge 1 ]; then
        log "  Screen sharing (ARD): Running"
    else
        warn "verify_headless_readiness: Screen sharing (ARD) not running — no GUI remote access"
        warnings=$((warnings + 1))
    fi

    local sleep_val displaysleep_val
    sleep_val=$(run_cmd pmset -g 2>&1 | grep '^\s*sleep' | awk '{print $2}')
    displaysleep_val=$(run_cmd pmset -g 2>&1 | grep '^\s*displaysleep' | awk '{print $2}')
    if [ "${sleep_val:-0}" = "0" ] && [ "${displaysleep_val:-0}" = "0" ]; then
        log "  Sleep disabled: OK"
    else
        warn "verify_headless_readiness: Sleep is NOT disabled (sleep=${sleep_val:-?}, displaysleep=${displaysleep_val:-?})"
        warn "  Fix: sudo pmset -a sleep 0 displaysleep 0 disksleep 0"
        warnings=$((warnings + 1))
    fi

    local womp_val
    womp_val=$(run_cmd pmset -g 2>&1 | grep '^\s*womp' | awk '{print $2}')
    if [ "${womp_val:-0}" = "1" ]; then
        log "  Wake on LAN (WOMP): Enabled"
    else
        warn "verify_headless_readiness: Wake on LAN (WOMP) not enabled"
        warnings=$((warnings + 1))
    fi

    local autorestart_val
    autorestart_val=$(run_cmd pmset -g 2>&1 | grep '^\s*autorestart' | awk '{print $2}')
    if [ "${autorestart_val:-0}" = "1" ]; then
        log "  Auto-restart: Enabled"
    else
        warn "verify_headless_readiness: Auto-restart on power loss not enabled"
        warnings=$((warnings + 1))
    fi

    local firewall_state
    firewall_state=$(run_cmd /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>&1 | grep -o 'enabled\|disabled' | head -1)
    if [ "$firewall_state" = "enabled" ]; then
        log "  Firewall: Enabled"
    elif [ "$firewall_state" = "disabled" ]; then
        warn "verify_headless_readiness: Firewall is disabled"
        warnings=$((warnings + 1))
    else
        warn "verify_headless_readiness: Could not determine firewall state"
        warnings=$((warnings + 1))
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
    efi_foreign=$(run_cmd bash -c "'find /Volumes/EFI/EFI/ -maxdepth 2 -name refind.conf 2>/dev/null'" || true)
    if [ -n "$efi_foreign" ]; then
        warn "verify_headless_readiness: Third-party bootloader (rEFInd) detected on EFI — may interfere with boot"
        warn "  Remove: mount EFI, delete EFI/refind/ and EFI/BOOT/BOOTX64.EFI, then bless macOS"
        warnings=$((warnings + 1))
    fi

    local ssh_keys
    ssh_keys=$(run_cmd bash -c "'cat ~/.ssh/authorized_keys 2>/dev/null | wc -l'" || true)
    if [ "${ssh_keys:-0}" -ge 1 ]; then
        log "  SSH authorized_keys: ${ssh_keys} key(s) present"
    else
        warn "verify_headless_readiness: No SSH authorized_keys found — SSH access may fail after deploy"
        warnings=$((warnings + 1))
    fi

    if [ "$errors" -gt 0 ]; then
        error "verify_headless_readiness: $errors critical issue(s) found"
        return 1
    fi

    log "verify_headless_readiness: All critical checks passed (${warnings} warning(s))"
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
        local _is_remote=0
        if [ -n "${TARGET_HOST:-}" ]; then
            _is_remote=1
        fi

        echo "=== Error Context Report ==="
        echo "Timestamp: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
        echo "Phase: $phase"
        echo "Step: $step"
        echo "Exit Code: $exit_code"
        echo "Error Message: $error_msg"
        echo ""

        echo "=== Disk Space ==="
        if [ "$_is_remote" -eq 1 ]; then
            remote_mac_exec "df -h 2>/dev/null" || echo "df command failed"
        else
            df -h 2>/dev/null || echo "df command failed"
        fi
        echo ""

        echo "=== Mount Points ==="
        if [ "$_is_remote" -eq 1 ]; then
            remote_mac_exec "mount 2>/dev/null | grep -E '(disk|ESP|CIDATA|/Volumes)'" || echo "mount command failed or no relevant mounts"
        else
            mount 2>/dev/null | grep -E "(disk|ESP|CIDATA|/Volumes)" || echo "mount command failed or no relevant mounts"
        fi
        echo ""

        echo "=== SIP Status ==="
        if [ "$_is_remote" -eq 1 ]; then
            remote_mac_exec "csrutil status 2>/dev/null" || echo "csrutil command failed (may require root)"
        else
            csrutil status 2>/dev/null || echo "csrutil command failed (may require root)"
        fi
        echo ""

        echo "=== FileVault Status ==="
        if [ "$_is_remote" -eq 1 ]; then
            remote_mac_exec "fdesetup status 2>/dev/null" || echo "fdesetup command failed (may require root)"
        else
            fdesetup status 2>/dev/null || echo "fdesetup command failed (may require root)"
        fi
        echo ""

        echo "=== APFS Containers ==="
        if [ "$_is_remote" -eq 1 ]; then
            remote_mac_exec "diskutil apfs list 2>/dev/null | head -30" || echo "diskutil apfs command failed"
        else
            diskutil apfs list 2>/dev/null | head -30 || echo "diskutil apfs command failed"
        fi
        echo ""

        echo "=== Disk Partition Table ==="
        if [ "$_is_remote" -eq 1 ]; then
            remote_mac_exec "diskutil list 2>/dev/null | head -50" || echo "diskutil list command failed"
        else
            diskutil list 2>/dev/null | head -50 || echo "diskutil list command failed"
        fi
        echo ""

        echo "=== End of Error Context ==="
    } >"$output_dest"

    return 0
}

# verify_bless_result mount_point
# Returns 0 if bless succeeded by checking boot device configuration
# In remote mode, checks bless status on the target Mac Pro via SSH
verify_bless_result() {
    local mount_point="$1"
    local is_remote=0
    if [ -n "${TARGET_HOST:-}" ]; then
        is_remote=1
    fi

    local blessed_device
    if [ "$is_remote" -eq 1 ]; then
        blessed_device=$(remote_mac_exec "bless --info --getBoot 2>/dev/null" || true)
    else
        blessed_device=$(bless --info --getBoot 2>/dev/null || true)
    fi

    if [ -n "$blessed_device" ]; then
        log "verify_bless_result: default boot device: $blessed_device"
    fi

    # bless --nextonly stores the next boot device in efi-boot-next NVRAM
    # bless --getBoot only reports the DEFAULT boot device, not --nextonly
    # Check NVRAM efi-boot-next for the one-time boot device set by --nextonly
    local efi_boot_next
    if [ "$is_remote" -eq 1 ]; then
        efi_boot_next=$(remote_mac_exec "nvram efi-boot-next 2>/dev/null" || true)
    else
        efi_boot_next=$(nvram efi-boot-next 2>/dev/null || true)
    fi

    if [ -n "$efi_boot_next" ]; then
        log "verify_bless_result: efi-boot-next NVRAM set (one-time boot device configured)"
        return 0
    fi

    if [ -n "$blessed_device" ]; then
        local esp_device
        if [ "$is_remote" -eq 1 ]; then
            esp_device=$(remote_mac_exec "diskutil info '$mount_point' 2>/dev/null | grep 'Device Node' | awk '{print \$3}'" || true)
        else
            esp_device=$(diskutil info "$mount_point" 2>/dev/null | grep "Device Node" | awk '{print $3}' || true)
        fi

        if [ -n "$esp_device" ] && [ "$blessed_device" = "$esp_device" ]; then
            log "verify_bless_result: ESP correctly blessed as default boot device"
            return 0
        fi

        log "verify_bless_result: bless set for next boot (acceptable)"
        return 0
    fi

    warn "verify_bless_result: no blessed boot device found"
    return 1
}
