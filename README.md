# Mac Pro 2013 Ubuntu 24.04 — Headless Autoinstall

Automated Ubuntu Server 24.04.4 dual-boot deployment for a headless Mac Pro 2013 (MacPro6,1) with Broadcom BCM4360 WiFi, installed entirely over SSH with zero physical access. macOS is preserved.

## Specifications

### Hardware
- **Model**: Mac Pro 2013 (MacPro6,1), trash can design
- **GPU**: AMD FirePro D300/D500/D700 (amdgpu driver, `nomodeset amdgpu.si.modeset=0`)
- **WiFi**: Broadcom BCM4360 — requires proprietary `wl` driver, not in Ubuntu
- **Storage**: Apple PCIe SSD via AHCI → `/dev/sda` (not NVMe)
- **No Ethernet port** — WiFi is the only network path

### Operational Constraints
- **Zero physical access** — no keyboard, monitor, or mouse available
- **macOS 12.7.6 running** — accessible only via SSH
- **Cannot disable SIP** — stuck with Apple's default bootloader (but `bless` works for dual-boot)
- **Dual-boot: macOS preserved** — existing partitions marked `preserve: true`; Ubuntu installed in free space
- **MacBook available on network** — can serve as monitoring/webhook endpoint

### Circular Dependency Problem
Mac Pro has no Ethernet. Broadcom BCM4360 WiFi requires a proprietary `wl` driver not included in Ubuntu. Without WiFi, the installer can't download packages. Without packages, we can't compile the driver. The `packages/` directory on the ISO breaks this cycle.

## Solution Overview

**Extract-and-repack ISO modification + remote boot via `bless`**:

1. Build a modified Ubuntu Server ISO: extract original, overlay custom files, repack preserving original EFI boot structure
2. Transfer ISO to Mac Pro, run `prepare-headless-deploy.sh` via SSH — shrinks APFS, creates 5GB ESP, extracts ISO contents, generates dual-boot autoinstall config, sets boot device
3. `bless --setBoot --nextonly` sets ESP as next boot device (reverts to macOS if installer fails)
4. Reboot → Mac Pro boots into Ubuntu installer → autoinstall runs headlessly

## Files

| File | Purpose |
|------|---------|
| `autoinstall.yaml` | Autoinstall config — WiFi driver compilation, SSH, dual-boot storage layout |
| `build-iso.sh` | Builds modified ISO: extract, overlay, repack preserving EFI boot |
| `packages/` | .deb files for driver compilation (34 packages) |
| `packages/dkms-patches/` | 6 DKMS patches for kernel 6.8+ compatibility (series file + *.patch) |
| `prepare-headless-deploy.sh` | macOS-side script: repartition, extract ISO, generate dual-boot config, bless, verify |
| `prereqs/` | Stock Ubuntu 24.04.4 Server ISO (`*.iso` gitignored) |
| `macpro-monitor/` | Node.js webhook server for installation monitoring (3-pane dashboard) |
| `vm-test/` | VirtualBox test environment for DKMS compilation validation |

## Prerequisites

### macOS (build/deploy machine)
- **Python 3** — for dynamic storage config generation (`python3` in PATH)
- **xorriso** — ISO repackaging (`brew install xorriso`)
- **gptfdisk** — GPT partition table manipulation (`brew install gptfdisk`, provides `sgdisk`)

```bash
brew install xorriso gptfdisk python3
```

## Quick Start

### Headless Deploy (Zero Physical Access)

```bash
# 1. Build the ISO and transfer to Mac Pro
sudo ./build-iso.sh
scp ubuntu-macpro.iso macpro:~

# 2. Start webhook monitor on MacBook
cd macpro-monitor && ./start.sh

# 3. SSH into Mac Pro and run the deploy script
ssh macpro
sudo ./prepare-headless-deploy.sh ~/ubuntu-macpro.iso

# 4. Monitor installation via webhook; SSH into installer for debugging
```

### USB Boot (Requires Physical Access)

```bash
sudo ./build-iso.sh
diskutil list  # find your USB drive
diskutil unmountDisk /dev/diskN
sudo dd if=ubuntu-macpro.iso of=/dev/diskN bs=1m
# Boot from USB — GRUB auto-selects autoinstall after 3 seconds
```

### Start Webhook Monitor

