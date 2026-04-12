# VM Adaptation Guide: Production → VirtualBox Test

This document specifies every change required to transform the **production** Mac Pro 2013 autoinstall scripts into a **VirtualBox VM test** variant. The goal is **maximum test coverage** — exercising as much of the production pipeline as possible while making only the minimal changes necessitated by the VM environment's differences from real hardware.

An AI agent should be able to take the production `build-iso.sh` and `autoinstall.yaml` as inputs, apply the changes described below, and produce working VM test equivalents with zero additional context.

---

## Guiding Principle

> **Emulate production constraints as closely as possible.** The Mac Pro has no internet — period. The VM must use the exact same offline `dpkg` pipeline from `macpro-pkgs/` for ALL package installation. `apt-get` is **completely banned** in both early-commands and late-commands. Every package the installer or target system needs must be bundled on the ISO. The only network the VM uses is Subiquity's network config step (Ethernet) and the webhook — no package installation via `apt-get` at any point.
>
> **Compile everything, load nothing fatally.** DKMS must build and install — that's the primary test. But `modprobe wl` and WiFi interface detection are non-fatal because the VM has no Broadcom hardware. Network connectivity uses Ethernet as a **fallback** only for Subiquity's network step and webhook reporting — never for package installation.

---

## Network Isolation Principle

The Mac Pro 2013 has **no internet** — not before the driver loads, not after. Every package must come from the ISO. `apt-get` is **completely banned** in the autoinstall config.

### ❌ `apt-get` is BANNED — Complete Prohibition

Every `apt-get` call in the autoinstall config must be replaced with the offline equivalent:

| Production `apt-get` Call | Replacement |
|---|---|
| `apt-get -y install openssh-server` (early-commands) | `dpkg --force-depends -i /cdrom/pool/restricted/o/openssh/openssh-server_*.deb /cdrom/pool/restricted/o/openssh/openssh-sftp-server_*.deb` (ISO pool fallback — production already does this as fallback) |
| `chroot /target apt-get -y install ufw` (late-commands) | Include `ufw` `.deb` and dependencies in `packages/` and install via `dpkg --root /target --force-depends --skip-same-version -i` |
| `apt-get update` / `apt-get install gcc-13 make patch ...` (VM early-commands) | **REMOVE** — use offline `dpkg -i` from `macpro-pkgs/` exactly like production |
| `chroot /target apt-get install gcc-13 make patch ...` (VM late-commands) | **REMOVE** — use 4-stage `dpkg --root /target` exactly like production |

### How Production Handles openssh-server

Production uses `apt-get` as **primary** with ISO pool `.deb` as **fallback**:
```sh
apt-get -y install openssh-server 2>>"$LOG" || dpkg --force-depends -i /cdrom/pool/restricted/o/openssh/openssh-server_*.deb /cdrom/pool/restricted/o/openssh/openssh-sftp-server_*.deb 2>>"$LOG" || true
```

Since `apt-get` is banned, the VM should use **only** the ISO pool fallback:
```sh
dpkg --force-depends -i /cdrom/pool/restricted/o/openssh/openssh-server_*.deb /cdrom/pool/restricted/o/openssh/openssh-sftp-server_*.deb 2>>"$LOG" || true
```

This is the same as production's fallback path, just without the `apt-get` primary.

### How Production Handles ufw

Production installs ufw via the `packages:` section in the autoinstall YAML AND via `chroot /target apt-get -y install ufw` in late-commands. Since `apt-get` is banned, ufw must be:

1. Kept in the `packages:` section (installed by Subiquity from the ISO's pool)
2. The `chroot /target apt-get -y install ufw` in late-commands should be removed — the `packages:` section already handles it

If the ISO's pool doesn't include `ufw`, it must be added to `packages/` and installed via `dpkg --root /target`.

### Test Coverage Benefit

By banning `apt-get` entirely, the VM validates that:
- `packages/` contains every `.deb` needed for the offline toolchain
- The ISO's pool contains `openssh-server` and `ufw`
- Dependency ordering is correct for `dpkg --force-depends --skip-same-version`
- No missing dependencies that `apt-get` would silently resolve

If any dependency is missing, the VM catches it — exactly as production would fail on the Mac Pro.

| Production File | VM Test File | Relationship |
|---|---|---|
| `build-iso.sh` | `vm-test/build-iso-vm.sh` | Same structure, different paths and GRUB config |
| `autoinstall.yaml` | `vm-test/autoinstall-vm.yaml` | Same skeleton, adapted for VM environment |
| (N/A) | `vm-test/create-vm.sh` | New — VirtualBox VM creation |
| (N/A) | `vm-test/test-vm.sh` | New — VM run/monitor/SSH/stop utility |

---

## 1. `build-iso.sh` → `build-iso-vm.sh` Changes

### 1.1 Path Variables

| Variable | Production | VM | Reason |
|---|---|---|---|
| `SCRIPT_DIR` | `$(dirname "$0")` | Same | — |
| `PROJECT_DIR` | (not present) | `$(dirname "$SCRIPT_DIR")` | VM script lives in `vm-test/` subdirectory; needs parent to find `packages/` and `prereqs/` |
| `BASE_ISO` | `$SCRIPT_DIR/prereqs/...` | `$PROJECT_DIR/prereqs/...` | ISO is in project root, not vm-test/ |
| `AUTOINSTALL` | `$SCRIPT_DIR/autoinstall.yaml` | `$SCRIPT_DIR/autoinstall-vm.yaml` | VM-specific autoinstall config |
| `PKGS_DIR` | `$SCRIPT_DIR/packages` | `$PROJECT_DIR/packages` | Packages are in project root |
| `OUTPUT_ISO` | `$SCRIPT_DIR/ubuntu-macpro.iso` | `$SCRIPT_DIR/ubuntu-vmtest.iso` | Different output name to avoid clobbering production ISO |
| `STAGING` | `/tmp/macpro-iso-staging` | `/tmp/vmtest-iso-staging` | Avoid staging collision with production build |

**No other variable changes.** Color constants, flags, and validation logic remain identical.

### 1.2 GRUB Configuration

**Production GRUB:**
```
menuentry "Ubuntu Server 24.04 Autoinstall (Mac Pro 2013)" {
    set gfxpayload=keep
    linux /casper/vmlinuz autoinstall ds=nocloud nomodeset amdgpu.si.modeset=0 ---
    initrd /casper/initrd
}
```

**VM GRUB — two changes:**
1. Menu label: `"Ubuntu Server 24.04 VM Test Autoinstall"` (cosmetic, identifies the test ISO)
2. Kernel parameters: add `console=ttyS0,115200` and **remove** `nomodeset amdgpu.si.modeset=0`

```
menuentry "Ubuntu Server 24.04 VM Test Autoinstall" {
    set gfxpayload=keep
    linux /casper/vmlinuz autoinstall ds=nocloud console=ttyS0,115200 ---
    initrd /casper/initrd
}
```

**Why these changes:**
- `console=ttyS0,115200` — Redirects all kernel output, init system logs, and shell `set -x` traces to the VirtualBox serial port (UART1). This is the **primary visibility mechanism** for the headless VM. Without it, early boot failures are invisible.
- Remove `nomodeset amdgpu.si.modeset=0` — The VM uses VMSVGA (VirtualBox graphics), not AMD FirePro. These params are harmless but unnecessary. Removing them confirms the VM config is for VirtualBox, not Mac Pro.

**Apply the same two changes to the "Manual Install" menu entry.**

### 1.3 cidata `meta-data`

**Production:** `instance-id: macpro-linux-i1`
**VM:** `instance-id: vmtest-i1`

Cosmetic only — differentiates NoCloud instances.

### 1.4 Everything Else

The following are **unchanged** between production and VM:
- ISO extraction step (`xorriso -osirrox on`)
- `chmod -R u+w` on extracted files
- Package copying (`*.deb` from `packages/` → `macpro-pkgs/`)
- DKMS patches copying (identical logic, same source directory)
- Boot parameter extraction (`xorriso -report_el_torito as_mkisofs`)
- ISO rebuild (`xorriso -as mkisofs` with `BOOT_ARRAY` and `-V "cidata"`)
- Verification step
- Volume label (`cidata`)

---

## 2. `autoinstall.yaml` → `autoinstall-vm.yaml` Changes

This is the largest diff. Changes are organized by YAML section.

### 2.1 `identity` Section

| Field | Production | VM | Reason |
|---|---|---|---|
| `hostname` | `macpro-linux` | `vmtest` | Differentiates the VM from production |
| `password` | (hashed, specific) | (different hash) | Uses `teja:teja` for easy VM SSH access |

**The `username` and `realname` remain `teja` / `Teja`** — consistent with production for test fidelity.

### 2.2 `reporting` Section

| Field | Production | VM | Reason |
|---|---|---|---|
| `endpoint` | `http://192.168.1.115:8080/webhook` | `http://10.0.2.2:8081/webhook` | VirtualBox NAT: `10.0.2.2` is the host gateway; port `8081` maps to host `8080` via NAT port forwarding |

### 2.3 `early-commands` — Changes

#### 2.3.1 Remove Disk Validation (Production-only)

**Remove entirely:**
```yaml
# Production-only — removed in VM:
if [ ! -e /dev/sda ]; then ... exit 1; fi
INTERNAL_COUNT=$(lsblk ...) ...
if lsblk -o FSTYPE /dev/sda ... grep -q apfs; then ...
```

**Reason:** The VM has a single blank VDI disk, no APFS, no dual-boot. The `/dev/sda` existence check, multi-disk warning, and APFS detection are Mac Pro-specific.

#### 2.3.2 Add Serial Log Dumping

**Added at the top of early-commands (after LOG/WHURL definitions):**
```sh
_dump_log() { cat "$LOG" > /dev/console 2>/dev/null; }
trap '_dump_log' EXIT
```

**Reason:** When the shell exits (success or failure), the entire log is dumped to `/dev/console`, which is connected to the VirtualBox serial port (`console=ttyS0,115200`). This ensures the full log is visible even if installation fails partway through and SSH is unavailable.

**Production does NOT have this** — production relies on SSH and webhook for visibility; the serial port doesn't exist on Mac Pro.

#### 2.3.3 Log Header

**Production:** `"=== MAC PRO 2013 AUTOINSTALL ==="`
**VM:** `"=== VM TEST AUTOINSTALL ==="`

Cosmetic — identifies which environment generated the log.

#### 2.3.4 Build Toolchain Installation Method — USE PRODUCTION OFFLINE PIPELINE

**⭐ CRITICAL: The VM MUST use the exact same offline `dpkg -i` pipeline as production.**

The Mac Pro has zero internet until the `wl` driver loads — the entire toolchain must be installed from the offline `.deb` packages on the ISO. The VM has Ethernet available from boot, but **must pretend it doesn't** to exercise the production code path. This is the whole point of the VM test: validating that the offline package staging, dependency ordering, and `--skip-same-version` logic actually works.

**Production AND VM (identical):** Offline `dpkg -i` from `macpro-pkgs/`
```sh
# Kernel headers (same in both)
dpkg --force-depends --skip-same-version -i $PKGS/linux-headers-${ABI_VER}_*.deb \
        $PKGS/linux-headers-${KVER}_*.deb \
        $PKGS/linux-libc-dev_*.deb 2>>"$LOG" || { echo "[early] FATAL: kernel headers failed" >> "$LOG"; exit 1; }

# Build toolchain (same in both — all from macpro-pkgs/)
dpkg --force-depends --skip-same-version -i $PKGS/binutils-common_*.deb $PKGS/libbinutils_*.deb \
        $PKGS/libctf-nobfd0_*.deb $PKGS/libctf0_*.deb \
        $PKGS/libsframe1_*.deb $PKGS/libgprofng0_*.deb \
        $PKGS/binutils_*.deb $PKGS/binutils-x86-64-linux-gnu_*.deb \
        $PKGS/libgcc-s1_*.deb $PKGS/gcc-13-base_*.deb \
        $PKGS/libisl23_*.deb $PKGS/libmpc3_*.deb $PKGS/libmpfr6_*.deb \
        $PKGS/libgcc-13-dev_*.deb $PKGS/cpp-13_*.deb \
        $PKGS/gcc-13-x86-64-linux-gnu_*.deb $PKGS/gcc-13_*.deb \
        $PKGS/libstdc++6_*.deb $PKGS/libstdc++-13-dev_*.deb \
        $PKGS/libc-dev-bin_*.deb $PKGS/libc6-dev_*.deb \
        $PKGS/libc-devtools_*.deb $PKGS/libcrypt-dev_*.deb \
        $PKGS/rpcsvc-proto_*.deb \
        $PKGS/make_*.deb $PKGS/build-essential_*.deb \
        $PKGS/fakeroot_*.deb $PKGS/libfakeroot_*.deb \
        $PKGS/patch_*.deb 2>>"$LOG" || { echo "[early] FATAL: build toolchain failed" >> "$LOG"; exit 1; }

# cc symlink (same in both)
ln -sf /usr/bin/x86_64-linux-gnu-gcc-13 /usr/bin/cc 2>/dev/null || ln -sf /usr/bin/gcc-13 /usr/bin/cc 2>/dev/null || true
```

**❌ `apt-get` is completely banned in the VM autoinstall config.** The current `autoinstall-vm.yaml` uses `apt-get install gcc-13 make patch linux-headers-${KVER}` — this must be replaced with the production offline `dpkg -i` pipeline because:
1. The Mac Pro has no internet — `apt-get` wouldn't work in production
2. It skips testing the offline `dpkg` dependency ordering and `--skip-same-version` logic
3. It doesn't validate that `packages/` contains all required `.deb` files
4. It doesn't test the `cc` symlink creation with `x86_64-linux-gnu-gcc-13` fallback

**The only SSH server installation method is the ISO pool `.deb` fallback** (production's secondary path, used without the `apt-get` primary):
```sh
dpkg --force-depends -i /cdrom/pool/restricted/o/openssh/openssh-server_*.deb /cdrom/pool/restricted/o/openssh/openssh-sftp-server_*.deb 2>>"$LOG" || true
```

**The only UFW installation method is the `packages:` YAML section** (installed by Subiquity from the ISO pool). The `chroot /target apt-get -y install ufw` late-command must be removed.

#### 2.3.5 `modprobe wl` — Non-Fatal

**Production (FATAL):**
```sh
modprobe wl 2>>"$LOG" || echo "[early] ERROR: modprobe wl failed" >> "$LOG"
sleep 5
if ! lsmod | grep -q wl; then
  # ... retry logic ...
  if lsmod | grep -q wl; then
    echo "[early] SUCCESS: wl module loaded" >> "$LOG"
  else
    echo "[early] FATAL: wl module not in lsmod" >> "$LOG"
    exit 1
  fi
fi
```

**VM (NON-FATAL):**
```sh
# Keep the same retry structure as production — just make final verdict non-fatal
modprobe wl 2>>"$LOG" || echo "[early] WARN: modprobe wl failed (expected in VM — no Broadcom hardware)" >> "$LOG"
sleep 5
if ! lsmod | grep -q wl; then
  echo "[early] WARN: wl not loaded, retrying after forcing conflicting drivers off..." >> "$LOG"
  for drv in b43 ssb bcma brcmsmac wl; do rmmod $drv 2>/dev/null || true; done
  modprobe wl 2>>"$LOG" || echo "[early] WARN: modprobe wl retry failed (expected in VM)" >> "$LOG"
  sleep 5
fi
if lsmod | grep -q wl; then
  echo "[early] SUCCESS: wl module loaded" >> "$LOG"
  curl -s -X POST "$WHURL" -H "Content-Type: application/json" -d '{"progress":18,"stage":"prep-wifi","status":"loaded","message":"WiFi driver loaded successfully"}' > /dev/null 2>&1 || true
else
  echo "[early] WARN: wl module not loaded — VM has no Broadcom hardware, skipping WiFi setup" >> "$LOG"
  curl -s -X POST "$WHURL" -H "Content-Type: application/json" -d '{"progress":18,"stage":"prep-wifi","status":"skipped","message":"VM: wl module not loaded (no Broadcom HW)"}' > /dev/null 2>&1 || true
fi
```

**Changes from production:**
- `modprobe wl` failure uses `|| echo WARN` instead of `|| echo ERROR`, and the initial attempt is non-fatal
- The retry logic is **preserved** (same `rmmod` + `modprobe` pattern) — it's harmless in the VM and tests the production path
- The final `lsmod` check: WARN instead of FATAL `exit 1`
- **The only real difference: no `exit 1` if driver doesn't load**

#### 2.3.6 WiFi Interface Detection — Same Timeout, Non-Fatal Verdict

**Production:** 60-second timeout, FATAL if no interface
```sh
for i in $(seq 1 60); do
  WIFI_IFACE=$(ip link show 2>/dev/null | grep -oE 'wl[pw][^:]+' | head -1)
  [ -n "$WIFI_IFACE" ] && break
  # ... more patterns ...
  sleep 1
done
if [ -z "$WIFI_IFACE" ]; then
  echo "[early] FATAL: No WiFi interface detected after 60s" >> "$LOG"
  exit 1
fi
```

**VM:** Same 60-second timeout, WARN if no interface
```sh
for i in $(seq 1 60); do
  WIFI_IFACE=$(ip link show 2>/dev/null | grep -oE 'wl[pw][^:]+' | head -1)
  [ -n "$WIFI_IFACE" ] && break
  # ... same patterns ...
  sleep 1
done
if [ -n "$WIFI_IFACE" ]; then
  echo "[early] WiFi interface detected: $WIFI_IFACE" >> "$LOG"
else
  echo "[early] WARN: No WiFi interface — VM test mode, using Ethernet" >> "$LOG"
fi
```

**Changes:**
- Timeout stays at **60 seconds** (same as production — exercises the full detection loop)
- Missing interface: WARN, not FATAL

**Current VM shortens to 10s — this should be changed back to 60s** to test the full production detection timeout logic.

#### 2.3.7 Remove WiFi Association/DHCP/Connectivity Checks

**Production has three WiFi verification steps — ALL removed in VM:**

1. **WiFi association check** (30s ESSID scan) — Removed. No WiFi interface to check.
2. **DHCP lease check** (30s `ip addr show` for `inet `) — Removed. No WiFi interface.
3. **Network connectivity circuit breaker** (60s curl to webhook, with reconnect retry) — Replaced with a single success webhook:

```sh
curl -s -X POST "$WHURL" -H "Content-Type: application/json" -d '{"progress":28,"stage":"prep-netcheck","status":"verified","message":"VM test setup complete"}' > /dev/null 2>&1 || true
```

**Reason:** The VM uses Ethernet. WiFi connectivity verification is irrelevant. The circuit breaker (which prevents storage from running without WiFi) would incorrectly block VM installation.

#### 2.3.8 Conflicting Driver Blacklist + rmmod — KEEP (Harmless, Tests Production Path)

**Production:**
```sh
for drv in b43 ssb bcma brcmsmac; do
    echo "blacklist $drv" >> /etc/modprobe.d/blacklist-bcm.conf
done
rmmod b43 ssb bcma brcmsmac 2>/dev/null || true
```

**VM:** **Keep identical to production.**

**Reason:** The `rmmod` will silently do nothing in the VM (those modules aren't loaded), and the blacklist file is harmless. Keeping this code path identical to production maximizes test coverage — if the blacklist logic ever needs to change, the VM will exercise the same change.

**Current VM incorrectly removes this.** An AI agent should **preserve it identically to production.**

#### 2.3.9 SSH Server — Use ISO Pool Only (No apt-get)

**Production:** `apt-get -y install openssh-server` with ISO pool `.deb` fallback.

**VM:** **Use only the ISO pool fallback path** — `apt-get` is banned:
```sh
dpkg --force-depends -i /cdrom/pool/restricted/o/openssh/openssh-server_*.deb /cdrom/pool/restricted/o/openssh/openssh-sftp-server_*.deb 2>>"$LOG" || true
```

This is production's fallback path, used without the `apt-get` primary. Keep the rest: `useradd`, `chpasswd`, authorized keys, SSH keys from inline strings.

#### 2.3.10 DKMS Patch Series Parsing — Use Production Pattern

**Production:** Uses `grep -v '^\s*$\|^\s*#'` to skip blank lines and comments in the series file.

**VM:** **Use the same `grep -v` pattern as production.**

```sh
# Use production pattern — more robust
for _p in $(grep -v '^\s*$\|^\s*#' "$PKGS/dkms-patches/series"); do
```

**Reason:** The current VM uses `cat` which doesn't skip comments or blank lines. While the production `series` file currently has none, using `grep -v` is the defensive pattern that both environments should use identically. An AI agent MUST use the production `grep -v` pattern.

#### 2.3.11 DKMS Build — Enhanced Logging

**VM adds after `dkms build`:**
```sh
_dkms_rc=$?
echo "[early] dkms build exit code: $_dkms_rc" >> "$LOG"
for _make_log in \
  /var/lib/dkms/broadcom-sta/6.30.223.271/$KVER/x86_64/make.log \
  /var/lib/dkms/broadcom-sta/6.30.223.271/build/make.log; do
  if [ -f "$_make_log" ]; then
    echo "=== DKMS make.log ($_make_log) ===" >> "$LOG"
    cat "$_make_log" >> "$LOG"
    cat "$_make_log" > /dev/console 2>/dev/null
  fi
done
if [ "$_dkms_rc" -ne 0 ]; then
  echo "=== DKMS BUILD FAILED — dumping full log ===" >> "$LOG"
  cat "$LOG" > /dev/console 2>/dev/null
  # ... then the retry logic ...
fi
```

**Reason:** If DKMS build fails, the make.log contains the exact compiler errors. Dumping it to `/dev/console` (serial port) ensures it's visible in `vmtest-serial.log` even if SSH never becomes available. Production doesn't need this — SSH and webhook provide equivalent visibility.

**Production does NOT have this enhanced logging.** It's VM-specific for serial visibility.

### 2.4 `network` Section — Complete Replacement

**Production:**
```yaml
network:
  version: 2
  renderer: networkd
  wifis:
    wl0:
      match:
        driver: wl
      dhcp4: true
      optional: true
      access-points:
        "ATTj6pXatS":
          password: "j75b39=z?mpg"
```

**VM:**
```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    enp0s3:
      dhcp4: true
```

**Changes:**
- `wifis: wl0:` → `ethernets: enp0s3:` — VM uses VirtualBox NAT (Intel 82540EM → `enp0s3`)
- No `match:` clause needed — Ethernet device name is predictable
- No `optional: true` — Ethernet connects faster than WiFi
- No SSID/password — Ethernet doesn't need credentials
- `renderer: networkd` preserved

### 2.5 `packages` Section — Keep All Production Packages

**Production:**
```yaml
packages:
  - openssh-server
  - wpasupplicant
  - curl
  - wireless-tools
  - avahi-daemon
  - libnss-mdns
  - efibootmgr
```

**VM:** **Keep identical to production.**

**Reason:** These packages are installed by Subiquity from the ISO's pool, not from the internet. Installing them in the VM validates they're available in the ISO and their dependencies are satisfied. `wpasupplicant` and `wireless-tools` are harmless even without WiFi hardware — they just won't be used. `avahi-daemon` and `libnss-mdns` provide mDNS which can function in a VM (unlike WiFi).

**Current VM incorrectly removes WiFi/mDNS packages.** An AI agent should **keep them all**.

### 2.6 `storage` Section — Simplified

**Production** uses `preserve: true` on the disk for dual-boot:
```yaml
storage:
  config:
    - type: disk
      id: root-disk
      path: /dev/sda
      ptable: gpt
      preserve: true
      wipe: superblock
    # ... partitions ...
```

**VM** — single blank disk, no preservation:
```yaml
storage:
  config:
    - type: disk
      id: root-disk
      path: /dev/sda
      ptable: gpt
      wipe: superblock
    # ... same partition layout ...
```

**Changes:**
- Remove `preserve: true` from disk — VM disk is blank, no macOS to preserve
- Partition layout is **identical** (EFI 512M, /boot 1G, / rest) — tests the same partitioning scheme

### 2.7 `late-commands` — Changes

#### 2.7.1 Add Serial Log Dumping (same as early-commands)

```sh
_dump_log() { cat "$LOG" > /dev/console 2>/dev/null; }
trap '_dump_log' EXIT
```

#### 2.7.2 Remove WiFi Health Check in Late-Commands

**Production** starts late-commands with a WiFi interface health check (reconnect logic, recovery mode if WiFi is lost). **VM removes this entirely** — Ethernet doesn't go down during storage operations.

#### 2.7.3 Toolchain Installation Method — USE PRODUCTION 4-STAGE OFFLINE PIPELINE

**⭐ CRITICAL: The VM MUST use the exact same 4-stage `dpkg --root /target` pipeline as production.**

Production cannot install packages into `/target` via apt-get because the target system has no network until `wl` is configured. The VM has Ethernet, but **must use the same offline pipeline** to validate that all 4 dependency-ordered stages succeed.

**Production AND VM (identical):**
```sh
# Stage 1: Kernel headers (no deps)
dpkg --root /target --force-depends --skip-same-version -i \
  $PKGS/linux-headers-${ABI_VER}_*.deb \
  $PKGS/linux-headers-${KVER}_*.deb \
  $PKGS/linux-libc-dev_*.deb 2>>"$LOG" || { exit 1; }

# Stage 2: Base libraries first, then binaries that depend on them
dpkg --root /target --force-depends --skip-same-version -i \
  $PKGS/binutils-common_*.deb $PKGS/libbinutils_*.deb \
  $PKGS/libctf-nobfd0_*.deb $PKGS/libctf0_*.deb \
  $PKGS/libsframe1_*.deb $PKGS/libgprofng0_*.deb \
  $PKGS/libgcc-s1_*.deb $PKGS/gcc-13-base_*.deb \
  $PKGS/libisl23_*.deb $PKGS/libmpfr6_*.deb $PKGS/libmpc3_*.deb \
  $PKGS/libstdc++6_*.deb $PKGS/libstdc++-13-dev_*.deb \
  $PKGS/libcrypt-dev_*.deb $PKGS/libc-dev-bin_*.deb \
  $PKGS/libc6-dev_*.deb $PKGS/rpcsvc-proto_*.deb \
  $PKGS/libc-devtools_*.deb \
  $PKGS/binutils_*.deb $PKGS/binutils-x86-64-linux-gnu_*.deb \
  $PKGS/libgcc-13-dev_*.deb $PKGS/cpp-13_*.deb \
  $PKGS/gcc-13-x86-64-linux-gnu_*.deb $PKGS/gcc-13_*.deb 2>>"$LOG" || { exit 1; }

# Stage 3: Build tools (depend on stage 2)
dpkg --root /target --force-depends --skip-same-version -i \
  $PKGS/make_*.deb $PKGS/build-essential_*.deb \
  $PKGS/fakeroot_*.deb $PKGS/libfakeroot_*.deb \
  $PKGS/patch_*.deb 2>>"$LOG" || { exit 1; }

# Stage 4: DKMS and driver (depend on stage 3) — same in both
dpkg --root /target --force-depends -i $PKGS/dkms_*.deb $PKGS/broadcom-sta-dkms_*.deb 2>>"$LOG" || echo "[late] WARN: dkms/broadcom dpkg returned non-zero (expected)" >> "$LOG"
```

**❌ `apt-get` is completely banned in late-commands.** The current `autoinstall-vm.yaml` uses:
```sh
cp /etc/resolv.conf /target/etc/resolv.conf 2>/dev/null || true
chroot /target apt-get install -y --no-install-recommends gcc-13 make patch "linux-headers-${KVER}"
```
This must be replaced with the production 4-stage `dpkg --root /target` pipeline because:
1. The Mac Pro has no internet — `apt-get` into `/target` wouldn't work in production
2. It skips the entire 4-stage dependency ordering test
3. It doesn't validate that `packages/` contains everything needed for offline target install
4. It doesn't test `dpkg --root /target --skip-same-version` which handles the live-environment version mismatch
5. The `cp /etc/resolv.conf /target/etc/resolv.conf` step is a networking hack that doesn't exist in production

**What's preserved for test coverage (now with full parity):**
- 4-stage `dpkg --root /target` installation — **identical to production**
- DKMS patch application in chroot — identical
- Bind mounts (`/proc`, `/sys`, `/dev`) — identical
- DKMS build + install in chroot with retry — identical
- `cc` symlink in target — identical

#### 2.7.4 GRUB Configuration — Simplified GPU Params

**Production:**
```sh
echo 'GRUB_CMDLINE_LINUX_DEFAULT="nomodeset amdgpu.si.modeset=0"' >> /target/etc/default/grub.d/macpro.cfg
```

**VM:**
```sh
echo 'GRUB_CMDLINE_LINUX_DEFAULT="nomodeset"' >> /target/etc/default/grub.d/macpro.cfg
```

**Reason:** `amdgpu.si.modeset=0` is Mac Pro FirePro-specific. `nomodeset` is kept because it's a safe default for VMs too.

#### 2.7.5 macOS Boot Entry — Cosmetic Rename

**Production:** `menuentry "Reboot to Apple Boot Manager" { fwsetup }`
**VM:** `menuentry "Reboot to Firmware" { fwsetup }`

**Reason:** The VM doesn't have macOS. `fwsetup` still works — it reboots to VirtualBox's EFI setup. The label is just more honest.

#### 2.7.6 boot-macos Helper Script — Removed

**Production** creates `/target/usr/local/bin/boot-macos` with `efibootmgr` logic to find and set the macOS boot entry.

**VM** omits this entirely — there's no macOS to switch to.

#### 2.7.7 Netplan Configuration — Dual Config

**Production:** Single WiFi netplan (`01-wifi.yaml` with `match: driver: wl`)

**VM:** Two netplan configs:
1. `01-ethernet.yaml` — Primary, for VM networking:
   ```yaml
   network:
     version: 2
     renderer: networkd
     ethernets:
       enp0s3:
         dhcp4: true
   ```
2. `02-wifi.yaml` — Fallback, identical to production WiFi config:
   ```yaml
   network:
     version: 2
     renderer: networkd
     wifis:
       wl0:
         match:
           driver: wl
         dhcp4: true
         optional: true
         access-points:
           "ATTj6pXatS":
             password: "j75b39=z?mpg"
   ```

**Reason:** The WiFi config is included to test that netplan generation works correctly and `netplan generate` succeeds with a `match: driver: wl` clause. On real hardware with a `wl` driver, the WiFi config would activate. On the VM, it's inert. The Ethernet config provides actual network connectivity.

#### 2.7.8 WiFi Power Management — Keep Production Pattern

**Production:** Creates a helper script `/usr/local/bin/wl-poweroff` + systemd service `wl-poweroff.service` that calls the helper.

**VM:** **Keep identical to production.** The helper script + service pattern should be preserved to test the production code path. The helper script works regardless of whether `wl` hardware is present (it gracefully handles no WiFi interface).

```sh
# Helper script — identical to production
mkdir -p /target/usr/local/bin
printf '#!/bin/sh\n# Disable WiFi power management to prevent disconnects\nIW=$(iwconfig 2>/dev/null | grep -oE "^wl[pw]?[0-9]*|^wlan[0-9]+|^wl[0-9]+" | head -1)\nif [ -n "$IW" ]; then\n  iwconfig "$IW" power off 2>/dev/null || true\nfi\n' > /target/usr/local/bin/wl-poweroff
chmod +x /target/usr/local/bin/wl-poweroff

# Systemd service — identical to production
printf '[Unit]\nDescription=Disable WiFi power management\nAfter=network.target\n\n[Service]\nType=oneshot\nExecStart=/usr/local/bin/wl-poweroff\nRemainAfterExit=yes\n\n[Install]\nWantedBy=multi-user.target\n' > /target/etc/systemd/system/wl-poweroff.service
chroot /target systemctl enable wl-poweroff.service 2>>"$LOG" || echo "[late] WARN: wl-poweroff service enable failed" >> "$LOG"
```

**What's preserved (all identical to production):**
- `echo "wl" >> /target/etc/modules`
- `/target/etc/modprobe.d/wl.conf` with `options wl`
- `/target/etc/modprobe.d/cfg80211.conf` with `ieee80211_regdom=US`
- `/target/etc/modprobe.d/blacklist-bcm.conf` with conflicting driver blacklists
- `/usr/local/bin/wl-poweroff` helper script
- `wl-poweroff.service` enabled via systemctl

#### 2.7.9 mDNS Configuration — Keep Production Pattern

**Production** modifies `/target/etc/nsswitch.conf` for mDNS resolution (`mdns_minimal`).

**VM:** **Keep identical to production.** mDNS works in a VM (via `avahi-daemon`), and the nsswitch.conf modification is harmless. Keeping it tests the production code path.

#### 2.7.10 Kernel Version Pinning — Keep Production Pattern

**Production:**
```sh
KVER="$(uname -r)"
chroot /target apt-mark hold "linux-image-${KVER}" 2>>/run/macpro.log || echo "[late] WARN: kernel hold failed" >> /run/macpro.log
chroot /target apt-mark hold "linux-headers-${KVER}" 2>>/run/macpro.log || echo "[late] WARN: headers hold failed" >> /run/macpro.log
```

**VM:** **Use the same pattern as production** — save `KVER` variable, use descriptive WARN messages.
```sh
KVER="$(uname -r)"
chroot /target apt-mark hold "linux-image-${KVER}" 2>>/run/macpro.log || echo "[late] WARN: kernel hold failed" >> /run/macpro.log
chroot /target apt-mark hold "linux-headers-${KVER}" 2>>/run/macpro.log || echo "[late] WARN: headers hold failed" >> /run/macpro.log
```

#### 2.7.11 Firewall (UFW) — Remove apt-get Install, Keep Configuration

**Production:** Installs UFW via `chroot /target apt-get -y install ufw` in late-commands, then configures it.

**VM:** **Remove the `apt-get` install** — UFW is already in the `packages:` YAML section, so Subiquity installs it from the ISO pool. Keep the configuration (deny incoming, allow SSH, enable):

```sh
# Remove: chroot /target apt-get -y install ufw  ← BANNED
# Keep: configuration commands (no apt-get needed, UFW already installed by packages: section)
chroot /target ufw default deny incoming 2>>/run/macpro.log || true
chroot /target ufw allow ssh 2>>/run/macpro.log || true
chroot /target ufw --force enable 2>>/run/macpro.log || true
```

The `cp /etc/resolv.conf /target/etc/resolv.conf` line that precedes the `apt-get` in production should also be removed — it was only needed for `apt-get` networking.

#### 2.7.12 Sudo Configuration — Preserved

Both `echo "teja ALL=(ALL) NOPASSWD:ALL" >> /target/etc/sudoers.d/teja` — identical.

#### 2.7.13 Target Verification — Keep with Non-Fatal WiFi Check

**Production** has a comprehensive verification step that checks:
- Kernel in `/target`
- Netplan WiFi config in `/target`
- WiFi driver module (`wl.ko`) in `/target`
- GRUB `nomodeset` param in `/target`
- **Recovery mode** if WiFi is broken (blocks reboot, keeps SSH alive)

**VM:** **Keep the verification checks** (they validate the installation succeeded), but make the WiFi module check non-fatal and remove the recovery mode:

```sh
echo "[late] Verifying target system integrity..." >> "$LOG"
VERIFY_OK=true
WIFI_CRITICAL=true  # Still track, but don't block reboot
if [ ! -f /target/vmlinuz ] && [ ! -f /target/boot/vmlinuz-* ]; then
  echo "[late] WARN: No kernel found in /target" >> "$LOG"
  VERIFY_OK=false
fi
if [ ! -f /target/etc/netplan/01-wifi.yaml ]; then
  echo "[late] WARN: Netplan WiFi config missing in /target" >> "$LOG"
  VERIFY_OK=false
fi
WIFI_MODULE_FOUND=false
if ls /target/lib/modules/*/updates/dkms/wl.ko 2>/dev/null | head -1 > /dev/null 2>&1; then
  WIFI_MODULE_FOUND=true
elif ls /target/lib/modules/*/extra/wl.ko 2>/dev/null | head -1 > /dev/null 2>&1; then
  WIFI_MODULE_FOUND=true
fi
if [ "$WIFI_MODULE_FOUND" = "false" ]; then
  echo "[late] WARN: No WiFi driver module in /target (expected in VM — no Broadcom HW)" >> "$LOG"
  # In production, WIFI_CRITICAL=false and recovery mode activates
  # In VM, this is expected — just log and continue
fi
if [ -f /target/etc/default/grub.d/macpro.cfg ]; then
  if ! grep -q 'nomodeset' /target/etc/default/grub.d/macpro.cfg; then
    echo "[late] WARN: GRUB nomodeset param missing in target" >> "$LOG"
    VERIFY_OK=false
  fi
else
  echo "[late] WARN: GRUB macpro.cfg missing in target" >> "$LOG"
  VERIFY_OK=false
fi
# Report verification result (no recovery mode — VM has Ethernet + console)
if [ "$VERIFY_OK" = "false" ]; then
  echo "[late] WARN: Some verification checks failed" >> "$LOG"
else
  echo "[late] All verification checks passed" >> "$LOG"
fi
```

**Changes from production:**
- WiFi module missing: WARN (expected in VM), not FATAL with recovery mode
- **No recovery mode** (`while true; do sleep 60; done`) — VM has Ethernet + console, so a broken WiFi doesn't create a headless brick
- All other verification checks preserved identically

#### 2.7.14 WiFi Reconnect Self-Healing — Removed

**Production** late-commands starts with WiFi health check and reconnect logic. **VM** removes this — Ethernet doesn't need reconnection.

### 2.8 `error-commands` — Enhanced Serial Logging

**Production:** Saves logs to `/var/log/macpro-install/` and copies to `/target/` if available.

**VM adds serial dumping:**
```sh
echo "=== ERROR — dumping full log to console ===" > /dev/console 2>/dev/null
cat "$LOG" > /dev/console 2>/dev/null
echo "=== DKMS make.log ===" > /dev/console 2>/dev/null
for _ml in /var/lib/dkms/broadcom-sta/6.30.223.271/*/x86_64/make.log; do
  [ -f "$_ml" ] && cat "$_ml" > /dev/console 2>/dev/null
done
```

Plus the same log persistence as production (`/var/log/macpro-install/` → `/target/var/log/macpro-install/`).

**Reason:** Serial logging provides visibility when SSH is unavailable. If DKMS build fails, the make.log is critical for debugging.

### 2.9 `ssh` Section — Unchanged

Both production and VM use:
```yaml
ssh:
  install-server: true
  allow-pw: true
  authorized-keys:
    - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA...
    # ... same keys ...
```

The only difference is the `password` hash (see §2.1).

### 2.10 `kernel` / `apt` / `refresh-installer` — Unchanged

Identical between production and VM.

---

## 3. New Files (VM-specific, no production equivalent)

### 3.1 `create-vm.sh` — VirtualBox VM Creation

Creates a VirtualBox VM matching Mac Pro 2013 characteristics where possible:

| Setting | Value | Matches Mac Pro? |
|---|---|---|
| Firmware | EFI | ✅ Yes (Mac Pro uses EFI) |
| CPUs | 4 | ✅ Same core count |
| RAM | 4576 MB | Approximation of 6GB Mac Pro |
| Disk | 25 GB VDI (SATA/AHCI) | ✅ AHCI matches Mac Pro SSD controller |
| Graphics | VMSVGA 128MB | ❌ Different (AMD FirePro vs VirtualBox) |
| Network | NAT (Intel 82540EM) | ❌ Different (Broadcom WiFi vs Intel Ethernet) |
| Serial | UART1 → /tmp/vmtest-serial.log | N/A (Mac Pro has no serial port) |
| SSH Forward | Host 2222 → Guest 22 | N/A |
| Webhook Forward | Host 8080 → Guest 8080 | N/A |

**Key:**
- **EFI firmware** is critical — Mac Pro 2013 uses EFI, and GRUB/efibootmgr behavior differs under EFI vs BIOS. The VM must use EFI.
- **SATA/AHCI** controller matches the Mac Pro's SSD path (`/dev/sda` via AHCI, not NVMe).
- **Serial port** (`--uart1 0x3F8 4 --uartmode1 file /tmp/vmtest-serial.log`) captures all console output when `console=ttyS0,115200` is in the kernel params.

### 3.2 `test-vm.sh` — VM Runner/Controller

A multi-command utility for interacting with the VM:

| Command | Description |
|---|---|
| `run` | Start VM headless, wait for SSH connectivity, grab logs |
| `ssh` | SSH into the VM (tries `teja` and `ubuntu` users) |
| `logs` | Grab installation logs via SSH (macpro log, curtin, subiquity, dmesg, dkms, lsmod, netplan, wl.ko) |
| `screenshot` | Take a VirtualBox screenshot PNG |
| `stop` | Power off the VM |
| `reset` | Power off + reset disk medium (for re-running tests) |
| `destroy` | Delete the VM entirely |

---

## 4. Complete Diff Summary — All Changes

| Category | Production | VM | Test Coverage Impact |
|---|---|---|---|
| **GRUB kernel params** | `nomodeset amdgpu.si.modeset=0` | `console=ttyS0,115200` | Different but justified: serial is VM's only visibility |
| **Disk validation** | `/dev/sda` existence, APFS check, multi-disk warn | Removed | VM has blank disk, no APFS |
| **SSH server** | `apt-get install openssh-server` with ISO pool fallback | **ISO pool `.deb` only** (no `apt-get`) | Tests offline install path |
| **UFW install** | `chroot /target apt-get -y install ufw` | **Removed** — `packages:` YAML section handles it | Subiquity installs from ISO pool |
| **Toolchain install (late)** | 4-stage `dpkg --root /target` from ISO packages | **Same 4-stage `dpkg --root /target`** | ✅ Now identical — tests dependency ordering offline |
| **modprobe wl** | FATAL on failure | WARN on failure | **Key change**: compilation tested, load skipped |
| **WiFi interface detect** | 60s timeout, FATAL | 60s timeout, WARN | Tests full detection loop, just non-fatal |
| **WiFi association/DHCP/connectivity** | Three verification stages | Removed, single success webhook | Ethernet provides network |
| **Conflicting driver blacklist** | `b43 ssb bcma brcmsmac` blacklisted + rmmod | **Same as production** (harmless, tests code path) | ✅ Now identical |
| **Network config** | WiFi (`wl0` + `match: driver: wl`) | Ethernet (`enp0s3`) | Different interface type |
| **Disk preservation** | `preserve: true` (dual-boot) | No preservation | VM disk is blank |
| **GRUB GPU params** | `nomodeset amdgpu.si.modeset=0` | `nomodeset` | No AMD FirePro in VM |
| **macOS boot entry** | `boot-macos` script + `efibootmgr` | Omitted | No macOS in VM |
| **WiFi reconnect** | Late-commands health check + reconnect | Removed | Ethernet doesn't drop |
| **Recovery mode** | Blocks reboot if WiFi broken | Removed (VM has Ethernet + console) | Only the infinite sleep loop removed |
| **Target verification** | Comprehensive with recovery mode | **Keep checks, non-fatal WiFi, no recovery mode** | Tests verification logic |
| **SSH authorized keys** | Inline keys copied to installer user | **Same as production** | Tests key injection |
| **WiFi power management** | Helper script + systemd service | **Same as production** | Tests helper + service enablement |
| **mDNS config** | nsswitch.conf modification | **Same as production** | Tests mDNS setup |
| **Netplan** | Single WiFi config | Dual: Ethernet + WiFi | WiFi config included for `netplan generate` test |
| **Serial logging** | None | `trap '_dump_log' EXIT` + `console=ttyS0` | VM's primary visibility mechanism |
| **DKMS make.log dump** | Not in early-commands | Dumped to console on build failure | VM-specific debugging aid |
| **Hostname** | `macpro-linux` | `vmtest` | Cosmetic |
| **Webhook URL** | `192.168.1.115:8080` | `10.0.2.2:8081` | VirtualBox NAT gateway |
| **Packages** | 7 (includes WiFi/mDNS tools) | **Same 7 packages** | All from ISO pool — validates availability |
| **Error commands** | Log persistence only | Log persistence + serial dump | Serial adds VM visibility |

---

## 5. What VM Test Actually Validates

These production code paths are exercised identically in the VM:

1. **ISO build pipeline** — extract, overlay, repack with preserved boot parameters
2. **NoCloud datasource discovery** — `cidata/` volume label + `ds=nocloud`
3. **Package discovery** — `/cdrom/macpro-pkgs/` mount point scanning
4. **Kernel header validation** — matching `$(uname -r)` against available debs
5. **Offline toolchain installation** (early-commands) — full `dpkg --force-depends --skip-same-version` from `macpro-pkgs/`, dependency-ordered, with version-skip handling
6. **`cc` symlink creation** — `x86_64-linux-gnu-gcc-13` with `gcc-13` fallback
7. **DKMS package installation** — `dpkg -i dkms broadcom-sta-dkms` with expected non-zero return
8. **DKMS patch application** — all 6 patches from `series` file, applied in order, FATAL on failure
9. **DKMS build** — `dkms build broadcom-sta/6.30.223.271 -k $KVER` with single-retry
10. **DKMS install** — `dkms install` with single-retry
11. **4-stage offline target installation** (late-commands) — `dpkg --root /target --force-depends --skip-same-version` in dependency order (headers → libs → tools → DKMS)
12. **DKMS build in target** (late-commands) — chroot with bind mounts, patch, build, install
13. **Conflicting driver blacklist** — `b43 ssb bcma brcmsmac` blacklisted + rmmod (harmless in VM)
14. **WiFi interface detection** — full 60-second detection loop with all `wl*`/`wlan*` patterns
15. **WiFi power management** — `wl-poweroff` helper script + systemd service + modprobe options
16. **EFI partition layout** — 512M EFI + 1G /boot + rest /
17. **GRUB configuration** — custom kernel params, os-prober, custom menu entry
18. **efibootmgr** — installed and EFI vars accessible
19. **UFW firewall** — deny incoming, allow SSH
20. **Kernel pinning** — `apt-mark hold` on kernel and headers
21. **Sudo configuration** — NOPASSWD for user
22. **Log persistence** — `/var/log/macpro-install/` on target
23. **Webhook reporting** — progress events at each stage
24. **Target verification** — kernel, netplan, WiFi module, GRUB params checked
25. **Autoinstall flow** — early-commands → network → storage → late-commands → reboot
26. **SSH server installation** — ISO pool `.deb` fallback only (no `apt-get`)
27. **SSH authorized keys** — inline key injection into installer `ubuntu` user

---

## 6. Serial Console Setup (Critical for VM Visibility)

The VM test relies on three pieces working together for full log visibility:

1. **GRUB kernel parameter:** `console=ttyS0,115200` — redirects kernel + init output to serial
2. **VirtualBox serial port:** `--uart1 0x3F8 4 --uartmode1 file /tmp/vmtest-serial.log` — captures serial output to a file
3. **Shell trap:** `trap '_dump_log' EXIT` in early-commands and late-commands — dumps the full macpro.log to `/dev/console` on exit

With all three in place, the serial log file at `/tmp/vmtest-serial.log` contains:
- Kernel boot messages
- `set -x` trace output from shell commands
- DKMS make.log on build failure
- Full macpro.log on any early/late-commands exit

**An AI agent creating a VM test MUST include all three.** Without `console=ttyS0`, kernel output goes only to the virtual display (invisible in headless mode). Without the EXIT trap, the macpro.log isn't visible on serial. Without the VirtualBox UART config, serial output goes nowhere.

---

## 7. Quick Reference: Production → VM Conversion Checklist

For an AI agent converting a production `build-iso.sh` + `autoinstall.yaml` to VM equivalents:

### `build-iso-vm.sh`:
- [ ] Set `PROJECT_DIR` to parent of `SCRIPT_DIR`
- [ ] Point `BASE_ISO`, `PKGS_DIR` to `$PROJECT_DIR/`
- [ ] Point `AUTOINSTALL` to `$SCRIPT_DIR/autoinstall-vm.yaml`
- [ ] Change `OUTPUT_ISO` to `$SCRIPT_DIR/ubuntu-vmtest.iso`
- [ ] Change `STAGING` to `/tmp/vmtest-iso-staging`
- [ ] Add `console=ttyS0,115200` to GRUB linux line
- [ ] Remove `nomodeset amdgpu.si.modeset=0` from GRUB linux line
- [ ] Change `instance-id` in meta-data to `vmtest-i1`
- [ ] Change menu labels to identify VM test
- [ ] Keep everything else identical (xorriso, packages, patches, verification)

### `autoinstall-vm.yaml`:
- [ ] Change `hostname` to `vmtest`
- [ ] Change `password` hash to `teja:teja`
- [ ] Change webhook `endpoint` to `http://10.0.2.2:8081/webhook`
- [ ] Add `_dump_log` trap + EXIT trap in early-commands and late-commands
- [ ] Remove `/dev/sda` existence check, APFS check, multi-disk warning from early-commands
- [ ] SSH server: use **ISO pool `.deb` only** — no `apt-get` (production's fallback path)
- [ ] UFW: remove `chroot /target apt-get -y install ufw` — the `packages:` section handles it
- [ ] **KEEP offline `dpkg -i` toolchain install — identical to production** (do NOT replace with `apt-get`)
- [ ] Change `modprobe wl` verdict from FATAL to WARN — **keep retry-with-rmmod pattern**
- [ ] **KEEP conflicting driver blacklist + rmmod — identical to production** (harmless in VM)
- [ ] Keep WiFi interface timeout at 60s (same as production) — make verdict non-fatal instead
- [ ] Remove WiFi association check, DHCP check, connectivity circuit breaker
- [ ] Add DKMS make.log dump to console on build failure
- [ ] Replace `wifis: wl0:` network config with `ethernets: enp0s3:`
- [ ] **KEEP all 7 packages — identical to production** (they come from ISO pool, not internet)
- [ ] Remove `preserve: true` from disk in storage config
- [ ] Remove WiFi health check + reconnect from late-commands start
- [ ] **KEEP 4-stage `dpkg --root /target` toolchain install — identical to production** (do NOT replace with `chroot apt-get`)
- [ ] Change GRUB params from `nomodeset amdgpu.si.modeset=0` to `nomodeset`
- [ ] Remove `boot-macos` helper script
- [ ] Rename macOS menu entry to "Reboot to Firmware"
- [ ] Write dual netplan configs (Ethernet primary + WiFi fallback)
- [ ] **KEEP mDNS nsswitch.conf modification — identical to production**
- [ ] **KEEP kernel pinning with KVER variable — identical to production**
- [ ] Remove target **recovery mode** only (the `while true; do sleep 60; done` loop) — keep verification checks with non-fatal WiFi verdict
- [ ] **KEEP SSH authorized keys setup — identical to production**
- [ ] **KEEP wl-poweroff helper script + service — identical to production**
- [ ] Add serial log dump to error-commands
- [ ] Remove WiFi reconnect from error-commands
- [ ] Keep DKMS install, patch, build, bind-mount — **unchanged** (critical test path)
- [ ] Keep UFW firewall **configuration** — unchanged (but remove `apt-get` install line, UFW comes from `packages:` section)
- [ ] Keep sudo config — unchanged
- [ ] Keep log persistence — unchanged