# Mac Pro 2013 Ubuntu Autoinstall - AGENTS.md

## Project Overview

Headless Ubuntu 24.04.4 LTS Server deployment for Mac Pro 2013 (MacPro6,1) with Broadcom BCM4360 WiFi. The machine is only accessible via SSH — zero physical access (no keyboard, monitor, or mouse). Cannot disable macOS SIP to install custom bootloader. The deployment preserves macOS via dual-boot, dynamically generates the autoinstall storage config to mark existing partitions as `preserve: true`, uses `bless` to set boot device, and reboots into an automated autoinstall.

## Hardware Specifications

- **Model**: Mac Pro 2013 (MacPro6,1)
- **Current OS**: macOS 12.7.6 (Monterey)
- **Access**: SSH only — zero physical access
- **GPU**: AMD FirePro D300/D500/D700 (amdgpu, needs `nomodeset amdgpu.si.modeset=0`)
- **WiFi**: Broadcom BCM4360 (proprietary `wl` driver, NOT in Ubuntu)
- **Storage**: Apple PCIe SSD via AHCI → `/dev/sda` (not NVMe)
- **No Ethernet port** — WiFi is the only network path
- **Cannot disable SIP** — stuck with Apple's default bootloader (but `bless` works for dual-boot)
- **MacBook available on network** — can serve as monitoring endpoint and fallback

## Project Structure

```
/Users/djtchill/Desktop/Mac/
├── autoinstall.yaml                 # Autoinstall configuration (added to ISO at /)
├── build-iso.sh                     # ISO builder (xorriso extract-and-repack) — injects config, cidata, GRUB, packages
├── prepare-headless-deploy.sh       # macOS-side script: repartition + extract + bless + verify via SSH
├── packages/                        # .deb files for driver compilation (34 debs)
│   ├── broadcom-sta-dkms_*.deb      # Broadcom WiFi driver source
│   ├── dkms_*.deb                   # Dynamic Kernel Module Support
│   ├── linux-headers-6.8.0-100*     # Kernel headers matching ISO kernel (6.8.0-100-generic)
│   ├── gcc-13_*, gcc-13-x86-64-linux-gnu_*, make_*, etc.       # Build toolchain (13.3.0 matching ISO kernel)
│   ├── dkms-patches/               # 6 kernel 6.8+ compatibility patches (series file + *.patch)
│   │   ├── series                   # Ordered patch list
│   │   ├── 29-*.patch               # Fix kernel version parsing
│   │   ├── 30-*.patch               # Fix unaligned header location (6.12+)
│   │   ├── 31-*.patch               # Provide local lib80211.h (6.13+)
│   │   ├── 32-*.patch               # Fix get_tx_power link_id param (6.14+)
│   │   ├── 38-*.patch               # Replace EXTRA_CFLAGS with ccflags-y (6.15+)
│   │   └── 39-*.patch               # Replace del_timer with timer_delete (6.15+)
│   └── ...
├── README.md                        # Documentation
├── macpro-monitor/                  # Node.js webhook monitor
│   ├── server.js
│   ├── start.sh / stop.sh / reset.sh
│   └── logs/
├── vm-test/                         # VirtualBox test environment
│   ├── autoinstall-vm.yaml          # VM-specific autoinstall (Ethernet, non-fatal driver init)
│   ├── build-iso-vm.sh              # VM ISO builder
│   ├── create-vm.sh                 # VirtualBox VM creation
│   └── test-vm.sh                   # Run/monitor/SSH/stop
└── prereqs/                         # Stock Ubuntu ISO (*.iso gitignored)
```

## Build/Lint/Test Commands

### Build ISO
```bash
sudo ./build-iso.sh
```

### Node.js Monitor
```bash
cd macpro-monitor && ./start.sh    # Start (port 8080)
./macpro-monitor/stop.sh           # Stop
```

### VM Test
```bash
cd vm-test && sudo ./build-iso-vm.sh && ./create-vm.sh && ./test-vm.sh
```

## Core Design Decisions

