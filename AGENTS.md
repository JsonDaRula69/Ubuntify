# Mac Pro 2013 Ubuntu Autoinstall - AGENTS.md

> **This document is for LLM agents and automated tools.** It describes architecture, constraints, code conventions, and implementation details that agents need to work effectively. For human-oriented usage instructions, troubleshooting, and examples, see `README.md`. For a record of what changed between versions, see `CHANGELOG.md`.
>
> **What this document contains:** Code structure, module APIs, naming conventions, constraints, build/test commands, deployment internals, and context management rules.  
> **What this document does NOT contain:** Bug fix histories, change logs, or version-specific deltas — those belong in `CHANGELOG.md`.

## Project Overview

Ubuntu 24.04.4 LTS Server deployment and management tool for Mac Pro 2013 (MacPro6,1) with Broadcom BCM4360 WiFi. Two deployment modes: **Local** (run directly on Mac Pro with sudo) and **Remote** (control Mac Pro via SSH from another machine). Two functional modes: **Deploy** (build ISO, deploy to ESP/USB/VM, monitor installation) and **Manage** (remote: SSH into installed instance for kernel management, driver rebuilds, macOS erasure, system updates). TUI interface using dialog/whiptail with raw bash fallback. Multi-target logging (serial + file + webhook). Published on GitHub for other Mac Pro owners.

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
│   ├── remote_mac.sh                # Remote execution wrapper (SSH/local routing based on DEPLOY_MODE)
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

## Deployment Modes

The script operates in two deployment modes, controlled by `DEPLOY_MODE` in `deploy.conf` or `--deploy-mode` CLI flag:

| Mode | Description | Requires sudo? | Runs commands |
|------|-------------|----------------|----------------|
| `local` (default) | Run directly on the Mac Pro | Yes (local sudo) | Locally on this machine |
| `remote` | Control the Mac Pro via SSH from another machine | No (remote sudo) | Via SSH on TARGET_HOST |

### Remote Mode Architecture

In remote mode, all macOS-specific operations (diskutil, sgdisk, bless, xorriso) execute on the target Mac Pro via SSH. The local machine only generates configuration files and transfers them via SCP.

**Command routing** (`lib/remote_mac.sh`):
- `remote_mac_exec <command>` — runs locally or via SSH based on DEPLOY_MODE
- `remote_mac_sudo <command>` — same with sudo prefix (uses REMOTE_SUDO_PASSWORD)
- `remote_mac_cp <local> <remote>` — copies file to target via scp
- `remote_mac_cp_dir <local> <remote>` — copies directory recursively
- `remote_mac_file_exists <path>` — checks file on target
- `remote_mac_dir_exists <path>` — checks directory on target
- `remote_mac_mkdir <path>` — creates directory on target
- `remote_mac_rm <path>` — removes file on target
- `remote_mac_preflight()` — verifies SSH connectivity, required tools, and sudo access

**Key differences in remote mode**:
- ISO is SCP'd to `/tmp` on target, then extracted remotely via `xorriso`
- Configuration is generated locally in `${OUTPUT_DIR}/staging`, validated, then SCP'd to target
- Preflight checks run on the target host (xorriso, sgdisk, python3, diskutil, bless)
- Root/sudo check is skipped on the local machine
- Revert can also operate remotely

**CLI flags for remote mode**:
```bash
# Interactive remote deployment
sudo ./prepare-deployment.sh --deploy-mode remote --target-host macpro

# Agent mode remote deployment
sudo ./prepare-deployment.sh --agent --deploy-mode remote --target-host macpro --remote-password XXX --method 1 --storage 1 --network 1 --json

# No local sudo needed in remote mode
./prepare-deployment.sh --deploy-mode remote --target-host macpro
```

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

