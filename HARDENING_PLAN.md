# Mac Pro 2013 Ubuntu Autoinstall - Hardening Plan

## Overview

This document outlines the deployment strategy for Ubuntu 24.04 LTS on Mac Pro 2013 (MacPro6,1) with Broadcom BCM4360 WiFi as the only network interface.

## Current Status

### ✅ Verified Working

| Component | Status | Notes |
|-----------|--------|-------|
| Ubuntu 24.04.4 LTS ISO | Downloaded | `prereqs/ubuntu-24.04.4-live-server-amd64.iso` |
| Kernel 6.8.0-107 | Tested | Works with broadcom-sta-dkms from noble-updates |
| broadcom-sta-dkms 6.30.223.271-23ubuntu1.1 | Verified | DKMS successfully builds on 6.8.0-107 |
| Cloud-init autoinstall | Tested | Password hash fixed, works in VM |
| VirtualBox VM test | Working | SSH accessible via IP (not hostname) |

### ⚠️ Issues to Resolve

| Issue | Status | Priority |
|-------|--------|-----------|
| SSH hostname not resolving | Open | Medium |
| SSH key not imported | Open | Medium |
| CIDATA not embedded in ISO | Pending | High |
| Autoinstall kernel param not in GRUB | Pending | High |

---

## Hardening Strategy

### Layer 1: Driver Management (Primary)

**Approach:** DKMS with noble-updates

```yaml
# In user-data late-commands
late-commands:
  - |
    # Enable noble-updates for Broadcom driver
    echo "deb http://archive.ubuntu.com/ubuntu noble-updates main restricted universe multiverse" >> /target/etc/apt/sources.list.d/noble-updates.list
    chroot /target apt-get update
    DEBIAN_FRONTEND=noninteractive chroot /target apt-get install -y broadcom-sta-dkms
    echo "wl" >> /target/etc/etc/modules
```

**Why it works:**
- broadcom-sta-dkms 6.30.223.271-23ubuntu1.1 from noble-updates includes kernel 6.14+ patches
- DKMS automatically rebuilds driver on kernel updates
- No kernel pinning needed - security updates preserved

### Layer 2: Recovery Partition (Secondary)

**Concept:** Two installations on same disk

```
Partition Layout:
/dev/sda1 - 512MB - EFI System Partition (shared)
/dev/sda2 - 8GB - Recovery Ubuntu (minimal)
/dev/sda3 - remaining - Main Ubuntu (full)
```

**Recovery Partition Contents:**
- Minimal Ubuntu Server
- SSH server (enabled)
- broadcom-sta-dkms
- Network-Manager
- Same kernel version as main system
- `/opt/recover-main.sh` script

**When to use:**
- Main partition kernel breaks WiFi
- Main partition corrupted
- Need to chroot and repair

### Layer 3: Systemd Recovery Service (Tertiary)

**Concept:** Auto-repair driver on boot

```bash
# /etc/systemd/system/broadcom-check.service
[Unit]
Description=Check Broadcom driver status
After=network.target

[Service]
Type=oneshot
ExecStart=/opt/broadcom/check-driver.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

**Check script:**
```bash
#!/bin/bash
# /opt/broadcom/check-driver.sh
# Verify wl module loaded
# If not, attempt modprobe, then DKMS rebuild
# Log all failures to /var/log/broadcom-failure.log
```

---

## ISO Build Plan

### ISO Contents

```
/EFI/BOOT/
├── BOOTX64.EFI
├── grubx64.efi
└── grub.cfg                     # Modified with autoinstall params

/casper/
├── vmlinuz                      # Linux kernel
├── initrd                       # Initrd (original)
├── initrd-modified              # Initrd with cloud-init (optional)
└── cidata/                      # Embedded cloud-init
    ├── user-data
    ├── meta-data
    └── vendor-data

/casper/broadcom/                # Pre-downloaded packages (optional)
├── broadcom-sta-dkms_*.deb
├── linux-headers-*.deb
├── build-essential_*.deb
└── dkms_*.deb
```

### GRUB Configuration

```bash
# /EFI/BOOT/grub.cfg
set timeout=5
set default=0

menuentry "Ubuntu Server Autoinstall (Mac Pro 2013)" {
    linux /casper/vmlinuz autoinstall ds=nocloud console=tty1 console=ttyS0,115200n8 quiet ---
    initrd /casper/initrd
}

