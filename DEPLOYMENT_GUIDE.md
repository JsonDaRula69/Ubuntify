# Mac Pro 2013 → Ubuntu 24.04.1 Deployment Guide

## Overview

This guide deploys Ubuntu Server 24.04.1 on a **headless Mac Pro 2013** with Broadcom BCM4360 WiFi. The deployment is **fully automated** and **destructive** (macOS will be erased).

### The Challenge

Standard Ubuntu installation fails on this hardware because:
1. **No Ethernet port** - Only WiFi available
2. **No physical access** - Completely headless (no monitor/keyboard)
3. **Proprietary WiFi driver** - Broadcom BCM4360 requires `wl` driver not included in installer

### The Solution

Pre-compile the WiFi driver and embed it into the installer's initramfs, allowing WiFi to work from boot.

### Key Points

- **Prerecorded files required** - All files must be synced from MacBook to Mac Pro before starting
- **No internet during install** - Everything needed is in the `prereqs/` folder
- **No user input** - Installation is 100% automated via cloud-init autoinstall
- **No rEFInd** - Uses Mac's native `bless` command for headless boot
- **One-way installation** - macOS is erased, no rollback possible

---

## Prerequisites

- Mac Pro 2013 and MacBook Pro on same WiFi network
- SSH access to Mac Pro working
- Files in `~/Desktop/Mac/` on both machines
- **Ubuntu ISO pre-extracted** (macOS cannot mount this ISO format)
- **No rEFInd required** - uses Mac's native `bless` command for headless boot
- **Python 3 with passlib** - Required for password hash generation

### System Requirements

The preparation script requires:

| Requirement | Purpose | How to Install |
|------------|---------|----------------|
| Python 3 | Password hash generation | Built-in on macOS / `xcode-select --install` |
| passlib | SHA-512 password hashes | `pip3 install passlib --user` |
| diskutil | Partition management | Built-in on macOS |
| curl | Webhook notifications | Built-in on macOS |
| rsync | File copying | Built-in on macOS |

### Pre-Extract the Ubuntu ISO (Required on macOS Monterey)

The Ubuntu 24.04.1 ISO uses UDF filesystem which macOS cannot mount. You must pre-extract it:

```bash
# On MacBook or Mac Pro (requires 7zip)
cd ~/Desktop/Mac/prereqs

# Install 7zip if needed
brew install p7zip

# Extract the ISO
7z x ubuntu-24.04.1-live-server-amd64.iso -oubuntu-iso -y
```

This creates `prereqs/ubuntu-iso/` with all installer files.

### Install Password Hashing Dependencies

The script uses SHA-512 password hashing, which requires passlib on macOS:

```bash
# Install passlib (required for password hash generation)
pip3 install passlib --user

# Verify installation
python3 -c "from passlib.hash import sha512_crypt; print('✓ passlib installed')"
```

**Note:** If passlib is not available, the script will automatically attempt to install it. On macOS, the built-in `crypt` module produces invalid SHA-512 hashes (only 13 characters), so passlib is required for proper password authentication.

### Verify Prerequisites

Before running the preparation script, verify:

```bash
# Check passlib
python3 -c "from passlib.hash import sha512_crypt; h = sha512_crypt.using(rounds=5000).hash('test'); print(f'✓ Hash length: {len(h)} (should be 100+)')"
# Expected: Hash length: 106 (should be 100+)

# Check files exist
ls ~/Desktop/Mac/prereqs/ubuntu-iso/      # Should show ISO contents
ls ~/Desktop/Mac/prereqs/*.deb | wc -l      # Should be 28-30
ls ~/Desktop/Mac/prereqs/initrd-modified   # Should be ~69MB
ls ~/Desktop/Mac/prereqs/wl-6.8.0-41.ko   # Should be ~7.2MB

# Verify checksums (automatic in script, but you can check manually)
shasum -a 256 ~/Desktop/Mac/prereqs/initrd-modified
shasum -a 256 ~/Desktop/Mac/prereqs/wl-6.8.0-41.ko
```

---

## Deployment Steps

### Step 0: Sync Files to Mac Pro

Before starting, sync all files from MacBook to Mac Pro:
```bash
rsync -avz --progress ~/Desktop/Mac/ macpro:~/Desktop/Mac/
```