# Revert via agent
sudo ./prepare-deployment.sh --agent --revert --json
```

Flags: `--agent`, `--yes`, `--verbose`, `--dry-run`, `--json`, `--method N`, `--storage N`, `--network N`, `--deploy-mode MODE`, `--target-host HOST`, `--remote-password PWD`, `--operation OP`, `--host HOST`, `--wifi-ssid`, `--wifi-password`, `--webhook-host`, `--webhook-port`, `--output-dir DIR`, `--revert`, `--username USER`, `--hostname HOST`, `--vm`

Exit codes: 0=success, 1=general, 2=usage, 3=config, 4=check, 5=partial, 6=dependency, 7=network, 8=disk, 9=timeout, 10=auth, 11=dry-run-ok, 12=agent-param, 13=agent-denied

## Manage Mode TUI Menu Structure

The Manage mode presents a menu that maps to remote.sh functions:

| Menu Item | Submenu/Action | Function Called |
|-----------|---------------|-----------------|
| System Info | — | `remote_get_info` |
| Kernel Management | Status, Pin, Unpin, Update, Security-only | `remote_kernel_status`, `remote_kernel_repin`, `remote_kernel_unpin`, `remote_kernel_update`, `remote_non_kernel_update` |
| WiFi/Driver | (submenu via remote.sh functions) | Various WiFi diagnostic functions |
| Storage | Disk usage, Erase macOS | `remote_get_info` (disk_usage), erase workflow |
| APT Sources | Enable/Disable | `remote_toggle_apt_sources(host, "enable"|"disable")` |
| Reboot | Reboot, Boot to macOS | `remote_reboot`, `remote_boot_macos` |

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

## Versioning

- Format: `v0.2.N` where N increments sequentially (v0.2.0, v0.2.1, v0.2.2, ...)
- **Every commit must have a version tag** — no untagged commits on main
- Tags are assigned in chronological order (oldest commit = lowest N)
- Version series MUST stay on v0.2.* — do NOT iterate to v0.3.* or higher without explicit user permission
- When creating a commit, immediately tag it with the next sequential v0.2.N number

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
| `DEPLOY_MODE` | Deployment mode: `local` (run on Mac Pro) or `remote` (SSH control from another machine) |
| `TARGET_HOST` | SSH hostname/IP for Mac Pro's macOS partition (required when DEPLOY_MODE=remote) |
| `REMOTE_SUDO_PASSWORD` | Sudo password for target Mac Pro (only used when DEPLOY_MODE=remote, stored encrypted) |

### Encryption Modes
| Mode | Description |
|------|-------------|
| `plaintext` | Password stored as-is; file must be chmod 600 |
| `aes256` | Password encrypted with `openssl aes-256-cbc -salt` |
| `keychain` | Password retrieved from macOS Keychain via `security find-generic-password` |

### First-Run Prompts
If `deploy.conf` is missing or keys are empty, `prepare-deployment.sh` prompts for:
- Deployment mode (local or remote) — local runs on Mac Pro directly, remote controls via SSH
- Target host (if remote mode) — hostname/IP of Mac Pro's macOS partition
- Remote sudo password (if remote mode) — for elevated operations on target
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

## Kernel Update Process

This section documents the kernel update workflow for the headless Mac Pro with WiFi-only networking. A kernel update that breaks the WiFi driver bricks the machine remotely — this process exists to prevent that outcome.

### The Circular Dependency Problem

```
New kernel installed → DKMS must recompile wl driver for new kernel
     ↑                                        ↓
     └── if wl fails on new kernel boot → NO SSH (no Ethernet) → BRICKED
