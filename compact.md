# Ubuntu Autoinstall for Mac Pro 2013 - Session Summary

## 1. Primary Request and Intent

**Goal:** Deploy Ubuntu 24.04.1 LTS headlessly on a Mac Pro 2013 (MacPro6,1) with Broadcom BCM4360 WiFi as the ONLY network interface. No monitor/keyboard/mouse available (fully headless deployment).

**Key Constraints:**
- WiFi is the only network option (no Ethernet on Mac Pro)
- Must be fully automated (no manual confirmation prompts)
- Test on VirtualBox VM first before deploying to actual Mac Pro hardware

## 2. Key Technical Concepts

- **Ubuntu 24.04.1 LTS Server autoinstall** (cloud-init)
- **NoCloud datasource** for cloud-init configuration
- **Broadcom BCM4360 WiFi driver** (wl.ko kernel module for kernel 6.8.0-41)
- **VirtualBox UEFI boot** configuration
- **GRUB kernel parameters** (`autoinstall ds=nocloud`)
- **CIDATA ISO** for cloud-init seed
- **UEFI System Partition (ESP)** - Required for UEFI boot with `grub_device: true` on partition

## 3. Files and Code Sections

### Working cloud-init user-data (`/tmp/cidata/user-data`)

```yaml
#cloud-config
autoinstall:
  version: 1
  early-commands:
    - |
      echo "=== EARLY COMMANDS START ===" > /run/autoinstall.log
      echo "Storage devices:" >> /run/autoinstall.log
      lsblk >> /run/autoinstall.log 2>&1
  identity:
    hostname: macpro-linux
    password: "$6$rounds=4096$saltsalt$PwYJqQJQJqJqJqJqJqJqJqJqJqJqJqJqJqJqJqJqJqJqJqJqJqJqJqJqJqJqJqJqJqJqJq"
    username: teja
    realname: Teja
  ssh:
    install-server: true
    allow-pw: true
  packages:
    - openssh-server
    - linux-headers-generic
    - build-essential
    - dkms
    - network-manager
    - wireless-tools
  grub:
    reorder_uefi: false
  storage:
    config:
      - type: disk
        id: root-disk
        path: /dev/sda
        ptable: gpt
        wipe: superblock-recursive
        preserve: false
      - type: partition
        id: efi-partition
        device: root-disk
        size: 512M
        flag: boot
        partition_type: EF00
        grub_device: true  # MUST be on partition, not disk
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
        id: root-partition
        device: root-disk
        size: -1
        number: 2
      - type: format
        id: root-format
        volume: root-partition
        fstype: ext4
      - type: mount
        id: root-mount
        device: root-format
        path: /
  late-commands:
    - |
      echo "=== LATE COMMANDS START ===" > /target/autoinstall.log
      mkdir -p /target/opt/broadcom
      cp -r /cdrom/casper/broadcom/* /target/opt/broadcom/ 2>> /target/autoinstall.log || echo "COPY FAILED" >> /target/autoinstall.log
      echo "teja ALL=(ALL) NOPASSWD:ALL" >> /target/etc/sudoers.d/teja
  error-commands:
    - |
      cp /var/log/installer/subiquity-server-debug.log /target/autoinstall-error.log 2>/dev/null || true
```

**Key fix:** Using `|` block scalar for shell commands to prevent YAML parsing errors with `$(date)` etc.

### meta-data (`/tmp/cidata/meta-data`)

```yaml
instance-id: macpro-linux-001
local-hostname: macpro-linux
```

### Modified GRUB config (`/tmp/ubuntu-extract/EFI/BOOT/grub.cfg`)

```
set timeout=5

menuentry "Ubuntu Server Autoinstall (Broadcom WiFi)" {
    linux /casper/vmlinuz autoinstall ds=nocloud quiet ---
    initrd /casper/initrd
}

menuentry "Try or Install Ubuntu Server" {
    linux /casper/vmlinuz  ---
    initrd /casper/initrd
}
```

### VirtualBox Files