**Important Files to Verify:**
- `prereqs/ubuntu-iso/` directory must exist (pre-extracted ISO)
- Checksums verified automatically by script

---

### Step 1: Start Monitoring Server (MacBook)

```bash
cd ~/Desktop/Mac/macpro-monitor
./start.sh
```

Open in browser: http://localhost:8080

**Note**: The monitoring server must be reachable from the Mac Pro. The script will:
- Try mDNS hostname first (`Tejas-MacBook-Pro.local`)
- Fall back to IP address if mDNS fails

---

### Step 2: Run Preparation Script (Mac Pro)

SSH into Mac Pro:
```bash
ssh teja@Tejas-Mac-Pro.local
```

Run the preparation script:
```bash
sudo ~/Desktop/Mac/prepare_ubuntu_install_final.sh
```

This will:
1. **Verify Prerequisites** - Check all required files exist
2. **Verify WiFi Network** - Scan for target WiFi network (prompts if not found)
3. **Detect Monitoring Server** - Try mDNS, fall back to IP address
4. **Copy Driver Packages** - From `prereqs/` to temporary directory
5. **Verify Pre-Extracted ISO** - Check `prereqs/ubuntu-iso/` exists with required files
6. **Mount Partitions** - Find and mount UBUNTU-TEMP
7. **Copy Ubuntu Files** - From pre-extracted ISO to partition
8. **Replace Initramfs** - With WiFi-enabled version
9. **Embed Driver Packages** - DKMS and dependencies
10. **Create Autoinstall Configuration** - user-data and meta-data
11. **Create Boot Configuration** - GRUB and EFI settings

---

### Step 3: Enable Boot Entry (Mac Pro)

After script completes:
```bash
sudo /tmp/enable_ubuntu_boot.sh
```

This uses Mac's native `bless` command to set UBUNTU-TEMP as the default boot volume.

⚠️ **WARNING**: Next reboot will ERASE macOS and install Ubuntu.

---

### Step 4: Reboot (Mac Pro)

```bash
sudo reboot
```

---

### Step 5: Monitor Installation (MacBook)

Watch progress at http://localhost:8080

**Monitoring Features:**
- Real-time progress tracking (0-100%)
- Phase detection (PREP vs INSTALL)
- Stall detection (warns at 5 minutes, alerts at 15 minutes with no update)
- Configuration display (hostname, username, WiFi SSID)
- IP address capture on completion

**Stall Detection:**
- If no webhook received for 5+ minutes: Yellow warning displayed
- If no webhook received for 15+ minutes: Red "STALLED INSTALLATION" alert
- Check Mac Pro status if stalled (may indicate hardware issue or network problem)

Installation takes ~15-20 minutes.

---

### Step 6: Connect (MacBook)

After installation completes:

```bash
ssh teja@macpro-linux.local
```

Password: `ubuntu-admin-2024`

**If SSH fails:**
1. Wait longer (installation may still be running)
2. Check the monitoring dashboard for completion status
3. Verify the user-data file was generated correctly:
   ```bash
   # On Mac Pro before reboot, verify password hash length:
   cat /Volumes/UBUNTU-TEMP/user-data | grep "password:" | head -1
   # Should show: password: "$6$salt$long_hash" (100+ characters)
   # NOT: password: "$6$short_hash" (should NOT be < 30 characters)
   ```

---

## Verification

On the new Ubuntu system:

```bash
# Check WiFi interface
ip addr show wlan0

# Check driver loaded
lsmod | grep wl

# Check connectivity
ping google.com

# Check DKMS status
dkms status
```

---

## Troubleshooting

### Can't SSH In

1. Wait longer (installation may still be running)
2. Check router for IP address
3. Try hostname: `macpro-linux.local`
4. Check mDNS: `avahi-browse -art | grep macpro`

### WiFi Not Working

```bash
# Check if interface exists
ip link show

# Load driver manually
sudo modprobe wl

# Check driver status
dkms status

# View recovery logs
cat /var/log/syslog | grep wifi-recovery
```

### SSH Key Issues

On MacBook:
```bash
# Remove old host key
ssh-keygen -R macpro-linux.local

# Add new host key
ssh-keyscan -H macpro-linux.local >> ~/.ssh/known_hosts
```

---

## Quick Reference