```bash
cd macpro-monitor && ./start.sh
# Dashboard: http://<your-ip>:8080
# Webhook:   http://<your-ip>:8080/webhook
```

## Architecture

### What's Added to the ISO

1. `/autoinstall.yaml` — installation configuration
2. `/cidata/` — NoCloud datasource for `ds=nocloud` discovery
3. `/macpro-pkgs/` — 34 .deb files for driver compilation
4. `/macpro-pkgs/dkms-patches/` — 6 DKMS compatibility patches for broadcom-sta on kernel 6.8+
5. `/EFI/boot/grub.cfg` and `/boot/grub/grub.cfg` — pre-baked `autoinstall ds=nocloud nomodeset amdgpu.si.modeset=0`
6. Volume label `cidata` — for NoCloud datasource discovery

### DKMS Patch Architecture

The `broadcom-sta-dkms` package (`6.30.223.271-23ubuntu1`) does not compile on kernel 6.8+. Six patches are applied during installation:

| Patch | Purpose | Kernel Threshold |
|-------|---------|-----------------|
| 29-fix-version-parsing.patch | Fix 2-component kernel version parsing | All 6.x |
| 30-6.12-unaligned-header-location.patch | `asm/unaligned.h` → `linux/unaligned.h` | 6.12+ |
| 31-build-Provide-local-lib80211.h-header.patch | Local `lib80211.h` (removed from kernel) | 6.13+ |
| 32-Prepare-for-6.14.0-rc6.patch | `wl_cfg80211_get_tx_power` gets `link_id` param | 6.14+ |
| 38-build-don-t-use-deprecated-EXTRA_-FLAGS.patch | `EXTRA_CFLAGS` → `ccflags-y` | 6.15+ |
| 39-wl-use-timer_delete-for-kernel-6.15.patch | `del_timer` → `timer_delete` | 6.15+ |

Patches use `#if LINUX_VERSION_CODE >= KERNEL_VERSION(...)` guards. Applied via `series` file in dependency order. **Do NOT call `dkms add` explicitly** — the postinst already does this.

### autoinstall.yaml Key Sections

**early-commands** (before network, in installer environment):
1. Detect running kernel dynamically → validate matching headers exist
2. Install kernel headers and build toolchain from discovered `macpro-pkgs/` mount
3. Install `broadcom-sta-dkms` and `dkms` — postinst auto-runs `dkms add` (creates symlink)
4. Apply 6 DKMS patches from `macpro-pkgs/dkms-patches/` — FATAL if missing or fail
5. Compile `wl.ko` via DKMS (`dkms build` + `dkms install`), single-retry fallback
6. Load driver with `modprobe wl` — FATAL if fails
7. Wait for WiFi interface (60s timeout), verify connectivity (scan + DHCP + HTTP)
8. Start SSH server (fallback to ISO pool `.deb`s with `--force-depends`)

**network**: `wl0` with `match: driver: wl`, `networkd` renderer, WiFi credentials

**storage (dual-boot)**: All existing partitions `preserve: true`. New partitions in free space only: EFI (512M), /boot (1G), / (rest).

**late-commands** (after install, in target system):
1. 4-stage `dpkg --root /target` install with bind mounts for chroot DKMS
2. Write netplan WiFi config (with fallback to simplified config)
3. Configure WiFi power management off, `cfg80211` regulatory domain `US`
4. Configure GRUB (kernel params, macOS boot entry via `fwsetup`, `efibootmgr`)
5. Pin kernel and disable all auto-updates (apt preferences, apt-mark hold, apt-daily timer masks, sources.list comment-out, snap hold)
6. Enable UFW firewall (deny incoming, allow SSH)
7. Verify target system (kernel, netplan, GRUB, WiFi module, user account)
8. Save logs to `/var/log/macpro-install/` — if WiFi broken, enter recovery mode (keep SSH alive, block reboot)

**error-commands**: Save diagnostics to persistent `/var/log/macpro-install/`, send webhook error notification.

### Dynamic Dual-Boot Storage Config

The `prepare-headless-deploy.sh` script uses Python + `sgdisk` to:
1. Read the GPT partition table after APFS resize
2. Generate `preserve: true` entries for every existing partition
3. Append new Ubuntu partitions in free space
4. Normalize partition type GUIDs to lowercase for curtin
5. Use string-based regex replacement (NOT `yaml.dump`) to preserve `|` block scalars