```

The `broadcom-sta-dkms` package uses DKMS to auto-compile the `wl` WiFi driver when a new kernel is installed. During installation, 6 compatibility patches are applied to `/usr/src/broadcom-sta-6.30.223.271/` to make the driver compile on kernel 6.8+. These patches persist on disk. DKMS will attempt to use them when building for any new kernel.

If the patches don't apply to the new kernel (ABI break, new kernel API changes), the build fails, `wl.ko` is not produced for that kernel, and rebooting into it means no WiFi, no SSH, no recovery.

### Current Safeguards Installed

The autoinstall config locks the system down to prevent accidental kernel updates:

| Layer | File/Command | Effect |
|-------|-------------|--------|
| apt preferences | `/etc/apt/preferences.d/99-pin-kernel` | Blocks all `linux-{image,headers,modules}-*` at priority -1; allows only `6.8.0-100*` at 1001 |
| apt-mark hold | `linux-image-6.8.0-100-generic` etc. | `apt-get upgrade` skips held packages |
| Sources commented out | `/etc/apt/sources.list` | `apt-get update` finds nothing |
| Auto-updates disabled | `apt-daily*` masked, `APT::Periodic::* = 0` | Nothing runs automatically |
| Snap held | `snap refresh --hold=forever` | Snap kernel snaps frozen |

**These must be temporarily removed for the update, then re-applied afterward.**

### The 7-Phase Update Process (remote_kernel_update)

The `remote_kernel_update()` function in `lib/remote.sh` implements a 7-phase interactive process with rollback capability at each step:

| Phase | Action | Can Rollback? |
|-------|--------|---------------|
| 1 | Enable apt package sources | Yes |
| 2 | Remove holds and pinning | Yes |
| 3 | `apt-get update && dist-upgrade` | Partial — kernel installed but not booted |
| 4 | Verify DKMS built wl.ko for new kernel | Yes — if DKMS fails, don't reboot |
| 5 | Configure GRUB fallback (old kernel = default) | Yes |
| 6 | `grub-reboot` into new kernel (one-time) | No after reboot — but power cycle reverts |
| 7 | Re-lock system (holds, preferences, sources) | N/A — final state |

Each phase writes a marker to `/tmp/macpro-kernel-update.env` to track progress. The `_remote_kernel_update_rollback()` function can roll back from any phase.

### ABORT AND ROLLBACK Procedures

**Scenario A: DKMS build failed (before reboot)**

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

echo "ROLLBACK COMPLETE — system remains on working kernel $KVER"
```

**Scenario B: New kernel booted but WiFi doesn't work**

You rebooted and can't SSH in. This is the worst case.

1. **Power cycle the Mac Pro** (pull power — this machine has no IPMI)
2. GRUB is configured with `GRUB_DEFAULT=saved` and `GRUB_SAVEDEFAULT=true` from Phase 5. Since the new kernel was selected via `grub-reboot` (one-time override), the **saved default** is still the old kernel. A normal reboot (not `grub-reboot`) will boot the old kernel.
3. If a simple reboot doesn't work (GRUB saved the new kernel as default because it booted successfully), you'll need:
   - **SSH from macOS side**: If macOS is still on the disk and `bless` was set with `--nextonly`, the firmware may revert to macOS. From macOS, you can re-bless the Ubuntu ESP and use `grub-editenv` or modify GRUB config to default to the old kernel.
   - **Physical access as last resort**: Hold Option at boot → select macOS → fix GRUB from macOS.

**Mitigation**: Before rebooting in Phase 6, verify that `sudo grub-editenv list` shows the old kernel as the saved default. The `grub-reboot` command only overrides for ONE boot; the saved default remains unchanged.

### Agent Mandatory Rules

When an AI agent performs a kernel update on this machine, it MUST follow these rules:

1. **NEVER run `apt-get dist-upgrade` or install a new kernel without following the 7-phase process.**
2. **NEVER reboot without first configuring GRUB fallback** (Phase 5).
3. **NEVER skip Phase 4 verification** — DKMS status MUST show `installed` for the new kernel before rebooting.
4. **NEVER remove the apt preferences, holds, or commented-out sources without immediately re-applying them after the update.**
5. **NEVER assume DKMS auto-build succeeded** — always verify explicitly with `dkms status`.
6. **ALWAYS confirm WiFi works post-reboot before re-locking the system** (Phase 7).
7. **ALWAYS use `grub-reboot` for the first boot into a new kernel** — never set it as the GRUB default until verified working.
8. **If DKMS build fails, ALWAYS enter ABORT AND ROLLBACK immediately** — never attempt to reboot into a kernel without a working `wl.ko`.

