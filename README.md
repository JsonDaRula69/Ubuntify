# Mac Pro 2013 Ubuntu 24.04 — Headless Autoinstall

Automated Ubuntu Server 24.04.4 deployment for a headless Mac Pro 2013 (MacPro6,1) with Broadcom BCM4360 WiFi, installed entirely over SSH with zero physical access.

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
- **SSH access required during install** — need to debug if anything goes wrong
- **MacBook available on network** — can serve as monitoring/webhook endpoint and fallback NetBoot host

### Circular Dependency Problem
Mac Pro has no Ethernet. Broadcom BCM4360 WiFi requires a proprietary `wl` driver not included in Ubuntu. Without WiFi, the installer can't download packages. Without packages, we can't compile the driver. The `packages/` directory on the ISO breaks this cycle.

## Solution Overview

**Extract-and-repack ISO modification + remote boot via `bless`**:

1. Build a modified Ubuntu Server ISO: extract original ISO, overlay custom files, repack preserving original EFI boot structure
2. Transfer ISO to Mac Pro, run `prepare-headless-deploy.sh` via SSH — shrinks APFS, creates ESP, extracts ISO contents, sets boot device
3. `bless --setBoot --nextonly` sets ESP as next boot device (reverts to macOS if installer fails)
4. Reboot → Mac Pro boots into Ubuntu installer from internal disk → autoinstall runs headlessly

```
SSH into macOS → repartition disk → extract ISO to ESP → bless --setBoot --nextonly → reboot → autoinstall completes
```

The autoinstall config compiles the WiFi driver, starts SSH for remote debugging, and runs headlessly. The `autoinstall` kernel parameter bypasses the confirmation prompt (required for zero-touch deployment). SSH is available during install at `installer@<ip>` or via the configured SSH keys.

## Files

| File | Purpose |
|------|---------|
| `autoinstall.yaml` | Ubuntu autoinstall configuration — WiFi driver compilation, SSH, storage layout |
| `build-iso.sh` | Builds modified ISO: extracts original, overlays custom files, repacks preserving EFI boot |
| `packages/` | .deb files needed to compile and install WiFi driver (~37 packages, ~75MB) |
| `packages/dkms-patches/` | 6 DKMS patches for kernel 6.8+ compatibility (series file + *.patch) |
| `prepare-headless-deploy.sh` | macOS-side script: repartition, extract ISO to ESP, bless, verify, reboot |
| `prereqs/` | Stock Ubuntu 24.04.4 Server ISO (`*.iso` gitignored) |
| `macpro-monitor/` | Node.js webhook server for headless install monitoring (3-pane dashboard) |

## Quick Start

### USB Boot (Requires Physical Access)

```bash
# 1. Build the ISO (place stock ISO in prereqs/ first)
sudo ./build-iso.sh
# The script extracts the original ISO, overlays custom files,
# and repacks preserving the original EFI boot structure.

# 2. Write to USB
diskutil list  # find your USB drive
diskutil unmountDisk /dev/diskN
sudo dd if=ubuntu-macpro.iso of=/dev/diskN bs=1m

# 3. Boot from USB — GRUB auto-selects autoinstall after 3 seconds
# No manual keyboard input needed (params are pre-baked in GRUB config)
```

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

# The script will:
#   - Auto-delete APFS snapshots (no interactive confirmation needed)
#   - Shrink APFS, create ESP, extract ISO contents
#   - Set boot device with bless --nextonly (safe: reverts to macOS if installer fails)
#   - Verify bless succeeded with bless --info
#   - Auto-reboot in 5 seconds in non-interactive (piped SSH) mode
#   - Or prompt for confirmation in interactive mode

