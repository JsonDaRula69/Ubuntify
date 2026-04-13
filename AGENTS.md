# Mac Pro 2013 Ubuntu Autoinstall - AGENTS.md

## Project Overview

Ubuntu 24.04.4 LTS Server deployment and management tool for Mac Pro 2013 (MacPro6,1) with Broadcom BCM4360 WiFi. Two modes: **Deploy** (local: build ISO, deploy to ESP/USB/VM, monitor installation) and **Manage** (remote: SSH into installed instance for kernel management, driver rebuilds, macOS erasure, system updates). TUI interface using dialog/whiptail with raw bash fallback. Multi-target logging (serial + file + webhook). Published on GitHub for other Mac Pro owners.

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
├── prepare-deployment.sh             # Main entry point — TUI with Deploy + Manage modes
├── autoinstall.yaml                 # Autoinstall configuration (base template — WiFi + dual-boot)
├── build-iso.sh                     # ISO builder (xorriso extract-and-repack) — called as subprocess
├── deploy.conf.example              # WiFi/webhook config template (copy to deploy.conf)
├── lib/                             # Modular library
│   ├── colors.sh                    # Color constants (RED, GREEN, YELLOW, NC) with guard
│   ├── logging.sh                   # Multi-target logger (serial+file+webhook) with level control
│   ├── tui.sh                       # TUI primitives (dialog/whiptail/raw) — auto-detect backend
│   ├── remote.sh                    # SSH management functions for post-install operations
│   ├── utils.sh                     # Legacy logger (log, warn, error, die, vlog) — backward compat
│   ├── detect.sh                    # detect_iso, detect_usb_devices, select_usb_device
│   ├── disk.sh                      # analyze_disk_layout, shrink_apfs_if_needed, create_esp_partition
│   ├── autoinstall.sh               # generate_autoinstall, generate_dualboot_storage
│   ├── bless.sh                     # verify_esp_contents, attempt_bless
│   ├── deploy.sh                    # deploy_internal_partition, deploy_usb, deploy_manual, deploy_vm_test
│   └── revert.sh                    # revert_changes, handle_revert_flag, cleanup_on_error
├── packages/                        # .deb files for driver compilation (34 debs)
│   ├── broadcom-sta-dkms_*.deb      # Broadcom WiFi driver source
│   ├── dkms_*.deb                   # Dynamic Kernel Module Support
│   ├── linux-headers-6.8.0-100*     # Kernel headers matching ISO kernel (6.8.0-100-generic)
│   ├── gcc-13_*, gcc-13-x86-64-linux-gnu_*, make_*, etc.       # Build toolchain
│   ├── dkms-patches/               # 6 kernel 6.8+ compatibility patches (series + *.patch)
│   └── ...
├── ssh/                             # SSH configuration for Manage mode
│   └── config.example               # Template for ~/.ssh/config (Host macpro-linux)
├── README.md                        # Documentation
├── How-to-Update.md                 # Kernel update safety guide (7 phases with rollback)
├── Post-Install.md                  # Post-install operations (erase macOS, system update)
├── macpro-monitor/                  # Node.js webhook monitor
│   ├── server.js                    # HTTP server with event bus and progress tracking
│   ├── package.json                 # Node.js package manifest
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

### Deploy (interactive TUI)
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

### Manage (SSH into installed instance)
```bash
sudo ./prepare-deployment.sh
# Select "Manage" from TUI → System Info, Kernel, WiFi/Driver, Storage, APT, Reboot
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

### Syntax check all shell scripts
```bash
bash -n prepare-deployment.sh && bash -n lib/*.sh && bash -n build-iso.sh && bash -n vm-test/*.sh
```

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
set -u
readonly CONST="value"
local var="value"
```
Use `RED`, `GREEN`, `NC` color constants. Log to file with `tee`.

### TUI Module (lib/tui.sh)
- Auto-detects `dialog` > `whiptail` > `raw` at source time
- All menus use `tui_menu`, `tui_confirm`, `tui_input`, `tui_password`
- Progress uses `tui_progress` (reads `PERCENT MESSAGE` from stdin)
- Log tailing uses `tui_tailbox`
- Never call `dialog` or `whiptail` directly — always via tui_* functions

### Logging Module (lib/logging.sh)
- Multi-target: serial console, file, webhook
- Levels: DEBUG(0), INFO(1), WARN(2), ERROR(3), FATAL(4)
- `log_init [LOG_DIR] [WEBHOOK_URL]` must be called at startup
- `log_shutdown` must be called in trap handlers
- Backward-compatible aliases: `log()` = `log_info()`, `die()` = `log_fatal()`

### Remote Management (lib/remote.sh)
- All functions accept optional `[HOST]` parameter (defaults to `macpro-linux`)
- SSH commands use `-o ConnectTimeout=10 -o BatchMode=yes`
- `LIBEFIVAR_OPS=efivarfs` set for all `efibootmgr` commands
- Destructive operations require explicit user confirmation

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