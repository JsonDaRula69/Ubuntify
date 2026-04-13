# Mac Pro 2013 Ubuntu Autoinstall - AGENTS.md

## Project Overview

Ubuntu 24.04.4 LTS Server deployment for Mac Pro 2013 (MacPro6,1) with Broadcom BCM4360 WiFi. Four deployment methods supported: (1) internal ESP partition with autoinstall, (2) USB drive with autoinstall, (3) manual install from USB, (4) VM test in VirtualBox. Dual-boot and full-disk storage layouts. WiFi-only and Ethernet network configurations. SIP blocks bless NVRAM writes — boot device must be selected via keyboard (hold Option at startup) or System Preferences with a monitor.

## Hardware Specifications

- **Model**: Mac Pro 2013 (MacPro6,1)
- **Current OS**: macOS 12.7.6 (Monterey)
- **Access**: SSH + local keyboard/monitor (for boot selection)
- **GPU**: AMD FirePro D300/D500/D700 (amdgpu, needs `nomodeset amdgpu.si.modeset=0`)
- **WiFi**: Broadcom BCM4360 (proprietary `wl` driver, NOT in Ubuntu)
- **Storage**: Apple PCIe SSD via AHCI → `/dev/sda` (not NVMe)
- **2 Ethernet ports** (may be plugged in for Ethernet installs)
- **SIP always enabled** — blocks bless NVRAM writes (0xe00002e2), boot device must be selected via keyboard Option key or System Preferences Startup Disk
- **MacBook available on network** — can serve as monitoring endpoint and fallback

## Project Structure

```
/Users/djtchill/Desktop/Mac/
├── autoinstall.yaml                 # Autoinstall configuration (base template — WiFi + dual-boot)
├── build-iso.sh                     # ISO builder (xorriso extract-and-repack) — injects config, cidata, GRUB, packages
├── prepare-deployment.sh             # Interactive deployment script (main orchestrator)
├── deploy.conf.example              # WiFi/webhook config template (copy to deploy.conf)
├── lib/                             # Modular library for prepare-deployment.sh
│   ├── colors.sh                    # Color constants (RED, GREEN, YELLOW, NC)
│   ├── utils.sh                     # log, warn, die, vlog, banner functions
│   ├── detect.sh                    # detect_iso, detect_usb_devices, select_usb_device
│   ├── disk.sh                      # analyze_disk_layout, shrink_apfs_if_needed, create_esp_partition
│   ├── autoinstall.sh               # generate_autoinstall, generate_dualboot_storage
│   ├── bless.sh                     # verify_esp_contents, attempt_bless
│   ├── deploy.sh                    # deploy_internal_partition, deploy_usb, deploy_manual, deploy_vm_test
│   └── revert.sh                    # revert_changes, handle_revert_flag
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
├── How-to-Update.md                 # Kernel update safety guide (circular dependency: DKMS ↔ new kernel)
├── Post-Install.md                  # Post-installation tasks (WiFi password rotation, SSH hardening)
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

### Deploy (interactive menu)
```bash
sudo ./prepare-deployment.sh
```

### Deploy with dry-run
```bash
sudo ./prepare-deployment.sh --dry-run
```

### Revert failed deployment
```bash
sudo ./prepare-deployment.sh --revert
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

1. **Extract-and-repack ISO modification**: The original ISO is extracted to a staging directory, custom files are overlaid, and the ISO is rebuilt using boot parameters preserved via `xorriso -report_el_torito as_mkisofs`. Boot params are flattened with `tr '\n' ' '` before `eval` — newlines in BOOT_PARAMS cause eval to treat each line as a separate command. This properly preserves Ubuntu 24.04's appended EFI partition image and MBR hybrid boot structure. Volume label set to `cidata` for NoCloud discovery.

2. **Compile during install with DKMS patches**: The `early-commands` dynamically detects the running kernel (`KVER="$(uname -r)"`), validates matching headers exist, then installs from discovered `macpro-pkgs/` mount. The `broadcom-sta-dkms` postinst auto-runs `dkms add` (creates symlink). DKMS patches are applied to `/usr/src/` AFTER `dpkg -i` but BEFORE `dkms build`. Missing patches are FATAL. Failed builds have single-retry fallback with clean-then-rebuild. The `late-commands` repeats this in a 4-stage `dpkg --root /target` install with bind mounts for chroot DKMS.