1. **Extract-and-repack ISO modification**: The original ISO is extracted to a staging directory, custom files are overlaid, and the ISO is rebuilt using boot parameters preserved via `xorriso -report_el_torito as_mkisofs`. This properly preserves Ubuntu 24.04's appended EFI partition image and MBR hybrid boot structure. Volume label set to `cidata` for NoCloud discovery.

2. **Compile during install with DKMS patches**: The `early-commands` dynamically detects the running kernel (`KVER="$(uname -r)"`), validates matching headers exist, then installs from discovered `macpro-pkgs/` mount. The `broadcom-sta-dkms` postinst auto-runs `dkms add` (creates symlink). DKMS patches are applied to `/usr/src/` AFTER `dpkg -i` but BEFORE `dkms build`. Missing patches are FATAL. Failed builds have single-retry fallback with clean-then-rebuild. The `late-commands` repeats this in a 4-stage `dpkg --root /target` install with bind mounts for chroot DKMS.

3. **GPU**: AMD FirePro uses built-in `amdgpu` driver. Only `nomodeset amdgpu.si.modeset=0` kernel params needed — pre-baked in GRUB config.

4. **Network**: Uses `wl0` with `match: driver: wl` in netplan. Config generated with `printf` (not heredoc — indentation inside `|` blocks adds unwanted spaces). Uses `networkd` renderer (NOT NetworkManager). WiFi interface detection with 60-second timeout and multiple patterns. WiFi power management disabled via modprobe options and systemd unit. If primary netplan config fails, falls back to simplified config without match clause. Netplan failure is FATAL.

5. **Storage (Dual-Boot)**: All existing partitions preserved with `preserve: true`. The `prepare-headless-deploy.sh` script dynamically generates storage config using Python + `sgdisk` after APFS resize. Partition type GUIDs normalized to lowercase for curtin. ESP labeled `cidata` for NoCloud discovery. Storage config uses string-based regex replacement (NOT `yaml.dump`) to preserve `|` block scalars.

6. **Remote boot via `bless`**: `bless --setBoot --mount <esp> --nextonly` from macOS SSH. The `--nextonly` flag reverts boot to macOS if the firmware can't find a valid bootloader. GRUB parameters are pre-baked.