# 4. Monitor installation via webhook; SSH into installer for debugging
```

### Start Webhook Monitor (recommended for headless deploy)

```bash
cd macpro-monitor && ./start.sh
# Dashboard: http://<your-ip>:8080
# Webhook:   http://<your-ip>:8080/webhook
# Auto-refreshes every 3 seconds
# 3-pane view: Subiquity Events | Custom Progress | Status
# Receives ALL events (DEBUG level) from Subiquity/Curtin
# Receives custom progress events from autoinstall early/late commands
```

## How It Works

### What's Added to the ISO

The build process extracts the original ISO, overlays custom files, then repacks using the original boot parameters (preserved via `xorriso -report_el_torito as_mkisofs`). Six things are overlaid:

1. `/autoinstall.yaml` — installation configuration
2. `/cidata/` — NoCloud datasource (`user-data`, `meta-data`, `vendor-data`) for `ds=nocloud` discovery
3. `/macpro-pkgs/` — flat directory of ~37 .deb files for driver compilation
4. `/macpro-pkgs/dkms-patches/` — 6 DKMS compatibility patches for broadcom-sta on kernel 6.8+ (with `series` file for ordered application)
5. `/EFI/boot/grub.cfg` and `/boot/grub/grub.cfg` — GRUB config with pre-baked `autoinstall ds=nocloud nomodeset amdgpu.si.modeset=0` kernel parameters (no manual keyboard input needed)
6. Volume label `cidata` — for NoCloud datasource discovery

### Why Packages Must Be Included

The stock Ubuntu 24.04.4 Server ISO does NOT include:
- `dkms` — Dynamic Kernel Module Support framework
- `broadcom-sta-dkms` — Broadcom WiFi driver source (requires patches for kernel 6.8+)
- `make`, `gcc-13`, `build-essential` — compilation toolchain
- `perl-base`, `kmod`, `fakeroot` — DKMS dependencies

These must be included on the ISO because without WiFi, the installer cannot download them from the internet.

We include all needed debs in `packages/` and DKMS patches in `packages/dkms-patches/` to avoid fragile dependency resolution against deep ISO pool paths.

### DKMS Patch Architecture

The `broadcom-sta-dkms` package (version `6.30.223.271-23ubuntu1`) does not compile cleanly on kernel 6.8+. Six patches are applied during installation to resolve compatibility issues:

| Patch | Purpose | Kernel Threshold |
|-------|---------|-----------------|
| 29-fix-version-parsing.patch | Fix 2-component kernel version parsing | All 6.x |
| 30-6.12-unaligned-header-location.patch | `asm/unaligned.h` → `linux/unaligned.h` | 6.12+ |
| 31-build-Provide-local-lib80211.h-header.patch | Local `lib80211.h` (removed from kernel) | 6.13+ |
| 32-Prepare-for-6.14.0-rc6.patch | `wl_cfg80211_get_tx_power` gets `link_id` param | 6.14+ |
| 38-build-don-t-use-deprecated-EXTRA_-FLAGS.patch | `EXTRA_CFLAGS` → `ccflags-y` | 6.15+ |
| 39-wl-use-timer_delete-for-kernel-6.15.patch | `del_timer` → `timer_delete` | 6.15+ |

All patches use `#if LINUX_VERSION_CODE >= KERNEL_VERSION(...)` guards and compile cleanly on 6.8 while enabling forward compatibility. Patches are applied via a `series` file in dependency order.

**Important**: `dkms add` is automatically called by the `broadcom-sta-dkms` package postinst (via `dh-dkms` debhelper). It creates a **symlink** from `/var/lib/dkms/broadcom-sta/6.30.223.271/source` → `/usr/src/broadcom-sta-6.30.223.271/`. Patches applied to `/usr/src/` are immediately visible through this symlink. Do NOT call `dkms add` explicitly — calling it again will fail with "module already added."

### autoinstall.yaml Key Sections

**early-commands** (runs before network config, in the installer environment):
1. Detects running kernel version dynamically (`KVER="$(uname -r)"`) — no hardcoded version
2. Validates kernel headers exist for running kernel; exits if not found
3. Installs kernel headers from `/cdrom/macpro-pkgs/`
4. Installs build toolchain (gcc, make, binutils, libc-dev, etc.)
5. Installs `broadcom-sta-dkms` and `dkms` (dpkg postinst auto-runs `dkms add`, creating a symlink)
6. Applies 6 DKMS patches from `/cdrom/macpro-pkgs/dkms-patches/` for kernel 6.8+ compatibility (patches modify `/usr/src/`, visible through the DKMS symlink)
7. Compiles `wl.ko` via DKMS against the detected kernel (`dkms build` + `dkms install`)
8. Loads driver with `modprobe wl`; exits if module fails to load (WiFi is critical)
9. Waits for WiFi interface to appear (up to 30 seconds, checks `wl[pw]*` and `wlan*` patterns)
10. Starts SSH server — tries `apt-get install openssh-server` first, falls back to ISO pool `.deb`s with `--force-depends`

Each step sends a progress webhook with `{progress, stage, status, message}` to the monitoring server. All critical failures call `exit 1` to abort installation.

**network**: Uses `wl0` interface with `match: driver: wl`, connects to configured WiFi

