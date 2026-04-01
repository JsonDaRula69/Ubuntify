# Mac Pro 2013 Ubuntu 24.04.1 Deployment - Technical Overview

## Executive Summary

This document describes a solution for deploying Ubuntu Server 24.04.1 on a **headless Mac Pro 2013** with Broadcom BCM4360 WiFi. The deployment:

- **Requires no physical access** (no monitor/keyboard)
- **Uses only WiFi** (no Ethernet available)
- **Erases macOS completely** (destructive, one-way installation)
- **Is fully automated** (no user input during installation)
- **Uses Apple's native bootloader** (no rEFInd or third-party tools)

### What You Need Before Starting

All required files are pre-prepared in the `prereqs/` directory:

| File | Size | Purpose |
|------|------|---------|
| `ubuntu-24.04.1-live-server-amd64.iso` | 2.6 GB | Ubuntu installer ISO (source) |
| `ubuntu-iso/` | 2.6 GB | Pre-extracted ISO contents |
| `initrd-modified` | 69 MB | Modified initramfs with embedded WiFi driver |
| `wl-6.8.0-41.ko` | 7.6 MB | Pre-compiled Broadcom WiFi driver |
| `*.deb` (30 packages) | ~200 MB | DKMS, build tools, kernel headers |

**System Requirements:**
- Python 3 with passlib library (`pip3 install passlib --user`)
- Standard macOS command-line tools (diskutil, curl, rsync)

**These files were prepared in advance** - the WiFi driver was compiled inside an Ubuntu 24.04.1 VM (macOS cannot compile Linux kernel modules), and the Ubuntu ISO must be pre-extracted because macOS cannot mount it natively.

### What Happens During Deployment

1. **Preparation Phase** (Mac Pro, ~5 minutes):
   - Copies pre-extracted ISO files to UBUNTU-TEMP partition
   - Replaces initramfs with WiFi-enabled version
   - Configures autoinstall (WiFi credentials, SSH key)
   - Sets up boot using `bless` command

2. **Installation Phase** (Mac Pro, ~15-20 minutes):
   - Boots from modified installer (WiFi driver pre-loaded)
   - Connects to WiFi automatically (credentials embedded)
   - Installs Ubuntu Server (no user input)
   - Reports completion via webhook
   - Reboots into Ubuntu

3. **Post-Install**:
   - SSH accessible via `macpro-linux.local`
   - WiFi auto-connects on every boot (wifi-recovery.service)
   - DKMS rebuilds driver for kernel updates

---

## The Challenge

Deploying Ubuntu 24.04.1 on a headless 2013 Mac Pro with Broadcom BCM4360 WiFi presented a unique set of challenges that required a carefully orchestrated solution.

### The Core Problem

A typical Ubuntu installation expects:
- Network connectivity during installation
- Physical access (monitor/keyboard) for troubleshooting
- Ethernet as a fallback for driver installation

The Mac Pro 2013 has:
- **No physical access** (completely headless)
- **No working Ethernet** (only WiFi available)
- **Broadcom BCM4360 WiFi** requiring proprietary `wl` driver

This creates a chicken-and-egg problem: the installer needs network to download the WiFi driver, but the WiFi driver must be installed before network works.

---

## Why the Standard Approach Fails

### Ubuntu's Default Behavior

