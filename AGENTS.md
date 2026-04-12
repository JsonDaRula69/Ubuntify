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
├── packages/                        # .deb files for driver compilation (~37 debs, ~75MB)
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

1. **Extract-and-repack ISO modification**: The original ISO is extracted to a staging directory, custom files are overlaid, and the ISO is rebuilt using boot parameters preserved via `xorriso -report_el_torito as_mkisofs`. This properly preserves Ubuntu 24.04's appended EFI partition image and MBR hybrid boot structure. Added files: `autoinstall.yaml`, `cidata/`, `macpro-pkgs/` (including `dkms-patches/`), and pre-baked GRUB configs. Volume label set to `cidata` for NoCloud discovery.

2. **Compile during install with DKMS patches**: The `early-commands` section dynamically detects the running kernel (`KVER="$(uname -r)"`), validates that matching headers exist, then installs kernel headers and build tools from `/cdrom/macpro-pkgs/`. The `broadcom-sta-dkms` package postinst auto-runs `dkms add` (which creates a symlink `/var/lib/dkms/.../source -> /usr/src/...`). DKMS compatibility patches are applied to `/usr/src/broadcom-sta-6.30.223.271/` BEFORE `dkms build` but AFTER `dpkg -i` (which triggers `dkms add`). Patches are visible through the symlink. The `late-commands` repeats this in a 4-stage `dpkg --root /target` install, with bind mounts of `/proc`, `/sys`, `/dev` for chroot DKMS compilation. DKMS build and install have single-retry logic with clean-then-rebuild fallback.

3. **GPU**: AMD FirePro uses built-in `amdgpu` driver. Only `nomodeset amdgpu.si.modeset=0` kernel params needed — pre-baked in GRUB config, not entered manually.

4. **Network matching**: Uses `wl0` interface ID with `match: driver: wl` in netplan. The late-commands generates netplan config using `printf` (not heredoc — indentation inside `|` blocks adds unwanted spaces). Uses `networkd` renderer (NOT NetworkManager) — networkd + wpa_supplicant works for WiFi on Ubuntu Server. WiFi interface detection uses a 60-second timeout and matches `wlp*`, `wl*`, `wlan*`, `wl[0-9]*` patterns (Ethernet patterns removed — Mac Pro has no Ethernet port). WiFi power management is disabled via `options wl` modprobe and `wl-poweroff.service` systemd unit. Netplan generation failure is FATAL (not just WARN).

5. **Storage (Dual-Boot)**: Mac Pro 2013 uses Apple PCIe SSDs via AHCI (not NVMe), so internal disk is `/dev/sda`. The deployment preserves macOS by using `preserve: true` on the disk and ALL existing partitions in the autoinstall storage config. The `prepare-headless-deploy.sh` script dynamically generates the `cidata/user-data` file after the APFS resize, using Python to read the GPT partition table (via `sgdisk`) and inject `preserve: true` entries for every existing partition (APFS container, macOS EFI, installer ESP). Partition sizes are calculated from sgdisk first/last sector fields (NOT `blockdev` — unavailable on macOS). Partition type GUIDs are normalized to lowercase for curtin compatibility. The ESP is labeled `cidata` (NOT `UBUNTU_ESP`) to enable reliable NoCloud datasource discovery. New Ubuntu partitions (EFI 512M, /boot 1G, / rest) are created in the free space ONLY. The storage config uses string-based regex replacement (NOT `yaml.dump`) to preserve `|` block scalars in the YAML — `yaml.dump` converts block scalars to quoted strings with `\n` escapes which breaks subiquity.

6. **Remote boot via `bless`**: For zero-physical-access deployment, use `bless --setBoot --mount <esp> --nextonly` from macOS SSH. The `--nextonly` flag ensures the boot device reverts to macOS if the installer fails. GRUB parameters are pre-baked in `EFI/boot/grub.cfg` — no manual keyboard input needed.

7. **macOS boot from GRUB**: GRUB cannot read APFS (no filesystem module exists), so the traditional `search --file /System/Library/CoreServices/boot.efi` chainloader approach does not work. Instead, GRUB's `40_macos` menu entry uses `fwsetup` which reboots to the Apple Boot Manager (firmware-level boot picker that lists all volumes including macOS). The `efibootmgr` package is installed for managing EFI boot variables from Ubuntu, and `/usr/local/bin/boot-macos` is a helper script that uses `efibootmgr --bootnext` to set macOS as the next boot device and reboots. From macOS, `bless --setBoot --mount /Volumes/EFI` switches back to Ubuntu.

