# Mac Pro 2013 Ubuntu Autoinstall - AGENTS.md

> **This document is for LLM agents and automated tools.** It describes architecture, constraints, code conventions, and implementation details that agents need to work effectively. For human-oriented usage instructions, troubleshooting, and examples, see `README.md`. For a record of what changed between versions, see `CHANGELOG.md`.
>
> **What this document contains:** Code structure, module APIs, naming conventions, constraints, build/test commands, deployment internals, and context management rules.  
> **What this document does NOT contain:** Bug fix histories, change logs, or version-specific deltas — those belong in `CHANGELOG.md`.

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
├── lib/                             # Modular library
│   ├── autoinstall.yaml             # Autoinstall configuration (base template — WiFi + dual-boot)
│   ├── build-iso.sh                 # ISO builder (xorriso extract-and-repack) — called as subprocess
│   ├── deploy.conf.example          # WiFi/webhook config template (copy to deploy.conf)
│   ├── autoinstall.sh               # generate_autoinstall, generate_dualboot_storage
│   ├── autoinstall-schema.json      # Subiquity YAML validation schema
│   ├── colors.sh                    # Color constants (RED, GREEN, YELLOW, NC) with guard
│   ├── logging.sh                   # Multi-target logger (serial+file+webhook) with level control
│   ├── tui.sh                       # TUI primitives (dialog/whiptail/raw) + agent mode bypass
│   ├── dryrun.sh                    # Dry-run wrapper, agent output, exit codes, JSON helpers
│   ├── retry.sh                     # Exponential backoff retry wrappers (diskutil, ssh, xorriso)
│   ├── verify.sh                    # Post-operation verification with self-healing
│   ├── rollback.sh                  # State journal + rollback engine (phase tracking)
│   ├── remote.sh                    # SSH management functions for post-install operations
│   ├── detect.sh                    # detect_iso, detect_usb_devices, select_usb_device
│   ├── disk.sh                      # analyze_disk_layout, shrink_apfs_if_needed, create_esp_partition
│   ├── bless.sh                     # verify_esp_contents, attempt_bless
│   ├── deploy.sh                    # 7-phase checkpointed deployment with journal state
│   └── revert.sh                    # revert_changes, handle_revert_flag, journal-aware rollback
├── packages/                        # .deb files for driver compilation (34 debs)
│   ├── broadcom-sta-dkms_*.deb      # Broadcom WiFi driver source
│   ├── dkms_*.deb                   # Dynamic Kernel Module Support
│   ├── linux-headers-6.8.0-100*     # Kernel headers matching ISO kernel (6.8.0-100-generic)
│   ├── gcc-13_*, gcc-13-x86-64-linux-gnu_*, make_*, etc.       # Build toolchain
│   ├── dkms-patches/               # 6 kernel 6.8+ compatibility patches (series + *.patch)
│   └── ...
├── ssh/                             # SSH configuration for Manage mode
│   └── config.example               # Template for ~/.ssh/config (Host macpro-linux)
├── tests/                           # Unit tests and testing protocol
│   ├── run_tests.sh                 # Test runner
│   ├── test_retry.sh               # lib/retry.sh tests
│   ├── test_rollback.sh            # lib/rollback.sh tests
│   ├── test_verify.sh              # lib/verify.sh tests
│   ├── test_dryrun.sh              # lib/dryrun.sh tests
│   ├── test_config.sh              # Config parsing, placeholder substitution, encryption tests
│   ├── TESTING_PROMPT.md           # Comprehensive code review and testing protocol
│   └── vm/                          # VM test environment (uses --vm flag)
│       ├── create-vm.sh             # VirtualBox VM creation
│       └── test-vm.sh              # Run/monitor/SSH/stop
├── README.md                        # Documentation (human-oriented)
├── CHANGELOG.md                     # Version history (change log per release)
├── How-to-Update.md                 # Kernel update safety guide (7 phases with rollback)
├── Post-Install.md                  # Post-install operations (erase macOS, system update)
├── macpro-monitor/                  # Node.js webhook monitor
│   ├── server.js                    # HTTP server with event bus and progress tracking
│   ├── package.json                 # Node.js package manifest
│   ├── start.sh / stop.sh / reset.sh
│   └── logs/
└── prereqs/                         # Stock Ubuntu ISO (*.iso gitignored)

