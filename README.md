# Mac Pro 2013 Ubuntu 24.04 — Autoinstall Deployment

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
- **SIP always enabled** — blocks bless NVRAM writes; boot device selected via keyboard Option key or System Preferences Startup Disk
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
| `autoinstall.yaml` | Autoinstall config — WiFi driver compilation, SSH, dual-boot storage layout |
| `build-iso.sh` | Builds modified ISO: extract, overlay, repack preserving EFI boot |
| `packages/` | .deb files for driver compilation (34 packages) |
| `packages/dkms-patches/` | 6 DKMS patches for kernel 6.8+ compatibility (series file + *.patch) |
| `prepare-deployment.sh` | Interactive deployment script: ESP partition, USB, manual, or VM test |
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

### Build the ISO (required for all methods)

```bash
sudo ./build-iso.sh
```

### Deploy (interactive menu)

```bash
sudo ./prepare-deployment.sh
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

### Serial Console

Both production and VM GRUB configs include `console=ttyS0,115200` for serial console output. In VirtualBox, UART1 is configured to log to `/tmp/vmtest-serial.log`.

## For Agents

`prepare-deployment.sh` supports a non-interactive agent mode designed for LLM agents (Claude Code, Cursor, etc.) that cannot interact with TUI dialogs. All operations can be driven via CLI flags with structured JSON output.

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

```bash
# Build the ISO
sudo ./prepare-deployment.sh --agent --yes --method 1

# Deploy to internal ESP partition (dual-boot, WiFi)  
sudo ./prepare-deployment.sh --agent --yes --method 1 --storage 1 --network 1

# Deploy to USB (full-disk, Ethernet)
sudo ./prepare-deployment.sh --agent --yes --method 2 --storage 2 --network 2

# Dry-run deploy (show what would happen)
sudo ./prepare-deployment.sh --agent --dry-run --method 1 --storage 1 --network 1

# VM test
sudo ./prepare-deployment.sh --agent --yes --method 4
```

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

# Rebuild WiFi driver
sudo ./prepare-deployment.sh --agent --yes --operation driver_rebuild

# Erase macOS (requires --yes)
sudo ./prepare-deployment.sh --agent --yes --operation erase_macos

# APT enable/disable
sudo ./prepare-deployment.sh --agent --yes --operation apt_enable
sudo ./prepare-deployment.sh --agent --yes --operation apt_disable

# Reboot
sudo ./prepare-deployment.sh --agent --yes --operation reboot

# Boot to macOS
sudo ./prepare-deployment.sh --agent --yes --operation boot_macos
```

| Operation | Description | Destructive? |
|-----------|-------------|-------------|
| `sysinfo` | System information | No |
| `kernel_status` | Kernel version, pin status | No |
| `kernel_pin` | Pin current kernel, disable updates | Yes |
| `kernel_unpin` | Unpin kernel, enable updates | Yes |
| `kernel_update` | Full 7-phase kernel update | Yes |
| `security_update` | Non-kernel security updates | Yes |
| `driver_status` | WiFi driver and DKMS status | No |
| `driver_rebuild` | Rebuild Broadcom WiFi driver | Yes |
| `disk_usage` | Disk usage information | No |
| `erase_macos` | Delete macOS partitions, expand Ubuntu | **Irreversible** |
| `apt_enable` | Enable APT sources | Yes |
| `apt_disable` | Disable APT sources | Yes |
| `reboot` | Reboot remote system | Yes |
| `boot_macos` | Set next boot to macOS | Yes |

### Configuration Overrides

CLI flags override `deploy.conf` settings:

| Flag | Overrides |
|------|-----------|
| `--wifi-ssid SSID` | `WIFI_SSID` |
| `--wifi-password PASS` | `WIFI_PASSWORD` |
| `--webhook-host HOST` | `WEBHOOK_HOST` |
| `--webhook-port PORT` | `WEBHOOK_PORT` |
| `--host HOST` | Remote SSH host (default: `macpro-linux`) |

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
sudo ./prepare-deployment.sh --agent --yes --method 1 2>/dev/null
# Output: {"type":"settings","title":"Deploy Configuration",...}
#         {"type":"result","title":"Deploy","value":"success",...}

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