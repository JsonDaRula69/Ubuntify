# Changelog

All notable changes to the Mac Pro 2013 Ubuntu Autoinstall project are documented in this file. Each version corresponds to a git tag. For the full commit history, see `git log`.

## v0.2.x — TUI Architecture, Agent Mode, and Config System

### v0.2.39 — Enhance TESTING_PROMPT.md with TUI audit and flow tracing
- docs: add 1.1.1 TUI raw fallback audit (contamination, variable scope, /dev/tty, return types)
- docs: add 2.8 TUI interactive prompt testing section
- docs: add 2.9 option selection flow pathway tracing section

### v0.2.38 — Fix tui_checklist raw TUI missing /dev/tty
- fix: tui_checklist raw fallback read from stdin instead of /dev/tty

### v0.2.37 — Fix tui_menu raw TUI shows numbered menu options
- fix: tui_menu raw TUI fallback now displays numbered menu options (was showing confirmation dialog)

### v0.2.35 — Fix tui_menu raw TUI unbound variable crash
- fix: tui_menu raw TUI fallback used undefined `$message` instead of `$description` (set -u caused crash)

### v0.2.34 — Testing protocol cycle, version bump, agent sudo fix
- fix: cleanup_on_error skips rollback for agent remote operations (sysinfo, kernel_status, health_check, etc. — no disk state modified, rollback irrelevant)
- fix: update hardcoded version strings from v0.2.24 to v0.2.33 in prepare-deployment.sh
- docs: add --verbose and --output-dir to AGENTS.md flags line, add missing manage operations to README.md
- test: Phase 0-5 complete (80 unit tests pass, all scripts bash -n, YAML validates, autodocs consistent, agent operations match code)

### v0.2.32 — TUI stdin fixes, sudo enforcement, progress indicators
- fix: tui.sh raw TUI branches read from /dev/tty (fixes heredoc stdin pollution), write prompts to stderr, interpret \n escapes. Restore accidentally-deleted tui_confirm function
- fix: enforce sudo for TTY mode only; allow agent remote operations without sudo
- fix: skip prompt_config for agent --operation (remote ops need no local config)
- fix: strip __REPLACE__ placeholders from deploy.conf.example on first run (prevents misleading 'SSH keys already configured' message)
- fix: disable macOS serial device detection in logging.sh (was blocking on /dev/ttys* open calls)
- feat: add [....]/[ OK ]/[FAIL] progress messages to ISO extraction, package copy, and build phases for raw TUI visibility
- test: 80 unit tests pass, all scripts pass bash -n, YAML validates, POSIX compliance verified

### v0.2.13 — Config system, template engine, and runtime output dir
- feat: config file system with encryption (plaintext, aes256, keychain)
- feat: template engine for deploy.conf generation with interactive prompts
- feat: configurable runtime output directory (`OUTPUT_DIR`, `--output-dir`)
- feat: `deploy.conf.example` template for first-run setup

### v0.2.12 — Project cleanup and documentation alignment
- chore: project cleanup, stale reference removal
- docs: documentation alignment across AGENTS.md and README.md

### v0.2.11 — Dry-run mode, agent mode, and LLM interface
- feat: dry-run mode (`DRY_RUN=1`, `--dry-run`) — wraps destructive commands, prints what would run
- feat: agent mode (`--agent`, `--yes`, `--json`) — non-interactive CLI for LLM agents
- feat: NDJSON output format for machine-readable progress
- feat: exit code constants (E_SUCCESS through E_AGENT_DENIED)
- feat: `agent_output`, `agent_error`, `agent_confirm` helpers in dryrun.sh
- feat: TUI bypass in agent mode — all menus/prompts emit JSON instead

### v0.2.10 — Trap and signal handling fixes
- fix: double `log_shutdown` from signal traps
- fix: BOOT_PARAMS regex in build-iso.sh allowing safe eval
- fix: state file override path for rollback

