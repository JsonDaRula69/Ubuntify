# Mac Pro 2013 Ubuntu Autoinstall - AGENTS.md

## Project Overview

Headless Ubuntu 24.04.4 LTS Server deployment for Mac Pro 2013 (MacPro6,1) with Broadcom BCM4360 WiFi. The machine is only accessible via SSH — zero physical access (no keyboard, monitor, or mouse). Cannot disable macOS SIP to install custom bootloader. The deployment must repartition the internal disk remotely, extract the installer to an EFI System Partition, use `bless` to set boot device, and reboot into an automated autoinstall.

## Hardware Specifications

- **Model**: Mac Pro 2013 (MacPro6,1)
- **Current OS**: macOS 12.7.6 (Monterey)
- **Access**: SSH only — zero physical access
- **GPU**: AMD FirePro D300/D500/D700 (amdgpu, needs `nomodeset amdgpu.si.modeset=0`)
- **WiFi**: Broadcom BCM4360 (proprietary `wl` driver, NOT in Ubuntu)
- **Storage**: Apple PCIe SSD via AHCI → `/dev/sda` (not NVMe)
- **No Ethernet port** — WiFi is the only network path
- **Cannot disable SIP** — stuck with Apple's default bootloader
- **MacBook available on network** — can serve as monitoring endpoint and fallback

## Project Structure

