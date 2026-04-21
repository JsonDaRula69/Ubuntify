# Ubuntify — Mac Pro 2013 Ubuntu Autoinstall

> **This document is for humans.** It covers how to use the deployment tool, what each feature does, and how to troubleshoot problems. For machine-oriented architecture details, code conventions, and constraint specifications, see `AGENTS.md`. For a record of what changed between versions, see `CHANGELOG.md`.
>
> **What this document contains:** Quick start guides, usage examples, feature descriptions, troubleshooting, and operational instructions.  
> **What this document does NOT contain:** Bug fix histories, change logs, or version-specific deltas — those belong in `CHANGELOG.md`.

Automated Ubuntu Server 24.04.4 deployment for Mac Pro 2013 (MacPro6,1) with Broadcom BCM4360 WiFi. Four deployment methods: internal ESP partition, USB drive, full manual, or VM test. Supports dual-boot (macOS preserved) and full-disk layouts, WiFi-only and Ethernet configurations.

## Specifications

### Hardware
- **Model**: Mac Pro 2013 (MacPro6,1), trash can design
- **GPU**: AMD FirePro D300/D500/D700 (amdgpu driver, `nomodeset amdgpu.si.modeset=0`)
- **WiFi**: Broadcom BCM4360 — requires proprietary `wl` driver, not in Ubuntu
- **Storage**: Apple PCIe SSD via AHCI → `/dev/sda` (not NVMe)
- **2 Ethernet ports** (may be plugged in for Ethernet installs)

### Operational Constraints
- **Keyboard + monitor available** — for boot selection (hold Option at startup)
- **macOS 12.7.6 running** — accessible via SSH
- **SIP is always enabled** — blocks bless NVRAM writes; boot device must be selected via keyboard Option key or System Preferences Startup Disk
- **Dual-boot or full-disk** — dual-boot preserves macOS with `preserve: true`; full-disk wipes everything
- **MacBook available on network** — can serve as monitoring/webhook endpoint

### Circular Dependency Problem
Mac Pro has no Ethernet. Broadcom BCM4360 WiFi requires a proprietary `wl` driver not included in Ubuntu. Without WiFi, the installer can't download packages. Without packages, we can't compile the driver. The `packages/` directory on the ISO breaks this cycle.

## Solution Overview

**Interactive deployment via `prepare-deployment.sh`**:

1. Build a modified Ubuntu Server ISO: extract original, overlay custom files, repack preserving original EFI boot structure
2. Run `prepare-deployment.sh` — interactive menu selects method, storage layout, and network type
3. For internal ESP: shrinks APFS, creates 5GB ESP, extracts ISO, generates autoinstall config, attempts bless
4. For USB: creates bootable USB with autoinstall
5. For manual: dd's standard Ubuntu ISO to USB
6. For VM test: builds VM ISO, creates VirtualBox VM, starts monitor — validates autoinstall flow without Mac Pro hardware
7. Boot device selected via keyboard Option key (SIP blocks bless NVRAM writes)
8. After Ubuntu installs, `efibootmgr` from Linux sets permanent boot order

## Files

| File | Purpose |
|------|---------|
| `prepare-deployment.sh` | Interactive deployment script: ESP partition, USB, manual, or VM test |
| `lib/autoinstall.yaml` | Autoinstall config template — all credentials are `__PLACEHOLDER__` markers |
| `lib/autoinstall.sh` | Template engine: substitutes placeholders from `deploy.conf` into `autoinstall.yaml` |
| `lib/build-iso.sh` | Builds modified ISO: extract, overlay, repack preserving EFI boot (`--vm` for VM test) |
| `lib/deploy.conf.example` | Config template: copy to `~/.Ubuntu_Deployment/deploy.conf` and customize |
| `packages/` | .deb files for driver compilation (36 packages) |
| `packages/dkms-patches/` | 6 DKMS patches for kernel 6.8+ compatibility (series file + *.patch) |
| `tests/` | Unit tests (`run_tests.sh`) and VM test environment |
| `ssh/` | SSH config template (`config.example`) for `macpro` and `macpro-linux` hosts |
| `prereqs/` | Stock Ubuntu 24.04.4 Server ISO (`*.iso` gitignored) |
| `macpro-monitor/` | Node.js webhook server for installation monitoring (3-pane dashboard) |
| `CHANGELOG.md` | Version history — what changed in each release |
| `AGENTS.md` | Architecture and implementation details for LLM agents and automation tools |

## Prerequisites

### macOS (build/deploy machine)
- **Python 3** — for dynamic storage config generation (`python3` in PATH)
- **xorriso** — ISO repackaging (`brew install xorriso`)
- **gptfdisk** — GPT partition table manipulation (`brew install gptfdisk`, provides `sgdisk`)

**For remote mode** (deploying from another machine):
- **SSH access** to the Mac Pro's macOS partition (key-based auth recommended)
- **Same prerequisites must be installed on the Mac Pro** (xorriso, gptfdisk, python3) — the script can auto-install them via Homebrew

```bash
brew install xorriso gptfdisk python3
```

## Quick Start

### Build the ISO (required for all methods)

```bash
sudo ./lib/build-iso.sh
```

### Deploy (interactive menu)

```bash
# Local mode (run directly on Mac Pro)
sudo ./prepare-deployment.sh

# Remote mode (control Mac Pro from another machine)
./prepare-deployment.sh --deploy-mode remote --target-host macpro
```

Select deployment method:
1. **Internal partition** — copies installer to CIDATA ESP on internal disk (requires APFS shrink for dual-boot)
2. **USB drive** — creates bootable USB with autoinstall
3. **Full manual** — creates standard Ubuntu USB (no autoinstall)
4. **VM test** — validates autoinstall flow in VirtualBox (no Mac Pro hardware needed)

Then select storage layout (dual-boot or full-disk) and network type (WiFi or Ethernet).

### Boot Selection

After deployment, select the boot device:

1. Hold **Option** at startup chime
2. Use arrow keys to select CIDATA (internal) or EFI Boot (USB)
3. Press Enter to boot Ubuntu installer

**Note**: USB dongle keyboards (e.g., Koorui BKM01) may not register the Option key in time due to reconnection delay after power cycle. Multi-key chords (Cmd+Option+R for Recovery) work because firmware uses a wider polling window.

### Revert a failed deployment

```bash
sudo ./prepare-deployment.sh --revert
```

### Start Webhook Monitor

```bash
cd macpro-monitor && ./start.sh
# Dashboard: http://<your-ip>:8080
# Webhook:   http://<your-ip>:8080/webhook
```

## Architecture

### What's Added to the ISO

1. `/autoinstall.yaml` — installation configuration (generated from `lib/autoinstall.yaml` template)
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

### lib/autoinstall.yaml Key Sections

**early-commands** (before network, in installer environment):
1. Detect running kernel dynamically → validate matching headers exist
2. Install kernel headers and build toolchain from discovered `macpro-pkgs/` mount
3. Install `broadcom-sta-dkms` and `dkms` — postinst auto-runs `dkms add` (creates symlink)
4. Apply 6 DKMS patches from `macpro-pkgs/dkms-patches/` — FATAL if missing or fail
5. Compile `wl.ko` via DKMS (`dkms build` + `dkms install`), single-retry fallback
6. Load driver with `modprobe wl` — FATAL if fails
7. Wait for WiFi interface (60s timeout), verify connectivity (scan + DHCP + HTTP)
8. Start SSH server (fallback to ISO pool `.deb`s with `--force-depends`)