**late-commands** (runs after install, installs into target system):
1. Detects running kernel version dynamically (`KVER="$(uname -r)"`)
2. Validates kernel headers exist for running kernel; exits if not found
3. Installs kernel headers, build toolchain, and DKMS into `/target` in 4 dependency-ordered stages (all fatal on failure)
4. Installs `broadcom-sta-dkms` (postinst auto-runs `dkms add`), applies DKMS patches, then compiles `wl.ko` via DKMS in the target chroot with `/proc`, `/sys`, `/dev` bind-mounted (ensures persistence across reboots)
5. Writes netplan WiFi config for target system (uses `printf` to avoid heredoc indentation issues, `networkd` renderer with `wpa_supplicant` for WiFi)
6. Pins kernel and headers to `$KVER` via `apt-mark hold` (dynamic, not hardcoded)
7. Configures mDNS for `macpro-linux.local` hostname resolution
8. Saves install logs to `/var/log/macpro-install/`

Each step sends a progress webhook (30-100%) to the monitoring server.

**error-commands**: Attempts to load driver and sends webhook error notification

**reporting**: Sends Subiquity/Curtin events to the webhook at `DEBUG` level (captures all events including network and storage details). Custom curl calls in early/late commands send progress updates with stage-specific identifiers (`prep-init`, `prep-headers`, `late-dkms`, etc.).

### AMD FirePro GPU

Mac Pro 2013 uses AMD FirePro D300/D500/D700. The `amdgpu` driver is built into the kernel. No additional GPU driver needed — only the kernel parameters `nomodeset amdgpu.si.modeset=0` in GRUB.

### Storage

The autoinstall targets `/dev/sda` — Mac Pro 2013 uses Apple PCIe SSDs connected via AHCI (not NVMe), so the internal SSD appears as `/dev/sda`.

## Remote Deployment (Zero Physical Access)

For the headless scenario, the USB boot method above requires physical access. The remote deployment approach uses macOS's `bless` command to boot into the installer from SSH:

### Feasibility

| Approach | Feasible? | Notes |
|----------|-----------|-------|
| Repartition + `bless` via SSH | ✅ | `diskutil resizeVolume` + `bless --setBoot --nextonly` works from SSH; auto-reverts to macOS if installer fails |
| `dd` ISO to partition | ❌ | Mac EFI expects FAT32 ESP with `/EFI/BOOT/BOOTX64.EFI`, not ISO9660 |
| Extract ISO to ESP + `bless` | ✅ | AsahiLinux uses this exact pattern for Mac Linux installs |
| NetBoot/NetInstall | ❌ | Requires macOS Server + BSDP protocol; Ubuntu doesn't speak BSDP |
| SSH during installer | ✅ | Must start sshd in `early-commands` before WiFi driver compilation |
| Target Disk Mode | ⚠️ Fallback | Needs brief physical access |

### Remote Deployment Flow

```
1. SSH into macOS
2. Transfer ISO to Mac Pro via scp
3. Delete APFS snapshots (automatically, for headless operation)
4. Shrink APFS partition: diskutil apfs resizeContainer
5. Create ESP partition via diskutil addPartition (detected via before/after diffing)
6. Format ESP as FAT32, mount ISO, extract all contents to ESP
7. Write GRUB config with: autoinstall ds=nocloud nomodeset amdgpu.si.modeset=0
8. bless --setBoot --nextonly (reverts to macOS if installer fails)
9. Verify bless with --info
10. Reboot → autoinstall runs headlessly (non-interactive reboot with 5s delay)
11. Monitor via webhook + SSH into installer environment
```

The `prepare-headless-deploy.sh` script automates steps 3-10.

### Risk: No Recovery Without Physical Access

If the installer fails or the partition setup is wrong, the Mac Pro becomes unreachable — no SSH, no monitor, no keyboard. With the dual-boot configuration, macOS is **preserved** — all existing partitions are marked `preserve: true` in the autoinstall storage config. If Ubuntu installation fails in late-commands, macOS remains intact and `bless --nextonly` will revert the boot device on the next reboot. However, if the installer fails during the storage config phase (before partitions are created), macOS is still safe because `preserve: true` prevents curtin from modifying existing partitions.

The `--nextonly` flag ensures the boot device reverts to macOS if the installer boot fails (corrupt ESP, missing GRUB). With dual-boot, this protection is even stronger — macOS survives even a successful Ubuntu install, so you can always boot back into macOS.

Mitigations:
- **`bless --nextonly`** — boot device falls back to macOS if the ESP boot files fail (but NOT if the installer succeeds in starting and then fails mid-process)
- **Webhook monitoring** — receive real-time status updates at each installation stage with progress percentages (2-100%)
- **SSH into installer** — debug during installation before target system is written
- **Test in VirtualBox first** — validate the entire flow before touching real hardware
- **Fallback: Target Disk Mode** — MacBook on network + Thunderbolt cable for emergency recovery

## Monitoring