3. **GPU**: AMD FirePro uses built-in `amdgpu` driver. Only `nomodeset amdgpu.si.modeset=0` kernel params needed — pre-baked in GRUB config.

4. **Network**: WiFi netplan generated in early-commands (after `wl` driver load + interface detection) with auto-detected interface name. The `network:` section cannot use `wifis:` because the driver doesn't exist in the live environment until early-commands compiles it. networkd does not support `match:` for `wifis:` (Ubuntu Bug #2073155), so the actual detected interface name must be used. Config generated with `printf` (not heredoc). Uses `networkd` renderer (NOT NetworkManager). WiFi power management disabled via modprobe options and systemd unit. Netplan failure is FATAL.

5. **Storage (Dual-Boot)**: All existing partitions preserved with `preserve: true`. The `prepare-deployment.sh` script dynamically generates storage config using Python + `sgdisk` after APFS resize. Partition type GUIDs normalized to lowercase for curtin. ESP labeled `CIDATA` (uppercase) for NoCloud discovery — FAT32 volume names on macOS must be uppercase. Storage config uses string-based regex replacement (NOT `yaml.dump`) to preserve `|` block scalars.

6. **Remote boot via `bless`**: `bless --setBoot --mount <esp> --file <esp>/EFI/boot/bootx64.efi --nextonly` from macOS SSH. On FAT32 volumes, `bless` requires `--file` to specify the EFI bootloader path. The GPT partition type must be `C12A7328-F81F-11D2-BA4B-00A0C93EC93B` (EFI System Partition) — `diskutil eraseVolume` sets Microsoft Basic Data, which Apple EFI firmware rejects. The `--nextonly` flag reverts boot to macOS if the firmware can't find a valid bootloader. GRUB parameters are pre-baked.