menuentry "Ubuntu Server Autoinstall (Mac Pro 2013 - Debug)" {
    linux /casper/vmlinuz autoinstall ds=nocloud debug console=tty1 console=ttyS0,115200n8 ---
    initrd /casper/initrd
}

menuentry "Ubuntu Server (Manual Install)" {
    linux /casper/vmlinuz ---
    initrd /casper/initrd
}
```

### Build Process (Run in VM)

```bash
# 1. Extract Ubuntu ISO
# 2. Modify GRUB config
# 3. Embed cidata directory
# 4. Add Broadcom packages
# 5. Rebuild ISO with xorriso
```

---

## VM Issues Investigation

### Issue 1: SSH Hostname Not Resolving

**Symptom:** `ssh teja@macpro-linux.local` fails, but `ssh teja@192.168.1.132` works.

**Root Cause FOUND:**
- Avahi/mDNS daemon not installed
- `/etc/nsswitch.conf` missing `mdns_minimal` in hosts line
- Current: `hosts: files dns`
- Required: `hosts: files mdns_minimal [NOTFOUND=return] dns`

**Current VM State:**
```
/etc/hostname: macpro-linux
/etc/hosts: 127.0.1.1 macpro-linux
/etc/nsswitch.conf: hosts: files dns  (MISSING mdns)
Avahi: NOT INSTALLED
```

**Fix Applied:**
```bash
# Install Avahi for mDNS
sudo apt-get install -y avahi-daemon libnss-mdns

# Update nsswitch.conf
sudo sed -i 's/^hosts:.*/hosts: files mdns_minimal [NOTFOUND=return] dns/' /etc/nsswitch.conf

# Restart services
sudo systemctl restart avahi-daemon
sudo systemctl restart systemd-resolved
```

**Prevention (in ISO):**
```yaml
packages:
  - avahi-daemon
  - libnss-mdns

late-commands:
  - |
    # Configure mDNS for hostname resolution
    sed -i 's/^hosts:.*/hosts: files mdns_minimal [NOTFOUND=return] dns/' /target/etc/nsswitch.conf
```

### Issue 2: SSH Key Not Imported

**Symptom:** SSH key from `~/.ssh/id_ed25519.pub` not authorized on VM.

**Root Cause FOUND:**
- Cloud-init user-data did not include `ssh.authorized-keys`
- No `~/.ssh/` directory exists on VM
- Only password authentication is configured

**Current VM State:**
```
~/.ssh/: DOES NOT EXIST
~/.ssh/authorized_keys: DOES NOT EXIST
/etc/ssh/sshd_config: PasswordAuthentication yes (correct)
```

**Fix Applied:**
```bash
# Create .ssh directory
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# Add authorized key
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOQ37O+h9gTmyE/z8eWMWflSDEzbZz/ojoEkalinYc06 teja@MacBookPro" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

**Prevention (in ISO user-data):**
```yaml
ssh:
  install-server: true
  allow-pw: true
  authorized-keys:
    - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOQ37O+h9gTmyE/z8eWMWflSDEzbZz/ojoEkalinYc06 teja@MacBookPro
```

### Issue 3: Hostname -A Shows Extra Names

**Symptom:** `hostname -A` shows `MacBookPro MacBookPro.attlocal.net`

**Root Cause:** VirtualBox network adapters have their own hostnames that get reported.

**Impact:** Cosmetic only - not affecting functionality.

**Note:** This is a VirtualBox artifact and won't occur on real Mac Pro hardware.

---

## Cloud-Init user-data (Hardened)