```
/Users/djtchill/Desktop/Mac/
├── autoinstall.yaml                 # Autoinstall configuration (added to ISO at /)
├── build-iso.sh                     # ISO builder (xorriso extract-and-repack) — injects config, cidata, GRUB, packages
├── prepare-headless-deploy.sh       # macOS-side script: repartition + extract + bless + verify via SSH
├── packages/                        # .deb files for driver compilation (~36 debs, ~75MB)
│   ├── broadcom-sta-dkms_*.deb      # Broadcom WiFi driver source
│   ├── dkms_*.deb                   # Dynamic Kernel Module Support
│   ├── linux-headers-6.8.0-100*     # Kernel headers matching ISO kernel (6.8.0-100-generic)
│   ├── gcc-13_*, make_*, etc.       # Build toolchain
│   └── ...
├── README.md                        # Documentation
├── macpro-monitor/                  # Node.js webhook monitor
│   ├── server.js
│   ├── start.sh / stop.sh / reset.sh
│   └── logs/
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

## Core Design Decisions

1. **Extract-and-repack ISO modification**: The original ISO is extracted to a staging directory, custom files are overlaid, and the ISO is rebuilt using boot parameters preserved via `xorriso -report_el_torito as_mkisofs`. This properly preserves Ubuntu 24.04's appended EFI partition image and MBR hybrid boot structure. Added files: `autoinstall.yaml`, `cidata/`, `macpro-pkgs/`, and pre-baked GRUB configs. Volume label set to `cidata` for NoCloud discovery.

2. **Compile during install**: The `early-commands` section dynamically detects the running kernel (`KVER="$(uname -r)"`), validates that matching headers exist, then installs kernel headers and build tools from `/cdrom/macpro-pkgs/`, and compiles `wl.ko` via DKMS against the running kernel. The `late-commands` section repeats this in a 4-stage `dpkg --root /target` install to ensure the driver persists in the target system. Critical errors (missing headers, driver load failure) now `exit 1` to abort rather than silently continue.

3. **GPU**: AMD FirePro uses built-in `amdgpu` driver. Only `nomodeset amdgpu.si.modeset=0` kernel params needed — pre-baked in GRUB config, not entered manually.

4. **Network matching**: Uses `wl0` interface ID with `match: driver: wl` in netplan. The late-commands generates netplan config using `printf` (not heredoc — indentation inside `|` blocks adds unwanted spaces).

5. **Storage**: Mac Pro 2013 uses Apple PCIe SSDs via AHCI (not NVMe), so internal disk is `/dev/sda`.

6. **Remote boot via `bless`**: For zero-physical-access deployment, use `bless --setBoot --mount <esp> --nextonly` from macOS SSH. The `--nextonly` flag ensures the boot device reverts to macOS if the installer fails. GRUB parameters are pre-baked in `EFI/boot/grub.cfg` — no manual keyboard input needed.

7. **SSH into installer**: `early-commands` starts `sshd` after WiFi driver compilation for remote debugging during installation. Falls back to installing from ISO pool (`/cdrom/pool/restricted/o/openssh/`) if network apt fails. The `ssh: install-server: true` config only applies to the target system.

8. **NoCloud datasource**: The ISO includes `/cidata/user-data`, `/cidata/meta-data`, and `/cidata/vendor-data` for `ds=nocloud` discovery. Volume label `cidata` also enables discovery. Kernel param `autoinstall` bypasses the confirmation prompt for zero-touch deployment.

9. **Autoinstall config discovery**: `/autoinstall.yaml` at ISO root is found regardless of NoCloud labeling. The volume label `cidata` provides an additional discovery path.

10. **Headless deploy safety**: `prepare-headless-deploy.sh` uses before/after partition diffing (not `tail -1`) to safely identify the newly created ESP. APFS snapshots are auto-deleted for headless operation. Bless is verified with `--info`. Non-interactive reboot with 5-second delay when piped via SSH.

11. **Monitoring and progress reporting**: The `macpro-monitor` server receives two event streams. Subiquity/Curtin built-in events are sent via the `reporting.macpro-monitor` webhook at DEBUG level (captures all events including DEBUG-level network/storage details). Custom progress events are sent via `curl` calls in early-commands and late-commands with `{progress, stage, status, message}` payloads — these track WiFi driver compilation, SSH startup, DKMS build, netplan config, GRUB setup, etc. The dashboard displays 3 panes: Subiquity events, custom progress, and status summary. All webhook events are logged to the server console for terminal debugging.

## Boot Methods

| Method | Physical Access? | Status |
|--------|-----------------|--------|
| USB + auto GRUB | Required (keyboard to hold Option) | Implemented (build-iso.sh) |
| Internal disk + `bless` via SSH | None required | Implemented (prepare-headless-deploy.sh) |
| NetBoot from MacBook | None required | Not feasible (requires macOS Server + BSDP) |
| Target Disk Mode | Brief physical | Fallback only |

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

### JavaScript (Node.js)
```javascript
const PORT = 8080;
const MAX_UPDATES = 200;
const MAX_BUILT_IN_EVENTS = 500;
const MAX_DISPLAY_EVENTS = 50;
```

## Error Handling

| Language | Guidelines |
|----------|------------|
| Bash | `set -e` at start; `|| true` only when failure acceptable |
| Node.js | Validate inputs; handle HTTP errors gracefully |

## Naming Conventions

| Language | Variable | Function | Class | Constant |
|----------|----------|----------|-------|----------|
| Bash | `snake_case` | `snake_case()` | N/A | `UPPER_SNAKE` |
| JavaScript | `camelCase` | `camelCase()` | `PascalCase` | `UPPER_SNAKE` |

**Files:** `snake_case.sh`, `snake_case.js`

## Important Files

- `autoinstall.yaml` - The core autoinstall configuration (added to ISO at /)
- `packages/` - .deb files for driver compilation (added to ISO at /macpro-pkgs/)
- `build-iso.sh` - ISO build script using xorriso extract-and-repack (injects config, cidata, GRUB, packages)
- `prepare-headless-deploy.sh` - macOS-side script for zero-physical-access deployment via bless
- `prereqs/` - Stock Ubuntu ISO directory (only `*.iso` files, gitignored)
- `macpro-monitor/` - Node.js webhook monitor for installation progress (3-pane dashboard: Subiquity Events | Custom Progress | Status)
- `.gitignore` - Excludes `*.iso`, `*.qcow2`, `ssh-*/`, `.sisyphus/`, `.DS_Store`

## Key Constraints

- **Zero physical access** — all operations must be performed remotely via SSH
- **Cannot disable SIP** — cannot install custom bootloader; must use Apple's `bless` command
- **WiFi-only networking** — no Ethernet; must compile `wl` driver before any network access
- **Kernel version dynamically detected** — `KVER="$(uname -r)"` in early-commands and late-commands; `packages/` must contain headers matching the ISO's kernel (currently 6.8.0-100-generic)
- **DKMS cross-kernel build**: `dkms build -k <version>` compiles against the specified kernel's headers, not the running kernel
- **`dpkg --root /target`** packages must be installed in dependency order (Stage 1: headers → Stage 2: libs → Stage 3: tools → Stage 4: dkms)
- **Netplan interface keys** must be actual names or logical IDs (not `wifi-iface`)
- **No `dd` ISO to partition** — Mac EFI expects FAT32 ESP with `/EFI/BOOT/BOOTX64.EFI`, not ISO9660
- **GRUB parameters must be pre-baked** — no manual keyboard input available during boot
- **Risk of unrecoverable state** — if installer fails, no physical access to recover; mitigations: `bless --nextonly` reverts to macOS, webhook monitoring with progress percentages, SSH into installer, VirtualBox testing first

## Context Management Rules

When working on this project, ALL agents (build, Sisyphus-Junior, exploration agents, etc.) MUST follow these rules:

### Memory (Cross-Session)
- **After completing significant work**, save key findings, decisions, and file locations to `ctx_memory` using categories: `ENVIRONMENT`, `CONSTRAINTS`, `WORKFLOW_RULES`, `ARCHITECTURE`
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