7. **macOS boot from GRUB**: GRUB cannot read APFS. The `40_macos` menu entry uses `fwsetup` to reboot to Apple Boot Manager. `efibootmgr` is installed with `LIBEFIVAR_OPS=efivarfs` workaround for Apple EFI 1.1 bug (Ubuntu Bug #2040190). `/usr/local/bin/boot-macos` uses `efibootmgr --bootnext` to set macOS as next boot device.

8. **SSH into installer**: `early-commands` starts `sshd` after WiFi driver compilation. Falls back to ISO pool `.deb`s with `--force-depends` if network apt fails. `ssh: install-server: true` only applies to the target system.

9. **NoCloud datasource**: ISO includes `/cidata/` for `ds=nocloud`. Volume label `CIDATA` (uppercase) enables discovery — cloud-init searches labels case-insensitively on Linux. `autoinstall` kernel param bypasses confirmation prompt.

10. **Deploy safety**: `prepare-deployment.sh` uses before/after partition diffing. APFS snapshots auto-deleted. Bless verified with `--info`. Error recovery trap reverts all changes (method-dependent: internal partition removes ESP and restores APFS, USB unmounts device, VM test powers off VM). Pre-flight checks validate ISO integrity, SIP, FileVault, and webhook reachability. Supports `--revert` flag for manual rollback.

11. **Monitoring**: `macpro-monitor` receives Subiquity/Curtin events via webhook at DEBUG level, plus custom progress events via `curl` with `{progress, stage, status, message}` payloads. Progress percentages are monotonically increasing.

12. **All critical paths are fatal**: DKMS failures, driver load failures, patch failures, WiFi connectivity failures, missing headers — all `exit 1`. Non-critical failures (`update-grub`, SSH start) use `|| true` or `|| echo WARN`. Error events sent to webhook before exit.

13. **WiFi connectivity verification**: After driver load and interface detection, the installer verifies WiFi by scanning for networks (iwlist), checking DHCP lease, and testing HTTP connectivity. If WiFi is lost, the system automatically reloads the `wl` driver and retries for up to 60 seconds. If reconnect fails in early-commands, installation aborts before storage. If reconnect fails in late-commands, the system enters recovery mode (keeps SSH alive, blocks reboot).

14. **Post-install verification and recovery**: Late-commands verify kernel, netplan, GRUB, WiFi module, and user account. If WiFi is broken in the target system, the installer does NOT reboot into a headless brick — keeps SSH alive with infinite sleep loop for remote debugging. Error logs saved to `/var/log/macpro-install/` (persists across reboots). UFW firewall denies all incoming except SSH.

15. **Dynamic mount discovery**: `macpro-pkgs/` is discovered dynamically by searching `/cdrom`, `/isodevice`, and `/mnt` — path varies by boot method.

16. **ISO extraction via xorriso on macOS**: macOS `hdiutil` cannot mount xorriso-built ISOs with hybrid MBR+GPT+appended EFI partition structures — this is a structural incompatibility, not a bug. The `prepare-deployment.sh` script uses `xorriso -osirrox on -indev` to extract files directly to the ESP, bypassing mount entirely.

17. **APFS container indirection on macOS**: The macOS partition table references APFS by physical partition (e.g. `disk0s2` contains `Apple_APFS Container disk1`), but `diskutil apfs` commands operate on the container reference (`disk1`). The `prepare-deployment.sh` script parses both — using `diskutil info` on the partition to discover the container reference. `diskutil apfs resizeContainer` takes the container reference, NOT the physical partition.

18. **ESP GPT type must be EFI System Partition**: `diskutil eraseVolume FAT32` sets the GPT partition type to Microsoft Basic Data (`EBD0A0A2-B9E5-4433-87C0-68B6B72699C7`), but Apple EFI firmware requires `C12A7328-F81F-11D2-BA4B-00A0C93EC93B` for `bless` to work. `sgdisk --typecode` fails on macOS boot disk (IOKit exclusive lock). Solution: use `diskutil addPartition disk0 %C12A7328-F81F-11D2-BA4B-00A0C93EC93B% %noformat% 5g` to create the partition with correct ESP type from the start, then format with `newfs_msdos -F 32 -v CIDATA` (which does NOT change GPT type, unlike `diskutil eraseVolume`).

19. **diskutil eraseVolume renumbers slices**: When `eraseVolume` changes the filesystem, macOS may assign a new slice number (e.g. creating `disk0s3` but formatting as `disk0s4`). Always find partitions by volume name, not by tracked device number.

20. **bless on FAT32 requires --file**: On FAT32 EFI volumes, `bless --setBoot --mount` alone fails with `0xe00002e2`. Must also specify `--file <esp>/EFI/boot/bootx64.efi` to identify the EFI bootloader path.

21. **SIP blocks ALL NVRAM writes**: On Mac Pro 2013 with macOS 12.7.6 (SIP enabled), both `bless --setBoot` and `nvram` fail — even with correct GPT type and IOKit registration. The error `0xe00002e2` occurs at the NVRAM write step, not at IOKit matching. `systemsetup -setstartupdisk` also fails under SIP. Boot device must be set via blind keyboard (hold Option → Right Arrow → Enter to select CIDATA) or Recovery Mode (Cmd+R → `csrutil enable --without nvram` → `bless`). After Ubuntu installs, `efibootmgr` from Linux (no SIP) sets permanent boot order. `prepare-deployment.sh` handles bless failure gracefully with blind boot instructions.

22. **newfs_msdos does not register with IOKit/DiskArbitration**: `newfs_msdos -F 32 -v CIDATA /dev/disk0s3` creates a valid FAT32 filesystem without changing the GPT partition type (unlike `diskutil eraseVolume`), but the volume is not registered with IOKit's DiskArbitration framework. Bless may fail because it cannot construct the IOMatch NVRAM dict. Unformatted partitions created by `diskutil addPartition %noformat%` also lack raw device nodes (`/dev/rdisk0sN`) — use block device `/dev/disk0sN` for `newfs_msdos`.

23. **cloud-init first-boot network overwrite**: cloud-init regenerates `/etc/netplan/50-cloud-init.yaml` on first boot, which can conflict with custom netplan configs. Disable cloud-init network config generation by writing `network: {config: disabled}` to `/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg` in late-commands.

24. **Volume label CIDATA uppercase**: FAT32 volume names on macOS must be uppercase. cloud-init's NoCloud datasource searches volume labels case-insensitively on Linux, so `CIDATA` is discovered correctly.

## VirtualBox Test Environment

| File | Purpose |
|------|---------|
| `autoinstall-vm.yaml` | DKMS compiles (fatal on failure), driver init non-fatal (no Broadcom HW). Uses Ethernet. Webhook targets `10.0.2.2` via NAT. |
| `build-iso-vm.sh` | Builds `ubuntu-vmtest.iso` from `../packages/` with VM config |
| `create-vm.sh` | VirtualBox VM: EFI, 4 CPUs, 4.5GB RAM, 25GB disk, NAT, SSH port forward |
| `test-vm.sh` | Run/monitor/SSH/grab logs/stop/destroy |

## Deployment Methods

The `prepare-deployment.sh` script supports four deployment methods:

| Method | Description | Requirements |
|--------|-------------|-------------|
| 1) Internal partition | Copies Ubuntu installer to CIDATA ESP on internal disk | Monitor or keyboard for boot selection (SIP blocks bless) |
| 2) USB drive | Creates bootable USB with Ubuntu installer | USB drive (4GB+), keyboard + monitor |
| 3) Full manual | Creates standard Ubuntu USB (no autoinstall) | USB drive (4GB+), keyboard + monitor |
| 4) VM test | Validates autoinstall flow in VirtualBox on this Mac | VirtualBox, 4GB+ disk space |