```yaml
#cloud-config
autoinstall:
  version: 1
  
  refresh-installer:
    update: yes
  
  early-commands:
    - |
      exec > /run/autoinstall-early.log 2>&1
      set -x
      echo "=== MAC PRO 2013 AUTOINSTALL START ==="
      date
      uname -r
      
      # Load Broadcom driver if available
      modprobe wl 2>/dev/null || true
      
      # Log storage.devices
      lsblk
  
  locale: en_US.UTF-8
  keyboard:
    layout: us
  
  identity:
    hostname: macpro-linux
    username: teja
    realname: Teja
    password: "$6$Jd1fuxxdGTbhQzQp$O.95tZaKnLatjbbw.p2NIZsZwH1KFlmwMafxr73CvqOsDZWAgNmI7aznjXu.8CXobh/gfGyYQcu/iNC5Qa7dL1"
  
  ssh:
    install-server: true
    allow-pw: true
    authorized-keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOQ37O+h9gTmyE/z8eWMWflSDEzbZz/ojoEkalinYc06 teja@MacBookPro
  
  packages:
    - openssh-server
    - linux-headers-generic
    - build-essential
    - dkms
    - network-manager
    - wireless-tools
    - firmware-linux
    - avahi-daemon
    - libnss-mdns
  
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
  
  network:
    version: 2
    ethernets:
      any-ethernet:
        match:
          name: "e*"
        dhcp4: true
    wifis:
      any-wifi:
        match:
          name: "wlp*"
        dhcp4: true
  
  grub:
    reorder_uefi: false
  
  late-commands:
    - |
      exec > /target/var/log/autoinstall-late.log 2>&1
      set -x
      echo "=== LATE COMMANDS START ==="
      date
      
      # Enable noble-updates for Broadcom driver
      echo "deb http://archive.ubuntu.com/ubuntu noble-updates main restricted universe multiverse" >> /target/etc/apt/sources.list.d/noble-updates.list
      
      # Update and install Broadcom driver
      chroot /target apt-get update
      DEBIAN_FRONTEND=noninteractive chroot /target apt-get install -y broadcom-sta-dkms
      
      # Load on boot
      echo "wl" >> /target/etc/modules
      
      # Configure SSH
      chroot /target ssh-keygen -A
      sed -i 's/#PasswordAuthentication.*/PasswordAuthentication yes/' /target/etc/ssh/sshd_config
      sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /target/etc/ssh/sshd_config
      sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /target/etc/ssh/sshd_config
      
      # Configure sudo
      echo "teja ALL=(ALL) NOPASSWD:ALL" >> /target/etc/sudoers.d/teja
      chmod 440 /target/etc/sudoers.d/teja
      
      # Enable mDNS for hostname resolution
      sed -i 's/^hosts:.*/hosts: files mdns_minimal [NOTFOUND=return] dns/' /target/etc/nsswitch.conf
      
      # Create WiFi setup script
      cat > /target/opt/setup-wifi.sh << 'WIFIEOF'
#!/bin/bash
# Usage: /opt/setup-wifi.sh SSID PASSWORD
INTERFACE=$(ip link show | grep -o 'wlp[^:]*' | head -1)
if [ -z "$INTERFACE" ]; then
  echo "No WiFi interface found"
  exit 1
fi
nmcli device wifi connect "$1" password "$2"
WIFIEOF
      chmod +x /target/opt/setup-wifi.sh
      
      # Create network diagnostics script
      cat > /target/opt/network-diag.sh << 'DIAGEOF'
#!/bin/bash
echo "=== Network Diagnostics ==="
date
echo "Interfaces:"
ip link show
echo "WiFi devices:"
ip link show | grep -E 'wl|wlp'
echo "Loaded modules:"
lsmod | grep -E 'wl|wifi|80211'
echo "Kernel:"
uname -r
echo "PCI network devices:"
lspci | grep -i network
DIAGEOF
      chmod +x /target/opt/network-diag.sh
      
      echo "=== LATE COMMANDS END ==="
  
  error-commands:
    - |
      exec > /target/var/log/autoinstall-error.log 2>&1
      set -x
      echo "=== ERROR DUMP ==="
      date
      echo "--- Packages ---"
      dpkg -l
      echo "--- Modules ---"
      lsmod
      echo "--- Network ---"
      ip addr show
      echo "--- Installer logs ---"
      cat /var/log/installer/subiquity-server-debug.log 2>/dev/null || true
      cat /var/log/curtin/install.log 2>/dev/null || true
```

---

## Next Steps

1. [ ] Fix SSH hostname resolution in VM (mDNS/Avahi)
2. [ ] Fix SSH key import in cloud-init
3. [ ] Create ISO build script
4. [ ] Build modified ISO
5. [ ] Test autoinstall in VM with new ISO
6. [ ] Deploy to Mac Pro 2013 hardware

---

## References

- Broadcom driver research: `broadcom-sta-dkms 6.30.223.271-23ubuntu1.1` from noble-updates
- Kernel compatibility: Tested on 6.8.0-107-generic
- Ubuntu release: 24.04.4 LTS (Noble Numbat)