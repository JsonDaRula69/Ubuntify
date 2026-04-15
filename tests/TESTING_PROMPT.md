# COMPREHENSIVE AUTOMATED CODE REVIEW AND TESTING PROTOCOL

> **Purpose:** This document is a prompt for LLM agents performing systematic code review and testing of the Mac Pro 2013 Ubuntu Autoinstall project. It provides exhaustive checklists for every phase, with project-specific checks grounded in how Subiquity, Ubuntu, and macOS actually work. Every script and flow path must be checked line by line.

Execute a systematic, multi-phase review and testing cycle. Do not stop at static analysis. Each phase must be completed before moving to the next. Found bugs must be fixed, then ALL tests re-run from the beginning.

## Table of Contents

- [Phase 0: Codebase Architecture Model](#phase-0-codebase-architecture-model)
- [Phase 1: Static Code Analysis](#phase-1-static-code-analysis)
  - [1.1.1 TUI Module Raw Fallback Audit](#111-tui-module-raw-fallback-audit)
- [Phase 2: Functional Behavior Testing](#phase-2-functional-behavior-testing)
  - [2.8 TUI Interactive Prompt Testing](#28-tui-interactive-prompt-testing)
  - [2.9 Option Selection Flow Pathway Tracing](#29-option-selection-flow-pathway-tracing)
- [Phase 3: Integration and System Testing](#phase-3-integration-and-system-testing)
- [Phase 4: Best Practices and Patterns](#phase-4-best-practices-and-patterns)
- [Phase 5: Execution and Validation](#phase-5-execution-and-validation)
- [Iterative Fix and Test Cycle](#iterative-fix-and-test-cycle)
- [Reporting Requirements](#reporting-requirements)
- [Final Checklist](#final-checklist)

---

## PHASE 0: CODEBASE ARCHITECTURE MODEL

Perform this phase FIRST. Its findings feed into and expand the scope of all subsequent phases.

**Phase 0 Gate:** Before proceeding to Phase 1, all Phase 0 findings must be documented and classified. Any P0 finding from Phase 0 (e.g., readonly variable collision preventing script launch) must be fixed before continuing, because it blocks all subsequent testing.

### 0.1 Sourcing Tree and Initialization Order
Map the complete sourcing tree: which script sources which, in what order
Trace the entry point initialization sequence step by step from first line to main()
Document which modules are loaded before others and why that order matters
Identify any modules that are conditionally sourced and under what conditions
Verify: does the main script (prepare-deployment.sh) set `readonly SCRIPT_DIR` before sourcing lib/*.sh?
Verify: do any lib/*.sh files re-assign SCRIPT_DIR when it's already readonly from the parent?
Verify: does lib/detect.sh, lib/deploy.sh, and lib/autoinstall.sh all have the `SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "$0")" && pwd)}"` pattern?
Verify: what happens when this defaults to the lib/ directory instead of the project root?
Check: does build-iso.sh also set `readonly SCRIPT_DIR` and source from `$LIB_DIR`?
Map: prepare-deployment.sh → colors.sh → logging.sh → tui.sh → dryrun.sh → retry.sh → verify.sh → rollback.sh → detect.sh → disk.sh → autoinstall.sh → bless.sh → deploy.sh → revert.sh (conditionally: remote.sh)
Identify: which modules are conditionally sourced (remote.sh is `if [ -f ]`) and what breaks if they're absent

### 0.2 Variable Namespace Collision Map
List ALL `readonly` and `declare -r` declarations across every file
List ALL `export`'d variables and trace which modules consume them
Identify ALL shared variable names across modules (SCRIPT_DIR, LIB_DIR, ESP_NAME, ESP_SIZE, STORAGE_LAYOUT, NETWORK_TYPE, INTERNAL_DISK, APFS_CONTAINER, TARGET_DEVICE, DRY_RUN, AGENT_MODE, JSON_OUTPUT, CONFIRM_YES, OUTPUT_DIR, LOG_LEVEL, etc.)
For each shared variable: document which module owns it, which modules read it, and whether any module attempts to reassign it
Flag: any library that re-assigns a variable already declared `readonly` in a parent scope (e.g., SCRIPT_DIR in detect.sh, deploy.sh, autoinstall.sh when sourced from prepare-deployment.sh)
Verify: ESP_NAME is set as readonly in prepare-deployment.sh AND as a non-readonly default in disk.sh — is there a collision?
Verify: ESP_SIZE is set as readonly in prepare-deployment.sh AND as a default in disk.sh — same pattern

### 0.3 Function Namespace Map
List ALL function definitions across every .sh file
Identify any function name collisions across modules (e.g., are there any name collisions between lib/revert.sh and lib/rollback.sh?)
Identify any function that shadows a system command (e.g., `log` in logging.sh shadows `/usr/bin/log` on macOS)
Check: does `die()` in build-iso.sh conflict with `die()` from logging.sh?
Check: do `warn()`, `error()`, `log()` aliases in build-iso.sh conflict with logging.sh versions?

### 0.4 Guard Variable Audit
Check every lib/*.sh for a guard variable (e.g., _COLORS_SH_SOURCED, _LOGGING_SH_SOURCED, etc.)
List which modules have guards and which don't
Determine if any module can be double-sourced and what would break
Verify: if colors.sh is double-sourced, readonly RED/GREEN/etc. would fail — does the guard prevent this?
Verify: lib/retry.sh has a one-line guard — does it properly prevent re-execution of the readonly declarations?
Check: lib/tui.sh declares `readonly TUI_BACKEND`, `readonly TUI_HAS_GAUGE`, `readonly TUI_HAS_TAILBOX`, `readonly TUI_BACKTITLE` — what happens on double-source?

### 0.5 Architecture Diagram
Produce a dependency diagram: main script → libs → sub-libs
Mark each edge with what is consumed (variables, functions)
Highlight circular dependencies or fragile ordering assumptions
Verify: rollback.sh depends on retry.sh and dryrun.sh — is this documented?
Verify: deploy.sh sources nearly everything — is the order significant?
Check: does build-iso.sh source a subset of libs? Which ones? Does it miss any it needs?

---

## PHASE 1: STATIC CODE ANALYSIS

Before running static analysis, create a `.shellcheckrc` file:
```
source-path=lib/
# Document intentional patterns that warrant ignores
# SC1090/SC1091: Sourced files with variable paths — we use source "$LIB_DIR/foo.sh"
# SC2034: Unused variables — some are used by sourced scripts
```

All findings from this phase must be classified by severity:
- **P0 (Fatal):** Script won't start, crashes immediately, data loss risk
- **P1 (Critical):** Core feature broken, wrong behavior, silent data corruption
- **P2 (Major):** Error path mishandled, missing validation, incorrect fallback
- **P3 (Minor):** Style, formatting, documentation gaps, non-idiomatic patterns

### 1.1 Syntax and Structure Validation
Run syntax checks on ALL shell scripts: `bash -n` for each .sh file
Run ShellCheck with full severity coverage: `shellcheck -x --severity=warning` on ALL .sh files including:
- prepare-deployment.sh
- build-iso.sh (in lib/ directory)
- Every file in lib/*.sh
- Every file in tests/*.sh and tests/vm/*.sh
- macpro-monitor/start.sh, stop.sh, reset.sh

Note: ShellCheck cannot follow dynamic `source "$LIB_DIR/foo.sh"` paths. Use `source-path=lib/` in .shellcheckrc and add `# shellcheck source=lib/foo.sh` directives where needed. SC1090/SC1091 warnings for sourced libs should be verified manually, not suppressed blindly.

Run formatting validation: `shfmt -i 2 -ci -bn -d`
Run Node.js syntax validation on macpro-monitor/server.js (`node --check`)
Document EVERY warning, error, and suggestion — do not filter
Classify each finding as P0/P1/P2/P3

### 1.1.1 TUI Module Raw Fallback Audit
lib/tui.sh contains multi-backend TUI functions (dialog, whiptail, raw). The raw fallback is the most error-prone — it is the code path executed when neither dialog nor whiptail is available. Copy-paste contamination between function fallbacks has caused P1 bugs. For each function, verify:

**Contamination check** — grep for function-crossing patterns that should NOT appear outside their respective fallbacks:
- `grep -n "Proceed\?" lib/tui.sh` — "Proceed?" should ONLY appear in tui_confirm raw fallback
- `grep -n "yes/no" lib/tui.sh` — "yes/no" prompt should ONLY appear in tui_confirm raw fallback
- `grep -n "Press Enter" lib/tui.sh` — "Press Enter to continue" should ONLY appear in tui_msgbox raw fallback
- `grep -n '\$message' lib/tui.sh` — `$message` is a tui_confirm parameter; `$description` is a tui_menu parameter; verify each usage is in the correct function

**Variable scope check** — for each raw fallback branch (else branch after dialog/whiptail checks):
- tui_menu: uses `$description` (NOT `$message`)
- tui_confirm: uses `$message` (NOT `$description`)
- tui_input: uses `$label`, `$default_value`
- tui_password: uses `$label`, reads with `IFS= read -rs`
- tui_checklist: uses `$description`, reads from `/dev/tty`
- tui_msgbox: uses `$message`
- tui_progress: output-only, no input
- tui_tailbox: uses `$title`, `$filepath`

**/dev/tty consistency check** — verify ALL raw input functions read from /dev/tty:
- `grep -n 'read.*< /dev/tty' lib/tui.sh` — should find exactly 6 matches (tui_menu, tui_confirm, tui_msgbox, tui_input, tui_password, tui_checklist)
- tui_progress and tui_tailbox are output-only and should NOT read from /dev/tty
- Any function reading from stdin (`read -rp`) without `< /dev/tty` is a P1 bug — stdin is consumed by heredoc/pipe in scripted contexts

**Return type check** — verify raw fallbacks return expected types:
- tui_menu returns: tag string (e.g., "existing", "generate", "skip")
- tui_confirm returns: 0 (yes) or 1 (no)
- tui_input returns: user-entered string
- tui_password returns: user-entered password
- tui_checklist returns: space-separated tag string
- tui_msgbox returns: nothing (displays and exits)

**set -u compatibility check** — source lib/tui.sh with `set -u` active, call each function with test args. Any "unbound variable" error indicates a missing local declaration or wrong parameter name in a fallback branch.

### 1.2 Variable and Scope Analysis
Audit ALL variable declarations (local, readonly, declare, export)
Identify duplicate declarations or reassignments of the same variable name
Trace variable scope throughout the codebase — especially across source boundaries
Check for variable naming conflicts between scripts/libraries (using Phase 0.2 map)
Verify all required environment variables are documented
Identify any variable used before it is set (with `set -u` active)
Check for variables that should be local but aren't
Specific checks:
- VERIFY: In prepare-deployment.sh, `readonly SCRIPT_DIR` is set BEFORE sourcing lib/*.sh — do any of those libs also set SCRIPT_DIR?
- VERIFY: `readonly ESP_NAME="CIDATA"` — but disk.sh has `ESP_NAME="${ESP_NAME:-CIDATA}"` — is this a collision?
- VERIFY: `readonly ESP_SIZE="5g"` — but disk.sh has `ESP_SIZE="${ESP_SIZE:-5g}"` — same pattern
- VERIFY: `readonly LIB_DIR="${LIB_DIR:-$SCRIPT_DIR/lib}"` — can LIB_DIR be overridden? What happens to subsequent `source "$LIB_DIR/..."` calls?
- CHECK: All `eval "$varname=..."` patterns in disk.sh, deploy.sh — are they safe with `set -u`?
- CHECK: `parse_conf()` reads deploy.conf line-by-line — what happens with empty values or values containing `=`?
- CHECK: `save_config()` writes deploy.conf — does it properly quote values containing spaces or special chars?

### 1.3 Dependency Graph Mapping
Map all function calls and their dependencies
Identify all external command dependencies including:
- macOS-specific: diskutil, bless, sgdisk, newfs_msdos, tmutil, csrutil, fdesetup, sw_vers, security
- Linux-specific (for remote.sh): ssh, dkms, apt-get, dpkg, efibootmgr, systemctl, ufw, grub-*
- Cross-platform: xorriso, python3, curl, dd, comm, stat
- Note which commands run on macOS vs. Linux (e.g., diskutil is macOS-only; dkms is Linux-only)
Check that all sourced files exist and are valid
Document the execution order and call hierarchy
Identify circular dependencies
Verify that every function referenced in a case/esac or callback actually exists
Specific checks:
- VERIFY: All functions referenced in prepare-deployment.sh's case statements (deploy_internal_partition, deploy_usb, deploy_manual, deploy_vm_test) are defined in lib/deploy.sh
- VERIFY: All functions referenced in _AGENT_OPERATIONS (remote_get_info, remote_kernel_status, etc.) are defined in lib/remote.sh
- VERIFY: All functions referenced in rollback PHASES_* constants are defined
- CHECK: build-iso.sh defines its own log/warn/error/die — are these compatible with logging.sh versions?

### 1.4 Control Flow Analysis
Trace all execution paths including error paths
Identify unreachable code
Check all exit paths have proper cleanup
Verify all conditionals cover their intended cases
Check loop termination conditions
Trace what happens when `set -e` encounters a failing command in a pipeline, subshell, or conditional
Identify any `|| true` or `|| :` that might be swallowing real errors
Specific checks:
- TRACE: What happens when deploy_internal_partition fails at phase _phase_generate_config? Does cleanup_on_error get called? Does the journal get destroyed?
- TRACE: What happens when build-iso.sh fails at step [4/5]? Does the staging directory get cleaned up? Does the trap fire?
- CHECK: The `run_phased` function in rollback.sh — when `is_dry_run` is true, it skips the phase function entirely. Does this mean journal phases are never recorded in dry-run mode? Is this correct?
- CHECK: In detect.sh, `select_usb_device` uses `eval` to set a variable by name — is this safe with user-controlled input?
- CHECK: In autoinstall.sh, `generate_autoinstall()` uses `sed -i` with both GNU and BSD syntax (`sed -i ... 2>/dev/null || sed -i '' ...`) — is this pattern correct for both platforms?
- CHECK: The `journal_set` function uses `eval` to read variable values — is the key validation regex sufficient to prevent injection (`^[a-zA-Z_][a-zA-Z0-9_]*$`)?
- CHECK: `retry_diskutil` checks stderr for "Resource busy" — are there other transient diskutil errors that should trigger retries?
- CHECK: `retry_xorriso` retries on I/O errors — does it properly clean up partial extraction directories on failure?

### 1.5 Line-by-Line Code Review
Review EVERY line of EVERY shell script for correctness. Do not skip sections assuming they work.
For each line, verify:
- Is the logic correct for the platform it runs on? (macOS vs. Ubuntu/Subiquity installer vs. Ubuntu target)
- Are all variable expansions properly quoted? (Every `"$VAR"` must be quoted, every unquoted `$VAR` is a finding)
- Are all conditional expressions correct? (`[[ ]]` for bash, `[ ]` only for POSIX contexts like autoinstall YAML `- |` blocks)
- Are exit codes properly checked? (No silent failures in `set -e` context)
- Are pipe failures caught? (`set -o pipefail` is set — verify pipe chains propagate failures)

Platform-specific line-by-line checks:
- **macOS (host) scripts** (prepare-deployment.sh, build-iso.sh, lib/disk.sh, lib/bless.sh, lib/detect.sh, lib/revert.sh): Use BSD工具语义。`stat -f%z`, `diskutil`, `bless`, `newfs_msdos`, `hdiutil`
- **autoinstall YAML `- |` blocks** (lib/autoinstall.sh embedded content, 生成されたautoinstall.yaml): Run via `sh -c` in Subiquity installer — POSIX ONLY, no `[[ ]]`, no arrays, no `<<<`。变量不会在不同的`- |`块之间共享
- **远程管理脚本** (lib/remote.sh): SSH命令在目标Ubuntu系统上执行。`apt`、`dkms`、`systemctl`、`efibootmgr`命令
- **Node.js** (macpro-monitor/server.js): Node.js语义，Promises, HTTP server

### 1.6 Generated Artifact Validation
Validate every `autoinstall.yaml` and `autoinstall-vm.yaml` variant (method × storage × network combinations) parses as valid YAML:
- `python3 -c "import yaml; yaml.safe_load(open('autoinstall.yaml'))"`
- Validate against `lib/autoinstall-schema.json` using a JSON Schema validator
- Verify all `__PLACEHOLDER__` tokens are replaced (no stray `__` in output)
- Validate the Python heredoc in `generate_dualboot_storage` is syntactically correct Python
- Verify partition type GUID values are lowercase hex (curtin normalizes to lowercase; uppercase causes `preserve: true` verification mismatches)
- Verify each `- |` block redefines KVER, ABI_VER, LOG, WHURL (POSIX constraint: variables not shared between blocks)
- Verify `netplan generate --root-dir /tmp/test-root` succeeds against generated netplan YAML (mock chroot)
- Verify autoinstall YAML complies with Subiquity's actual schema — check against https://ubuntu.com/server/docs/install/autoinstall-reference:
  - `network:` section CANNOT contain `wifis:` (networkd renderer does not support `match:` for wifis; Ubuntu Bug #2073155)
  - `early-commands` and `late-commands` run via `sh -c` — verify POSIX-only syntax
  - `storage:` section with `preserve: true` must have lowercase GUID type codes
  - `reporting:` section must use `{progress, stage, status, message}` fields, NOT `{name, event_type, origin}` (those trigger built-in Subiquity handler)

---

## PHASE 2: FUNCTIONAL BEHAVIOR TESTING

### 2.1 Mode and Flag Testing
Test EVERY command-line flag in prepare-deployment.sh:
- --dry-run, --verbose, --agent, --yes, --json
- --method (1|2|3|4), --storage (1|2), --network (1|2)
- --host, --operation, --wifi-ssid, --wifi-password
- --webhook-host, --webhook-port
- --username, --hostname, --vm, --revert, --help

Test --flag=value syntax for all applicable flags (--method=1, --storage=2, etc.)
Test invalid flag values: --method 5, --storage 3, --network 0
Test missing required arguments: --method without value, --operation without value
Test --help output matches actual flag implementation
Test --revert flag standalone (should work without other flags)
Test --build-iso flag (agent mode only)
Verify exit codes match documentation (0=success, 1=general, 2=usage, etc.)
Test build-iso.sh flags: --vm flag for VM mode, default behavior for production mode

### 2.2 Execution Mode Testing
Test dry-run/simulation modes for EVERY deployment method:
- --agent --dry-run --method 1 --storage 1 --network 1 --yes --json (internal partition)
- --agent --dry-run --method 2 --storage 1 --network 1 --yes --json (USB)
- --agent --dry-run --method 3 (manual)
- --agent --dry-run --method 4 --vm (VM test)

Verify dry-run produces ZERO side effects — audit every code path to ensure no destructive command executes when DRY_RUN=1
Verify dry-run exits with code $E_DRY_RUN_OK (11)
Check specifically: does `dry_run_exec` wrap ALL destructive commands in lib/deploy.sh, lib/disk.sh, lib/bless.sh, lib/revert.sh?
Check specifically: does `dry_run_callback` properly fall through to the real command when NOT in dry-run?
Verify `dryrun.sh` guard variable prevents double-sourcing
Test verbose/quiet modes (VERBOSE=1, LOG_LEVEL overrides)
Test agent mode with --agent flag
Test --agent --yes confirms destructive operations automatically
Test --agent WITHOUT --yes denies destructive operations (CONFIRM_YES=0)
Test --json flag produces valid JSON output (validate with `python3 -m json.tool`)
Test TUI fallback when dialog/whiptail are unavailable (TUI_BACKEND="raw")

### 2.3 Normal Execution Path Testing
Execute all primary workflows that can be safely executed:
- prepare-deployment.sh --help
- prepare-deployment.sh --dry-run --agent --method 1 --storage 1 --network 1 --yes --json
- prepare-deployment.sh --dry-run --agent --method 2 --storage 2 --network 2 --yes --json
- prepare-deployment.sh --agent --build-iso --json
- prepare-deployment.sh --agent --operation kernel_status --host macpro-linux --json

Test with valid inputs across boundary conditions
Test file operations (create, read, modify, delete) where safe
Test network operations (webhook server start/stop)
Test process execution and subprocess handling
Test config file parsing: deploy.conf with all keys, empty values, missing file fallback to deploy.conf.example
Test config file encryption modes: plaintext, aes256, keychain
Test save_config and encrypt_config round-trip

### 2.4 Error Path Testing
Test with missing required arguments (--method without value)
Test with invalid input types (--method foo, --storage bar)
Test with missing/invalid file paths (nonexistent ISO, missing prereqs/ directory)
Test with insufficient permissions (running without sudo)
Test resource exhaustion scenarios (disk full simulation, large ISO)
Test network failures and timeouts (unreachable webhook host)
Test dependency failures:
- Missing xorriso, sgdisk, python3, comm, diskutil
- Wrong versions of dependencies
- Missing dialog and whiptail (TUI_BACKEND="raw")

Verify error messages are clear and actionable
Verify exit codes match documented values (E_SUCCESS=0 through E_AGENT_DENIED=13)
Specific error path tests:
- What happens when analyze_disk_layout can't find the internal disk?
- What happens when detect_iso can't find any ISO file?
- What happens when select_usb_device finds no USB devices?
- What happens when APFS resize fails mid-operation?
- What happens when bless fails with SIP enabled (error 0xe00002e2)?
- What happens when xorriso extraction fails mid-stream?
- What happens when journal_init finds an existing incomplete state file?
- What happens when build-iso.sh can't find the base ISO?
- What happens when the DKMS patches series file lists a patch that doesn't exist?

### 2.5 Journal State Machine Testing
Test the rollback journal system (lib/rollback.sh) independently:
- Test `journal_init` with fresh state, existing state, and corrupted state files
- Test `journal_set` / `journal_set_phase` records correct timestamps and phase names
- Test `journal_is_complete` returns correct boolean for each known phase
- Test `journal_destroy` properly cleans up state file
- Test `rollback_from_journal` dispatches to correct rollback function for each phase
- Test that `DRY_RUN=1` prevents journal writes (or records them with dry-run marker)
- Verify atomic write pattern (temp file + mv) for crash safety
- Test `journal_set` with keys containing only valid characters (alphanumeric + underscore)
- Test `journal_set` rejects keys with special characters or spaces
- Test rollback_from_journal when state file exists but is empty or has zero phases recorded

### 2.6 Config Round-Trip Testing
Test the full deploy.conf lifecycle:
- Write deploy.conf with all keys → `parse_conf()` → verify all values match
- Write deploy.conf with special characters in values (spaces, quotes, `#`, `$`, `\`, newlines) → `parse_conf()` → verify values preserved
- Write deploy.conf → `encrypt_config()` → `parse_conf()` with encrypted values → verify decryption matches original
- Write deploy.conf with `ENCRYPTION=aes256` → verify password is decrypted at runtime, not stored in plaintext
- Write deploy.conf with `ENCRYPTION=keychain` → verify keychain lookup works and falls back gracefully on failure
- Write deploy.conf with multiple `SSH_KEY=` lines → verify all keys are collected in order
- Write deploy.conf with `SSH_KEYS_FILE=/path/to/file` → verify file is read and merged with `SSH_KEY=` entries
- Test `save_config()` preserves all keys, including ones not in the original file
- Test that `save_config()` sets mode 600 on the output file
- Test `parse_conf()` with `IFS='=' read -r key value` correctly handles values containing `=` (only splits on first `=`)
- Test `parse_conf()` with empty lines, comment lines, and lines with only whitespace

### 2.7 Network Connectivity Circuit Breaker Testing
Test the WiFi connectivity verification circuit breaker that prevents disk wipe when networking is non-functional:
- Verify deployment aborts (does NOT proceed to APFS resize / disk wipe) if WiFi check fails
- Verify 169.254.x.x link-local addresses are excluded from DHCP lease validation
- Verify the circuit breaker fires in the correct phase order (after driver load, before storage)
- Test what happens when WiFi interface detection times out (≥60s timeout for `wl` module initialization)
- Test what happens when WiFi interface is detected but DHCP fails
- Verify `grep -q "inet "` checks exclude `inet 169.254.` per project constraint
- Verify POSIX `if ! cmd1 || cmd2` correctly means `(!cmd1) || cmd2` — both failure modes caught

### 2.8 TUI Interactive Prompt Testing
Test TUI functions with actual interactive input (requires keyboard, cannot be piped). The raw TUI backend (`TUI_BACKEND=raw`) is the fallback when dialog/whiptail are unavailable and is the most bug-prone code path.

**Menu option selection test** (tui_menu raw fallback):
```
TUI_BACKEND=raw ./prepare-deployment.sh --help 2>&1 | head -5
# Should show: "=== Mac Pro 2013 Ubuntu Deployment ===" and "Select operation mode:"
# Should show numbered options: "1) Deploy", "2) Manage", "3) Revert Failed Deploy", "4) Exit"
# Should show: "Enter choice [1-4]:"
```
Test: `echo "1" | ./prepare-deployment.sh` — should enter Deploy flow (not crash, not show "yes/no" prompt)

**SSH Key Configuration menu test** (first-run config flow):
```
TUI_BACKEND=raw source lib/colors.sh lib/tui.sh 2>/dev/null
echo "existing" | tui_menu "SSH Key Configuration" "Choose how to provide SSH public key:" \
    "Provide existing key" "existing" "Generate new key" "generate" "Skip SSH setup" "skip"
# Should display: "=== SSH Key Configuration ===", description, "1) Provide existing key", "2) Generate new key", "3) Skip SSH setup"
# Should show: "Enter choice [1-3]:"
# Should return: "existing" (the tag value, NOT "yes" or "no")
```

**Checklist selection test** (tui_checklist raw fallback):
- Verify numbered options are displayed with checkbox state
- Verify comma-separated input works: `echo "1,3" | tui_checklist ...`
- Verify /dev/tty read (not stdin — test by running from script with piped input)

**Error path tests**:
- Enter invalid choice: `echo "99" | tui_menu ...` — should re-prompt with error
- Enter empty input on tui_input: should use default value
- Enter empty password on tui_password: should use empty value
- Keyboard interrupt (Ctrl-C) during tui_input/tui_password: should exit cleanly

### 2.9 Option Selection Flow Pathway Tracing
Every menu choice, checklist selection, confirmation, and input value flows through a chain: TUI function → caller → conditional logic → next step. Trace EVERY selection pathway end-to-end to verify the resolved behavior matches the user's expectation.

**Trace methodology**: For each TUI call site in prepare-deployment.sh, document: (1) which TUI function is called, (2) what the expected return type is, (3) how the return value is used, (4) what the final resolved behavior is.

**Deploy mode menu** (tui_menu, tag → case dispatch):
```
Line 764: choice=$(tui_menu "Mac Pro 2013 Ubuntu Deployment" "Select operation mode:" ...)
  → returns tag: "deploy", "manage", "revert", "exit"
  → Line 766: case "$choice" in deploy|...) menu_deploy ;;
  → Line 775: case "$choice" in esp|usb|manual|vm) menu_deploy "$choice" ;;
  → ...
  Verify: user selects "1" → gets "Deploy" → gets deployment method submenu
  Verify: each tag maps to the correct function with correct arguments
```

**SSH key configuration flow** (tui_menu → conditional):
```
Line 411: choice=$(tui_menu "SSH Key Configuration" ...)
  → returns tag: "existing", "generate", "skip"
  → Line 415: case "$choice" in
      existing) prompt_existing_key ;;
      generate) prompt_generate_key ;;
      skip) ... ;; esac
  Verify: "existing" → scans ~/.ssh/*.pub → if none found → warns user
  Verify: "generate" → prompts key type → runs ssh-keygen → saves to ~/.ssh/macpro_ubuntu_*
  Verify: "skip" → skips SSH setup → warns about console access
```

**Kernel management submenu** (tui_menu, tag → multi-step confirm):
```
Line 1064: choice=$(tui_menu "Kernel Management" ...)
  → returns tag: "status", "pin", "unpin", "update", "security", "back"
  → Line 1072: case "$choice" in
      pin) if tui_confirm "Pin Kernel" ...; then remote_kernel_repin ...; fi ;;
      unpin) if tui_confirm "Unpin Kernel" ...; then remote_kernel_unpin ...; fi ;;
      ...
  Verify: "pin" → shows tui_confirm dialog → on yes → calls remote_kernel_repin
  Verify: "unpin" → shows tui_confirm dialog → on yes → calls remote_kernel_unpin
  Verify: each destructive operation (pin/unpin/update/security) requires tui_confirm "yes"
  Verify: read-only operations (status) do NOT require confirmation
```

**WiFi/Driver submenu** (tui_menu, destructive with confirm):
```
Line 1126: choice=$(tui_menu "WiFi/Driver" ...)
  → Line 1131: case "$choice" in
      status) remote_driver_status ;;  # no confirm
      rebuild) if tui_confirm "Rebuild Driver" ...; then remote_driver_rebuild ...; fi ;;
      back) return ;;
  Verify: "rebuild" requires explicit confirm before calling remote function
```

**Storage submenu** (tui_menu, ERASE is destructive):
```
Line 1156: choice=$(tui_menu "Storage" ...)
  → Line 1161: case "$choice" in
      disk) remote_get_info ... ;;  # read-only, no confirm
      erase) if tui_confirm "ERASE macOS" "WARNING: This will DELETE..."; then remote_erase_macos ...; fi ;;
  Verify: "erase" shows explicit warning in tui_confirm, user must type "yes" to proceed
```

**Password input flow** (tui_password → validation):
```
prompt_config: tui_password "Password" "Enter password for $USERNAME:"
  → returns: password string (raw, may be empty)
  → prompt_config: if [ -z "$PASS" ]; then tui_password "Confirm Password" ...; fi
  → if [ "$PASS" != "$CONFIRM" ]; then echo "[FATAL] Passwords do not match" ...; fi
  Verify: password mismatch → FATAL, does not continue
  Verify: password match → proceeds to next step (SSH config)
```

**Tracing requirements** — for each flow pathway:
1. List all TUI functions called in order
2. List all expected return types (tag string, boolean via tui_confirm, string via tui_input, password via tui_password)
3. List all conditional branches (case statements, if statements)
4. For each branch, document the final resolved behavior (what actually happens)
5. Flag any pathway where: the return type doesn't match the caller's expectation, or the branch logic seems wrong

**Automated trace** (grep + sed):
```bash
# Extract all tui_* calls and their immediate context
grep -n 'tui_menu\|tui_confirm\|tui_input\|tui_password\|tui_checklist\|tui_msgbox' prepare-deployment.sh | \
  grep -A3 '$(tui_menu\||| tui_confirm\|if.*tui_confirm\|tui_input\|tui_password\|tui_checklist'

# For each tui_menu call, verify the returned tag is used in a case statement with matching values
```

**Key invariants to verify for every flow**:
- Menu tag values in `tui_menu` calls match the `case` statements that consume them
- All destructive operations (APFS resize, ESP create, kernel pin/unpin/update, macOS erase) are gated by `tui_confirm`
- All tui_menu callers capture output as `choice=$(tui_menu ...)` — NOT as `if tui_menu ...`
- All tui_confirm callers use it as `if tui_confirm ...` or `||` — NOT capturing output
- tui_input and tui_password results are checked for emptiness before use
- Back/exit choices always return from the function or exit the script, never fall through

---

## PHASE 3: INTEGRATION AND SYSTEM TESTING

### 3.1 Script Interaction Testing
Test scripts calling other scripts:
- prepare-deployment.sh calls build-iso.sh via menu_build_iso
- prepare-deployment.sh sources all lib/*.sh files
- macpro-monitor/start.sh starts server.js
- tests/vm/create-vm.sh and test-vm.sh

Test scripts sourcing libraries — verify sourcing order matches Phase 0.1
Test scripts using shared resources (state files, journal, ESP mount)
Test scripts in different working directories (CWD != SCRIPT_DIR)
Test scripts with relative vs absolute paths (LIB_DIR override)
Test: does build-iso.sh work when run from a different directory than its location?

### 3.2 Environment Testing
Test with minimal environment (empty ENV, no deploy.conf)
Test with missing dependencies (xorriso not installed, python3 missing)
Test with conflicting configurations (deploy.conf has WIFI_password with shell metacharacters)
Test with different shell versions (bash 3.2 which ships on macOS vs bash 5.x)
- Specifically: test arrays in tui.sh (`local -a`), `[[ ]]` vs `[ ]`, `${var,,}` vs `tr`
Test on all target platforms (macOS for build/deploy, Ubuntu for remote manage)
Test: does build-iso.sh run correctly on Linux (where `stat -f%z` becomes `stat -c%s`)?

### 3.3 Concurrency and State Testing
Test scripts running simultaneously (two deploy instances, two monitor instances)
Test scripts modifying shared state (journal file concurrent access)
Test idempotency (run prepare-deployment.sh --dry-run multiple times)
Test cleanup on interrupt (Ctrl-C) during each deployment phase
Test cleanup on SIGTERM during deployment
Verify trap handlers execute correctly in all exit scenarios
Verify: does cleanup_on_error in prepare-deployment.sh properly call rollback_from_journal or revert_changes?
Verify: does build-iso.sh's cleanup trap properly remove staging directory on failure?

### 3.4 Resource Management
Verify all temporary files are cleaned up:
- build-iso.sh staging directory ($STAGING)
- retry_diskutil stderr temp files
- retry_ssh stderr temp files
- tui.sh temp files from _tui_mktemp
- journal state files in /var/tmp/macpro-deploy*

Verify all file descriptors are closed (serial FD in logging.sh, tui temp file FDs)
Verify all background processes are terminated (macpro-monitor start/stop)
Verify all locks are released
Verify proper handling of large files (ISO extraction ~3.4GB, ESP with limited space)

---

## PHASE 4: BEST PRACTICES AND PATTERNS

### 4.1 Error Handling Audit
Verify `set -Eeuo pipefail` usage (or equivalent) in ALL scripts:
- prepare-deployment.sh: set -e, set -o pipefail, set -u
- build-iso.sh: set -e, set -o pipefail, set -u
- lib/*.sh: verify each has appropriate error handling

Check for proper error trapping: `trap 'cleanup_on_error' ERR` in prepare-deployment.sh, `trap cleanup EXIT` in build-iso.sh
Verify all external commands have error handling
Check for proper exit codes (E_SUCCESS through E_AGENT_DENIED)
Verify error messages are clear and actionable
Specific checks:
- VERIFY: `set -e` behavior with `|| die` patterns — does the script exit immediately on failure or does die() handle it?
- CHECK: In build-iso.sh, `xorriso -report_el_torito as_mkisofs` output is eval'd — is the injection check (`grep -qE '[;&|${}()]`) sufficient?
- CHECK: In rollback.sh, `journal_set` uses `eval` to reconstruct state — is this safe given the regex key validation?
- CHECK: In remote.sh, all destructive operations (kernel pin, apt sources changes) use `dry_run_exec` — are there any that don't?
- CHECK: In remote.sh, `remote_kernel_update` is interactive (uses tui_confirm) — how does this work in agent mode?
- CHECK: In remote.sh, some functions use `read -rp` for confirmation (non-TUI) while others use `tui_confirm` — is this inconsistent?

### 4.2 Safety and Security Review

#### 4.2.1 Input Validation and Sanitization
Check for proper input validation and sanitization on ALL user-facing inputs
Verify no unsafe use of eval or source with user input
Trace every tui_input / tui_password / deploy.conf value from entry point to execution
Verify user-supplied values (SSID, password, ISO path, device path) are quoted in every command they reach
Check for proper quoting of ALL variable expansions — every `"$VAR"` must be quoted, every unquoted `$VAR` is a finding
Test every user input field with shell metacharacters: `; | & $ \` ' " \n \t` space and Unicode
Test every user input field with YAML metacharacters: `: - [ ] { } & * ! % @ \``
Test every user input field with path traversal: `../` `/etc/passwd` `/dev/sda`

#### 4.2.2 Credential and Secret Handling
Trace every path where credentials appear: deploy.conf → autoinstall.yaml → netplan → ESP
Verify WiFi SSID and password are NEVER written to log files
Verify WiFi password is never visible in process args (ps output)
Verify SSH_AUTHORIZED_KEYS are not logged
Verify deploy.conf permissions (should be 600, not world-readable)
Verify autoinstall.yaml on ESP is not world-readable (note: FAT32 limitation)
Check if any error message or debug output leaks credential values
Audit all printf/echo/log statements that reference variables containing secrets
Verify gitignore covers deploy.conf and any other files containing credentials
Check that --wifi-password flag value is not visible in process listing (/proc/cmdline, ps)
Specific checks:
- VERIFY: In autoinstall.sh, `sed -i "s#__WIFI_PASSWORD__#${escaped_password}#g"` — is the escaping sufficient? What if password contains `#` or `/`?
- VERIFY: In autoinstall.sh, SSH_KEYS are split by newline and inserted into YAML — are special characters in SSH keys handled?
- CHECK: Does `log()` or `log_info()` ever log WIFI_SSID or WIFI_PASSWORD values?
- CHECK: Does `agent_output()` ever include credential values in its JSON output?
- CHECK: In save_config(), WIFI_PASSWORD is written in plaintext — verify chmod 600 is applied after

#### 4.2.3 Command Injection Attack Surface
This script runs as root (sudo). Any path from user input to command execution is root-level code execution.
Map every path from user-controlled input to shell command execution
Check: do any user inputs reach diskutil, xorriso, dd, sgdisk, newfs_msdos without proper quoting?
Check: does eval usage (e.g., return-by-name pattern in disk.sh deploy.sh detect.sh) allow injection through variable values?
Check: can any deploy.conf value break out of its intended context?
Check: are autoinstall.yaml early-commands and late-commands properly escaped when they contain variable interpolation?
Verify: every command constructed with user input uses proper quoting or array form
Specific checks:
- TRACE: WIFI_SSID from deploy.conf → exported → used in autoinstall.sh sed replacement → embedded in YAML early-commands → executed by sh -c in installer
- TRACE: USB device path from select_usb_device → diskutil, sgdisk commands in disk.sh deploy.sh — is it properly quoted?
- TRACE: ISO path from detect_iso → xorriso command — is it properly quoted?
- CHECK: In autoinstall.sh, python3 -c blocks receive $OUTPUT_PATH — is this safe from injection?
- CHECK: In remote.sh, remote__exec constructs SSH commands — are all arguments properly quoted for the remote shell?

#### 4.2.4 YAML Injection
User-controlled SSID and password get string-replaced into autoinstall.yaml
Test: can special characters in SSID/password break YAML parsing or inject arbitrary keys?
Test: can a SSID like 'sshd: enabled' inject YAML keys?
Test: can a password containing a colon or newline break the autoinstall structure?
Verify: the autoinstall generation properly escapes or quotes all user-controlled values
Check: does the YAML generation use printf with proper quoting, or does it use heredocs that might allow expansion?
Verify: netplan YAML generation (inside autoinstall early-commands) properly escapes SSID/password
Specific checks:
- VERIFY: generate_autoinstall() uses sed for placeholder replacement — test with SSID containing `#`, `/`, `&`, `\`
- VERIFY: The `generate_dualboot_storage()` Python script uses subprocess.run with sgdisk — is disk_dev properly validated before passing to sgdisk?
- CHECK: autoinstall.yaml early-commands are executed by `sh -c` in the installer — are all variable interpolations safe?
- CHECK: Does netplan YAML generation use `printf` (correct) or heredoc (risky — indentation inside `|` blocks adds unwanted spaces)?

#### 4.2.5 Supply Chain Integrity
The packages/ directory contains 34 .deb files installed via dpkg on the target system
Verify: are any .deb checksums or signatures validated before installation?
Document: what is the current trust model for packages/ (assumed: trusted source + git)
Check: could a malicious .deb in packages/ achieve root execution on the target?
Assess: is there a mechanism to verify package integrity (sha256sums, signatures)?
Check: are dkms-patches applied without integrity verification?
Recommend: add checksum verification for .deb files if not present
Verify: build-iso.sh checks for `.deb` file count but not integrity

#### 4.2.6 Privilege Escalation and Execution Context
Map every code path that runs as root (via sudo or in autoinstall context)
Identify all autoinstall early-commands and late-commands — these run as root in the installer
Verify: no autoinstall command downloads and executes arbitrary code from the internet
Verify: no autoinstall command exposes a network service unnecessarily
Check: does the webhook listener (macpro-monitor) accept connections from any interface? (HOST = '0.0.0.0')
Check: is the webhook URL (containing potential secrets) logged or stored insecurely?
Verify: SSH connections in remote.sh properly validate host keys (NOT StrictHostKeyChecking=no)

#### 4.2.7 TOCTOU and Race Conditions
Identify all check-then-act sequences (e.g., check disk exists → modify disk)
Check: `diskutil list` → `diskutil addPartition` — can partition layout change between calls?
Check: `diskutil info` → `diskutil apfs resizeContainer` — can container change between calls?
Check: `verify_esp_mount` → write to ESP — can ESP be unmounted between calls?
Document: which race conditions are acceptably unlikely vs which need mitigation
Check: are lock files or other serialization mechanisms used for shared resources?

#### 4.2.8 Filesystem and Permission Security
Verify: temporary files created with mktemp (not predictable paths in /tmp)
Verify: temporary directories created with safe permissions (not world-readable)
Verify: ESP mount point permissions (note: FAT32 has no Unix permissions)
Verify: journal files (.Ubuntu_Deployment/, /var/tmp/macpro-deploy-state.env) are not world-readable
Verify: log files do not contain credentials or sensitive configuration
Check: are cleanup trap handlers robust against partial state (e.g., ESP mounted but not formatted)?
Specific checks:
- VERIFY: retry_diskutil and retry_ssh use mktemp for stderr files — are they cleaned up in all paths?
- VERIFY: tui.sh _tui_mktemp uses mktemp but falls back to /tmp/tui_$$ — is this safe?
- VERIFY: rollback.sh STATE_FILE at /var/tmp/macpro-deploy-state.env — is this world-readable?
- VERIFY: build-iso.sh STAGING directory at /tmp/macpro-iso-staging or /tmp/vmtest-iso-staging — predictable path vulnerability?
- CHECK: Is /var/tmp/macpro-deploy-state.env cleaned up by journal_destroy on success?

#### 4.2.9 Network Security
Verify: SSH connections use key-based auth, not password-in-command-line
Verify: SSH config does not disable StrictHostKeyChecking
- CHECK: remote.sh uses `-o ConnectTimeout=10 -o BatchMode=yes` — verify host key verification behavior
- CHECK: Verify SSH config example in ssh/config.example uses proper key-based auth
Verify: webhook server (macpro-monitor) does not expose sensitive data without auth
- CHECK: server.js listens on 0.0.0.0 by default — accessible from any network
- CHECK: server.js has rate limiting (RATE_LIMIT_MAX_REQUESTS = 10 per second) — is this sufficient?
- CHECK: server.js sanitizes input (sanitizeString, sanitizeProgress) — test with XSS payloads
Check: can the webhook URL be used to inject false progress reports or trigger actions?
Verify: no credentials transmitted in plaintext over network (webhook is HTTP, not HTTPS)
Macpro-monitor specific security checks:
- Test: POST to /webhook with malformed JSON — does it handle gracefully or crash?
- Test: POST to /webhook with oversized body (>256KB) — is it rejected?
- Test: GET /api/progress — does it expose any sensitive data?
- Test: Can XSS be injected through webhook progress messages? (check escapeHtml usage)
- Check: ALLOWED_ORIGINS environment variable — default empty means CORS allows any origin

#### 4.2.10 Autoinstall Environment Security
Review all early-commands in autoinstall.yaml (and autoinstall-vm.yaml) for security implications
Verify: no early-command writes to locations outside the target filesystem
Verify: no early-command creates setuid binaries
Verify: no early-command modifies SSH configuration to allow root login with password
- CHECK: early-commands start SSH server with `useradd -m -s /bin/bash ubuntu` and `echo "ubuntu:ubuntu" | chpasswd` — this creates a known password!
Verify: late-commands do not leave backdoors or disable security features
Check: is UFW configuration applied in late-commands correct and restrictive?
Check: is the kernel pin mechanism (apt preferences) tamper-resistant?

### 4.3 Portability Review
Check for bashisms if POSIX compatibility required (note: scripts use bash 3.2 features, not POSIX)
**Critical distinction:** Code that runs on macOS uses bash 3.2+ and BSD tools. Code embedded in autoinstall YAML `- |` blocks runs via `sh -c` (dash) in Ubuntu's Subiquity installer — POSIX ONLY. Verify each `- |` block contains NO bashisms:
- No `[[ ]]` — use `[ ]` instead
- No arrays — use positional parameters or string iteration
- No `<<<` herestrings — use `echo "..." | command` or `printf`
- No `${var,,}` or `${var^^}` — use `tr` or `awk`
- No `local -n` namerefs — use `eval` pattern with validated variable names
- No `mapfile`/`readarray` — use `while read` loops
- No associative arrays — use flat key=value files or case statements

Verify GNU vs BSD command compatibility (macOS uses BSD, Ubuntu uses GNU):
- CHECK: `stat -f%z` in detect_iso — macOS syntax. Does this work on Linux? (Linux uses `stat -c%s`)
- CHECK: `sed -i` patterns in autoinstall.sh use both GNU (`sed -i s/.../`) and BSD (`sed -i '' s/.../`) syntax — are both covered?
- CHECK: `diskutil` is macOS-only — does remote.sh use any diskutil commands for Linux?
- CHECK: `sgdisk` usage — is it available on both macOS (via Homebrew) and Ubuntu?

Check for hardcoded paths:
- VERIFY: Are there any hardcoded absolute paths that won't work on both platforms?
- CHECK: /tmp paths in build-iso.sh, logging.sh, retry.sh — are they appropriate for both platforms?
- CHECK: /var/tmp paths in rollback.sh — are they writable on both platforms?

Verify proper shebang lines (`#!/bin/bash` on all .sh files)
Check for platform-specific code paths:
- VERIFY: Does logging.sh properly detect platform (Darwin vs Linux) for serial device paths?
- VERIFY: Does detect_iso's stat command handle both macOS and Linux?
- CHECK: Does remote.sh's SSH command construction work with both macOS and Linux SSH clients?

### 4.4 Documentation Consistency and Accuracy Review

This project maintains three documentation files with distinct audiences:
- **AGENTS.md** — For LLM agents and automated tools: architecture, constraints, code conventions, implementation details
- **README.md** — For humans: usage instructions, quick start, troubleshooting, feature descriptions
- **CHANGELOG.md** — For everyone: version-by-version record of what changed

#### 4.4.1 Delineation Enforcement
Verify each document contains its audience delineation header
Verify AGENTS.md header states: "for LLM agents and automated tools" and cross-references README.md and CHANGELOG.md
Verify README.md header states: "for humans" and cross-references AGENTS.md and CHANGELOG.md
Verify CHANGELOG.md header explains its purpose as the version history record
Verify no document contains content that belongs in another (see 4.4.2–4.4.4)

#### 4.4.2 Content Boundary Audit
AGENTS.md MUST contain (and README.md must NOT duplicate):
- Code style guidelines (naming conventions, set -e patterns, etc.)
- Module API descriptions (each lib/*.sh function signature and behavior)
- deploy.conf parsing internals (IFS behavior, KEY=VALUE split semantics)
- Key Constraints section (hardware limitations, platform quirks)
- Context Management Rules (memory, context reduction, session notes)
- YAML generation internals (string replacement vs yaml.dump, block scalar handling)
- DKMS Patch Architecture (install order, symlink behavior, patch guards)
- Kernel Update Process internals (7-phase function, rollback function, apt preferences internals, DKMS circular dependency)
- macOS Erasure internals (partition classification rules, sgdisk commands, GRUB update commands, rollback function)
- Agent Operations Reference (exact --operation flag mappings, function names, destructive flags)

README.md MUST contain (and AGENTS.md must NOT duplicate):
- Quick Start guide
- Prerequisites and installation commands (brew install ...)
- Troubleshooting section
- Monitoring stages table (human-readable progress descriptions)
- Risk assessment and mitigations section
- Switching between macOS and Ubuntu table
- Serial console instructions
- VM test environment usage
- Updating the System (Kernel Updates) — step-by-step commands, pre-update checklist, rollback procedures
- Erasing macOS and Expanding to Full Disk — step-by-step commands, danger warnings, partition classification

CHANGELOG.md MUST contain (and neither other doc should duplicate):
- Version-by-version change lists
- What was added/changed/fixed in each release
- Corresponding git tag for each entry

BOTH documents should contain (with appropriate framing for their audience):
- Deployment method descriptions (README: how to use, AGENTS: method codes, phase names, internals)
- Agent mode CLI flags (README: usage examples, AGENTS: flag implementation details)
- Exit codes (README: table with meanings, AGENTS: constant names and values)
- deploy.conf keys (README: what each key means, AGENTS: parsing behavior, encryption modes)
- Kernel update process (README: step-by-step commands, AGENTS: function internals, phase names, rollback logic)
- macOS erasure (README: step-by-step commands and warnings, AGENTS: partition classification rules, agent prompt template)

#### 4.4.3 Accuracy Verification
Verify AGENTS.md project structure tree matches actual filesystem (`ls -R`)
Verify AGENTS.md lib/*.sh descriptions match actual function signatures
Verify AGENTS.md Key Constraints are still accurate (no stale hardware assumptions)
Verify README.md deployment method numbers match --method flag values (1=ESP, 2=USB, 3=manual, 4=VM)
Verify README.md --help output matches actual prepare-deployment.sh --help output
Verify README.md agent mode operations table matches actual _AGENT_OPERATIONS in code
Verify deploy.conf.example documents ALL keys that parse_conf() accepts
Verify Exit code documentation in --help matches E_* constants in dryrun.sh
Verify DKMS patch instructions in AGENTS.md match actual patches in packages/dkms-patches/
Verify AGENTS.md Kernel Update and macOS Erasure sections cover all manage mode operations from lib/remote.sh
Verify AGENTS.md agent operations table has NO phantom operations (driver_status, driver_rebuild, erase_macos, apt_enable, apt_disable — these functions DO NOT EXIST)
Verify AGENTS.md agent operations table includes health_check and rollback_status (these exist but may be missing)
Verify documentation does NOT reference --build-iso flag (it does not exist; use `sudo ./lib/build-iso.sh` directly)
Verify documentation does NOT reference How-to-Update.md or Post-Install.md (they have been deleted; content is in AGENTS.md and README.md)
Verify README.md kernel update phase count matches code (7 phases in remote_kernel_update, not 8)
Verify README.md macOS erasure step count matches code (6 steps, not 7)
Verify CHANGELOG.md version tags correspond to actual git tags (`git tag --list`)
Verify CHANGELOG.md entries match commit messages at each tag (`git log -1 <tag>`)

#### 4.4.4 Stale Content Detection
Scan all documentation for references to removed/renamed files, functions, or variables
Check for documentation describing features that no longer exist
Check for documentation referencing old default values
Check for TODO/FIXME/NOTE/HACK markers that should be resolved or documented
Verify no documentation references bug fixes or changes — those belong in CHANGELOG.md
Verify no documentation contains version-specific deltas — those belong in CHANGELOG.md
Verify vm-test/ section in AGENTS.md reflects that vm-test/ is superseded by --vm flag
Check for references to deleted files (How-to-Update.md, Post-Install.md — content moved to AGENTS.md/README.md)
Check for agent operations that reference nonexistent functions (driver_status → remote_driver_status, driver_rebuild → remote_driver_rebuild, erase_macos → remote_erase_macos, apt_enable → remote_apt_enable, apt_disable → remote_apt_disable)
Check for references to --build-iso flag (does not exist — ISO is built via `sudo ./lib/build-iso.sh`)

---

## PHASE 5: EXECUTION AND VALIDATION

**SAFETY BOUNDARIES** — classify every testable unit before execution:
- **SAFE** (run on development Mac): syntax checks, --help, --dry-run, read-only operations, Node.js monitor
- **DESTRUCTIVE** (only via --dry-run flag or in VirtualBox): disk partitioning, APFS resize, format, dd, USB writes
- **REMOTE-ONLY** (requires ssh access to target): all lib/remote.sh operations, manage mode
- **VM-REQUIRED**: deploy_vm_test, VirtualBox operations

### 5.1 Deployment Path Testing
For EACH deployment method, test the complete flow in dry-run mode:

METHOD 1: Internal Partition (ESP)
- prepare-deployment.sh --agent --dry-run --method 1 --storage 1 --network 1 --yes --json
- prepare-deployment.sh --agent --dry-run --method 1 --storage 2 --network 1 --yes --json
- prepare-deployment.sh --agent --dry-run --method 1 --storage 1 --network 2 --yes --json
- prepare-deployment.sh --agent --dry-run --method 1 --storage 2 --network 2 --yes --json
- Verify: all phases (analyze → shrink_apfs → create_esp → extract_iso → copy_pkgs → generate_config → verify_bless) are walked in dry-run
- Verify: generate_autoinstall produces valid YAML for each storage/network combination
- Verify: generate_dualboot_storage produces valid YAML with preserve:true entries for dual-boot

METHOD 2: USB
- prepare-deployment.sh --agent --dry-run --method 2 --storage 1 --network 1 --yes --json
- Verify: all phases (detect_usb → partition_usb → extract_iso_usb → copy_pkgs_usb → generate_config_usb → verify_usb) are walked
- Verify: USB device selection works in agent mode (auto-selects first device)

METHOD 3: Full Manual
- prepare-deployment.sh --agent --dry-run --method 3 --yes --json
- Verify: prompts for ISO path and USB device, creates standard Ubuntu USB

METHOD 4: VM Test
- prepare-deployment.sh --agent --dry-run --method 4 --vm --yes --json
- Verify: all phases (check_vbox → find_iso → build_iso → create_vm → start_monitor) are walked
- Verify: VM-specific autoinstall is used (autoinstall-vm.yaml)

Build ISO
- prepare-deployment.sh --agent --build-iso --dry-run --json
- Verify: ISO build steps are walked in dry-run

Manage Mode Operations
- prepare-deployment.sh --agent --operation kernel_status --host macpro-linux --json
- prepare-deployment.sh --agent --operation sysinfo --host macpro-linux --json
- prepare-deployment.sh --agent --operation driver_status --host macpro-linux --json
- (These are remote-only, will fail without target — verify error handling)

Revert
- prepare-deployment.sh --revert (requires prior failed deployment state)

### 5.2 Failure Mode Testing
For each deployment path, inject failures at critical points:
- METHOD 1: What happens if APFS resize fails mid-operation? Does rollback restore original size?
- METHOD 1: What happens if ESP creation succeeds but ISO extraction fails? Does cleanup remove the ESP partition?
- METHOD 2: What happens if USB partition creation succeeds but ISO extraction to USB fails?
- METHOD 4: What happens if VM creation succeeds but ISO copy fails?

Test recovery mechanisms:
- journal_init should detect and offer to resume from previous incomplete state
- rollback_from_journal should properly roll back based on recorded phase
- handle_phase_failure should collect error context and offer recovery instructions

Verify rollback works correctly for each deployment method (rollback_internal, rollback_usb, rollback_vm)
Test cleanup on failure:
- SIGINT during deploy: does cleanup_on_error fire? Does it call rollback?
- SIGTERM during deploy: same test
- Verify trap handlers in prepare-deployment.sh and build-iso.sh

Verify logs/reports are accurate after failure:
- STATE_FILE should contain last completed phase
- ERROR_REPORT_FILE should contain system state at failure point
- collect_error_context should gather disk, mount, SIP, FileVault info

### 5.3 Node.js Monitor Testing
Test macpro-monitor/server.js independently:
- Start server: `node server.js`
- POST /webhook with valid JSON progress event
- POST /webhook with built-in Subiquity event format
- GET / to verify HTML dashboard renders
- GET /api/progress to verify JSON API
- Test rate limiting: send >10 requests/second from same IP
- Test CORS headers: verify Access-Control-Allow-Origin
- Test XSS prevention: POST with `<script>alert(1)</script>` in message field
- Test stall detection: start with progress, wait >5 minutes, verify STALLED state
- Test graceful shutdown: SIGTERM, verify server closes and saves state
- Test persistence: start server, POST events, restart server, verify events are loaded from logs/progress.json
- Test WebSocket refresh: verify dashboard auto-refreshes every 3 seconds
- Test body size limit: POST >256KB, verify 413 response

### 5.4 VM Test Execution
Build VM test ISO: `cd vm-test && sudo ./build-iso-vm.sh`
Create VM: `cd vm-test && sudo ./create-vm.sh`
Run VM test: `./test-vm.sh` (monitors VM serial console for DKMS compilation success/failure)
Verify serial log at `/tmp/vmtest-serial.log` contains expected progress stages
Verify webhook events received by macpro-monitor during VM test
Verify autoinstall-vm.yaml produces valid YAML (per Phase 1.6 validation)
Verify VM test completes all DKMS compilation and driver installation phases
Verify VM test Ethernet networking works (enp0s3)
Verify VM test WiFi driver compilation succeeds (non-fatal — no Broadcom HW in VM)
Clean up: `./create-vm.sh --force` to remove VM for next test

### 5.5 Logging Verification
Verify multi-target logging writes to all configured targets:
- Verify `log_init` creates log directory and sets up webhook connection
- Verify log levels work correctly: DEBUG only to file, INFO/WARN/ERROR to all targets
- Verify serial FD is opened and written to on Linux (logging.sh detects platform)
- Verify webhook POST failure does not block or crash the main script
- Verify `log_shutdown` flushes all targets and closes file descriptors
- Verify log files contain timestamps, severity levels, and module context
- Verify serial console output includes all webhook progress stages (per AGENTS.md workflow)

---

## ITERATIVE FIX AND TEST CYCLE

Process findings in severity order: P0 first, then P1, then P2, then P3.
Within each severity level, fix bugs one at a time, **except when a single root cause affects multiple files** — in that case, fix all affected files in one commit with a clear commit message listing all files changed. Then re-run all phases. Do not fix one file, test, fix the next file, test — this wastes regression cycles on what is logically one change.

For each bug:
1. **Fix Implementation**
   Document the bug in detail
   Identify root cause
   Implement minimal, focused fix
   Add comments explaining the fix if non-obvious

2. **Full Regression Testing**
   After ANY code change, re-run ALL phases from the beginning:
   - Phase 0: Re-verify architecture model is still accurate
   - Phase 1: Re-run all static analysis
   - Phase 2: Re-run all functional tests
   - Phase 3: Re-run all integration tests
   - Phase 4: Re-run all best practices checks
   - Phase 5: Re-run all execution tests
   Document any NEW findings introduced by the fix

3. **Version Control and Documentation**
   When all phases pass for a fix:
   Query current version: `git tag --list 'v0.2.*' | sort -V | tail -1`
   Append CHANGELOG.md entry under next version:
     ```
     ### v0.2.X — [brief description]
     - fix: [specific change]
     - fix: [specific change]
     ```
   Stage changes: `git add -A`
   Commit with descriptive message:
     ```
     fix: [brief description]

     - Fixed [specific issue]
     - Root cause: [explanation]
     - Verified by: [phases re-run]
     ```
   Tag with next version: `git tag -a v0.2.X -m "fix: [brief description]"`
   Push: `git push && git push --tags`

### Continue Until
- ALL phases pass with zero P0, P1, P2 findings
- P3 findings are documented (fix if trivial, document if not)
- ShellCheck reports zero errors (warnings acceptable if covered by .shellcheckrc)
- Scripts execute correctly in all tested environments within safety boundaries
- Documentation reflects current reality

---

## REPORTING REQUIREMENTS

After each phase, provide:

- **Findings:** Complete list of all issues discovered
- **Severity:** P0/P1/P2/P3 classification for each finding
- **Impact:** What breaks and for whom
- **Evidence:** Logs, output, or reproduction steps
- **Root Cause:** Why this happens (especially for cross-module issues found via Phase 0)
- **Fix Applied:** What was changed and why
- **Verification:** How the fix was validated and which phases were re-run
- **Next Steps:** What needs to be checked next

### Phase Pass Criteria
- **Phase 0 PASS:** Architecture model is complete, all collisions documented, no P0 issues blocking further testing
- **Phase 1 PASS:** Zero P0 findings, zero P1 findings, all P2/P3 findings documented
- **Phase 2 PASS:** All deployment methods produce correct output in dry-run mode, no P0/P1 findings
- **Phase 3 PASS:** No P0/P1 findings, all safety boundary classifications verified
- **Phase 4 PASS:** No P0/P1 security findings, no P0/P1 accuracy findings
- **Phase 5 PASS:** All SAFE-classified tests pass, VM test completes with DKMS success

---

## FINAL CHECKLIST

Before completion, verify:

- [ ] All scripts pass `bash -n` syntax check
- [ ] All scripts pass ShellCheck with zero errors
- [ ] All command-line flags tested individually and in combination
- [ ] All execution modes tested (dry-run, verbose, agent, json)
- [ ] All 4 deployment methods tested in dry-run mode (method 1/2/3/4 × storage 1/2 × network 1/2)
- [ ] All manage mode operations tested
- [ ] Build ISO path tested
- [ ] Revert path tested
- [ ] All readonly/export variable collisions resolved
- [ ] All guard variables present and effective
- [ ] All lib modules source-compatible with main script's declarations
- [ ] Dry-run mode produces zero side effects for all deployment methods
- [ ] All error paths tested with proper messages and exit codes
- [ ] All dependencies documented and verified
- [ ] All temporary resources properly cleaned up
- [ ] All exit codes match documentation
- [ ] All integration scenarios tested
- [ ] Architecture model (Phase 0) still accurate after all fixes
- [ ] All commits properly tagged on v0.2.* sequence and pushed
- [ ] No credentials leaked in logs, error messages, or process args
- [ ] All user inputs validated and quoted in every execution path
- [ ] deploy.conf permissions are 600 (not world-readable)
- [ ] YAML injection tested — SSID/password cannot break autoinstall structure
- [ ] Command injection tested — no user input reaches shell execution unquoted
- [ ] SSH connections validate host keys (no StrictHostKeyChecking=no in production)
- [ ] Autoinstall early/late-commands reviewed — no backdoors or unsafe downloads
- [ ] Webhook server does not expose sensitive data without authentication
- [ ] Supply chain: .deb integrity verification mechanism documented or implemented
- [ ] TOCTOU race conditions identified and mitigated where feasible
- [ ] Node.js monitor tested — XSS, rate limiting, body size, persistence
- [ ] macpro-monitor CORS and security headers verified
- [ ] Server.js stall detection and graceful shutdown verified
- [ ] VM test executed and DKMS compilation verified
- [ ] Multi-target logging verified (serial + file + webhook)
- [ ] Journal state machine tested (init, set, destroy, rollback, crash recovery)
- [ ] Config round-trip tested (parse_conf → save_config → parse_conf)
- [ ] WiFi connectivity circuit breaker tested
- [ ] Autoinstall YAML validated against Subiquity schema for all method/storage/network combinations
- [ ] Every autoinstall YAML `- |` block verified POSIX-only (no bashisms)
- [ ] AGENTS.md has LLM audience delineation header with cross-references
- [ ] README.md has human audience delineation header with cross-references
- [ ] CHANGELOG.md exists and covers all tagged versions
- [ ] No bug fix histories or change logs in AGENTS.md or README.md
- [ ] AGENTS.md project structure tree matches actual filesystem
- [ ] README.md --method values match actual code implementation
- [ ] deploy.conf.example documents all parse_conf() keys
- [ ] Documentation accuracy verified against actual code behavior