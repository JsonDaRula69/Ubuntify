#!/bin/bash
#
# lib/autoinstall.sh - Autoinstall configuration generation
#
# Provides generate_autoinstall for creating autoinstall YAML configs
# and generate_dualboot_storage for dynamic dual-boot storage configs.
#
# Dependencies: lib/colors.sh, lib/logging.sh
#

[ "${_AUTOINSTALL_SH_SOURCED:-0}" -eq 1 ] && return 0
_AUTOINSTALL_SH_SOURCED=1

source "${LIB_DIR:-./lib}/colors.sh"
source "${LIB_DIR:-./lib}/logging.sh"

: "${SCRIPT_DIR:=$(cd "$(dirname "$0")" && pwd)}"

write_grub_config() {
    local ESP_MOUNT="$1"

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

    mkdir -p "$ESP_MOUNT/boot/grub"
    cp "$ESP_MOUNT/EFI/boot/grub.cfg" "$ESP_MOUNT/boot/grub/grub.cfg"
}

generate_autoinstall() {
    local OUTPUT_PATH="$1"
    local STORAGE_TYPE="$2"  # dualboot or fulldisk
    local NETWORK_TYPE="$3"  # wifi or ethernet

    log "Generating autoinstall configuration..."
    log "  Storage: $STORAGE_TYPE, Network: $NETWORK_TYPE"

    # Start with base template
    local TEMPLATE_PATH="${LIB_DIR:-./lib}/autoinstall.yaml"
    if [ ! -f "$TEMPLATE_PATH" ]; then
        die "Template not found: $TEMPLATE_PATH"
    fi

    cp "$TEMPLATE_PATH" "$OUTPUT_PATH"

    # Modify based on selections
    local FULL_DISK_STORAGE NETWORK_CONFIG SIMPLE_EARLY
    if [ "$STORAGE_TYPE" = "fulldisk" ]; then
        # Replace storage section with full-disk config
        FULL_DISK_STORAGE='  storage:
    config:
    - type: disk
      id: root-disk
      path: /dev/sda
      ptable: gpt
      wipe: superblock-recursive
    - type: partition
      id: efi-partition
      device: root-disk
      size: 512M
      flag: boot
      partition_type: c12a7328-f81f-11d2-ba4b-00a0c93ec93b
      grub_device: true
      number: 1
    - type: format
      id: efi-format
      volume: efi-partition
      fstype: fat32
    - type: mount
      id: efi-mount
      device: efi-format
      path: /boot/efi
    - type: partition
      id: boot-partition
      device: root-disk
      size: 1G
      number: 2
    - type: format
      id: boot-format
      volume: boot-partition
      fstype: ext4
    - type: mount
      id: boot-mount
      device: boot-format
      path: /boot
    - type: partition
      id: root-partition
      device: root-disk
      size: -1
      number: 3
    - type: format
      id: root-format
      volume: root-partition
      fstype: ext4
    - type: mount
      id: root-mount
      device: root-format
      path: /'

        # Use sed to replace storage section
        python3 -c "
import re
with open('$OUTPUT_PATH', 'r') as f:
    content = f.read()

pattern = r'  storage:\n    config:.*?\n(?=  [a-z]|\Z)'
content = re.sub(pattern, '''$FULL_DISK_STORAGE''', content, flags=re.DOTALL)

with open('$OUTPUT_PATH', 'w') as f:
    f.write(content)
" || die "Failed to modify storage section"
    fi

    if [ "$NETWORK_TYPE" = "ethernet" ]; then
        # Add network section with ethernet config
        local NETWORK_CONFIG
        NETWORK_CONFIG='  network:
    version: 2
    ethernets:
      primary:
        match:
          name: "en*"
        dhcp4: true
        optional: true
'

        # Insert network section before early-commands
        python3 -c "
with open('$OUTPUT_PATH', 'r') as f:
    content = f.read()

if '  network:' not in content:
    content = content.replace('  early-commands:', '''$NETWORK_CONFIG  early-commands:''')

with open('$OUTPUT_PATH', 'w') as f:
    f.write(content)
" || die "Failed to add network section"

        # For ethernet, replace early-commands with minimal version (no DKMS)
        local SIMPLE_EARLY
        SIMPLE_EARLY='  early-commands:
    - |
      set -x
      LOG="/run/macpro.log"
      WHURL="__WHURL__"
      wh() { curl -s -X POST "\$WHURL" -H "Content-Type: application/json" -d "\$1" > /dev/null 2>&1 || true; }
      log() { echo "[early] \$1" >> "\$LOG"; }

      echo "=== MAC PRO 2013 AUTOINSTALL (Ethernet mode) ===" > "\$LOG"
      echo "Kernel: \$(uname -r)" >> "\$LOG"
      wh '"'"'{"progress":5,"stage":"prep-init","status":"running","message":"Autoinstall started — Ethernet mode, network ready"}'"'"'

      # Start SSH server for remote debugging (ethernet network already up)
      wh '"'"'{"progress":20,"stage":"prep-ssh","status":"starting","message":"Starting SSH server for remote debugging"}'"'"'
      log "Starting SSH server..."
      dpkg --force-depends -i /cdrom/pool/restricted/o/openssh/openssh-server_*.deb 2>>"\$LOG" || true
      if [ -f /usr/sbin/sshd ]; then
        useradd -m -s /bin/bash ubuntu 2>/dev/null || true
        echo "ubuntu:ubuntu" | chpasswd 2>/dev/null || true
        mkdir -p /home/ubuntu/.ssh 2>/dev/null || true
        : > /home/ubuntu/.ssh/authorized_keys 2>/dev/null || true
        chmod 700 /home/ubuntu/.ssh 2>/dev/null || true
        chmod 600 /home/ubuntu/.ssh/authorized_keys 2>/dev/null || true
        chown -R ubuntu:ubuntu /home/ubuntu/.ssh 2>/dev/null || true
        mkdir -p /run/sshd
        /usr/sbin/sshd -D -e &
        log "SSH server started"
        wh '"'"'{"progress":25,"stage":"prep-ssh","status":"ready","message":"SSH server ready — early-commands complete"}'"'"'
      fi
      set +x'

        python3 -c "
import re
with open('$OUTPUT_PATH', 'r') as f:
    content = f.read()

# Replace early-commands section
pattern = r'  early-commands:.*?\n(?=  [a-z]|\Z)'
content = re.sub(pattern, '''$SIMPLE_EARLY''', content, flags=re.DOTALL)

with open('$OUTPUT_PATH', 'w') as f:
    f.write(content)
" || die "Failed to simplify early-commands"
    fi

    log "Autoinstall configuration generated: $OUTPUT_PATH"

    # Helper: escape special chars for sed replacement with # delimiter
    # Must escape: \ (escape char), & (pattern repeat), # (delimiter), / (common in URLs)
    _sed_escape() {
        # Escape sed replacement special chars: &, \, #, /
        printf '%s\n' "$1" | sed 's/[&\\\/#]/\\&/g'
    }

    _sed_escape_yaml_dq() {
        # Escape for YAML double-quoted strings: backslash, double-quote,
        # newline, tab, ampersand, hash. Newlines and tabs become \n and \t
        # (YAML escape sequences). Trailing newline stripped for sed.
        printf '%s' "$1" | sed -e ':a' -e 'N' -e '$!ba' \
            -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
            -e 's/\n/\\n/g' -e 's/\t/\\t/g' \
            -e 's/&/\\&/g' -e 's/#/\\#/g'
    }


    # Deploy.conf placeholders → autoinstall template
    if [ -n "${USERNAME:-}" ]; then
        local escaped_val
        escaped_val=$(_sed_escape "$USERNAME")
        sed -i "s#__USERNAME__#${escaped_val}#g" "$OUTPUT_PATH" 2>/dev/null || \
            sed -i '' "s#__USERNAME__#${escaped_val}#g" "$OUTPUT_PATH"
    fi
    if [ -n "${REALNAME:-}" ]; then
        local escaped_val
        escaped_val=$(_sed_escape "$REALNAME")
        sed -i "s#__REALNAME__#${escaped_val}#g" "$OUTPUT_PATH" 2>/dev/null || \
            sed -i '' "s#__REALNAME__#${escaped_val}#g" "$OUTPUT_PATH"
    fi
    if [ -n "${PASSWORD_HASH:-}" ]; then
        # $6$ hashes contain $ — already escaped by _sed_escape
        local escaped_val
        escaped_val=$(_sed_escape "$PASSWORD_HASH")
        sed -i "s#__PASSWORD_HASH__#${escaped_val}#g" "$OUTPUT_PATH" 2>/dev/null || \
            sed -i '' "s#__PASSWORD_HASH__#${escaped_val}#g" "$OUTPUT_PATH"
    fi
    if [ -n "${HOSTNAME:-}" ]; then
        local escaped_val
        escaped_val=$(_sed_escape "$HOSTNAME")
        sed -i "s#__HOSTNAME__#${escaped_val}#g" "$OUTPUT_PATH" 2>/dev/null || \
            sed -i '' "s#__HOSTNAME__#${escaped_val}#g" "$OUTPUT_PATH"
    fi
    if [ -n "${WHURL:-}" ]; then
        local escaped_val
        escaped_val=$(_sed_escape "$WHURL")
        sed -i "s#__WHURL__#${escaped_val}#g" "$OUTPUT_PATH" 2>/dev/null || \
            sed -i '' "s#__WHURL__#${escaped_val}#g" "$OUTPUT_PATH"
    fi
    if [ -n "${SSH_KEYS:-}" ]; then
        local yaml_keys=""
        local bash_keys=""
        while IFS= read -r key; do
            [ -z "$key" ] && continue
            yaml_keys="${yaml_keys}      - ${key}"$'\n'
            bash_keys="${bash_keys} \"${key}\""
        done <<< "$SSH_KEYS"
        yaml_keys="${yaml_keys%$'\n'}"
        local escaped_yaml escaped_bash
        escaped_yaml=$(_sed_escape "$yaml_keys")
        escaped_bash=$(_sed_escape "$bash_keys")
        sed -i "s#__SSH_KEYS__#${escaped_yaml}#g" "$OUTPUT_PATH" 2>/dev/null || \
            sed -i '' "s#__SSH_KEYS__#${escaped_yaml}#g" "$OUTPUT_PATH"
        sed -i "s#__SSH_KEYS_LIST__#${escaped_bash}#g" "$OUTPUT_PATH" 2>/dev/null || \
            sed -i '' "s#__SSH_KEYS_LIST__#${escaped_bash}#g" "$OUTPUT_PATH"
    fi
    if [ -n "${WIFI_SSID:-}" ] && [ -n "${WIFI_PASSWORD:-}" ]; then
        local escaped_ssid escaped_password
        escaped_ssid=$(_sed_escape_yaml_dq "$WIFI_SSID")
        escaped_password=$(_sed_escape_yaml_dq "$WIFI_PASSWORD")
        sed -i "s#__WIFI_SSID__#${escaped_ssid}#g" "$OUTPUT_PATH" 2>/dev/null || \
            sed -i '' "s#__WIFI_SSID__#${escaped_ssid}#g" "$OUTPUT_PATH"
        sed -i "s#__WIFI_PASSWORD__#${escaped_password}#g" "$OUTPUT_PATH" 2>/dev/null || \
            sed -i '' "s#__WIFI_PASSWORD__#${escaped_password}#g" "$OUTPUT_PATH"
    fi
}