8. **SSH into installer**: `early-commands` starts `sshd` after WiFi driver compilation for remote debugging during installation. Falls back to installing from ISO pool (`/cdrom/pool/restricted/o/openssh/`) with `--force-depends` if network apt fails. The `ssh: install-server: true` config only applies to the target system.

9. **NoCloud datasource**: The ISO includes `/cidata/user-data`, `/cidata/meta-data`, and `/cidata/vendor-data` for `ds=nocloud` discovery. Volume label `cidata` also enables discovery. Kernel param `autoinstall` bypasses the confirmation prompt for zero-touch deployment.

10. **Autoinstall config discovery**: `/autoinstall.yaml` at ISO root is found regardless of NoCloud labeling. The volume label `cidata` provides an additional discovery path.

11. **Headless deploy safety**: `prepare-headless-deploy.sh` uses before/after partition diffing (not `tail -1`) to safely identify the newly created ESP. APFS snapshots are auto-deleted for headless operation. Bless is verified with `--info`. Error recovery trap resets macOS boot device via `bless --mount`. Non-interactive reboot when piped via SSH or when `DEPLOY_HEADLESS=1` is set. Pre-flight checks validate ISO integrity, SIP status, FileVault status, and webhook reachability.

12. **Monitoring and progress reporting**: The `macpro-monitor` server receives two event streams. Subiquity/Curtin built-in events are sent via the `reporting.macpro-monitor` webhook at DEBUG level (captures all events including DEBUG-level network/storage details). Custom progress events are sent via `curl` calls in early-commands and late-commands with `{progress, stage, status, message}` payloads — these track WiFi driver compilation, SSH startup, DKMS build, netplan config, GRUB setup, etc. Progress percentages are monotonically increasing from 0-100.

13. **All critical paths are fatal**: Early-commands and late-commands use `exit 1` on any critical failure (missing headers, DKMS build failure, driver load failure, patch application failure, WiFi connectivity failure). Non-critical failures (SSH server start, update-grub) use `|| true` or `|| echo WARN`. Webhook error events are sent before exit for remote debugging.

14. **WiFi connectivity circuit breaker**: Before storage proceeds, `early-commands` verifies WiFi is actually working by testing network connectivity (curl to a known endpoint). If WiFi isn't functional after driver load and interface detection, the installation aborts with `exit 1` — this prevents storage from modifying the disk when there's no network path for the installed system. DKMS patches missing is also fatal (not just a warning).

15. **WiFi driver configuration**: The `wl` module is configured with power management disabled (`options wl` in `/etc/modprobe.d/`) and `iwconfig power off` to prevent WiFi drops from power saving. The `cfg80211` regulatory domain is set to `US` via module options.

16. **Post-install verification**: Late-commands verify the target system has the kernel installed, netplan config, GRUB config, WiFi module, and user account before reporting completion. Verification results are logged.

17. **Error diagnostics and persistence**: Error-commands save `dmesg`, `journalctl`, DKMS status, `lsmod`, and `lspci` output to `/var/log/macpro-install/` which persists across reboots (not `/tmp/`). If `/target` exists, logs are also copied there.