7. **macOS boot from GRUB**: GRUB cannot read APFS. The `40_macos` menu entry uses `fwsetup` to reboot to Apple Boot Manager. `efibootmgr` is installed with `LIBEFIVAR_OPS=efivarfs` workaround for Apple EFI 1.1 bug (Ubuntu Bug #2040190). `/usr/local/bin/boot-macos` uses `efibootmgr --bootnext` to set macOS as next boot device.

8. **SSH into installer**: `early-commands` starts `sshd` after WiFi driver compilation. Falls back to ISO pool `.deb`s with `--force-depends` if network apt fails. `ssh: install-server: true` only applies to the target system.

9. **NoCloud datasource**: ISO includes `/cidata/` for `ds=nocloud`. Volume label `cidata` enables discovery. `autoinstall` kernel param bypasses confirmation prompt.

10. **Headless deploy safety**: `prepare-headless-deploy.sh` uses before/after partition diffing. APFS snapshots auto-deleted. Bless verified with `--info`. Error recovery trap resets macOS boot device. Pre-flight checks validate ISO integrity, SIP, FileVault, and webhook reachability.

11. **Monitoring**: `macpro-monitor` receives Subiquity/Curtin events via webhook at DEBUG level, plus custom progress events via `curl` with `{progress, stage, status, message}` payloads. Progress percentages are monotonically increasing.

12. **All critical paths are fatal**: DKMS failures, driver load failures, patch failures, WiFi connectivity failures, missing headers — all `exit 1`. Non-critical failures (`update-grub`, SSH start) use `|| true` or `|| echo WARN`. Error events sent to webhook before exit.

13. **WiFi connectivity verification**: After driver load and interface detection, the installer verifies WiFi by scanning for networks (iwlist), checking DHCP lease, and testing HTTP connectivity. If WiFi is lost, the system automatically reloads the `wl` driver and retries for up to 60 seconds. If reconnect fails in early-commands, installation aborts before storage. If reconnect fails in late-commands, the system enters recovery mode (keeps SSH alive, blocks reboot).

14. **Post-install verification and recovery**: Late-commands verify kernel, netplan, GRUB, WiFi module, and user account. If WiFi is broken in the target system, the installer does NOT reboot into a headless brick — keeps SSH alive with infinite sleep loop for remote debugging. Error logs saved to `/var/log/macpro-install/` (persists across reboots). UFW firewall denies all incoming except SSH.

15. **Dynamic mount discovery**: `macpro-pkgs/` is discovered dynamically by searching `/cdrom`, `/isodevice`, and `/mnt` — path varies by boot method.

## VirtualBox Test Environment

| File | Purpose |
|------|---------|
| `autoinstall-vm.yaml` | DKMS compiles (fatal on failure), driver init non-fatal (no Broadcom HW). Uses Ethernet. Webhook targets `10.0.2.2` via NAT. |
| `build-iso-vm.sh` | Builds `ubuntu-vmtest.iso` from `../packages/` with VM config |
| `create-vm.sh` | VirtualBox VM: EFI, 4 CPUs, 4.5GB RAM, 25GB disk, NAT, SSH port forward |
| `test-vm.sh` | Run/monitor/SSH/grab logs/stop/destroy |

## Boot Methods

| Method | Physical Access? | Status |
|--------|-----------------|--------|
| USB + auto GRUB | Required (keyboard to hold Option) | Implemented |
| Internal disk + `bless` via SSH | None required | Implemented |
| NetBoot from MacBook | None required | Not feasible (requires macOS Server + BSDP) |
| Target Disk Mode | Brief physical | Fallback only |

## Switching Between macOS and Ubuntu

| Direction | Method | Command |
|-----------|--------|---------|
| macOS → Ubuntu | `bless` | `bless --setBoot --mount /Volumes/ESP --nextonly` then reboot |
| Ubuntu → macOS | `efibootmgr` | `sudo boot-macos` then reboot |
| Ubuntu → macOS | GRUB menu | Select "Reboot to Apple Boot Manager" |
| Any → macOS | Firmware | Hold Option at boot (requires physical access) |

## Code Style Guidelines

### Shell Scripts (Bash)
```bash
set -e
set -o pipefail
readonly CONST="value"
local var="value"
```
Use `RED`, `GREEN`, `NC` color constants. Log to file with `tee`.

### YAML (autoinstall.yaml)
- Use `|` block scalar for shell commands to avoid YAML parsing issues
- Quote all strings containing special characters
- Use `match: driver: wl` with logical interface IDs, not hardcoded names
- Use `printf` for netplan YAML generation (not heredoc)
- Shell commands run via `sh -c` (dash) — POSIX-compatible syntax only
- `${VAR}` for variable interpolation in JSON strings

### JavaScript (Node.js)
```javascript
const PORT = parseInt(process.env.PORT || '8080', 10);
const MAX_UPDATES = 200;
```

## Error Handling

| Language | Guidelines |
|----------|------------|
| Bash | `set -e` at start; `|| true` only when failure acceptable; `exit 1` on critical failures |
| YAML | All DKMS/header/driver failures must `exit 1`; webhook error before exit; non-critical only for SSH, update-grub |
| Node.js | Validate inputs; handle HTTP errors gracefully |

## Naming Conventions

| Language | Variable | Function | Class | Constant |
|----------|----------|----------|-------|----------|
| Bash | `snake_case` | `snake_case()` | N/A | `UPPER_SNAKE` |
| JavaScript | `camelCase` | `camelCase()` | `PascalCase` | `UPPER_SNAKE` |

**Files:** `snake_case.sh`, `snake_case.js`

## DKMS Patch Architecture

The `broadcom-sta-dkms` package (`6.30.223.271-23ubuntu1`) requires patches to compile on kernel 6.8+:

1. `dpkg -i broadcom-sta-dkms_*.deb` → postinst runs `dkms add` (creates symlink)
2. Apply patches to `/usr/src/broadcom-sta-6.30.223.271/` (visible through symlink)
3. `dkms build broadcom-sta/6.30.223.271 -k $KVER` → compiles patched source
4. `dkms install` → installs module to running kernel

**DO NOT call `dkms add` explicitly** — the postinst already does this. Calling it again fails with "module already added."

Patches use `#if LINUX_VERSION_CODE >= KERNEL_VERSION(...)` guards and compile cleanly on 6.8 while enabling forward compatibility.

## Key Constraints

- **Zero physical access** — all operations must be performed remotely via SSH
- **Cannot disable SIP** — cannot install custom bootloader into `/System`; must use `bless` on ESP
- **GRUB cannot read APFS** — use `fwsetup` or `efibootmgr` to switch to macOS
- **WiFi-only networking** — must compile `wl` driver before any network access
- **Kernel version dynamically detected** — `KVER="$(uname -r)"` in each `- |` block; packages must contain headers matching the ISO kernel
- **DKMS add handled by postinst** — do NOT call `dkms add` explicitly
- **DKMS add creates symlink** — patches applied to `/usr/src/` are visible through symlink
- **`dpkg --root /target`** runs postinst scripts (chroots); must install in dependency order (Stage 1-4)
- **Bind mounts required for chroot DKMS** — `/proc`, `/sys`, `/dev` must be bind-mounted into `/target`
- **Each `- |` block in autoinstall.yaml runs in separate `sh -c`** — variables NOT shared between blocks
- **Shell commands via `sh -c`** (dash) — POSIX-compatible syntax only (no `[[ ]]`, no arrays, no `<<<`)
- **ESP must be 5GB+** — ISO is ~3.4GB with squashfs layers ~2.5GB
- **Partition type GUIDs must be lowercase** — curtin normalizes to lowercase; uppercase causes verification mismatches
- **Autoinstall YAML must use string-based replacement** — `yaml.dump` converts `|` block scalars to quoted strings with `\n` escapes
- **gcc-13 must match ISO kernel** — `gcc-13 13.3.0-6ubuntu2~24.04` and `gcc-13-x86-64-linux-gnu` required. `cc` symlink points to `x86_64-linux-gnu-gcc-13`
- **dpkg --skip-same-version** — ISO live environment has base packages at newer versions; `--skip-same-version` prevents downgrades that break the live environment
- **dkms/broadcom dpkg returns non-zero** — postinst auto-runs `dkms add` which fails to build without patches; this is expected (WARN, not FATAL)
- **Ubuntu broadcom-sta-dkms has flat source tree** — `Makefile` at root, not under `amd64/`; Debian patches may need `amd64/` and `i386/` prefixes stripped
- **Apple EFI 1.1 bug** — `efibootmgr` fails without `LIBEFIVAR_OPS=efivarfs` set (Ubuntu Bug #2040190)
- **`bless --nextonly` limitation** — only reverts if firmware can't find bootloader, NOT on kernel panic
- **Updates and kernel pinned** — all automatic updates disabled; kernel locked to 6.8.0-100-generic via apt preferences (block all at `-1`, allow only `6.8.0-100*` at `1001`); apt sources commented out; snap refresh held forever; cloud-init apt upgrade disabled
- **ISO-only packages** — only packages from the ISO should be installed during and after installation; this prevents kernel updates that would break the WiFi driver

## Context Management Rules

When working on this project, ALL agents MUST follow these rules:

### Memory (Cross-Session)
- **After completing significant work**, save key findings, decisions, and file locations to `ctx_memory` using categories: `ENVIRONMENT`, `CONSTRAINTS`, `WORKFLOW_RULES`
- **Before exploring the codebase** for a question that may have been answered before, search `ctx_memory` first with `ctx_search`
- **When learning non-obvious constraints** the hard way, save immediately to `ctx_memory` under `CONSTRAINTS`

### Context Reduction (Within Session)
- **After processing large tool outputs**, use `ctx_reduce` to drop them once extracted and acted upon
- **Never drop user messages or recent conversation text** — these are cheap and auto-compartmentalized
- **Never blind-drop large ranges** — review each tag before deciding

### Session Notes
- **Use `ctx_note`** for session-level reminders and deferred intentions
- **Notes are NOT for task tracking** — use todos for that
- **Notes survive context compression** — write them for anything you'll need later in the session