### Switching Between macOS and Ubuntu

| Direction | Method | Command |
|-----------|--------|---------|
| macOS → Ubuntu | `bless` | `bless --setBoot --mount /Volumes/cidata --nextonly` |
| Ubuntu → macOS | `efibootmgr` | `sudo boot-macos` |
| Ubuntu → macOS | GRUB menu | Select "Reboot to Apple Boot Manager" |
| Any → macOS | Firmware | Hold Option at boot (physical access required) |

Note: `bless --nextonly` only reverts if firmware can't find bootloader, NOT on kernel panic. GRUB cannot read APFS — `fwsetup` reboots to Apple Boot Manager.

### Risk: No Recovery Without Physical Access

**Mitigations:**
- macOS is **preserved** — all partitions marked `preserve: true`
- WiFi connectivity circuit breaker — aborts before storage if WiFi isn't functional
- `bless --nextonly` — reverts to macOS if firmware can't find bootloader on ESP
- Recovery mode — if target WiFi broken, installer blocks reboot and keeps SSH alive
- Webhook monitoring — real-time status at each stage
- UFW firewall — denies all incoming except SSH
- VirtualBox test environment — validate flow before real hardware

## Updating Packages

If you need to refresh `packages/` for a different kernel version:

```bash
# Kernel headers must match the ISO's kernel version (e.g., 6.8.0-100-generic)
# The autoinstall config detects the running kernel dynamically via KVER="$(uname -r)"
# Packages already in the ISO live environment (kmod, perl-base, linux-modules, libkmod2)
# do NOT need to be included in packages/ — they are skipped by --skip-same-version
```

## Troubleshooting

### Driver won't compile
```bash
dmesg | grep -i 'dkms\|wl\|broadcom'
cat /run/macpro.log
ls /macpro-pkgs/linux-headers-$(uname -r)_*.deb
```

### WiFi doesn't connect
```bash
dmesg | grep wl
iwconfig | grep "Power Management"
cat /etc/modprobe.d/wl.conf
```

### Switch back to macOS
```bash
sudo boot-macos    # uses efibootmgr to set macOS as next boot
```

### Kernel updates break WiFi
Kernel is pinned via apt preferences and `apt-mark hold`. See AGENTS.md for full constraints.

## Monitoring

The `macpro-monitor/` server provides a real-time 3-pane dashboard (Subiquity Events | Custom Progress | Status):

| Stage | Range | Description |
|-------|-------|-------------|
| `prep-init` | 2% | Autoinstall started, validating kernel headers |
| `prep-headers` | 5% | Installing kernel headers |
| `prep-toolchain` | 10% | Installing build toolchain |
| `prep-dkms` | 13-15% | DKMS build WiFi driver |
| `prep-wifi` | 18-22% | WiFi driver loaded, interface detected |
| `prep-netcheck` | 24-28% | WiFi connectivity verified |
| `prep-ssh` | 23-29% | SSH server ready for debugging |
| `late-init` | 29-30% | Late commands started |
| `late-headers` | 35% | Stage 1/4: kernel headers into target |
| `late-libs` | 45% | Stage 2/4: base libraries into target |
| `late-tools` | 55% | Stage 3/4: build tools into target |
| `late-dkms` | 60-65% | Stage 4/4: DKMS compile WiFi driver for target |
| `late-netplan` | 70-73% | Writing WiFi network configuration |
| `late-grub` | 75-78% | Configuring GRUB bootloader |
| `late-hold` | 85-88% | Pinning kernel, disabling auto-updates |
| `late-logs` | 95% | Saving installation logs |
| `complete` | 100% | Installation complete, rebooting |

### Security: WiFi Credentials

WiFi SSID and password are in plain text in `autoinstall.yaml` and on the FAT32 ESP. Mitigations: UFW firewall denies all incoming except SSH, ESP is only accessible during install. Future improvement: inject credentials via environment variable at deploy time.

## VM Test Environment

```bash
cd vm-test && sudo ./build-iso-vm.sh && ./create-vm.sh && ./test-vm.sh
```

VM uses Ethernet (`enp0s3`) instead of WiFi, DKMS compiles (fatal on failure) but driver init is non-fatal (no Broadcom HW). Webhook targets `10.0.2.2` via NAT.