### v0.2.9 — Cross-module robustness fixes
- fix: `retry_diskutil` double-command invocation
- fix: bless/sgdisk using wrong `dry_run_exec` wrapper
- fix: `journal --list` command
- fix: awk injection potential in progress tracking
- fix: bash 3.2 `${var^^}` incompatibility (use `tr` instead)
- fix: duplicate `log()` function between build-iso.sh and logging.sh

### v0.2.8 — Version alignment
- chore: fix version tag alignment

### v0.2.7 — Rollback integration
- feat: integrate rollback modules into main script
- feat: add Revert mode to TUI
- feat: `prepare-deployment.sh --revert` for undoing failed deployments

### v0.2.6 — Phase checkpoints and rollback
- feat: phase checkpointed deployment with journal state
- feat: journal-aware rollback engine
- feat: SSH retry with exponential backoff
- feat: kernel update savepoints for driver rebuilds

### v0.2.5 — Rollback module
- feat: `lib/rollback.sh` — state journal, phase tracking, and rollback engine
- feat: `run_phased` function for checkpointed execution
- feat: `journal_init`, `journal_set`, `journal_get`, `journal_destroy`

### v0.2.4 — Error handling and verification
- feat: `lib/retry.sh` — exponential backoff retry wrappers (diskutil, ssh, xorriso)
- feat: `lib/verify.sh` — post-operation verification with self-healing
- feat: `verify_esp_mount`, `verify_iso_extraction`, `verify_yaml_syntax`

### v0.2.3 — Bash 3.2 compatibility
- fix: replace `local -n` namerefs with `eval` for Bash 3.2 (macOS) compatibility
- fix: return-by-name pattern using `eval` with variable name parameters

### v0.2.2 — Deep code review fixes
- fix: data loss bug in APFS resize (missing size validation)
- fix: trap quoting allowing shell expansion in error handlers
- fix: APFS revert using original size from journal
- fix: bless exit codes not propagating correctly

### v0.2.1 — Oracle review fixes
- fix: security — input validation and quoting
- fix: compatibility — cross-platform stat, sed syntax
- fix: robustness — error path handling, cleanup on failure

### v0.2.0 — TUI architecture and remote management
- feat: TUI architecture (dialog > whiptail > raw bash fallback)
- feat: Remote management mode for SSH operations
- feat: Multi-target logging (serial + file + webhook)
- feat: `lib/tui.sh` — menu, confirm, input, password, progress, tailbox
- feat: `lib/logging.sh` — multi-target logger with level control
- feat: `lib/remote.sh` — SSH management (kernel, driver, disk, APT, reboot)
- feat: `lib/disk.sh` — disk analysis, APFS resize, ESP creation
- feat: `macpro-monitor/` — Node.js webhook server with 3-pane dashboard

## v0.1.x — CLI Flags, Modularization, and Hardening

### v0.1.9 — Color centralization and script hardening
- refactor: centralize color constants into `lib/colors.sh` with guard
- fix: eval guard for unsafe variable expansion
- fix: harden script flags (set -u, set -o pipefail)
- fix: stderr redirect bugs (2>1 → 2>&1) across all scripts
- fix: sed delimiter for WiFi credentials containing `/`
- fix: remove duplicate revert handler
- fix: hardcoded paths + body accumulation + graceful shutdown + CORS in monitor

### v0.1.8 — Documentation update
- docs: update AGENTS.md with lib/ structure, deploy.conf, dry-run docs

### v0.1.7 — Cleanup
- fix: final stale reference cleanup

### v0.1.6 — CLI flags and configuration
- feat: CLI flags for all deployment options
- feat: WiFi credentials externalization via deploy.conf
- feat: `deploy.conf` runtime configuration file
- feat: `deploy.conf.example` template

### v0.1.5 — Modularization
- refactor: modularize `prepare-deployment.sh` into `lib/` directory
- feat: separate modules for disk, detect, autoinstall, bless, deploy, revert