**network** (WiFi-only): No `wifis:` section (networkd doesn't support `match:` for wifis). Netplan generated in early-commands after driver load with auto-detected interface name.

**network** (Ethernet available): `ethernets:` with `match: name: "en*"` and `dhcp4: true`

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

The `prepare-deployment.sh` script uses Python + `sgdisk` to:
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

For updating the running Ubuntu system, including kernel updates, see the [Updating the System (Kernel Updates)](#updating-the-system-kernel-updates) section below.

## Updating the System (Kernel Updates)

**CRITICAL**: This machine has **zero physical access** and **WiFi-only networking** via a proprietary Broadcom BCM4360 `wl` driver. A kernel update that breaks the WiFi driver bricks the machine remotely. Follow this process **exactly** — every verification step exists for a reason.

### The Circular Dependency Problem

```
New kernel installed → DKMS must recompile wl driver for new kernel
     ↑                                        ↓
     └── if wl fails on new kernel boot → NO SSH (no Ethernet) → BRICKED
```

The `broadcom-sta-dkms` package uses DKMS to auto-compile the `wl` WiFi driver when a new kernel is installed. During installation, 6 compatibility patches were applied to `/usr/src/broadcom-sta-6.30.223.271/` to make the driver compile on kernel 6.8+. These patches persist on disk. DKMS will attempt to use them when building for any new kernel.

**If the patches don't apply to the new kernel** (ABI break, new kernel API changes), the build fails, `wl.ko` is not produced for that kernel, and rebooting into it means no WiFi, no SSH, no recovery.

### Current Safeguards Installed

The autoinstall config locked the system down to prevent accidental kernel updates:

| Layer | File/Command | Effect |
|-------|-------------|--------|
| apt preferences | `/etc/apt/preferences.d/99-pin-kernel` | Blocks all `linux-{image,headers,modules}-*` at priority -1; allows only `6.8.0-100*` at 1001 |
| apt-mark hold | `linux-image-6.8.0-100-generic` etc. | `apt-get upgrade` skips held packages |
| Sources commented out | `/etc/apt/sources.list` | `apt-get update` finds nothing |
| Auto-updates disabled | `apt-daily*` masked, `APT::Periodic::* = 0` | Nothing runs automatically |
| Snap held | `snap refresh --hold=forever` | Snap kernel snaps frozen |

**These must be temporarily removed for the update, then re-applied afterward.**

### Pre-Update Checklist

Run these **before** starting any update steps:

```bash
# 1. Record current kernel
CURRENT_KERNEL="$(uname -r)"
echo "Current kernel: $CURRENT_KERNEL"

# 2. Verify WiFi is working RIGHT NOW
ping -c 3 google.com || { echo "ABORT: WiFi not working before update"; exit 1; }

# 3. Verify DKMS patches still exist on disk
ls /usr/src/broadcom-sta-6.30.223.271/
cat /usr/src/broadcom-sta-6.30.223.271/.patched 2>/dev/null || \
  ls /usr/src/broadcom-sta-6.30.223.271/ | head -5

# 4. Record current DKMS status
dkms status broadcom-sta

# 5. Verify the wl module is loaded
lsmod | grep wl
modinfo wl 2>/dev/null || modinfo /lib/modules/$CURRENT_KERNEL/updates/dkms/wl.ko

# 6. Save this output — you'll need it for comparison
```

**If any of these fail, DO NOT proceed.** Fix the current system first.

### Update Process (8 Phases)

#### Phase 1: Enable apt Sources

```bash
# Uncomment all apt sources
sudo sed -i 's/^#deb/deb/' /etc/apt/sources.list
for list in /etc/apt/sources.list.d/*.list; do
  [ -f "$list" ] && sudo sed -i 's/^#deb/deb/' "$list"
done

# Verify sources are active
grep -c '^deb' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null
```

#### Phase 2: Remove Holds and Pinning

```bash
# Get current kernel version (for removing holds)
KVER="$(uname -r)"

# Remove apt-mark holds on current kernel packages
sudo apt-mark unhold "linux-image-${KVER}" 2>/dev/null || true
sudo apt-mark unhold "linux-headers-${KVER}" 2>/dev/null || true
sudo apt-mark unhold "linux-modules-${KVER}" 2>/dev/null || true
sudo apt-mark unhold "linux-modules-extra-${KVER}" 2>/dev/null || true

# Remove apt preferences that block kernel updates
sudo rm /etc/apt/preferences.d/99-pin-kernel

# Re-enable auto-update timers (optional, for this session only)
sudo systemctl unmask apt-daily.service apt-daily.timer 2>/dev/null || true
sudo systemctl unmask apt-daily-upgrade.service apt-daily-upgrade.timer 2>/dev/null || true
```

#### Phase 3: Update Package Lists and Run Upgrade

```bash
# Update package lists
sudo apt-get update

# Run full upgrade (this will install a new kernel if available)
# --with-new-pkgs ensures new kernel packages are pulled in
sudo apt-get dist-upgrade -y
```

> **NOTE**: `dist-upgrade` may install a new kernel. DKMS will **automatically attempt** to build `broadcom-sta` for the new kernel during the `linux-headers-*` postinst. **Watch for DKMS build output** in the apt output. If you see `dkms: build failed`, proceed to Phase 4 Step 2 (manual DKMS build).

#### Phase 4: Verify DKMS Built Successfully for New Kernel

This is the **most critical step**. Do not skip any sub-step.

```bash
# Step 1: Identify what kernels are now installed
ls /boot/vmlinuz-*
echo "---"
dkms status broadcom-sta

# Step 2: If DKMS did NOT auto-build for the new kernel, do it manually
# Replace NEW_KVER with the newly installed kernel version (e.g., 6.8.0-200-generic)
NEW_KVER="<from ls output above, the NEWEST version>"

# Check if DKMS already built for the new kernel
if ! dkms status broadcom-sta/6.30.223.271 -k "$NEW_KVER" 2>/dev/null | grep -q installed; then
  echo "DKMS did not auto-build for $NEW_KVER — building manually..."

  # Try DKMS build for the new kernel
  if ! sudo dkms build broadcom-sta/6.30.223.271 -k "$NEW_KVER"; then
    echo "=== DKMS BUILD FAILED FOR NEW KERNEL ==="
    echo "The WiFi driver CANNOT compile for kernel $NEW_KVER."
    echo "DO NOT REBOOT into this kernel."
    echo "Proceed to the ABORT AND ROLLBACK section below."
    exit 1
  fi

  # Install the module into the new kernel's modules directory
  if ! sudo dkms install broadcom-sta/6.30.223.271 -k "$NEW_KVER"; then
    echo "=== DKMS INSTALL FAILED FOR NEW KERNEL ==="
    echo "DO NOT REBOOT into this kernel."
    echo "Proceed to the ABORT AND ROLLBACK section below."
    exit 1
  fi
fi

# Step 3: Verify wl.ko exists for the new kernel
if [ ! -f "/lib/modules/$NEW_KVER/updates/dkms/wl.ko" ] && \
   [ ! -f "/lib/modules/$NEW_KVER/extra/wl.ko" ]; then
  echo "=== FATAL: wl.ko NOT FOUND for kernel $NEW_KVER ==="
  echo "DO NOT REBOOT into this kernel."
  echo "Proceed to the ABORT AND ROLLBACK section below."
  exit 1
fi

echo "SUCCESS: wl.ko exists for new kernel $NEW_KVER"

# Step 4: Verify the module can be loaded (without actually loading it —
# we're still on the old kernel, so modprobe would load the old one.
# Instead, check that the module metadata is valid.)
modinfo "/lib/modules/$NEW_KVER/updates/dkms/wl.ko" 2>/dev/null || \
  modinfo "/lib/modules/$NEW_KVER/extra/wl.ko" 2>/dev/null || {
  echo "=== FATAL: wl.ko metadata invalid for $NEW_KVER ==="
  exit 1
}

# Step 5: Ensure initramfs includes the wl module for the new kernel
sudo update-initramfs -u -k "$NEW_KVER"
```

#### Phase 5: Configure GRUB Fallback (SAFETY NET)

**This is the key safety mechanism.** We configure GRUB so the machine defaults to the OLD (known-working) kernel. The new kernel is available in the GRUB menu, but NOT the default. If the new kernel fails, a simple power cycle reverts to the old kernel.

```bash
# Record kernel versions
OLD_KVER="$(uname -r)"
NEW_KVER="<from Phase 4>"

# Make GRUB remember the last booted entry and default to saved
sudo sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
echo 'GRUB_SAVEDEFAULT=true' | sudo tee -a /etc/default/grub

# Set the OLD (working) kernel as the default boot entry
# This ensures a power cycle returns to the working kernel
sudo grub-set-default "Ubuntu, with Linux ${OLD_KVER}"

# Update GRUB
sudo update-grub

# Verify the default is set correctly
sudo grub-editenv list 2>/dev/null || sudo grep -A1 'menuentry' /boot/grub/grub.cfg | head -20
```

#### Phase 6: Reboot Into New Kernel

```bash
# Use grub-reboot to boot the NEW kernel ONE TIME ONLY
# If it fails, power cycling will return to the OLD kernel (the saved default)
# Replace the menu entry name with the exact string from /boot/grub/grub.cfg
sudo grub-reboot "Ubuntu, with Linux ${NEW_KVER}"
sudo reboot
```

**After reboot, from your MacBook/other machine:**

```bash
# Wait 60-90 seconds, then attempt SSH
ssh macpro-linux

# If SSH connects, verify:
uname -r                    # Should show NEW kernel
lsmod | grep wl             # WiFi driver loaded?
ping -c 3 google.com        # WiFi actually working?
dkms status broadcom-sta    # DKMS reports installed for new kernel?
```

#### Phase 7: Post-Update — Re-lock the System

**Only do this after confirming the new kernel works with WiFi.**

```bash
NEW_KVER="$(uname -r)"

# Step 1: Set new kernel as GRUB default (it works, make it permanent)
sudo grub-set-default "Ubuntu, with Linux ${NEW_KVER}"

# Step 2: Re-apply apt-mark holds for the NEW kernel
sudo apt-mark hold "linux-image-${NEW_KVER}"
sudo apt-mark hold "linux-headers-${NEW_KVER}"
sudo apt-mark hold "linux-modules-${NEW_KVER}"
sudo apt-mark hold "linux-modules-extra-${NEW_KVER}" 2>/dev/null || true

# Step 3: Re-write apt preferences to pin to the NEW kernel
sudo tee /etc/apt/preferences.d/99-pin-kernel > /dev/null << 'PREFS'
Package: linux-image-*
Pin: release o=Ubuntu
Pin-Priority: -1

Package: linux-headers-*
Pin: release o=Ubuntu
Pin-Priority: -1

Package: linux-modules-*
Pin: release o=Ubuntu
Pin-Priority: -1

Package: linux-image-REPLACE_KVER*
Pin: release o=Ubuntu
Pin-Priority: 1001

Package: linux-headers-REPLACE_KVER*
Pin: release o=Ubuntu
Pin-Priority: 1001

Package: linux-modules-REPLACE_KVER*
Pin: release o=Ubuntu
Pin-Priority: 1001
PREFS

# Replace placeholder with actual kernel ABI version
# e.g., 6.8.0-200 from NEW_KVER=6.8.0-200-generic
NEW_ABI="$(echo "$NEW_KVER" | sed 's/-generic$//')"
sudo sed -i "s/REPLACE_KVER/${NEW_ABI}/g" /etc/apt/preferences.d/99-pin-kernel

# Step 4: Comment out apt sources again
sudo sed -i '/^deb/ s/^/#/' /etc/apt/sources.list
for list in /etc/apt/sources.list.d/*.list; do
  [ -f "$list" ] && sudo sed -i '/^deb/ s/^/#/' "$list"
done

# Step 5: Re-disable auto-update timers
sudo systemctl mask apt-daily.service 2>/dev/null || true
sudo systemctl mask apt-daily.timer 2>/dev/null || true
sudo systemctl mask apt-daily-upgrade.service 2>/dev/null || true
sudo systemctl mask apt-daily-upgrade.timer 2>/dev/null || true

# Step 6: Re-disable auto-upgrades config
sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null << 'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
APT::Periodic::Download-Upgradeable-Packages "0";
EOF

# Step 7: Hold snap refreshes
sudo snap refresh --hold=forever 2>/dev/null || true

# Step 8: Verify the lockdown
echo "=== Verification ==="
echo "Kernel: $(uname -r)"
apt-mark showhold | grep linux
cat /etc/apt/preferences.d/99-pin-kernel
grep -c '^#deb' /etc/apt/sources.list
dkms status broadcom-sta
lsmod | grep wl
ping -c 3 google.com
```

#### Phase 8: Clean Up Old Kernel (Optional)

**Only after confirming the new kernel is fully stable.** Keep the old kernel as a fallback for at least a few days.

```bash
# List installed kernels
dpkg -l | grep linux-image | grep '^ii'

# Remove the old kernel (replace with your old version)
OLD_KVER="<previous kernel version>"
sudo apt-get remove "linux-image-${OLD_KVER}" "linux-headers-${OLD_KVER}" "linux-modules-${OLD_KVER}" "linux-modules-extra-${OLD_KVER}" -y
sudo update-grub
```

### ABORT AND ROLLBACK

If DKMS failed to build for the new kernel in Phase 4, or if the new kernel booted but WiFi is broken:

#### Scenario A: DKMS build failed (before reboot)

The new kernel is installed but you haven't rebooted. You're still on the working kernel.

```bash
# Re-apply all safeguards immediately
KVER="$(uname -r)"
sudo apt-mark hold "linux-image-${KVER}"
sudo apt-mark hold "linux-headers-${KVER}"
sudo apt-mark hold "linux-modules-${KVER}"
sudo apt-mark hold "linux-modules-extra-${KVER}" 2>/dev/null || true

# Re-create apt preferences
NEW_ABI="$(echo "$KVER" | sed 's/-generic$//')"
sudo tee /etc/apt/preferences.d/99-pin-kernel > /dev/null << PREFS
Package: linux-image-*
Pin: release o=Ubuntu
Pin-Priority: -1

Package: linux-headers-*
Pin: release o=Ubuntu
Pin-Priority: -1

Package: linux-modules-*
Pin: release o=Ubuntu
Pin-Priority: -1

Package: linux-image-${NEW_ABI}*
Pin: release o=Ubuntu
Pin-Priority: 1001

Package: linux-headers-${NEW_ABI}*
Pin: release o=Ubuntu
Pin-Priority: 1001

Package: linux-modules-${NEW_ABI}*
Pin: release o=Ubuntu
Pin-Priority: 1001
PREFS

# Comment out sources
sudo sed -i '/^deb/ s/^/#/' /etc/apt/sources.list
for list in /etc/apt/sources.list.d/*.list; do
  [ -f "$list" ] && sudo sed -i '/^deb/ s/^/#/' "$list"
done

# Optionally remove the broken new kernel
# sudo apt-get remove "linux-image-${NEW_KVER}" "linux-headers-${NEW_KVER}" -y
# sudo update-grub

echo "ROLLBACK COMPLETE — system remains on working kernel $KVER"
```

#### Scenario B: New kernel booted but WiFi doesn't work

You rebooted and can't SSH in. **This is the worst case.**

1. **Power cycle the Mac Pro** (pull power or use IPMI if available — this machine has no IPMI, so physical power cycle may be required)
2. GRUB is configured with `GRUB_DEFAULT=saved` and `GRUB_SAVEDEFAULT=true` from Phase 5. However, since the new kernel was selected via `grub-reboot` (one-time override), the **saved default** is still the old kernel. A normal reboot (not `grub-reboot`) will boot the old kernel.
3. If a simple reboot doesn't work (GRUB saved the new kernel as default because it booted successfully), you'll need:
   - **SSH from macOS side**: If macOS is still on the disk and `bless` was set with `--nextonly`, the firmware may revert to macOS. From macOS, you can re-bless the Ubuntu ESP and use `grub-editenv` or modify GRUB config to default to the old kernel.
   - **Physical access as last resort**: Hold Option at boot → select macOS → fix GRUB from macOS.

**Mitigation**: Before rebooting in Phase 6, verify that `sudo grub-editenv list` shows the old kernel as the saved default. The `grub-reboot` command only overrides for ONE boot; the saved default remains unchanged.

### Non-Kernel Security Updates (Safe Shortcut)

For security updates that do NOT touch the kernel, a simplified process works:

```bash
# Just update non-kernel packages
sudo sed -i 's/^#deb/deb/' /etc/apt/sources.list
for list in /etc/apt/sources.list.d/*.list; do
  [ -f "$list" ] && sudo sed -i 's/^#deb/deb/' "$list"
done
sudo apt-get update
sudo apt-get upgrade -y --exclude=linux-image-*,linux-headers-*,linux-modules-*
sudo sed -i '/^deb/ s/^/#/' /etc/apt/sources.list
for list in /etc/apt/sources.list.d/*.list; do
  [ -f "$list" ] && sudo sed -i '/^deb/ s/^/#/' "$list"
done
```

This avoids the kernel entirely while still getting security patches for all other packages.

### Update Frequency Recommendation

| Update Type | Frequency | Risk |
|-------------|-----------|------|
| Security updates (non-kernel) | Monthly or as needed for critical CVEs | Low — DKMS not involved |
| Kernel update | Only when required by security CVE | Medium-High — requires full process above |
| Full `dist-upgrade` | Quarterly at most | High — likely pulls new kernel |

> **WARNING — Critical Safety Rules:**
> - **NEVER** run `apt-get dist-upgrade` or install a new kernel without following the full process above.
> - **NEVER** reboot without first configuring GRUB fallback (Phase 5).
> - **NEVER** skip Phase 4 verification — DKMS status MUST show `installed` for the new kernel before rebooting.
> - **NEVER** remove the apt preferences, holds, or commented-out sources without immediately re-applying them after the update.
> - **NEVER** assume DKMS auto-build succeeded — always verify explicitly with `dkms status`.
> - **ALWAYS** confirm WiFi works post-reboot before re-locking the system (Phase 7).
> - **ALWAYS** use `grub-reboot` for the first boot into a new kernel — never set it as the GRUB default until verified working.
> - **If DKMS build fails, ALWAYS enter ABORT AND ROLLBACK immediately** — never attempt to reboot into a kernel without a working `wl.ko`.

## Erasing macOS and Expanding to Full Disk

### Overview

The initial dual-boot installation preserves macOS on separate APFS partitions. Once Ubuntu is confirmed working and you want to reclaim all disk space, this operation:

1. Identifies and deletes all macOS/APFS partitions
2. Expands the Ubuntu root (`/`) partition into the freed space
3. Updates GRUB and fstab
4. Removes the macOS boot entry from GRUB and `efibootmgr`
5. Verifies the system still boots and WiFi works

**When to do this**: After confirming Ubuntu works properly, you want the full disk for Ubuntu, and you no longer need macOS on this machine.

### Danger Summary

| Risk | Consequence | Mitigation |
|------|-------------|------------|
| Deleting the wrong partition | Data loss, unbootable system | Step 1 has explicit partition identification with verification prompts |
| Root partition resize fails | Root filesystem corruption | Step 3 reads current state first, uses `growpart` + `resize2fs` (safe, in-place) |
| GRUB misconfiguration after partition deletion | Unbootable system | Step 4 regenerates GRUB, Step 5 verifies before declaring success |
| Boot-recovery partition accidentally deleted | No fallback | EFI System Partition (ESP) is never touched — it's a separate partition |

### Prerequisites

Before executing this operation, verify:

```bash
# You have active SSH access RIGHT NOW
whoami  # must succeed
ping -c 3 google.com  # WiFi must be working
uname -r  # record current kernel
dkms status broadcom-sta  # record DKMS status
```

**If any prerequisite fails, DO NOT proceed.**

### Step 1: Identify the Current Partition Layout

```bash
# List all partitions with types and labels
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT /dev/sda
echo "---"
# Show GPT partition details
sudo sgdisk -p /dev/sda
echo "---"
# Identify which partitions belong to macOS vs Ubuntu
# macOS partitions: FSTYPE=apfs, or partition type GUID C12A7328-F81F-11D2-BA4B-00A0C93EC93B (EFI)
#   or 426F6F74-0000-11AA-AA11-00306543ECAC (Apple Boot / Recovery HD)
#   or 7C3457EF-0000-11AA-AA11-00306543ECAC (Apple APFS)
# Ubuntu partitions: the ones currently MOUNTED (/ and /boot)
```

**Read the output and classify every partition as either macOS or Ubuntu before proceeding.** Classification rules:

| Partition Type | Classification | Action |
|---------------|----------------|--------|
| Mounted at `/` | Ubuntu root | **DO NOT DELETE** |
| Mounted at `/boot` | Ubuntu boot | **DO NOT DELETE** |
| Mounted at `/boot/efi` | EFI System Partition | **DO NOT DELETE** — shared by both OSes |
| FSTYPE contains `apfs` | macOS | Target for deletion |
| TYPE GUID `7C3457EF-...` | Apple APFS container | Target for deletion |
| TYPE GUID `426F6F74-...` | Apple Boot/Recovery | Target for deletion |
| LABEL contains `Macintosh` or `Recovery` | macOS | Target for deletion |
| Swap partition (FSTYPE=`swap`) | Ubuntu | **DO NOT DELETE** |

**Record the partition numbers to delete. You will need them in Step 2.**

### Step 2: Delete macOS Partitions

**⚠️  WARNING: This step is IRREVERSIBLE. Once partitions are deleted, macOS data is gone forever.**

Before deleting, create a backup of the partition table:

```bash
# Save current GPT partition table (for emergency recovery)
sudo sgdisk -b /tmp/gpt-backup-$(date +%Y%m%d%H%M%S).bin /dev/sda
echo "GPT backup saved. In emergency: sgdisk -l <backup-file> /dev/sda"
```

**Delete each identified macOS partition by number:**

```bash
# Replace N1, N2, N3 with the actual partition numbers from Step 1
# DELETE ONE AT A TIME — verify each succeeds
# EXAMPLE (adjust partition numbers based on Step 1):
# sudo sgdisk -d 3 /dev/sda    # Delete partition 3 (macOS APFS)
# sudo sgdisk -d 4 /dev/sda    # Delete partition 4 (Recovery HD)
# etc.

# IMPORTANT: After each deletion, partition NUMBERS may shift.
# Re-read the partition table after EACH deletion:
# sudo sgdisk -p /dev/sda
# Then identify the NEXT macOS partition by its new number.
```

**Verification after all deletions:**

```bash
sudo sgdisk -p /dev/sda
# Confirm: no APFS partitions remain, no Apple Boot partitions remain
# Confirm: Ubuntu partitions (/, /boot, /boot/efi) still exist
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT /dev/sda
# Confirm: / and /boot are still mounted and accessible
df -h / /boot
# Confirm: filesystem still writable
touch /tmp/write-test && rm /tmp/write-test
```

**If verification fails at any point, STOP. Do NOT proceed.** The system may need a reboot to re-read the partition table, but only if all critical partitions are intact.

### Step 3: Expand the Root Partition into Free Space

The freed space from deleted macOS partitions is now unallocated. Expand the root (`/`) partition to consume it.

```bash
# Step 3a: Identify the root partition number
ROOT_PART=$(lsblk -no NAME,MOUNTPOINT /dev/sda | grep ' /$' | grep -oE '[0-9]+')
ROOT_DISK="/dev/sda"
ROOT_DEVICE="${ROOT_DISK}${ROOT_PART}"  # e.g., /dev/sda5

echo "Root partition: ${ROOT_DEVICE} (partition ${ROOT_PART})"
lsblk "$ROOT_DEVICE"
df -h /

# Step 3b: Check that free space exists AFTER the root partition
# (partitions between root and free space would block resize)
sudo parted /dev/sda print free
# Look for "Free Space" entries after the root partition
# If free space is NOT adjacent to the root partition, you must
# rearrange partitions first (advanced — consult the user)

# Step 3c: Use growpart to expand the partition (safe, in-place)
# growpart is installed by default on Ubuntu Server
sudo growpart /dev/sda "$ROOT_PART"

# Step 3d: Resize the ext4 filesystem to fill the expanded partition
sudo resize2fs "${ROOT_DEVICE}"

# Step 3e: Verify
df -h /
# The "Size" column should now reflect the full available disk space
# (minus /boot, /boot/efi, and any remaining partitions)
```

**Troubleshooting:**

| Error | Cause | Fix |
|-------|-------|-----|
| `growpart` fails with "no free space" | Free space not adjacent to root partition | Must move partitions — ask user before proceeding |
| `resize2fs` fails | Partition wasn't actually expanded | `sudo partprobe /dev/sda` then retry `resize2fs` |
| `growpart` not found | Not installed | `sudo apt-get install cloud-guest-utils` — but sources may be commented out, so uncomment first |

### Step 4: Update GRUB and Remove macOS Boot Entries

```bash
# Step 4a: Remove the macOS GRUB menu entry (no longer needed)
sudo rm -f /etc/grub.d/40_macos

# Step 4b: Remove fwsetup entry if it's the only macOS boot method
# Check if 40_macos was the only custom entry:
ls /etc/grub.d/

# Step 4c: Update GRUB configuration
sudo update-grub

# Step 4d: Remove macOS from EFI boot manager
export LIBEFIVAR_OPS=efivarfs  # Workaround for Apple EFI 1.1 bug
# List all boot entries
efibootmgr
# Find the macOS boot entry number (Boot80, Boot81, or any "macOS"/"Apple" entry)
# Delete it:
# MACOS_ENTRY=$(efibootmgr | grep -i "macos\|apple" | head -1 | grep -oE 'Boot[0-9A-F]+' | sed 's/Boot//')
# if [ -n "$MACOS_ENTRY" ]; then
#   sudo efibootmgr --delete-bootnum --bootnum "$MACOS_ENTRY"
#   echo "Removed macOS boot entry: $MACOS_ENTRY"
# else
#   echo "No macOS boot entry found in EFI — nothing to remove"
# fi

# Step 4e: Remove the boot-macos script (no longer needed)
sudo rm -f /usr/local/bin/boot-macos

# Step 4f: Verify GRUB config no longer references macOS
grep -i "macos\|apple\|fwsetup" /boot/grub/grub.cfg && echo "WARNING: macOS references still in GRUB" || echo "GRUB clean — no macOS references"
```

### Step 5: Verify and Reboot

```bash
# Step 5a: Verify the system is still functional before reboot
echo "=== Pre-reboot verification ==="
uname -r
lsmod | grep wl  # WiFi driver loaded
ping -c 3 google.com  # WiFi working
df -h / /boot /boot/efi  # All filesystems mounted
cat /etc/fstab  # fstab intact
ls /boot/vmlinuz-*  # Kernel still present
sudo grub-editenv list 2>/dev/null || echo "GRUB env block OK"
echo "=== Verification complete ==="

# Step 5b: Reboot
sudo reboot
```

**After reboot, from your MacBook/other machine:**

```bash
# Wait 60-90 seconds, then attempt SSH
ssh macpro-linux

# Verify:
uname -r  # Kernel
lsmod | grep wl  # WiFi driver
ping -c 3 google.com  # Network
df -h /  # Full disk now available
lsblk /dev/sda  # Only Ubuntu partitions remain
```

### Step 6 (Optional): Extend Swap

If the root partition was significantly expanded and you want swap space:

```bash
# Check if swap exists
swapon --show

# If no swap, create a swapfile on the expanded root filesystem:
sudo fallocate -l 8G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

# Make it persistent:
grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

# Verify:
free -h
```

### Rollback Information

**Once macOS partitions are deleted (Step 2), there is NO rollback.** macOS data is gone. The GPT backup saved in Step 2 only restores the partition table entries, not the data.

The only reversible step is the partition expansion — if `growpart` fails before `resize2fs`, the partition table can be restored from the GPT backup:

```bash
# EMERGENCY ONLY: Restore GPT from backup
sudo sgdisk -l /tmp/gpt-backup-*.bin /dev/sda
sudo reboot
```

**If Step 2 has been executed (partitions deleted), there is no undo.** Proceed with Steps 3-5. If Step 2 has NOT been executed yet, the operation can be safely cancelled.

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

The kernel is pinned via apt preferences and `apt-mark hold` to prevent accidental updates that could break WiFi. If you need to update the kernel, follow the complete [Updating the System section](#updating-the-system-kernel-updates) above. This includes DKMS verification, GRUB fallback configuration, and rollback procedures.

**Never update the kernel without:**
1. Verifying DKMS can build the `wl` driver for the new kernel
2. Configuring GRUB fallback to the old kernel first
3. Using `grub-reboot` (one-time) for the first boot into the new kernel
4. Confirming WiFi works before making the new kernel permanent

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

WiFi SSID and password are in plain text in the generated `autoinstall.yaml` (on the FAT32 ESP during install). Mitigations: UFW firewall denies all incoming except SSH, ESP is only accessible during install. Credentials come from `~/.Ubuntu_Deployment/deploy.conf` (encrypted at rest) and are substituted into the template at build time.

## VM Test Environment

```bash
cd tests/vm && ./create-vm.sh && ./test-vm.sh
# Or build the VM test ISO first:
sudo ./lib/build-iso.sh --vm
```

VM uses Ethernet (`enp0s3`) instead of WiFi, DKMS compiles (fatal on failure) but driver init is non-fatal (no Broadcom HW). Webhook targets `10.0.2.2` via NAT.

### Serial Console

Both production and VM GRUB configs include `console=ttyS0,115200` for serial console output. In VirtualBox, UART1 is configured to log to `/tmp/vmtest-serial.log`.

## For Agents and Automation

`prepare-deployment.sh` supports a non-interactive agent mode for LLM agents (Claude Code, Cursor, etc.) and CI/CD pipelines. All operations can be driven via CLI flags with structured JSON output.

> For architecture details, code conventions, constraint specifications, and implementation internals, see `AGENTS.md` (the LLM-oriented companion to this document).

### Agent Mode Flags

```bash
sudo ./prepare-deployment.sh --agent --yes [OPERATION FLAGS]
```

| Flag | Description |
|------|-------------|
| `--agent` | Enable non-interactive agent mode (auto-sets `--json`) |
| `--yes` | Auto-confirm all destructive operation prompts |
| `--json` | Output structured JSON lines (NDJSON) to stdout |
| `--dry-run` | Print what would happen without executing |
| `--verbose` | Enable DEBUG-level logging |

### Deploy Mode (Local Operations)

To build the ISO in agent mode, call `lib/build-iso.sh` directly (there is no `--build-iso` flag in `prepare-deployment.sh`). The deploy methods (1-4) below assume the ISO is already built.

```bash
# Build the ISO
sudo ./lib/build-iso.sh

# Deploy to internal ESP partition (dual-boot, WiFi)  
sudo ./prepare-deployment.sh --agent --yes --method 1 --storage 1 --network 1

# Deploy to USB (full-disk, Ethernet)
sudo ./prepare-deployment.sh --agent --yes --method 2 --storage 2 --network 2

# Dry-run deploy (show what would happen)
sudo ./prepare-deployment.sh --agent --dry-run --method 1 --storage 1 --network 1

# VM test
sudo ./prepare-deployment.sh --agent --yes --method 4
```

### Remote Deployment Mode

In remote mode, you control the Mac Pro from another machine (e.g., a MacBook) via SSH. No local `sudo` is needed — all macOS-specific commands run on the target Mac Pro through SSH. Configuration files are generated locally and transferred via SCP.

```bash
# Interactive remote deployment (prompts for SSH password, config values)
./prepare-deployment.sh --deploy-mode remote --target-host macpro

# Agent mode remote deployment (non-interactive)
./prepare-deployment.sh --agent --yes --deploy-mode remote --target-host macpro \
  --remote-password XXX --method 1 --storage 1 --network 1 --json

# Remote revert (no local sudo needed)
./prepare-deployment.sh --deploy-mode remote --revert
```

**Prerequisites for remote mode:**
1. SSH key authentication to the Mac Pro's macOS partition (set up `ssh/config.example`)
2. `xorriso`, `gptfdisk` (`sgdisk`), and `python3` installed on the Mac Pro — the script can auto-install via Homebrew during preflight
3. Sudo access on the Mac Pro (passwordless recommended, or provide via `--remote-password`)

**How it works:**
- ISO and configuration files are generated locally on your machine
- Disk operations (`diskutil`, `bless`, `sgdisk`, `xorriso`) run on the Mac Pro via SSH
- Files are transferred to the Mac Pro via SCP
- Preflight checks verify the Mac Pro has all required tools before starting

| Flag | Values | Description |
|------|--------|-------------|
| `--method` | `1` | Internal partition (ESP) |
| | `2` | USB drive |
| | `3` | Full manual (standard ISO to USB) |
| | `4` | VM test (VirtualBox) |
| `--storage` | `1` | Dual-boot (preserve macOS) |
| | `2` | Full disk (replace macOS) |
| `--network` | `1` | WiFi only (Broadcom BCM4360) |
| | `2` | Ethernet available |

### Manage Mode (Remote SSH Operations)

```bash
# System info
sudo ./prepare-deployment.sh --agent --operation sysinfo --host macpro-linux

# Kernel status
sudo ./prepare-deployment.sh --agent --operation kernel_status

# Pin kernel
sudo ./prepare-deployment.sh --agent --yes --operation kernel_pin

# Unpin kernel
sudo ./prepare-deployment.sh --agent --yes --operation kernel_unpin

# Kernel update (7-phase process with rollback)
sudo ./prepare-deployment.sh --agent --yes --operation kernel_update

# Security updates (non-kernel)
sudo ./prepare-deployment.sh --agent --yes --operation security_update

# Health check
sudo ./prepare-deployment.sh --agent --operation health_check

# Disk usage
sudo ./prepare-deployment.sh --agent --operation disk_usage

# Rollback status
sudo ./prepare-deployment.sh --agent --operation rollback_status

# Reboot
sudo ./prepare-deployment.sh --agent --yes --operation reboot

# Boot to macOS
sudo ./prepare-deployment.sh --agent --yes --operation boot_macos
```

| Operation | Description | Destructive? |
|-----------|-------------|---------------|
| `sysinfo` | System information (kernel, WiFi, disk, DKMS, uptime) | No |
| `kernel_status` | Kernel version, pin status, held packages, apt preferences | No |
| `kernel_pin` | Pin current kernel, disable apt sources, enable holds | Yes |
| `kernel_unpin` | Unpin kernel, enable apt sources, remove holds | Yes |
| `kernel_update` | Full kernel update process (7 phases with rollback) | Yes |
| `security_update` | Non-kernel security updates only | Yes |
| `health_check` | Comprehensive health check (SSH, WiFi, disk, DKMS, kernel) | No |
| `disk_usage` | Disk usage information | No |
| `rollback_status` | Check for incomplete kernel update | No |
| `driver_status` | WiFi/DKMS driver status check | No |
| `driver_rebuild` | Rebuild DKMS WiFi driver module | Yes |
| `reboot` | Reboot remote system | Yes |
| `boot_macos` | Set next boot to macOS | Yes |
| `erase_macos` | Delete macOS partitions, expand Ubuntu to full disk | Yes |
| `apt_enable` / `apt_disable` | Enable/disable APT package sources | Yes |

**Note**: macOS erasure is a manual process documented in the [Erasing macOS and Expanding to Full Disk](#erasing-macos-and-expanding-to-full-disk) section above. It is not available as an agent `--operation` flag.

### Configuration Overrides

CLI flags override `deploy.conf` settings:

| Flag | Overrides |
|------|-----------|
| `--deploy-mode MODE` | `DEPLOY_MODE` — `local` (on Mac Pro) or `remote` (via SSH) |
| `--target-host HOST` | `TARGET_HOST` — SSH hostname/IP for Mac Pro's macOS |
| `--remote-password PWD` | `REMOTE_SUDO_PASSWORD` — sudo password for target |
| `--username USER` | `USERNAME` |
| `--hostname HOST` | `HOSTNAME` |
| `--wifi-ssid SSID` | `WIFI_SSID` |
| `--wifi-password PASS` | `WIFI_PASSWORD` |
| `--webhook-host HOST` | `WEBHOOK_HOST` |
| `--webhook-port PORT` | `WEBHOOK_PORT` |
| `--host HOST` | Remote SSH host (default: `macpro-linux`) |
| `--output-dir DIR` | `OUTPUT_DIR` |

### JSON Output Format

In agent mode, output is newline-delimited JSON (NDJSON) to stdout:

```json
{"type":"confirm","title":"Pin Kernel","value":"yes"}
{"type":"settings","title":"Deploy Configuration","value":"","method":"1","storage":"1","network":"1"}
{"type":"progress","title":"Build ISO","value":"starting"}
{"type":"result","title":"Deploy","value":"success","exitCode":"0"}
{"type":"error","title":"Error","value":"Missing --method","exitCode":"12"}
```

| Type | When Emitted |
|------|-------------|
| `confirm` | Confirmation prompt result |
| `menu` | Menu selection result |
| `menu_options` | Available choices when no selection provided |
| `msgbox` | Information display |
| `input` | Input prompt result |
| `settings` | Configuration summary before action |
| `progress` | Operation started |
| `result` | Operation completed (success/failed) |
| `error` | Error with exit code |

### Exit Codes

| Code | Constant | Meaning |
|------|----------|---------|
| 0 | `E_SUCCESS` | Success |
| 1 | `E_GENERAL` | General error |
| 2 | `E_USAGE` | Invalid usage / missing arguments |
| 3 | `E_CONFIG` | Configuration error |
| 4 | `E_CHECK` | Pre-flight check failed |
| 5 | `E_PARTIAL` | Partial success |
| 6 | `E_DEPENDENCY` | Missing dependency |
| 7 | `E_NETWORK` | Network error |
| 8 | `E_DISK` | Disk/partition error |
| 9 | `E_TIMEOUT` | Timeout |
| 10 | `E_AUTH` | Authentication error |
| 11 | `E_DRY_RUN_OK` | Dry-run completed (no changes made) |
| 12 | `E_AGENT_PARAM` | Agent mode: missing required parameter |
| 13 | `E_AGENT_DENIED` | Agent mode: confirmation denied |

### Example: Full Deploy via Agent

```bash
# 1. Build ISO
sudo ./lib/build-iso.sh

# 2. Dry-run to verify
sudo ./prepare-deployment.sh --agent --dry-run --method 1 --storage 1 --network 1

# 3. Actual deploy
sudo ./prepare-deployment.sh --agent --yes --method 1 --storage 1 --network 1

# 4. Check system after install
sudo ./prepare-deployment.sh --agent --operation sysinfo --host macpro-linux
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `AGENT_MODE` | `0` | Set by `--agent` |
| `CONFIRM_YES` | `0` | Set by `--yes` |
| `JSON_OUTPUT` | `0` | Set by `--json` (auto-set by `--agent`) |
| `DRY_RUN` | `0` | Set by `--dry-run` |
| `AGENT_MENU_SELECTION` | | Pre-select menu choice |
| `AGENT_INPUT_VALUE` | | Pre-fill input prompt |
| `AGENT_PASSWORD_VALUE` | | Pre-fill password prompt |