- `~/Desktop/Mac/vbox-test/cidata.iso` - Cloud-init seed ISO
- `~/Desktop/Mac/vbox-test/ubuntu-test.vdi` - Target disk for installation
- `~/Desktop/Mac/prereqs/ubuntu-24.04.1-live-server-amd64.iso` - Original Ubuntu ISO
- `~/Desktop/Mac/prereqs/initrd-modified` - Initrd with embedded wl.ko
- `~/Desktop/Mac/prereqs/wl-6.8.0-41.ko` - Broadcom WiFi driver

## 4. Problem Solving

### Solved Problems:

1. **Language selection prompt** - CIDATA ISO with `ds=nocloud` kernel parameter
2. **"Failed to find matching device for {'size': 'largest'}"** - Use explicit `path: /dev/sda` instead of match spec
3. **"Failed to find matching device for {}"** - Use explicit disk path, not empty match
4. **"autoinstall config did not create needed bootloader partition"** - UEFI requires `grub_device: true` on ESP partition with `partition_type: EF00`
5. **YAML parsing error in error-commands** - Use `|` block scalar for multiline shell commands
6. **Logs extraction from VM** - Used Python HTTP server to receive `curl -T` uploads from VM

### Ongoing Issues:

1. **Creating bootable modified Ubuntu ISO** - Multiple failed attempts with xorriso, hdiutil, grub-mkrescue
2. **GRUB not picking up autoinstall kernel parameter** - Need to modify ISO's EFI/BOOT/grub.cfg

## 5. Pending Tasks

1. Complete current installation by typing "yes" at the autoinstall confirmation prompt
2. After installation, edit GRUB to add `autoinstall ds=nocloud` kernel parameters
3. Test automatic reboot without confirmation prompt
4. Create bootable ISO or disk image for Mac Pro deployment
5. Deploy to actual Mac Pro 2013 hardware

## 6. Current Work

**VM State:** VirtualBox VM "Ubuntu-MacPro-Test" is running with:
- IDE Port 0, Unit 0: Ubuntu 24.04.1 ISO
- IDE Port 1, Unit 0: cidata.iso (cloud-init seed)

**Immediate Action Required:** User needs to type `yes` at the `Continue with autoinstall? (yes|no)` prompt in the VirtualBox window.

## 7. Next Steps (After Installation Completes)

**Step 1: Edit GRUB configuration**

```bash
sudo nano /etc/default/grub
```

Find and change:
```
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
```
To:
```
GRUB_CMDLINE_LINUX_DEFAULT="autoinstall ds=nocloud quiet"
```

**Step 2: Update GRUB**

```bash
sudo update-grub
sudo reboot
```

**Step 3: Create final ISO for Mac Pro**

Once confirmed working, create a bootable modified Ubuntu ISO:
1. Extract Ubuntu ISO
2. Modify `EFI/BOOT/grub.cfg` with autoinstall kernel parameter
3. Rebuild ISO using proper UEFI boot structure
4. Include cidata.iso as second CD or embed cloud-init files

## 8. Correct Configuration Summary

**Kernel Parameter (GRUB):**
```
autoinstall ds=nocloud quiet ---
```

**CIDATA ISO location:** `~/Desktop/Mac/vbox-test/cidata.iso`

**VM Configuration:**
- Memory: 4GB
- CPUs: 2
- Firmware: EFI
- Network: NAT

**Credentials (after installation):**
- Username: `teja`
- Password: `ubuntu-admin-2024`
- SSH: `ssh teja@macpro-linux.local`

## 9. Lessons Learned

1. **YAML block scalars (`|`)** are essential for shell commands in cloud-init to prevent parsing errors
2. **UEFI boot requires ESP partition** with `grub_device: true` and `partition_type: EF00`
3. **VirtualBox UEFI reads `EFI/BOOT/grub.cfg`** not `boot/grub/grub.cfg`
4. **Serial logging** (`console=ttyS0,115200n8`) captures kernel output but not installer logs
5. **Creating bootable UEFI ISOs on macOS** is extremely difficult due to filesystem limitations
6. **Manual confirmation approach** is fastest path forward for this use case