### v0.1.4 — Netplan reliability
- fix: netplan generate/apply now fatal with retry in early-commands

### v0.1.3 — Cleanup
- fix: stale refs, dead files, network section clarity

### v0.1.2 — Script hardening
- fix: deploy script hardening — set -u, local, USB validation

### v0.1.1 — VM safety
- fix: VM kernel params + production safety nets

### v0.1.0 — Documentation
- docs: comprehensive AGENTS.md and README.md update
- feat: VM test as deployment method 4

## v0.0.x — Initial Development

102 iterations of rapid development from initial concept to working deployment tool.

### v0.0.99–v0.0.102 — Interactive menu and VM test
- feat: restructure deployment script with interactive menu
- feat: VM test as method 4 for autoinstall validation
- fix: rework bless methods + NVRAM delete approach
- fix: blacklist all 4 conflicting WiFi drivers + serial console

### v0.0.90–v0.0.98 — Bless and boot reliability
- fix: 3-tier bless fallback with IOKit registration
- fix: bless --file required on FAT32
- fix: sgdisk disk lock — try raw device, graceful fallback
- fix: EFI partition type set correctly for bless

### v0.0.70–v0.0.89 — APFS resize and partitioning
- fix: auto-calculate APFS shrink target from actual usage
- fix: ESP creation with correct GPT type via diskutil addPartition
- fix: APFS container detection for resize
- fix: remove leftover CIDATA ESP before creating new one
- fix: find ESP by volume name, not tracked device number

### v0.0.60–v0.0.69 — VM-tested critical fixes
- fix: VM-tested critical fixes — cc1 compiler, kernel pins, netplan match, printf quoting
- fix: dpkg --skip-same-version, gcc-13 13.3.0 match to ISO kernel
- fix: DKMS patches rewritten for Ubuntu source tree

### v0.0.50–v0.0.59 — DKMS and driver architecture
- feat: 6 DKMS patches for broadcom-sta kernel 6.8+ compatibility
- fix: remove explicit dkms add calls — postinst already runs them
- fix: dynamic kernel version detection in each early-commands block
- feat: self-healing WiFi reconnect and netplan fallback

### v0.0.40–v0.0.49 — Safety and documentation
- fix: critical deployment readiness fixes
- docs: self-healing design decisions
- fix: replace eval xorriso with safe bash array
- fix: critical headless deploy safety (blockdev, ESP label, APFS init, signals)

### v0.0.20–v0.0.39 — Dual-boot architecture
- feat: switch to dual-boot deployment — preserve macOS
- feat: dynamic dual-boot storage config with sgdisk + Python
- fix: lowercase partition type GUIDs for curtin compatibility
- fix: string-based storage replacement instead of yaml.dump
- fix: macOS chainloader — GRUB cannot read APFS, use fwsetup + efibootmgr
- feat: UFW firewall on target system
- feat: firewall (ufw) before reboot

### v0.0.10–v0.0.19 — Autoinstall reliability
- fix: dynamic kernel version, fatal errors, better SSH fallback
- fix: ESP size increase (2GB → 5GB), squashfs verification
- fix: extract-repack approach for EFI boot preservation
- feat: auto-delete snapshots before APFS resize
- feat: bless verification, non-interactive reboot

### v0.0.1–v0.0.9 — Initial implementation
- feat: initial Mac Pro 2013 Ubuntu autoinstall project
- feat: headless deploy script with cidata, pre-baked GRUB
- feat: packages/ directory with WiFi driver build dependencies
- feat: minimal ISO approach — compile drivers during install from ISO pool
- fix: late-commands dpkg ordering
- fix: WiFi iface auto-detection
- fix: 3 critical autoinstall bugs

## Versioning Scheme

- **v0.0.x**: Rapid iteration during initial development (102 micro-releases)
- **v0.1.x**: CLI flags, modularization, and hardening (9 releases)
- **v0.2.x**: TUI architecture, agent mode, config system (14 releases to date)