The `macpro-monitor/` Node.js server provides a real-time dashboard for headless installation monitoring:

**Two event sources:**
1. **Subiquity/Curtin built-in events** — sent automatically via the `reporting.macpro-monitor` webhook config at DEBUG level. These include network configuration, storage operations, package installation, and other installer events.
2. **Custom progress events** — sent via `curl` calls in `early-commands` and `late-commands` with `{progress, stage, status, message}` payloads. These track WiFi driver compilation, SSH startup, DKMS build, netplan config, GRUB setup, etc.

**Dashboard layout:**
- **Subiquity Events pane** — all built-in installer events with level badges (DEBUG/INFO/WARN/ERROR) and result badges (SUCCESS/FAIL)
- **Custom Progress pane** — stage-specific progress events with progress percentages and status icons
- **Status panel** — last event summaries, event counts, error/warning counts, config info

**Progress stages reported:**

| Stage | Range | Description |
|-------|-------|-------------|
| `prep-init` | 2% | Autoinstall started, validating kernel headers |
| `prep-headers` | 5% | Installing kernel headers |
| `prep-toolchain` | 10% | Installing build toolchain |
| `prep-dkms` | 13-15% | Installing DKMS, building wl driver |
| `prep-wifi` | 18-22% | WiFi driver loaded, interface detected |
| `prep-ssh` | 23-25% | SSH server ready for debugging |
| `late-init` | 30% | Late commands started |
| `late-headers` | 35% | Stage 1/4: kernel headers into target |
| `late-libs` | 45% | Stage 2/4: base libraries into target |
| `late-tools` | 55% | Stage 3/4: build tools into target |
| `late-dkms` | 60-65% | Stage 4/4: DKMS compile WiFi driver for target |
| `late-netplan` | 70-73% | Writing WiFi network configuration |
| `late-grub` | 75-78% | Configuring GRUB bootloader |
| `late-mdns` | 80-83% | Configuring mDNS hostname resolution |
| `late-hold` | 85-88% | Pinning kernel version |
| `late-sudo` | 90% | Configuring sudo |
| `late-logs` | 95% | Saving installation logs |
| `complete` | 100% | Installation complete, rebooting |

Edit `autoinstall.yaml` to change:

| Setting | Location | Default |
|---------|----------|---------|
| WiFi SSID | `network.wifis.wl0.access-points` | `ATTj6pXatS` |
| WiFi password | `network.wifis.wl0.access-points` | `j75b39=z?mpg` |
| Hostname | `identity.hostname` | `macpro-linux` |
| Username | `identity.username` | `teja` |
| SSH keys | `ssh.authorized-keys` | 4 keys |
| Webhook URL | `reporting.macpro-monitor.endpoint` | `http://192.168.1.115:8080/webhook` |
| Reporting level | `reporting.macpro-monitor.level` | `DEBUG` (captures all Subiquity events) |

## Updating Packages

If you need to refresh the `packages/` directory (e.g., for a different kernel version):

```bash
# Download packages from Ubuntu packages archive
# Kernel headers must match the ISO's kernel version
# For example, if the ISO ships with 6.8.0-100-generic, you need:
# - linux-headers-6.8.0-100 (all + generic)
# - broadcom-sta-dkms, dkms
# - gcc-13, make, build-essential, and all build dependencies
# The autoinstall config detects the running kernel dynamically via KVER="$(uname -r)"
# and validates that matching headers exist in /cdrom/macpro-pkgs/
```

## Troubleshooting

### Driver won't compile
```bash
dmesg | grep -i 'dkms\|wl\|broadcom'
cat /run/macpro.log
# Check that kernel headers match running kernel:
ls /cdrom/macpro-pkgs/linux-headers-$(uname -r)_*.deb
# Check DKMS patch application:
cat /var/log/macpro-install/macpro.log | grep -i patch
# Verify DKMS symlink exists:
ls -la /var/lib/dkms/broadcom-sta/6.30.223.271/source
```

### WiFi doesn't connect
```bash
dmesg | grep wl
ip link show | grep wl
lsmod | grep wl
```

### Can't SSH after install
```bash
ssh teja@macpro-linux.local
# Or try IP directly (check router DHCP table)
```

### Kernel updates break WiFi
Kernel is pinned to the ISO's kernel version via `apt-mark hold`. If you must update, you'll need to recompile the driver with the DKMS patches applied:
```bash
# Apply patches to /usr/src/broadcom-sta-6.30.223.271/ first, then:
sudo dkms build broadcom-sta/6.30.223.271 -k <new-kernel>
sudo dkms install broadcom-sta/6.30.223.271 -k <new-kernel>
```