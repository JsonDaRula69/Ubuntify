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

    mkdir -p "$ESP_MOUNT/EFI/boot"
    cat > "$ESP_MOUNT/EFI/boot/grub.cfg" << 'GRUBEOF'
set default=0
set timeout=3

menuentry "Ubuntu Server 24.04 Autoinstall (Mac Pro 2013)" {
    set gfxpayload=keep
    linux /casper/vmlinuz autoinstall ds=nocloud nomodeset amdgpu.si.modeset=0 module.sig_enforce=0 ---
    initrd /casper/initrd
}

menuentry "Ubuntu Server 24.04 (Manual Install)" {
    set gfxpayload=keep
    linux /casper/vmlinuz nomodeset amdgpu.si.modeset=0 module.sig_enforce=0 ---
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
    - type: format
      id: root-format
      volume: root-partition
      fstype: ext4
    - type: mount
      id: root-mount
      device: root-format
      path: /
'

         # Replace storage section via Python (avoids shell quoting issues)
         python3 - "$OUTPUT_PATH" "$FULL_DISK_STORAGE" << 'PYEOF' || die "Failed to modify storage section"
import sys, re
path, storage = sys.argv[1], sys.argv[2]
with open(path, 'r') as f:
    content = f.read()
pattern = r'  storage:\n    config:.*?\n(?=  [a-z]|\Z)'
content = re.sub(pattern, storage + '\n', content, flags=re.DOTALL)
with open(path, 'w') as f:
    f.write(content)
PYEOF
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

        # Insert network section before early-commands (avoids shell quoting issues)
        python3 - "$OUTPUT_PATH" "$NETWORK_CONFIG" << 'PYEOF' || die "Failed to add network section"
import sys
path, netconf = sys.argv[1], sys.argv[2]
with open(path, 'r') as f:
    content = f.read()
if '  network:' not in content:
    content = content.replace('  early-commands:', netconf + '  early-commands:')
with open(path, 'w') as f:
    f.write(content)
PYEOF

        # For ethernet, replace early-commands with minimal version (no DKMS)
        local SIMPLE_EARLY
        SIMPLE_EARLY='  early-commands:
    - |
      set -x
      LOG="/run/macpro.log"
      WHURL="__WHURL__"
      wh() { curl -s -X POST "$WHURL" -H "Content-Type: application/json" -d "$1" > /dev/null 2>&1 || true; }
      log() { echo "[early] $1" >> "$LOG"; }

      echo "=== MAC PRO 2013 AUTOINSTALL (Ethernet mode) ===" > "$LOG"
      echo "Kernel: $(uname -r)" >> "$LOG"
      wh '"'"'{"progress":5,"stage":"prep-init","status":"running","message":"Autoinstall started — Ethernet mode, network ready"}'"'"'

      # Start SSH server for remote debugging (ethernet network already up)
      wh '"'"'{"progress":20,"stage":"prep-ssh","status":"starting","message":"Starting SSH server for remote debugging"}'"'"'
      log "Starting SSH server..."
      dpkg --force-depends -i /cdrom/pool/restricted/o/openssh/openssh-server_*.deb 2>>"$LOG" || true
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

        # Replace early-commands section (avoids shell quoting issues)
        python3 - "$OUTPUT_PATH" "$SIMPLE_EARLY" << 'PYEOF' || die "Failed to simplify early-commands"
import sys, re
path, early = sys.argv[1], sys.argv[2]
with open(path, 'r') as f:
    content = f.read()
pattern = r'  early-commands:.*?\n(?=  [a-z]|\Z)'
content = re.sub(pattern, early + '\n', content, flags=re.DOTALL)
with open(path, 'w') as f:
    f.write(content)
PYEOF
    fi

    log "Autoinstall configuration generated: $OUTPUT_PATH"

    # Deploy.conf placeholders → autoinstall template
    # Uses Python for placeholder substitution to avoid shell quoting issues
    # with special characters (double-quotes, backslashes, ampersands, etc.)
    python3 - "$OUTPUT_PATH" "$USERNAME" "$REALNAME" "$PASSWORD_HASH" "$HOSTNAME" "$WHURL" "$SSH_KEYS" "$WIFI_SSID" "$WIFI_PASSWORD" << 'PYEOF' || die "Failed to substitute placeholders"
import sys

output_path = sys.argv[1]
username = sys.argv[2] if len(sys.argv) > 2 else ""
realname = sys.argv[3] if len(sys.argv) > 3 else ""
password_hash = sys.argv[4] if len(sys.argv) > 4 else ""
hostname_arg = sys.argv[5] if len(sys.argv) > 5 else ""
whurl = sys.argv[6] if len(sys.argv) > 6 else ""
ssh_keys = sys.argv[7] if len(sys.argv) > 7 else ""
wifi_ssid = sys.argv[8] if len(sys.argv) > 8 else ""
wifi_password = sys.argv[9] if len(sys.argv) > 9 else ""

def shell_sq_escape(val):
    """Escape a value for shell single-quoted context: ' -> '\\''"""
    return val.replace("'", "'\\''")

def yaml_dq_escape(val):
    """Escape a value for YAML double-quoted string context."""
    val = val.replace('\\', '\\\\')
    val = val.replace('"', '\\"')
    val = val.replace('\n', '\\n')
    val = val.replace('\t', '\\t')
    return val

with open(output_path, 'r') as f:
    content = f.read()

if username:
    content = content.replace('__USERNAME__', yaml_dq_escape(username))
if realname:
    content = content.replace('__REALNAME__', yaml_dq_escape(realname))
if password_hash:
    content = content.replace('__PASSWORD_HASH__', yaml_dq_escape(password_hash))
if hostname_arg:
    content = content.replace('__HOSTNAME__', yaml_dq_escape(hostname_arg))
if whurl:
    content = content.replace('__WHURL__', yaml_dq_escape(whurl))

if ssh_keys:
    yaml_lines = []
    bash_items_list = []
    for key in ssh_keys.strip().split('\n'):
        key = key.strip()
        if not key:
            continue
        yaml_lines.append(f'      - "{yaml_dq_escape(key)}"')
        bash_items_list.append(f'"{key}"')
    yaml_block = '\n'.join(yaml_lines)
    bash_list = ' '.join(bash_items_list)
    content = content.replace('__SSH_KEYS__', yaml_block)
    content = content.replace('__SSH_KEYS_LIST__', bash_list)

if wifi_ssid and wifi_password:
    content = content.replace('__WIFI_SSID__', shell_sq_escape(wifi_ssid))
    content = content.replace('__WIFI_PASSWORD__', shell_sq_escape(wifi_password))

with open(output_path, 'w') as f:
    f.write(content)
PYEOF
}