| Item | Value |
|------|-------|
| Hostname | `macpro-linux.local` |
| Username | `teja` |
| Password | `ubuntu-admin-2024` |
| WiFi SSID | `ATTj6pXatS` |
| Monitor URL | http://localhost:8080 |

---

## What Happens During Installation

1. Mac Pro boots from UBUNTU-TEMP partition (via `bless` command)
2. GRUB loads kernel + modified initramfs with embedded WiFi driver
3. Ubuntu installer starts with `wl` module pre-loaded in kernel
4. WiFi connects automatically (credentials in user-data)
5. Autoinstall runs without user input:
   - Partitions disk (erases macOS)
   - Installs Ubuntu Server
   - Configures WiFi (netplan)
   - Installs SSH server + SSH key
   - Installs Broadcom driver via DKMS
   - Creates wifi-recovery service
   - Installs Avahi/mDNS for hostname access
6. Webhook reports completion with IP address
7. System reboots into Ubuntu

---

## Files on UBUNTU-TEMP

```
/Volumes/UBUNTU-TEMP/
├── casper/
│   ├── vmlinuz                    # Linux kernel (from ISO)
│   ├── initrd                     # Modified (WiFi-enabled)
│   ├── initrd.original            # Backup of original
│   └── broadcom/                  # Driver packages
│       ├── wl.ko                   # Pre-compiled driver
│       └── *.deb (30 packages)    # DKMS + build deps
├── EFI/BOOT/                      # EFI boot files (from ISO)
│   ├── BOOTX64.EFI               # shim bootloader
│   └── grubx64.efi                # GRUB EFI binary
├── EFI/ubuntu/grub.cfg            # GRUB config (updated)
├── boot/grub/grub.cfg             # GRUB config
├── user-data                      # Autoinstall config
└── meta-data                      # Instance info
```

---

## What Happens When the Script Runs

When `prepare_ubuntu_install_final.sh` executes on the Mac Pro:

1. **Prerequisites Check** - Verifies all files in `prereqs/` exist
   - Verifies `prereqs/ubuntu-iso/` directory exists (pre-extracted)
   - Validates SHA256 checksums of `initrd-modified` and `wl-6.8.0-41.ko`
   - Checks for critical `.deb` packages
2. **WiFi Network Verification** - Scans for target WiFi network visibility
   - Uses `airport` utility to list available networks
   - Falls back to `networksetup` if airport unavailable
   - Prompts user if target network not found
3. **Monitoring Server Detection** - Detects webhook server reachability
   - Tries mDNS hostname first (`Tejas-MacBook-Pro.local`)
   - Falls back to hardcoded IP address if mDNS fails
   - Continues if no monitoring server available
4. **Copy Driver Packages** - Copies `.deb` files to temp directory
5. **Verify Pre-Extracted ISO** - Confirms `prereqs/ubuntu-iso/` has required files
6. **Mount Partitions** - Finds and mounts UBUNTU-TEMP
7. **Copy Ubuntu Files** - Copies pre-extracted files from `prereqs/ubuntu-iso/`
8. **Replace Initramfs** - Backs up original, copies modified version with embedded WiFi driver
9. **Embed Driver Packages** - Copies DKMS packages to `casper/broadcom/`
10. **Create Autoinstall Configuration** - Generates `user-data` and `meta-data`
11. **Create Boot Configuration** - Updates GRUB config, sets up EFI boot
12. **Generate Enable Script** - Creates `/tmp/enable_ubuntu_boot.sh` with `bless` commands

### Progress Tracking

The script sends webhook updates to the monitoring server at each stage:

| Progress | Status | Message |
|----------|--------|---------|
| 0% | starting | Mac Pro Ubuntu preparation started |
| 5% | copying | Copying driver packages from local storage |
| 10% | copied | Driver packages copied |
| 20% | iso_ready | Ubuntu ISO verified |
| 30% | partitions_ready | Partitions mounted |
| 30% | extracted | Ubuntu ISO files found |
| 40% | copied | Ubuntu files copied to partition |
| 45% | initrd_replaced | Initramfs replaced with WiFi driver |
| 50% | drivers_embedded | Broadcom driver packages embedded |
| 60% | config_ready | Autoinstall configuration created |
| 70% | boot_config | Creating boot configuration |
| 80% | boot_ready | Boot configuration created |
| 90% | ready | Preparation complete |
| 100% | waiting_reboot | Ready for reboot |

