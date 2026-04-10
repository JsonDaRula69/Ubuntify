# Mac Pro 2013 Ubuntu Autoinstall - AGENTS.md

## Project Overview

Automated Ubuntu 24.04.4 LTS Server installer for headless Mac Pro 2013 (MacPro6,1) with Broadcom BCM4360 WiFi. Uses minimal ISO modification — only `autoinstall.yaml` and a `packages/` directory of required debs are injected into the stock Ubuntu ISO.

## Project Structure

```
/Users/djtchill/Desktop/Mac/
├── autoinstall.yaml                 # Autoinstall configuration (added to ISO at /)
├── build-iso.sh                     # ISO builder (xorriso)
├── packages/                        # .deb files for driver compilation (~36 debs, ~75MB)
│   ├── broadcom-sta-dkms_*.deb      # Broadcom WiFi driver source
│   ├── dkms_*.deb                   # Dynamic Kernel Module Support
│   ├── linux-headers-6.8.0-100*     # Kernel headers matching ISO kernel
│   ├── gcc-13_*, make_*, etc.       # Build toolchain
│   └── ...
├── README.md                        # Documentation
├── macpro-monitor/                  # Node.js webhook monitor
│   ├── server.js
│   ├── start.sh / stop.sh / reset.sh
│   └── logs/
└── prereqs/                         # Stock Ubuntu ISO (gitignored)
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

1. **Minimal ISO modification**: Only `autoinstall.yaml` and `packages/` directory are added via `xorriso -map`. EFI boot structure is preserved with `-boot_image any keep`. No initrd hacking, no kernel swapping, no driver pre-compilation.

2. **Compile during install**: The `early-commands` section installs kernel headers and build tools from `/cdrom/macpro-pkgs/`, then compiles `wl.ko` via DKMS against the running kernel. This avoids kernel version mismatches since compilation happens against the actual booted kernel.

3. **GPU**: AMD FirePro uses built-in `amdgpu` driver. Only `nomodeset amdgpu.si.modeset=0` kernel params needed (set in GRUB at boot time, not baked into ISO).

4. **Network matching**: Uses `match: driver: wl` in netplan to handle variable interface names (wlan0, wlp2s0, etc).

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
- Use `driver: wl` matching, not hardcoded interface names

### JavaScript (Node.js)
```javascript
const PORT = 8080;
const MAX_UPDATES = 100;
function escapeHtml(str) {
    if (!str) return '';
    return String(str).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}
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
- `build-iso.sh` - ISO build script using xorriso
- `.gitignore` - Excludes `prereqs/`, `*.iso`, `ssh-*/`, `.sisyphus/`