18. **Firewall**: UFW is installed and enabled on the target system before reboot, denying all incoming connections except SSH. This protects the machine on the local network since the WiFi credentials are in the git repository.
19. **Dynamic mount discovery**: The `macpro-pkgs/` directory is discovered dynamically at install time by searching `/cdrom`, `/isodevice`, and `/mnt` — the path varies depending on boot method (USB vs internal ESP).
20. **DKMS patch pre-validation**: Before applying DKMS patches, each patch file is validated for existence and readability. Missing patches are FATAL (not just WARN) because they are required for kernel 6.8+ compatibility.
21. **WiFi connectivity verification**: After driver load and interface detection, the installer verifies WiFi by scanning for networks (iwlist), checking DHCP lease, and testing HTTP connectivity. All three checks must pass before installation proceeds.
22. **Apple EFI 1.1 bug workaround**: Mac Pro 2013 firmware has an EFI 1.1 implementation that causes `efibootmgr` to fail with `LIBEFIVAR_OPS=efivarfs` set. This environment variable is exported before `efibootmgr` calls in late-commands (Ubuntu Bug #2040190).
23. **Late-commands recovery mode**: If post-install verification finds WiFi is broken in the target system (missing netplan config or WiFi driver module), the installer does NOT reboot into a headless brick. Instead, it keeps SSH alive and enters an infinite sleep loop, allowing remote SSH debugging.
24. **WiFi power management**: The `wl` module is loaded with power management disabled via modprobe options (`options wl`) and a systemd unit (`wl-poweroff.service`) that runs `iwconfig <iface> power off` on boot. This prevents WiFi disconnections from power saving.
25. **Self-healing DKMS**: If the initial DKMS build fails, the system automatically attempts a clean rebuild: removes the broken build directory, reapplies patches, and retries. If the retry also fails, it exits with FATAL.
26. **WiFi reconnect self-healing**: If WiFi connectivity is lost (early-commands curl test or late-commands IP check), the system automatically reloads the `wl` driver (rmmod conflicting modules + modprobe wl) and retries connectivity for up to 60 seconds. If reconnect also fails, the early-commands version exits with FATAL before storage begins; the late-commands version enters recovery mode (keeps SSH alive, blocks reboot).
27. **Netplan fallback regeneration**: If `netplan generate` fails on the primary config (which includes `match: driver: wl`), the system regenerates with a simplified config (no match clause) and retries. If the simplified config also fails, exits with FATAL.
28. **DKMS patch paths for Ubuntu**: The Ubuntu `broadcom-sta-dkms` package (6.30.223.271-23ubuntu1) has a flat source tree — `Makefile` at root, not under `amd64/`. DKMS patches from Debian must have `amd64/` and `i386/` prefixes stripped. Patch 29 fixes SUBLEVEL parsing in the Makefile using sed `;t;s/...` syntax (not shell `'; s/...'` which causes "Unterminated quoted string").
29. **gcc must match ISO kernel build**: Kernel 6.8.0-100-generic was built with gcc-13 13.3.0-6ubuntu2~24.04. Bundled packages at older versions (13.2.0) cause DKMS build failures. The `gcc-13-x86-64-linux-gnu` package provides `x86_64-linux-gnu-gcc-13` (the exact binary the kernel was compiled with). The `cc` symlink points to `x86_64-linux-gnu-gcc-13` with fallback to `gcc-13`.
30. **dpkg --skip-same-version prevents downgrades**: The ISO's live environment contains base packages (libgcc-s1, libstdc++6, perl-base, kmod) at newer versions than our bundled debs. Using `dpkg --force-depends --skip-same-version -i` skips already-installed packages instead of downgrading and breaking the live environment.
31. **dkms/broadcom dpkg non-zero is expected**: `dpkg -i dkms broadcom-sta-dkms` returns non-zero because the broadcom postinst auto-runs `dkms add` which tries (and fails) to build without patches. This is WARN (not FATAL) — we apply patches AFTER dpkg and build manually.

## VirtualBox Test Environment

The `vm-test/` folder provides a full VM-based test of the DKMS compilation pipeline without requiring Mac Pro hardware.

| File | Purpose |
|------|---------|
| `autoinstall-vm.yaml` | VM-specific autoinstall — DKMS compiles (fatal on failure), but driver init is non-fatal (no Broadcom HW). Uses Ethernet `enp0s3` instead of WiFi. Webhook targets `10.0.2.2` (host via NAT). |
| `build-iso-vm.sh` | Builds `ubuntu-vmtest.iso` from the same `../packages/` with VM config |
| `create-vm.sh` | Creates VirtualBox VM: EFI firmware, 4 CPUs, 4.5GB RAM, 25GB disk, NAT networking, SSH port forward (2222→22), webhook forward (8081→8080) |
| `test-vm.sh` | Run/monitor/SSH/grab logs/stop/destroy the VM |

**Key VM vs production differences:**
- Toolchain installed via `chroot /target apt-get` (VM has network) instead of `dpkg --root /target -i` (production is offline)
- `cp /etc/resolv.conf /target/etc/resolv.conf` needed before chroot apt-get
- `useradd ubuntu` + `chpasswd` in early-commands for installer SSH access
- Serial port (UART1) configured for console logging
- `modprobe wl` failure is non-fatal (no Broadcom hardware)
- WiFi interface detection falls through to Ethernet
- Single disk, no dual-boot preserve

**Usage:**
```bash
cd vm-test && sudo ./build-iso-vm.sh && ./create-vm.sh && ./test-vm.sh
```

## Boot Methods

| Method | Physical Access? | Status |
|--------|-----------------|--------|
| USB + auto GRUB | Required (keyboard to hold Option) | Implemented (build-iso.sh) |
| Internal disk + `bless` via SSH | None required | Implemented (prepare-headless-deploy.sh) |
| NetBoot from MacBook | None required | Not feasible (requires macOS Server + BSDP) |
| Target Disk Mode | Brief physical | Fallback only |

## Switching Between macOS and Ubuntu

| Direction | Method | Command |
|-----------|--------|---------|
| macOS → Ubuntu | `bless` | `bless --setBoot --mount /Volumes/ESP --nextonly` then reboot (NOTE: `--nextonly` only reverts if firmware can't find bootloader, NOT on kernel panic) |
| Ubuntu → macOS | `efibootmgr` | `sudo boot-macos` then reboot |
| Ubuntu → macOS | GRUB menu | Select "Reboot to Apple Boot Manager" at GRUB boot |
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
- Use `match: driver: wl` with a logical interface ID (e.g., `wl0:`), not hardcoded interface names
- Use `printf` for netplan YAML generation (not heredoc — indentation inside `|` blocks adds unwanted spaces)
- Shell commands run via `sh -c` (dash) — use only POSIX-compatible syntax (no `[[ ]]`, no arrays, no `<<<`)
- Use `${VAR}` for bash variable interpolation inside JSON strings, never `+ VAR +` (JS concatenation)

### JavaScript (Node.js)
```javascript
const PORT = parseInt(process.env.PORT || '8080', 10);
const MAX_UPDATES = 200;
const MAX_BUILT_IN_EVENTS = 500;
const MAX_DISPLAY_EVENTS = 50;
```

## Error Handling

| Language | Guidelines |
|----------|------------|
| Bash | `set -e` at start; `|| true` only when failure acceptable; `exit 1` on critical failures |
| YAML | All DKMS/header/driver failures must `exit 1`; webhook error sent before exit; non-critical (`|| echo WARN`) only for SSH, update-grub |
| Node.js | Validate inputs; handle HTTP errors gracefully |

## Naming Conventions

| Language | Variable | Function | Class | Constant |
|----------|----------|----------|-------|----------|
| Bash | `snake_case` | `snake_case()` | N/A | `UPPER_SNAKE` |
| JavaScript | `camelCase` | `camelCase()` | `PascalCase` | `UPPER_SNAKE` |

**Files:** `snake_case.sh`, `snake_case.js`

## DKMS Patch Architecture

The `broadcom-sta-dkms` package (version `6.30.223.271-23ubuntu1`) requires patches to compile on kernel 6.8+. Patches are stored in `packages/dkms-patches/` and applied during autoinstall:

1. `dpkg -i broadcom-sta-dkms_*.deb` → postinst runs `dkms add` (creates symlink `/var/lib/dkms/.../source -> /usr/src/...`)
2. Apply patches to `/usr/src/broadcom-sta-6.30.223.271/` (visible through symlink)
3. `dkms build broadcom-sta/6.30.223.271 -k $KVER` → compiles patched source
4. `dkms install` → installs module to running kernel

**DO NOT call `dkms add` explicitly** — the postinst already does this. Calling it again will fail with "module already added."

Patches use `#if LINUX_VERSION_CODE >= KERNEL_VERSION(...)` guards and compile cleanly on 6.8 while enabling forward compatibility with newer kernels.

## Important Files

- `autoinstall.yaml` - The core autoinstall configuration (added to ISO at /)
- `packages/` - .deb files for driver compilation (added to ISO at /macpro-pkgs/)
- `packages/dkms-patches/` - 6 DKMS patches for kernel 6.8+ compatibility (added to ISO at /macpro-pkgs/dkms-patches/)
- `build-iso.sh` - ISO build script using xorriso extract-and-repack (injects config, cidata, GRUB, packages, dkms-patches)
- `prepare-headless-deploy.sh` - macOS-side script for zero-physical-access deployment via bless; dynamically generates dual-boot storage config
- `prereqs/` - Stock Ubuntu ISO directory (only `*.iso` files, gitignored)
- `macpro-monitor/` - Node.js webhook monitor for installation progress (3-pane dashboard: Subiquity Events | Custom Progress | Status)
- `vm-test/` - VirtualBox test environment for validating DKMS compilation without Mac Pro hardware
- `.gitignore` - Excludes `*.iso`, `*.qcow2`, `ssh-*/`, `.sisyphus/`, `.DS_Store`

## Key Constraints

- **Zero physical access** — all operations must be performed remotely via SSH
- **Cannot disable SIP** — cannot install custom bootloader into `/System`; must use Apple's `bless` command on ESP
- **GRUB cannot read APFS** — no APFS filesystem module exists in GRUB; use `fwsetup` (Apple Boot Manager) or `efibootmgr` to switch to macOS
- **WiFi-only networking** — no Ethernet; must compile `wl` driver before any network access (hardware has 2 Ethernet ports but they're unplugged)
- **Kernel version dynamically detected** — `KVER="$(uname -r)"` in early-commands and late-commands; `packages/` must contain headers matching the ISO's kernel (currently 6.8.0-100-generic)
- **DKMS cross-kernel build**: `dkms build -k <version>` compiles against the specified kernel's headers, not the running kernel
- **DKMS add handled by postinst** — broadcom-sta-dkms postinst auto-runs `dkms add`; do NOT call it explicitly
- **DKMS add creates symlink** — `/var/lib/dkms/.../source -> /usr/src/...`; patches applied to `/usr/src/` are visible through symlink
- **`dpkg --root /target`** runs postinst scripts (chroots to target); must install in dependency order (Stage 1-4)
- **Bind mounts required for chroot DKMS** — `/proc`, `/sys`, `/dev` must be bind-mounted into `/target` before `chroot /target dkms build`
- **Netplan interface keys** must be actual names or logical IDs (not `wifi-iface`)
- **Disk identification verified in early-commands** — `/dev/sda` existence is validated before autoinstall storage proceeds; APFS presence confirms dual-boot mode is active; multiple-disk scenarios log warnings
- **Each `- |` block in autoinstall.yaml runs in a separate `sh -c`** — variables defined in one block (like `KVER`) are NOT available in other blocks. Each block that needs `KVER` must define it independently with `KVER="$(uname -r)"`
- **Networkd renders WiFi** — `networkd` renderer + `wifis:` section works for WiFi on Ubuntu Server (wpa_supplicant integration)
- **No `dd` ISO to partition** — Mac EFI expects FAT32 ESP with `/EFI/BOOT/BOOTX64.EFI`, not ISO9660
- **GRUB parameters must be pre-baked** — no manual keyboard input available during boot
- **Shell commands run via `sh -c`** (dash) — use only POSIX-compatible syntax in autoinstall.yaml
- **ESP must be 5GB+** — the Ubuntu 24.04.4 Server ISO is ~3.4GB with casper/ squashfs layers totaling ~2.5GB; a 2GB ESP cannot hold the installer contents
- **Partition type GUIDs must be lowercase** — curtin normalizes GUIDs to lowercase for verification; using uppercase causes `preserve: true` verification mismatches
- **Autoinstall YAML must use string-based replacement** — `yaml.dump` converts `|` block scalars to quoted strings with `\n` escapes, breaking subiquity; use regex replacement to preserve formatting
- **Dual-boot safety** — macOS is preserved with `preserve: true` on all existing partitions. If Ubuntu install fails, `bless --nextonly` reverts boot to macOS. Remaining risk: if curtin itself has a bug that ignores `preserve: true`, or if the GPT partition table gets corrupted. Mitigations: webhook monitoring, SSH into installer, VirtualBox testing, Target Disk Mode fallback
- **gcc-13 must match ISO kernel** — packages must provide `gcc-13 13.3.0-6ubuntu2~24.04` and `gcc-13-x86-64-linux-gnu` (provides `x86_64-linux-gnu-gcc-13`). Older versions cause DKMS build failures (`cc: not found`, library ABI mismatches). `cc` symlink must point to `x86_64-linux-gnu-gcc-13` with fallback to `gcc-13`
- **dpkg --skip-same-version** — the ISO live environment has base packages (libgcc-s1, libstdc++6, perl-base, kmod) at newer versions than our bundles; without `--skip-same-version`, dpkg downgrades them and breaks the live environment

## Context Management Rules

When working on this project, ALL agents (build, Sisyphus-Junior, exploration agents, etc.) MUST follow these rules:

### Memory (Cross-Session)
- **After completing significant work**, save key findings, decisions, and file locations to `ctx_memory` using categories: `ENVIRONMENT`, `CONSTRAINTS`, `WORKFLOW_RULES`
- **Before exploring the codebase** for a question that may have been answered before, search `ctx_memory` first with `ctx_search`
- **When learning non-obvious constraints** the hard way (e.g., build failures, platform quirks), save immediately to `ctx_memory` under `CONSTRAINTS`

### Context Reduction (Within Session)
- **After processing large tool outputs** (file reads, grep results, agent outputs), use `ctx_reduce` to drop them once extracted and acted upon
- **After completing a todo phase**, drop tool outputs from that phase
- **Never drop user messages or recent conversation text** — these are cheap and auto-compartmentalized
- **Never blind-drop large ranges** — review each tag before deciding

### Session Notes
- **Use `ctx_note`** for session-level reminders and deferred intentions
- **Notes are NOT for task tracking** — use todos for that
- **Notes survive context compression** — write them for anything you'll need later in the session