**Installation Progress** (during Ubuntu install):

| Stage | Status | Message |
|-------|--------|---------|
| 7 | complete | Installation complete |
| error | failed | Installation failed |

### Error Handling

If installation fails, the system will:
1. Send failure webhook to monitoring server (both mDNS and fallback IP)
2. Display error message on console
3. Shut down after 5 seconds

The monitoring dashboard will show "failed" status if an error occurs.

---

## Why Files Must Be Synced First

The Mac Pro needs all files locally **before** the script runs because:

1. **No internet during preparation** - Mac Pro is still running macOS, which can't access the network during script execution
2. **No internet during install** - Ubuntu installer needs WiFi driver, which is in `initrd-modified`
3. **Large files** - ISO is 2.6 GB, can't be downloaded quickly
4. **Cannot generate modified initrd** - Requires Linux environment with kernel headers

### Sync Command

```bash
# From MacBook (before starting):
rsync -avz --progress ~/Desktop/Mac/ macpro:~/Desktop/Mac/

# Verify sync on Mac Pro:
ssh macpro 'ls ~/Desktop/Mac/prereqs/*.deb | wc -l'
# Should output: 30
```

---

## If Something Goes Wrong

### Recovery Method 1: Check WiFi Recovery Service

The system automatically runs `wifi-recovery.service` on boot. Check logs:
```bash
ssh teja@macpro-linux.local 'journalctl -u wifi-recovery'
```

### Recovery Method 2: DKMS Rebuild

If driver isn't loaded:
```bash
sudo dkms install broadcom-sta/6.30.223.271 -k $(uname -r)
sudo modprobe wl
```

### Recovery Method 3: Physical Access

If all else fails, connect a monitor and keyboard to diagnose directly.

---

## Pre-Flight Checks

**Before running the script**, the system performs these checks:

1. **Prerequisites Directory** - Verifies `prereqs/` exists
2. **Pre-Extracted ISO** - Verifies `prereqs/ubuntu-iso/` exists
3. **Checksum Verification** - Validates `initrd-modified` and `wl-6.8.0-41.ko`
4. **Critical Packages** - Checks for required `.deb` files
5. **WiFi Network Visibility** - Scans for target SSID using `airport` or `networksetup`
6. **Monitoring Server Reachability** - Tests mDNS and fallback IP
7. **Password Hashing Capability** - Verifies passlib is available for SHA-512 hashes

**If passlib is not installed:**
- Script attempts automatic installation via `pip3 install passlib --user`
- If installation fails, falls back to MD5 hashing (less secure, but functional)
- Validates hash length to ensure it's valid for Ubuntu authentication

**If WiFi network not found:**
- Script lists available networks
- Prompts user to continue or abort
- Allows proceeding at user's own risk

**If monitoring server unreachable:**
- Continues without webhook tracking
- User sees warning but installation proceeds

---

## Success Indicators

- ✅ Prerequisites verified automatically
- ✅ Password hashing capability checked (passlib installed or MD5 fallback)
- ✅ WiFi network scanned and confirmed visible
- ✅ Monitoring server reachable (mDNS or IP fallback)
- ✅ Installer boots from UBUNTU-TEMP
- ✅ Webhook shows progress on dashboard throughout installation
- ✅ Password hash length validated (100+ chars for SHA-512, 30+ for MD5)
- ✅ Installation completes in ~15-20 minutes
- ✅ Failure webhook sent if errors occur
- ✅ SSH connects: `ssh teja@macpro-linux.local`
- ✅ Password works (uses SHA-512 hash from passlib)
- ✅ WiFi works: `ping google.com`
- ✅ Driver loaded: `lsmod | grep wl`
- ✅ DKMS status: `broadcom-sta ... installed`

---

## After Installation

### Set New Password

```bash
passwd
```

### Update System

```bash
sudo apt update && sudo apt upgrade -y
```

### Verify Kernel

```bash
uname -r
# Should show: 6.8.0-41-generic (or newer with DKMS rebuild)
```

### Install Additional Tools

```bash
sudo apt install -y htop tmux vim git curl wget
```

---

## Notes

- The Broadcom driver will automatically rebuild when kernel updates
- WiFi recovery service ensures headless operation
- mDNS allows `hostname.local` addressing
- All driver packages are kept locally for recovery