generate_dualboot_storage() {
    local TEMPLATE_PATH="$1"
    local OUTPUT_PATH="$2"
    local DISK_DEV="$3"

    log "Generating dual-boot storage config..."

    python3 - "$TEMPLATE_PATH" "$OUTPUT_PATH" "$DISK_DEV" << 'PYEOF' || die "Failed to generate dual-boot storage config"
import sys, subprocess, re, os

template_path = sys.argv[1]
output_path = sys.argv[2]
disk_dev = sys.argv[3]

with open(template_path) as f:
    content = f.read()

# Read GPT partition table using sgdisk
try:
    result = subprocess.run(['sgdisk', '-p', disk_dev], capture_output=True, text=True)
    part_lines = result.stdout.strip().split('\n')
except Exception as e:
    print(f"WARNING: Could not read partition table: {e}", file=sys.stderr)
    with open(output_path, 'w') as f:
        f.write(content)
    sys.exit(0)

# Parse existing partitions
preserved_yaml = ""
max_part_num = 0
part_count = 0

for line in part_lines:
    fields = line.split()
    if len(fields) < 7:
        continue
    try:
        part_num = int(fields[0])
        max_part_num = max(max_part_num, part_num)
    except (ValueError, IndexError):
        continue

    try:
        # Get detailed partition info
        info = subprocess.run(['sgdisk', '-i', str(part_num), disk_dev],
                             capture_output=True, text=True)
        info_text = info.stdout

        part_type_guid = ''
        part_uuid = ''
        first_sector = None
        last_sector = None

        for info_line in info_text.split('\n'):
            if 'Partition type GUID code:' in info_line or 'Partition type code:' in info_line:
                guid_match = re.search(r'([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})', info_line)
                if guid_match:
                    part_type_guid = guid_match.group(1).lower()
            elif 'Partition unique GUID:' in info_line or 'Partition GUID:' in info_line:
                guid_match = re.search(r'([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})', info_line)
                if guid_match:
                    part_uuid = guid_match.group(1).lower()
            elif 'First sector:' in info_line:
                sector_match = re.search(r'(\d+)', info_line.split(':')[-1])
                if sector_match:
                    first_sector = int(sector_match.group(1))
            elif 'Last sector:' in info_line:
                sector_match = re.search(r'(\d+)', info_line.split(':')[-1])
                if sector_match:
                    last_sector = int(sector_match.group(1))

        if first_sector is None or last_sector is None or not part_type_guid or not part_uuid:
            continue

        offset_bytes = first_sector * 512
        size_bytes = (last_sector - first_sector + 1) * 512
        part_path = f"/dev/sda{part_num}"

        if size_bytes < 1048576:
            continue

        preserved_yaml += f"""    - device: root-disk
      size: {size_bytes}
      number: {part_num}
      preserve: true
      grub_device: false
      offset: {offset_bytes}
      partition_type: {part_type_guid}
      path: {part_path}
      uuid: {part_uuid}
      id: preserved-partition-{part_num}
      type: partition
"""
        part_count += 1
    except Exception as e:
        print(f"WARNING: Could not parse partition {part_num}: {e}", file=sys.stderr)
        continue

if not preserved_yaml:
    print("WARNING: No preserved partitions found — copying template as-is", file=sys.stderr)
    with open(output_path, 'w') as f:
        f.write(content)
    sys.exit(0)

APPLE_APFS_GUID = "7c3457ef-0000-11aa-aa11-00306543ecac"
APPLE_EFI_GUID = "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
has_apfs_container = any(APPLE_APFS_GUID in line for line in preserved_yaml.lower().split('\n'))
if not has_apfs_container:
    print(f"ERROR: APFS container partition (GUID {APPLE_APFS_GUID}) not found in preserved partitions!", file=sys.stderr)
    print("The macOS Recovery partition lives inside the APFS container. Without preserving it,", file=sys.stderr)
    print("the installer will DESTROY all macOS data including Recovery. Aborting.", file=sys.stderr)
    sys.exit(1)

next_num = max_part_num + 1

# Build the new storage section
new_storage = f"""  storage:
    config:
    - type: disk
      id: root-disk
      path: /dev/sda
      ptable: gpt
      preserve: true
      wipe: superblock
{preserved_yaml}    - type: partition
      id: efi-partition
      device: root-disk
      size: 512M
      flag: boot
      partition_type: c12a7328-f81f-11d2-ba4b-00a0c93ec93b
      grub_device: true
      number: {next_num}
    - type: format
      id: efi-format
      volume: efi-partition
      fstype: fat32
    - type: mount
      id: efi-mount
      device: efi-format
      path: /boot/efi
    - type: partition
      id: boot-partition
      device: root-disk
      size: 1G
      number: {next_num + 1}
    - type: format
      id: boot-format
      volume: boot-partition
      fstype: ext4
    - type: mount
      id: boot-mount
      device: boot-format
      path: /boot
    - type: partition
      id: root-partition
      device: root-disk
      size: -1
      number: {next_num + 2}
    - type: format
      id: root-format
      volume: root-partition
      fstype: ext4
    - type: mount
      id: root-mount
      device: root-format
      path: /
"""

# Replace the storage section in the template
pattern = r'  storage:\n    config:.*?(?=\n  [a-z]|\Z)'
replacement = new_storage.rstrip()
new_content = re.sub(pattern, replacement, content, count=1, flags=re.DOTALL)

if new_content == content:
    print("WARNING: Storage section not found in template — copying as-is", file=sys.stderr)
    with open(output_path, 'w') as f:
        f.write(content)
else:
    with open(output_path, 'w') as f:
        f.write(new_content)
    print(f"  Preserving {part_count} existing partitions (macOS + installer ESP)")
PYEOF
}