# Runtime output: ~/.Ubuntu_Deployment/    # Generated files (ISO, autoinstall.yaml, deploy.conf, staging)
```

## Build/Lint/Test Commands

### Build ISO
```bash
sudo ./lib/build-iso.sh
```

### Deploy (interactive TUI)
```bash
sudo ./prepare-deployment.sh
```

### Deploy with dry-run
```bash
sudo ./prepare-deployment.sh --dry-run
```

### Deploy with agent mode (non-interactive, for LLM/automation)
```bash
sudo ./prepare-deployment.sh --agent --yes --method 1 --storage 1 --network 1 --json
```

### Manage via agent mode
```bash
sudo ./prepare-deployment.sh --agent --operation kernel_status --host macpro-linux --json
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
cd tests/vm && sudo ./create-vm.sh && ./test-vm.sh
# Or use build-iso.sh --vm:
sudo ./lib/build-iso.sh --vm
```

### Syntax check all shell scripts
```bash
bash -n prepare-deployment.sh && bash -n lib/*.sh && bash -n tests/vm/*.sh
```

### Run unit tests
```bash
bash tests/run_tests.sh
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

## CLI Interface

### Interactive (TUI)
```bash
sudo ./prepare-deployment.sh          # Deploy or Manage menu
sudo ./prepare-deployment.sh --dry-run  # Show what would happen
sudo ./prepare-deployment.sh --revert   # Undo failed deployment
```

### Agent Mode (non-interactive)
```bash
# Deploy - internal partition, dual-boot, WiFi
sudo ./prepare-deployment.sh --agent --yes --method 1 --storage 1 --network 1 --json

# Deploy - USB, full-disk, Ethernet
sudo ./prepare-deployment.sh --agent --yes --method 2 --storage 2 --network 2 --json --dry-run

# Manage - check kernel status
sudo ./prepare-deployment.sh --agent --operation kernel_status --host macpro-linux --json

# Manage - erase macOS
sudo ./prepare-deployment.sh --agent --yes --operation erase_macos --host macpro-linux --json

# Build ISO only
sudo ./prepare-deployment.sh --agent --build-iso --json

# Revert via agent
sudo ./prepare-deployment.sh --agent --revert --json
```

Flags: `--agent`, `--yes`, `--dry-run`, `--json`, `--method N`, `--storage N`, `--network N`, `--operation OP`, `--host HOST`, `--wifi-ssid`, `--wifi-password`, `--webhook-host`, `--webhook-port`, `--revert`, `--build-iso`, `--username USER`, `--hostname HOST`, `--vm`

Exit codes: 0=success, 1=general, 2=usage, 3=config, 4=check, 5=partial, 6=dependency, 7=network, 8=disk, 9=timeout, 10=auth, 11=dry-run-ok, 12=agent-param, 13=agent-denied

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
- When `AGENT_MODE=1`, all tui_* functions bypass interactive prompts and emit JSON/log output

### Dry-Run and Agent Module (lib/dryrun.sh)
- `dry_run_exec "description" command args` — wraps destructive commands; in DRY_RUN=1, prints `[DRY-RUN]` and returns 0 without executing
- `is_dry_run` — returns 0 if DRY_RUN=1, 1 otherwise
- `agent_output type title value [key val...]` — emits NDJSON (JSON_OUTPUT=1) or log lines for LLM agents
- `agent_error message [code]` — emits structured error and exits with code
- `agent_confirm title prompt` — auto-approve (CONFIRM_YES=1) or auto-deny (0) in agent mode
- Exit code constants: E_SUCCESS(0), E_GENERAL(1), E_USAGE(2), E_CONFIG(3), E_CHECK(4), E_PARTIAL(5), E_DEPENDENCY(6), E_NETWORK(7), E_DISK(8), E_TIMEOUT(9), E_AUTH(10), E_DRY_RUN_OK(11), E_AGENT_PARAM(12), E_AGENT_DENIED(13)

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

### YAML (lib/autoinstall.yaml)
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

### deploy.conf Parsing
- `parse_conf()` uses `IFS='=' read -r key value` split (first `=` only) to preserve `$` in password hashes
- No `xargs` — values are used directly as shell variables
- `SSH_AUTHORIZED_KEYS` supports multi-line value via repeated `SSH_KEY=` entries
- `SSH_KEYS_FILE=/path/to/file` loads keys from external file

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

## deploy.conf Configuration

Runtime configuration file (KEY=VALUE format). Lives in `~/.Ubuntu_Deployment/deploy.conf` (created on first run). Template at `lib/deploy.conf.example`.

### Config File Format
```
KEY=value                    # First = only (preserves $ in password hashes)
SSH_KEY=ssh-rsa AAAA...      # One SSH_KEY per line for multiple keys
SSH_KEYS_FILE=/path/to/file  # Load keys from external file
```

### Keys
| Key | Description |
|-----|-------------|
| `USERNAME` | Ubuntu login username (default: ubuntu) |
| `REALNAME` | Full name for user account |
| `PASSWORD_HASH` | crypt(3) hash (e.g., `openssl passwd -6`) or plaintext |
| `HOSTNAME` | Ubuntu system hostname |
| `SSH_KEY` | SSH public key (repeat for multiple keys) |
| `SSH_KEYS_FILE` | Path to file containing SSH public keys |
| `ENCRYPTION` | Password encryption mode (see below) |
| `OUTPUT_DIR` | Override runtime output directory (default: ~/.Ubuntu_Deployment/) |

### Encryption Modes
| Mode | Description |
|------|-------------|
| `plaintext` | Password stored as-is; file must be chmod 600 |
| `aes256` | Password encrypted with `openssl aes-256-cbc -salt` |
| `keychain` | Password retrieved from macOS Keychain via `security find-generic-password` |

### First-Run Prompts
If `deploy.conf` is missing or keys are empty, `prepare-deployment.sh` prompts for:
- Username, real name, password (with encryption mode selection)
- SSH key configuration (interactive menu):
  - **Provide existing key**: scans `~/.ssh/*.pub` for keys to select, or paste manually
  - **Generate new key**: `ssh-keygen` with ed25519 (recommended) or RSA-4096
  - **Skip SSH**: warns about needing console access
- Offer to create `~/.ssh/config` entries for `macpro` and `macpro-linux`
- Hostname
- WiFi credentials (if network=wifi)
- Webhook URL (optional)
- Pre-execution summary confirmation before deployment begins

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

## Runtime Output Directory

All generated files (ISO, autoinstall.yaml, deploy.conf) go to `~/.Ubuntu_Deployment/` by default. Override via `OUTPUT_DIR` in `deploy.conf` or `--output-dir` CLI flag.

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