Each method (except 3 and 4) offers two storage layouts:
- **Dual-boot**: Preserves macOS partitions with `preserve: true`, dynamically generates storage config
- **Full disk**: Wipes entire disk, fresh GPT + EFI + /boot + / (simpler autoinstall)

And two network configurations:
- **WiFi only**: Must compile `wl` driver in early-commands before network (slower, requires DKMS packages)
- **Ethernet available**: Network works immediately via DHCP, WiFi driver compiled for target system only

Method 4 (VM test) uses fixed Ethernet and single disk — no storage or network selection needed.

## Boot Methods

| Method | Physical Access? | Status |
|--------|-----------------|--------|
| Keyboard Option key at startup | Keyboard (no monitor needed for USB) | Implemented — wireless dongle keyboards may not register in time |
| System Preferences Startup Disk | Monitor required | SIP blocks bless from SSH, but GUI works with monitor |
| Recovery Mode → csrutil enable --without nvram | Keyboard (hold Cmd+Option+R) | Works — then bless succeeds from macOS |

## Switching Between macOS and Ubuntu

| Direction | Method | Command |
|-----------|--------|---------|
| macOS → Ubuntu | Startup Disk GUI | System Preferences → Startup Disk → select CIDATA (requires monitor) |
| macOS → Ubuntu | Keyboard Option key | Hold Option at chime → select CIDATA from Startup Manager |
| macOS → Ubuntu | Recovery Mode | Cmd+R → Terminal → `csrutil enable --without nvram` → reboot → `bless --nextonly` |
| Ubuntu → macOS | `efibootmgr` | `sudo boot-macos` then reboot |
| Ubuntu → macOS | GRUB menu | Select "Reboot to Apple Boot Manager" |
| Any → macOS | Firmware | Hold Option at boot (requires keyboard) |

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
- Use auto-detected interface name in netplan (not `match:` — networkd does not support match: for wifis)
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
- **BOOT_PARAMS must have newlines flattened** — `xorriso -report_el_torito as_mkisofs` outputs each param on its own line; `tr '\n' ' '` before `eval` is required or each line becomes a separate command
- **macOS hdiutil cannot mount xorriso ISOs** — structural incompatibility with hybrid MBR+GPT+appended EFI; use `xorriso -osirrox` for extraction
- **diskutil eraseVolume sets Microsoft Basic Data GPT type** — use `diskutil addPartition %C12A7328-F81F-11D2-BA4B-00A0C93EC93B% %noformat% 5g` to create with correct ESP type, then `newfs_msdos -F 32 -v CIDATA` (sgdisk --typecode fails on macOS boot disk due to IOKit lock)
- **bless --file required on FAT32** — `bless --setBoot --mount` alone fails with `0xe00002e2` on FAT32 volumes
- **APFS container reference ≠ physical partition** — `diskutil apfs resizeContainer` takes container ref (e.g. `disk1`), not physical partition (`disk0s2`)
- **diskutil eraseVolume renumbers slices** — find ESP by volume name, not tracked device number
- **sgdisk cannot modify mounted GPT** — must unmount partition before `sgdisk --typecode`
- **169.254.x.x link-local addresses** — must be excluded from DHCP lease checks; `grep -q "inet 169\.254\."` guard on all IP validation
- **Serial console output** — GRUB `console=ttyS0,115200` param enables serial output for headless debugging; VirtualBox UART1 maps to `/tmp/vmtest-serial.log`
- **Blacklist loop redirect** — for-loop writing to blacklist file must use `>>` (append), not `>` (overwrite); `>` truncates on each iteration, only keeping the last driver entry

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