### Headless Readiness Verification

The Mac Pro operates without monitor or keyboard (headless). Before and after deployment, verify headless readiness with `verify_headless_readiness` (local) or `remote_headless_verify` (remote via `--operation headless_verify`).

Checks performed (critical = blocks deployment, warning = logged but continues):

| Check | Critical? | Fix |
|-------|-----------|-----|
| SIP disabled | Yes | Boot to Recovery (Option+R) → `csrutil disable` |
| SSH (Remote Login) enabled | Yes | `sudo systemsetup -setremotelogin on` |
| Passwordless sudo | Yes | Add `user ALL=(ALL) NOPASSWD: ALL` to `/etc/sudoers.d/` |
| Screen sharing (ARD) running | Yes | `sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart -activate -configure -access -on -privs -all -users macpro` |
| Sleep disabled | Warning | `sudo pmset -a sleep 0 displaysleep 0 disksleep 0` |
| Wake on LAN (WOMP) enabled | Warning | `sudo pmset -a womp 1` |
| Auto-restart on power loss | Warning | `sudo pmset -a autorestart 1` |
| Firewall enabled | Warning | `sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on` |
| Recovery partition present | Yes | Reinstall macOS or use Internet Recovery |
| No third-party bootloader (rEFInd) | Warning | Mount EFI, remove `EFI/refind/` and `EFI/BOOT/BOOTX64.EFI`, then `bless --mount / --setBoot` |
| SSH authorized_keys present | Warning | `ssh-copy-id` from control machine |

Note: On Mac Pro 2013, boot to Recovery with **Option+R** (not Command+R) — this is a keyboard layout requirement.

### Update Frequency Recommendations

| Update Type | Frequency | Risk |
|-------------|-----------|------|
| Security updates (non-kernel) | Monthly or as needed for critical CVEs | Low — DKMS not involved |
| Kernel update | Only when required by security CVE | Medium-High — requires full process above |
| Full `dist-upgrade` | Quarterly at most | High — likely pulls new kernel |

### Non-Kernel Updates (security_update operation)

For security updates that do NOT touch the kernel, use the `security_update` operation (maps to `remote_non_kernel_update()` in lib/remote.sh):

```bash
sudo ./prepare-deployment.sh --agent --yes --operation security_update --host macpro-linux --json
```

This operation:
1. Temporarily enables APT sources
2. Runs `apt-get upgrade` excluding kernel packages
3. Disables APT sources again

This avoids the kernel entirely while still getting security patches for all other packages.

### Rollback Function Reference

The `_remote_kernel_update_rollback(host, from_phase)` function in `lib/remote.sh` handles rollback from any phase:

- Phase 0-1: Disables apt sources
- Phase 2-3: Re-pins kernel, disables apt sources
- Phase 4: Re-pins kernel, disables apt sources, warns about unverified new kernel
- Phase 5: Resets GRUB default, updates GRUB, re-pins kernel, disables apt sources

The `remote_rollback_status()` function checks `/tmp/macpro-kernel-update.env` to detect incomplete updates and provides recovery instructions.

## macOS Erasure and Full-Disk Expansion

This section documents the process for erasing macOS partitions and expanding Ubuntu to use the full disk. This operation is **irreversible** — once macOS partitions are deleted, they cannot be recovered.

### Overview

The erase operation (managed via the TUI Storage menu) performs these steps:
1. Identifies and deletes all macOS/APFS partitions
2. Expands the Ubuntu root (`/`) partition into the freed space
3. Updates GRUB and removes macOS boot entries
4. Verifies the system still boots and WiFi works

### Danger Summary