When you boot the Ubuntu Server 24.04.1 installer:
1. The kernel loads with open-source drivers only
2. Broadcom BCM4360 is NOT supported by open-source drivers (b43, brcmsmac don't support this chipset)
3. The proprietary `wl` driver from `broadcom-sta-dkms` package is required
4. Installer attempts to download packages from the internet
5. **FAILS**: No network available because WiFi driver isn't loaded

### Why DKMS Alone Doesn't Work

DKMS (Dynamic Kernel Module Support) is designed to rebuild drivers when kernels update. However:
- DKMS requires the driver to be installed AFTER the base system is installed
- The installer needs network BEFORE the base system is installed
- Result: Catch-22 situation

---

## Our Solution: Pre-compiled Driver Injection

### Overview

We solved this by pre-compiling the `wl.ko` kernel module and injecting it directly into the installer's initramfs. This allows WiFi to work during installation.

### The Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    PREPARATION PHASE                             │
│                    (on MacBook/VM)                               │
├─────────────────────────────────────────────────────────────────┤
│  1. Ubuntu 24.04.1 Server ISO                                   │
│     └─ Kernel: 6.8.0-41-generic                                 │
│                                                                  │
│  2. Compile wl.ko for kernel 6.8.0-41                           │
│     └─ Source: broadcom-sta-dkms 6.30.223.271                   │
│     └─ Environment: Ubuntu 24.04.1 VM                           │
│                                                                  │
│  3. Extract ISO's initramfs                                     │
│     └─ Ubuntu 24.04.1 format:                                  │
│         - Segment 1: AMD microcode (cpio) ~77KB                │
│         - Segment 2: Intel microcode (cpio) ~7.7MB             │
│         - Segment 3: Userspace (zstd compressed) ~62MB         │
│         - Kernel modules embedded inside zstd segment          │
│                                                                  │
│  4. Inject wl.ko.zst into initramfs                             │
│     └─ Path: usr/lib/modules/6.8.0-41-generic/.../wl.ko.zst     │
│     └─ Inside zstd-compressed userspace segment                │
│                                                                  │
│  5. Rebuild initramfs preserving structure                      │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                    INSTALLATION PHASE                            │
│                    (on Mac Pro)                                  │
├─────────────────────────────────────────────────────────────────┤
│  1. Boot modified ISO from UBUNTU-TEMP partition               │
│     └─ Mac `bless` command sets partition as default boot     │
│     └─ GRUB bootloader loads kernel + modified initramfs       │
│                                                                  │
│  2. Installer starts with wl driver pre-loaded                  │
│     └─ WiFi hardware detected and configured                    │
│     └─ Network connection established                          │
│                                                                  │
│  3. Cloud-init autoinstall runs                                 │
│     └─ Uses WiFi credentials from user-data                     │
│     └─ Installs base system                                     │
│                                                                  │
│  4. late-commands execute                                       │
│     └─ Install broadcom-sta-dkms for future kernel updates     │
│     └─ Configure netplan for persistent WiFi                   │
│     └─ Install wifi-recovery.service for headless recovery      │
│                                                                  │
│  5. First boot                                                   │
│     └─ WiFi configured via netplan                              │
│     └─ SSH accessible via macpro-linux.local                   │
└─────────────────────────────────────────────────────────────────┘
```

---

## Technical Details

### Password Hash Generation

**CRITICAL**: macOS's built-in `crypt` module produces **invalid SHA-512 hashes** for Ubuntu.

| Platform | `crypt.crypt()` Result | Correct |
|----------|----------------------|---------|
| Linux | `$6$salt$...` (106 chars) | ✅ |
| macOS | `$6$salt` (13 chars) | ❌ BROKEN |

**Why it matters**: A 13-character hash will not work for authentication on Ubuntu. Users would be locked out after installation.

**Solution**: The script uses Python's `passlib` library which generates proper SHA-512 hashes:

```bash
# Correct approach (used in script)
python3 -c "from passlib.hash import sha512_crypt; print(sha512_crypt.using(rounds=5000).hash('password'))"
# Output: $6$jwtP5UvrSyZ7egDE$kAoWiOtqCTwBe... (106 chars)

# Wrong approach (macOS crypt)
python3 -c "import crypt; print(crypt.crypt('password', crypt.mksalt(crypt.METHOD_SHA512)))"
# Output: $6YNiNAxBTcdg (13 chars - BROKEN)
```

The script automatically:
1. Checks for passlib availability
2. Attempts to install passlib via pip3 if missing
3. Falls back to OpenSSL MD5 (`-1`) if passlib unavailable
4. Validates hash length (rejects <100 chars for SHA-512, <30 chars for MD5)

### Why Pre-compile in a VM?

The `wl.ko` kernel module must match:
- **Exact kernel version**: 6.8.0-41-generic
- **Architecture**: x86_64
- **Kernel configuration**: Must align with Ubuntu's kernel build

Compiling on the MacBook (macOS) wouldn't work because:
- macOS doesn't have Linux kernel headers
- Cross-compilation is complex and error-prone
- Need to ensure ABI compatibility

**Solution**: Use an Ubuntu 24.04.1 VM to compile, then extract the module.

### Why Must the ISO Be Pre-Extracted?

The Ubuntu 24.04.1 ISO uses UDF/SquashFS filesystem formats that macOS (especially Monterey and earlier) cannot mount natively. This means:
- `hdiutil attach` fails with "no mountable file systems"
- The ISO must be pre-extracted using `7z` (7-Zip)

**Solution:**
1. Pre-extract the ISO using 7-Zip before running the script:
   ```bash
   cd prereqs/
   7z x ubuntu-24.04.1-live-server-amd64.iso -oubuntu-iso -y
   ```
2. The script copies pre-extracted files from `prereqs/ubuntu-iso/` to the UBUNTU-TEMP partition
3. No runtime ISO mounting required

### Initramfs Structure Discovery

Ubuntu 24.04.1 uses a 3-segment initramfs with zstd compression:

| Segment | Type | Contents | Size |
|---------|------|----------|------|
| 1 | cpio | AMD CPU microcode | ~77KB |
| 2 | cpio | Intel CPU microcode | ~7.7MB |
| 3 | zstd | Userspace + kernel modules | ~62MB |

**Key insight**: Unlike older Ubuntu versions, kernel modules are embedded inside the zstd-compressed userspace segment, not in a separate cpio segment. The `wl.ko.zst` file is placed at:
```
usr/lib/modules/6.8.0-41-generic/kernel/drivers/net/wireless/wl.ko.zst
```

The initramfs is:
1. Extract microcode segments (cpio archives)
2. Decompress zstd userspace segment
3. Add `wl.ko.zst` to the kernel modules directory
4. Recompress userspace with zstd
5. Concatenate all segments

### Why zstd Compression?

Ubuntu 24.04.1 compresses kernel modules with zstd (`.ko.zst`), not gzip. This is why we:
- Compressed `wl.ko` with `zstd -19`
- Named it `wl.ko.zst`
- Placed it in the correct kernel modules directory

---

## Safety Mechanisms

### 1. WiFi Recovery Service

Since the Mac Pro is headless, a WiFi failure would brick the device. We created `wifi-recovery.service`:

```bash
#!/bin/bash
# Runs on every boot to verify WiFi connectivity
# If WiFi fails:
#   - Reloads wl module
#   - Reapplies netplan
#   - Attempts 3 retries
#   - Logs failures for remote debugging
```

### 2. DKMS Kernel Hook

When Ubuntu updates the kernel, the WiFi driver must be rebuilt:

```bash
#!/bin/bash
# /etc/kernel/postinst.d/dkms-wl
# Automatically rebuilds broadcom-sta for new kernels
dkms autoinstall -k "$1"
```

### 3. Driver Package Backup

All driver packages are copied to `/cdrom/casper/broadcom/`:
- If network fails during late-commands, packages are still available
- DKMS can rebuild from local packages if needed

### 4. Webhook Monitoring

Every stage of installation reports to the monitoring server:
- Progress tracking during preparation
- Installation completion notification
- IP address reporting for SSH access
- **Error notification** - Sends failure webhook if installation fails

### 5. Stall Detection

The monitoring server automatically detects stalled installations:
- **5 minutes** since last update → Yellow warning displayed
- **15 minutes** since last update → Red "STALLED INSTALLATION" alert
- Dashboard shows elapsed time since last webhook
- Helps identify hardware issues, network problems, or frozen installers

### 6. WiFi Pre-Flight Check

Before installation begins, the script verifies:
- Target WiFi network is visible (using `airport` or `networksetup`)
- Shows available networks if target not found
- Prompts user to continue or abort
- Allows proceeding at user's own risk

### 7. Monitoring Server Detection

The script automatically detects the monitoring server:
- Tries mDNS hostname first (`Tejas-MacBook-Pro.local`)
- Falls back to hardcoded IP address if mDNS fails
- Warns if no monitoring server available
- Continues installation even if webhook unavailable

### 8. Password Hash Validation

Before creating the autoinstall configuration, the script validates the password hash:
- Checks for passlib availability (preferred for SHA-512)
- Attempts automatic installation via pip3 if missing
- Falls back to OpenSSL MD5 if passlib unavailable
- Validates hash length (rejects <100 chars for SHA-512, <30 for MD5)
- Provides clear error messages for troubleshooting

---

## Configuration Choices

### Why Hostname-Based Webhook with IP Fallback?

Using `Tejas-MacBook-Pro.local` with fallback to `192.168.1.115`:
- Survives DHCP IP changes (via mDNS)
- Falls back to hardcoded IP if mDNS fails
- Works across network changes
- More robust than IP-only approach

### Why networkd Instead of NetworkManager?

Netplan with `networkd` renderer:
- Simpler configuration
- No GUI dependencies
- Faster boot time
- More reliable in headless environment

### Why Disable Package Updates?

```yaml
package_update: false
package_upgrade: false
```

- Prevents network dependency during installation
- WiFi driver is already pre-installed
- Updates can be run post-install with network verified

---

## Alternative Approaches Considered

### Approach 1: USB Ethernet Adapter
- **Pros**: Simple, well-tested
- **Cons**: Requires additional hardware, adds complexity

### Approach 2: Clone VM Image to Mac Pro
- **Pros**: Tested driver installation
- **Cons**: Initramfs mismatch, storage controller differences, post-boot fixes needed

### Approach 3: Network Install with Preseed
- **Pros**: Standard Ubuntu approach
- **Cons**: Still requires network; Broadcom driver problem remains

### Approach 4: Pre-compiled Driver Injection (CHOSEN)
- **Pros**: 
  - Single solution for both installer and target
  - No additional hardware needed
  - Minimal risk of failure
  - Clean installation
- **Cons**: 
  - Complex preparation phase
  - VM required for compilation

---

## Kernel Version Alignment

This approach succeeds because all components use kernel 6.8.0-41-generic:

| Component | Kernel Version | Source |
|-----------|---------------|--------|
| Ubuntu 24.04.1 ISO | 6.8.0-41-generic | From vmlinuz filename |
| Kernel headers | 6.8.0-41-generic | Downloaded to prereqs/ |
| Pre-compiled wl.ko | 6.8.0-41-generic | Built in VM |
| Modified initramfs | 6.8.0-41-generic modules | Matches ISO |
| Target system | 6.8.0-41-generic | From ISO installation |

If kernel versions mismatch, `modprobe wl` will fail with "Invalid module format".

---

## Post-Install Considerations

### Future Kernel Updates

When Ubuntu releases kernel 6.8.0-48 (for example):
1. DKMS hook runs: `/etc/kernel/postinst.d/dkms-wl`
2. `dkms autoinstall -k 6.8.0-48-generic` executes
3. broadcom-sta source recompiles for new kernel
4. WiFi continues working after reboot

### Troubleshooting Remote Access

If SSH fails after installation:
1. Check mDNS: `ping macpro-linux.local`
2. Check router for IP assignment
3. WiFi recovery service logs: `/var/log/wifi-recovery.log`
4. Driver status: `ssh ... 'dkms status'`
5. Module loaded: `ssh ... 'lsmod | grep wl'`

---

## Lessons Learned

1. **Initramfs format varies**: Ubuntu 24.04.1 uses 2 cpio segments + zstd userspace, not 4 segments
2. **Kernel version must match exactly**: Even minor version differences break module loading
3. **Headless recovery is critical**: Without physical access, automation is mandatory
4. **Testing in VM first**: Compiling and testing in VM before touching Mac Pro saved significant time
5. **mDNS is essential**: Hostname-based access survives IP changes
6. **macOS crypt module is broken for SHA-512**: The `crypt` module on macOS produces invalid 13-character hashes that don't work on Ubuntu. Must use `passlib` library for proper SHA-512 hashes (106 characters).
7. **Password hash validation is crucial**: Always validate hash length - SHA-512 should be 100+ chars, MD5 should be 30+ chars. Invalid hashes will lock users out.

---

## File Structure Summary

### Directory Layout on MacBook

All files are in `/Users/djtchill/Desktop/Mac/` and must be synced to the Mac Pro before deployment:

```
/Users/djtchill/Desktop/Mac/
├── prepare_ubuntu_install_final.sh   # Main preparation script (run on Mac Pro)
├── DEPLOYMENT_GUIDE.md              # Quick reference guide
├── TECHNICAL_OVERVIEW.md            # This document
├── CODE_REVIEW_PROMPT.md            # LLM review instructions
├── macpro-monitor/                  # Node.js webhook server (run on MacBook)
│   ├── server.js                   # Dashboard + webhook receiver
│   ├── start.sh                    # Start server
│   └── stop.sh                     # Stop server
├── prereqs/                         # All deployment files (~2.7GB total)
│   ├── ubuntu-24.04.1-live-server-amd64.iso  # Ubuntu installer
│   ├── wl-6.8.0-41.ko              # Pre-compiled driver (kernel 6.8.0-41)
│   ├── initrd-modified              # WiFi-enabled initramfs
│   ├── prereqs.manifest            # File checksums
│   ├── broadcom-sta-dkms_*.deb     # Driver source for DKMS
│   ├── dkms_*.deb                   # Dynamic Kernel Module Support
│   ├── linux-headers-6.8.0-41*     # Kernel headers (matching ISO)
│   └── [30 packages total]          # Build dependencies
├── ssh-MacPro/                      # Mac Pro SSH keys (for reference)
└── ssh-Macbook/                     # MacBook SSH keys (embedded in user-data)
```

### What Each File Does

| File | Purpose | Run Where |
|------|---------|-----------|
| `prepare_ubuntu_install_final.sh` | Prepares installer on Mac Pro | Mac Pro |
| `server.js` | Monitors installation progress | MacBook |
| `initrd-modified` | Installer with WiFi driver pre-loaded | Copied to Mac Pro |
| `wl-6.8.0-41.ko` | Backup driver (for DKMS) | Copied to Mac Pro |
| `*.deb` packages | Driver build dependencies | Copied to Mac Pro |

### Key Configuration Values

These are hardcoded in `prepare_ubuntu_install_final.sh`:

| Setting | Value | Location |
|---------|-------|----------|
| Hostname | `macpro-linux` | Line 71 |
| Username | `teja` | Line 72 |
| Password | `ubuntu-admin-2024` | Line 73 |
| WiFi SSID | `ATTj6pXatS` | Line 75 |
| WiFi Password | (in script) | Line 76 |
| SSH Key | ed25519 from `ssh-Macbook/` | Line 78 |
| Fallback Webhook IP | `192.168.1.115` | Line 69 |

**Note**: Webhook URL is auto-detected at runtime (mDNS first, IP fallback).

---

## References

- Ubuntu Autoinstall: https://ubuntu.com/server/docs/install/autoinstall
- Broadcom STA driver: http://www.broadcom.com/docs/linux_sta/hybrid-v35_64-nodebug-pcopt-6.30.223.271.tar.gz
- DKMS: https://github.com/dell/dkms
- Mac bless command: https://ss64.com/osx/bless.html
- Initramfs format: https://www.kernel.org/doc/Documentation/filesystems/ramfs-rootfs-initramfs.txt