generate_dualboot_storage() {
    local TEMPLATE_PATH="$1"
    local OUTPUT_PATH="$2"
    local DISK_DEV="$3"
    local ROOT_SIZE_BYTES="$4"

    log "Generating dual-boot storage config..."
    log_debug "generate_dualboot_storage: DISK_DEV=$DISK_DEV, ROOT_SIZE_BYTES=$ROOT_SIZE_BYTES, TARGET_HOST=${TARGET_HOST:-}"

    if [ -z "$ROOT_SIZE_BYTES" ]; then
        ROOT_SIZE_BYTES=0
    fi

    local PARTITION_DATA
    local PARTITION_DETAIL=""
    local part_num

    if [ -n "${TARGET_HOST:-}" ]; then
        PARTITION_DATA=$(remote_mac_sudo "sgdisk -p $DISK_DEV" 2>/dev/null) || true
        local _pd_lines=$(echo "$PARTITION_DATA" | wc -l | tr -d ' ')
        log_debug "generate_dualboot_storage: PARTITION_DATA has ${_pd_lines} lines"
        for part_num in $(echo "$PARTITION_DATA" | awk '{print $1}' | grep -E '^[0-9]+$'); do
            PARTITION_DETAIL="${PARTITION_DETAIL}===PART:${part_num}===
$(remote_mac_sudo "sgdisk -i $part_num $DISK_DEV" 2>/dev/null)
"
        done
    else
        PARTITION_DATA=$(sgdisk -p "$DISK_DEV" 2>/dev/null) || true
        for part_num in $(echo "$PARTITION_DATA" | awk '{print $1}' | grep -E '^[0-9]+$'); do
            PARTITION_DETAIL="${PARTITION_DETAIL}===PART:${part_num}===
$(sgdisk -i "$part_num" "$DISK_DEV" 2>/dev/null)
"
        done
    fi

    local _part_detail_file="${OUTPUT_PATH}.partdetail"
    printf '%s' "$PARTITION_DETAIL" > "$_part_detail_file"

    python3 - "$TEMPLATE_PATH" "$OUTPUT_PATH" "$_part_detail_file" "$ROOT_SIZE_BYTES" << 'PYEOF' || { rm -f "$_part_detail_file"; die "Failed to generate dual-boot storage config"; }
import sys, re

template_path = sys.argv[1]
output_path = sys.argv[2]
part_detail_path = sys.argv[3]
root_size_bytes = sys.argv[4]

with open(template_path) as f:
    content = f.read()

with open(part_detail_path) as f:
    partition_detail_raw = f.read()

import os
os.unlink(part_detail_path)

# Parse sgdisk -i output for each partition
partition_info = {}
for section in partition_detail_raw.split('===PART:'):
    if not section.strip():
        continue
    header_match = re.match(r'(\d+)==', section)
    if header_match:
        p_num = int(header_match.group(1))
        partition_info[p_num] = section.split('\n', 1)[1] if '\n' in section else ''

# Extract exact byte sizes and type GUIDs for partitions 1-3 (preserved)
# Partition 4 (root) gets wipe: superblock with the pre-created size
sizes = {}
type_guids = {}
has_apfs = False

for p_num, info_text in partition_info.items():
    first_sector = None
    last_sector = None
    part_type_guid = ''

    for info_line in info_text.split('\n'):
        if 'Partition GUID code:' in info_line or 'Partition type GUID code:' in info_line or 'Partition type code:' in info_line:
            guid_match = re.search(r'([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})', info_line)
            if guid_match:
                part_type_guid = guid_match.group(1).lower()
        elif 'First sector:' in info_line:
            sector_match = re.search(r'(\d+)', info_line.split(':')[-1])
            if sector_match:
                first_sector = int(sector_match.group(1))
        elif 'Last sector:' in info_line:
            sector_match = re.search(r'(\d+)', info_line.split(':')[-1])
            if sector_match:
                last_sector = int(sector_match.group(1))

    if first_sector is not None and last_sector is not None and part_type_guid:
        sizes[p_num] = (last_sector - first_sector + 1) * 512
        type_guids[p_num] = part_type_guid
        if part_type_guid == '7c3457ef-0000-11aa-aa11-00306543ecac':
            has_apfs = True

if not has_apfs:
    print("ERROR: APFS container partition (GUID 7c3457ef-0000-11aa-aa11-00306543ecac) not found!", file=sys.stderr)
    print("Dual-boot requires preserving the macOS APFS container. Aborting.", file=sys.stderr)
    sys.exit(1)

# Verify partitions 1-3 exist (required for dual-boot)
for required_num in [1, 2, 3]:
    if required_num not in sizes:
        print(f"ERROR: Required partition {required_num} not found in GPT table!", file=sys.stderr)
        print("Dual-boot requires partitions 1 (ESP), 2 (APFS), and 3 (CIDATA) to exist.", file=sys.stderr)
        sys.exit(1)

# Replace the size placeholders in the template with actual values
# If ROOT_SIZE_BYTES is 0, auto-detect from partition 4 if it exists
root_size = int(root_size_bytes) if root_size_bytes and root_size_bytes != '0' else 0
if root_size == 0:
    # Check if partition 4 exists on disk (pre-created by create_root_partition)
    if 4 in sizes:
        root_size = sizes[4]
        print(f"  Auto-detected root partition 4 size: {root_size} bytes", file=sys.stderr)
    else:
        print("ERROR: ROOT_SIZE_BYTES=0 and no partition 4 found on disk!", file=sys.stderr)
        print("Either pre-create the root partition with create_root_partition(), or pass ROOT_SIZE_BYTES.", file=sys.stderr)
        sys.exit(1)

content = content.replace('__ROOT_SIZE_BYTES__', str(root_size))
content = content.replace('size: 209715200', f'size: {sizes[1]}')
content = content.replace('size: 49999998976', f'size: {sizes[2]}')
content = content.replace('size: 4999999488', f'size: {sizes[3]}')
if 5 in sizes:
    content = content.replace('size: 134217728', f'size: {sizes[5]}')
else:
    # No partition 5 (Recovery) found — remove the recovery partition entry
    import re
    content = re.sub(r'\n      - type: partition\n        id: recovery\n        device: root-disk\n        number: 5\n        size: 134217728\n        preserve: true\n        partition_type: 426f6f74-0000-11aa-aa11-00306543ecac', '', content)

# Log what we're preserving
for p_num in sorted(sizes.keys()):
    if p_num == 4 and root_size > 0:
        continue  # logged separately below
    size_gb = sizes[p_num] / (1024**3)
    print(f"  Partition {p_num}: {sizes[p_num]} bytes ({size_gb:.1f} GB), type: {type_guids.get(p_num, 'unknown')}", file=sys.stderr)
print(f"  Root partition (4): {root_size} bytes, preserve: true, wipe: superblock", file=sys.stderr)

with open(output_path, 'w') as f:
    f.write(content)

print(f"  Preserving {len([p for p in sizes if p != 4])} existing partitions (ESP + APFS + CIDATA + Recovery) + 1 root (preserve, wipe superblock)")
PYEOF
}