| Risk | Consequence | Mitigation |
|------|-------------|------------|
| Deleting the wrong partition | Data loss, unbootable system | Step 1 has explicit partition identification with verification prompts |
| Root partition resize fails | Root filesystem corruption | Step 2 reads current state first, uses `growpart` + `resize2fs` (safe, in-place) |
| GRUB misconfiguration after partition deletion | Unbootable system | Step 3 regenerates GRUB, Step 4 verifies before declaring success |
| Boot-recovery partition accidentally deleted | No fallback | EFI System Partition (ESP) is never touched — it's a separate partition |

### 6-Step Process Overview

**Step 1: Identify Partition Layout**
- Read GPT partition table with `sgdisk -p /dev/sda`
- Classify every partition as macOS or Ubuntu
- **NEVER delete partitions mounted at `/`, `/boot`, or `/boot/efi`**

**Step 2: Delete macOS Partitions**
- Create GPT backup: `sgdisk -b /tmp/gpt-backup-$(date +%Y%m%d%H%M%S).bin /dev/sda`
- Delete macOS partitions one at a time using `sgdisk -d N /dev/sda`
- Re-read partition table after each deletion (partition numbers may shift)

**Step 3: Expand Root Partition**
- Identify root partition: `lsblk -no NAME,MOUNTPOINT /dev/sda | grep ' /$'`
- Verify free space is adjacent: `parted /dev/sda print free`
- Expand partition: `growpart /dev/sda $PART_NUM`
- Resize filesystem: `resize2fs /dev/sda${PART_NUM}`
- Verify: `df -h /`

**Step 4: Update GRUB**
- Remove macOS GRUB entry: `rm -f /etc/grub.d/40_macos`
- Update GRUB: `update-grub`
- Remove macOS EFI entry: `efibootmgr --delete-bootnum --bootnum $MACOS_ENTRY`
- Remove boot-macos script: `rm -f /usr/local/bin/boot-macos`

**Step 5: Verify and Reboot**
- Verify WiFi: `ping -c 3 google.com`
- Verify all filesystems mounted: `df -h / /boot /boot/efi`
- Verify GRUB clean: `grep -i "macos\|apple" /boot/grub/grub.cfg` should return nothing
- Reboot: `sudo reboot`
- After reboot, re-verify SSH, WiFi, and disk space

**Step 6: Optional Swap**
- If root partition was significantly expanded, consider adding swap:
- `sudo fallocate -l 8G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile`
- Add to `/etc/fstab` for persistence

### Partition Classification Rules

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

### Rollback Information

**Once macOS partitions are deleted (Step 2), there is NO rollback.** macOS data is gone. The GPT backup saved in Step 2 only restores the partition table entries, not the data.

The only reversible step is the partition expansion — if `growpart` fails before `resize2fs`, the partition table can be restored from the GPT backup:

```bash
# EMERGENCY ONLY: Restore GPT from backup
sudo sgdisk -l /tmp/gpt-backup-*.bin /dev/sda
sudo reboot
```

**Agent instruction: If Step 2 has been executed (partitions deleted), there is no undo. Proceed with Steps 3-5. If Step 2 has NOT been executed yet, the operation can be safely cancelled.**

### Agent Prompt Template

When delegating macOS erasure to an agent, use this condensed prompt:

```
You are erasing macOS on a headless Mac Pro 2013 running Ubuntu 24.04 via SSH. This machine has ZERO physical access and WiFi-only networking via a proprietary Broadcom BCM4360 wl driver.

Execute the 6-step process from AGENTS.md (macOS Erasure section):

1. Identify: Read partition table with sgdisk -p /dev/sda. Classify EVERY partition as macOS or Ubuntu. Output your classification for confirmation.
2. Delete: Create GPT backup first. Delete macOS partitions ONE AT A TIME. Re-read partition table after each deletion (numbers shift).
3. Expand: Verify free space is ADJACENT to root partition. Use growpart then resize2fs.
4. GRUB: Remove 40_macos, update-grub, remove macOS EFI entry, remove boot-macos script.
5. Verify: Check WiFi (ping), filesystems (df), GRUB clean (grep). Then reboot.
6. Swap: Optional — add swapfile if desired.

CRITICAL:
- NEVER delete partitions mounted at /, /boot, or /boot/efi
- NEVER delete the EFI System Partition
- If growpart reports free space not adjacent, STOP and ask user
- After Step 2 executes, there is NO ROLLBACK — proceed to completion
```

## Agent Operations Reference

The following operations are available in agent mode via `--operation OP`:

| Operation | Maps to Function | Description | Destructive? |
|-----------|-----------------|-------------|-------------|
| `sysinfo` | `remote_get_info()` | System information (kernel, WiFi, disk, uptime, apt, DKMS) | No |
| `kernel_status` | `remote_kernel_status()` | Kernel version, pin status, held packages, apt preferences | No |
| `kernel_pin` | `remote_kernel_repin()` | Pin current kernel, disable apt sources, enable holds | Yes |
| `kernel_unpin` | `remote_kernel_unpin()` | Unpin kernel, enable apt sources, remove holds | Yes |
| `kernel_update` | `remote_kernel_update()` | Full 7-phase kernel update with rollback | Yes |
| `security_update` | `remote_non_kernel_update()` | Non-kernel security updates only | Yes |
| `health_check` | `remote_health_check()` | Comprehensive health check (SSH, WiFi, disk, DKMS, kernel) | No |
| `disk_usage` | `remote_get_info()` | Same as sysinfo (includes disk info) | No |
| `rollback_status` | `remote_rollback_status()` | Check for incomplete kernel update | No |
| `reboot` | `remote_reboot()` | Reboot remote system with health check after | Yes |
| `boot_macos` | `remote_boot_macos()` | Set next boot to macOS and reboot | Yes |
| `driver_status` | `remote_driver_status()` | WiFi/DKMS driver status check | No |
| `driver_rebuild` | `remote_driver_rebuild()` | Rebuild DKMS WiFi driver module | Yes |
| `erase_macos` | `remote_erase_macos()` | Delete macOS partitions, expand Ubuntu to full disk | Yes |
| `apt_enable` | `remote_apt_enable()` | Enable APT package sources (use kernel_unpin instead) | Yes |
| `apt_disable` | `remote_apt_disable()` | Disable APT package sources (use kernel_pin instead) | Yes |
| `headless_verify` | `remote_headless_verify()` | Verify macOS headless readiness (SSH, SIP, sleep, Recovery, etc.) | No |

**Note**: The `driver_status`, `driver_rebuild`, `erase_macos`, `apt_enable`, and `apt_disable` operations exist as implemented functions but have recommended alternatives:
- `driver_status` — `sysinfo` or `health_check` includes DKMS status
- `driver_rebuild` — specialized operation for DKMS rebuild only
- `erase_macos` — irreversible, use with extreme caution
- `apt_enable` / `apt_disable` — `kernel_pin`/`kernel_unpin` are preferred as they manage the full lock/unlock workflow

The `remote_toggle_apt_sources(host, action)` function (line 234 in lib/remote.sh) takes "enable" or "disable" as the action parameter and is used internally by the kernel pin/unpin functions.

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
- **macOS erasure is irreversible** — once macOS partitions are deleted, they cannot be recovered; the GPT backup only restores partition table entries, not data
- **macOS Recovery MUST be preserved** — `check_recovery_health()` runs before deployment (in `analyze_disk_layout`), after APFS resize (in `shrink_apfs_if_needed`), and after bless (in `_phase_verify_bless`). If Recovery is missing/unhealthy, deployment is blocked. `generate_dualboot_storage` verifies the APFS container partition (GUID `7c3457ef-0000-11aa-aa11-00306543ecac`) is in the preserve list — without it, the installer destroys Recovery. `diskutil apfs resizeContainer` can corrupt APFS volume metadata that the firmware uses to discover Recovery — the post-resize check catches this.

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
