#!/bin/bash
#
# lib/drivers.sh - Driver installation and performance optimization for Mac Pro 2013
#
# Installs and configures drivers for all Mac Pro 2013 (MacPro6,1) hardware:
#   Phase 1: GPU (AMD FirePro D500 / Tahiti — amdgpu enablement)
#   Phase 2: Intel microcode (CPU vulnerability mitigations)
#   Phase 3: Bluetooth (Apple BCM2046B1)
#   Phase 4: Performance tuning (governor, swappiness, I/O scheduler, sysctl)
#   Phase 5: Audio (ALSA + PipeWire for Cirrus Logic CS4208 HDA)
#   Phase 6: Verification (comprehensive status check)
#
# All operations execute remotely via SSH using remote__exec / remote_toggle_apt_sources.
#
# Dependencies: lib/colors.sh, lib/logging.sh, lib/dryrun.sh, lib/remote.sh
#

[ "${_DRIVERS_SH_SOURCED:-0}" -eq 1 ] && return 0
_DRIVERS_SH_SOURCED=1

source "${LIB_DIR:-./lib}/colors.sh"
source "${LIB_DIR:-./lib}/logging.sh"
source "${LIB_DIR:-./lib}/dryrun.sh"

# ---------------------------------------------------------------------------
# Phase 1: GPU Driver Stack (AMD FirePro D500 / Tahiti)
# ---------------------------------------------------------------------------

_drivers_phase_gpu() {
    local host="$1"

    log "Phase 1/6: Installing GPU driver stack..."

    dry_run_exec "Enabling apt sources for GPU packages on $host" \
        remote_toggle_apt_sources "$host" enable

    dry_run_exec "Installing Mesa Vulkan + OpenCL + firmware on $host" \
        remote__exec "$host" "sudo apt-get update -qq && sudo apt-get install -y \
            mesa-vulkan-drivers libvulkan1 libvulkan-dev \
            glslc spirv-headers spirv-tools \
            mesa-opencl-icd clinfo \
            linux-firmware linux-modules-extra-\$(uname -r)" || {
        error "GPU driver installation failed"
        remote_toggle_apt_sources "$host" disable
        return 1
    }

    dry_run_exec "Setting RADV_DEBUG workarounds in /etc/environment on $host" \
        remote__exec "$host" "grep -q '^RADV_DEBUG=' /etc/environment 2>/dev/null && \
            sudo sed -i 's/^RADV_DEBUG=.*/RADV_DEBUG=novm,syncshaders,zerovram/' /etc/environment || \
            echo 'RADV_DEBUG=novm,syncshaders,zerovram' | sudo tee -a /etc/environment"

    # Replace nomodeset amdgpu.si.modeset=0 → amdgpu.si.modeset=1 amdgpu.dpm=1
    # Add amdgpu.si_support=1 radeon.si_support=0 if absent
    local grub_needs_update=0

    # Check if GRUB drop-in overrides our settings (/etc/default/grub.d/ files
    # take precedence over /etc/default/grub when sourced by update-grub)
    local grub_dropin
    grub_dropin=$(remote__exec "$host" "ls /etc/default/grub.d/macpro.cfg 2>/dev/null && echo PRESENT || echo NONE" || echo "CHECK_FAILED")
    if [ "$grub_dropin" = "PRESENT" ]; then
        log "Disabling /etc/default/grub.d/macpro.cfg drop-in (overrides GRUB_CMDLINE_LINUX_DEFAULT)..."
        dry_run_exec "Renaming macpro.cfg drop-in on $host" \
            remote__exec "$host" "sudo mv /etc/default/grub.d/macpro.cfg /etc/default/grub.d/macpro.cfg.disabled"
        grub_needs_update=1
    fi

    # Check if GRUB needs modification
    local current_grub
    current_grub=$(remote__exec "$host" "cat /etc/default/grub" 2>/dev/null || echo "")

    # Remove nomodeset from GRUB_CMDLINE_LINUX_DEFAULT and/or GRUB_CMDLINE_LINUX
    if echo "$current_grub" | grep -q "nomodeset"; then
        log "Removing nomodeset from GRUB configuration..."
        dry_run_exec "Removing nomodeset from GRUB on $host" \
            remote__exec "$host" "sudo sed -i 's/nomodeset[[:space:]]*//g; s/[[:space:]]*nomodeset//g' /etc/default/grub"
        grub_needs_update=1
    fi

    # Replace amdgpu.si.modeset=0 with amdgpu.si.modeset=1 amdgpu.dpm=1, OR add if missing
    if echo "$current_grub" | grep -q "amdgpu.si.modeset=0"; then
        log "Updating amdgpu.si.modeset=0 → amdgpu.si.modeset=1 amdgpu.dpm=1..."
        dry_run_exec "Updating amdgpu params in GRUB on $host" \
            remote__exec "$host" "sudo sed -i 's/amdgpu.si.modeset=0/amdgpu.si.modeset=1 amdgpu.dpm=1/g' /etc/default/grub"
        grub_needs_update=1
    elif ! echo "$current_grub" | grep -q "amdgpu.si.modeset=1"; then
        # amdgpu.si.modeset=0 was removed but modeset=1 not yet added
        log "Adding amdgpu.si.modeset=1 amdgpu.dpm=1 to GRUB..."
        dry_run_exec "Adding amdgpu.modeset params to GRUB on $host" \
            remote__exec "$host" "if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then \
                sudo sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/\"$/ amdgpu.si.modeset=1 amdgpu.dpm=1\"/' /etc/default/grub; \
            else \
                sudo sed -i '/^GRUB_CMDLINE_LINUX=/ s/\"$/ amdgpu.si.modeset=1 amdgpu.dpm=1\"/' /etc/default/grub; \
            fi"
        grub_needs_update=1
    else
        log "GRUB: amdgpu.si.modeset=1 already present"
    fi

    # Add amdgpu.si_support=1 radeon.si_support=0 if not present
    if ! echo "$current_grub" | grep -q "amdgpu.si_support=1"; then
        log "Adding amdgpu.si_support=1 radeon.si_support=0 to GRUB..."
        # Append to GRUB_CMDLINE_LINUX_DEFAULT (or GRUB_CMDLINE_LINUX if no _DEFAULT)
        dry_run_exec "Adding amdgpu.si_support params to GRUB on $host" \
            remote__exec "$host" "if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then \
                sudo sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/\"$/ amdgpu.si_support=1 radeon.si_support=0\"/' /etc/default/grub; \
            else \
                sudo sed -i '/^GRUB_CMDLINE_LINUX=/ s/\"$/ amdgpu.si_support=1 radeon.si_support=0\"/' /etc/default/grub; \
            fi"
        grub_needs_update=1
    fi

    # Update GRUB if any changes were made
    if [ "$grub_needs_update" -eq 1 ]; then
        dry_run_exec "Updating GRUB on $host" \
            remote__exec "$host" "sudo update-grub"
    fi

    # Disable apt sources after package installation
    dry_run_exec "Disabling apt sources on $host" \
        remote_toggle_apt_sources "$host" disable

    # --- GPU GTT size increase (better performance for larger models) ---
    local gtt_configured
    gtt_configured=$(remote__exec "$host" "grep -c 'gttsize' /etc/modprobe.d/amdgpu-gtt.conf 2>/dev/null || echo 0")
    if [ "$gtt_configured" = "0" ]; then
        log "Setting amdgpu GTT size to 8192M..."
        dry_run_exec "Configuring amdgpu GTT size on $host" \
            remote__exec "$host" "echo 'options amdgpu gttsize=8192' | sudo tee /etc/modprobe.d/amdgpu-gtt.conf > /dev/null"
    fi

    # --- RADV_PERFTEST for Ollama GPU compute ---
    local radv_configured
    radv_configured=$(remote__exec "$host" "grep -c 'RADV_PERFTEST' /etc/systemd/system/ollama.service.d/10-radv.conf 2>/dev/null || echo 0")
    if [ "$radv_configured" = "0" ]; then
        log "Configuring RADV_PERFTEST for Ollama..."
        dry_run_exec "Creating RADV Ollama config on $host" \
            remote__exec "$host" "sudo mkdir -p /etc/systemd/system/ollama.service.d && \
                printf '[Service]\nEnvironment=\"RADV_PERFTEST=sam\"\nEnvironment=\"OLLAMA_HOST=0.0.0.0:11434\"\n' | \
                sudo tee /etc/systemd/system/ollama.service.d/10-radv.conf > /dev/null && \
                sudo systemctl daemon-reload && sudo systemctl restart ollama.service"
    fi

    log "Phase 1/6 complete: GPU drivers installed"
    agent_output "progress" "GPU Drivers" "installed" "phase" "1/6"

    return 0
}

# ---------------------------------------------------------------------------
# Phase 2: Intel Microcode
# ---------------------------------------------------------------------------

_drivers_phase_microcode() {
    local host="$1"

    log "Phase 2/6: Installing Intel microcode..."

    # apt sources should already be enabled by Phase 1 or re-enabled here
    dry_run_exec "Enabling apt sources for microcode on $host" \
        remote_toggle_apt_sources "$host" enable

    dry_run_exec "Installing intel-microcode on $host" \
        remote__exec "$host" "sudo apt-get update -qq && sudo apt-get install -y intel-microcode" || {
        error "Intel microcode installation failed"
        remote_toggle_apt_sources "$host" disable
        return 1
    }

    # Verify microcode updated (will take effect after reboot)
    local current_ucode
    current_ucode=$(remote__exec "$host" "grep -m1 'microcode' /proc/cpuinfo | awk '{print \$3}'" 2>/dev/null || echo "unknown")
    log "Current microcode revision: $current_ucode (updated version requires reboot)"

    dry_run_exec "Disabling apt sources on $host" \
        remote_toggle_apt_sources "$host" disable

    log "Phase 2/6 complete: Intel microcode installed (reboot required)"
    agent_output "progress" "Intel Microcode" "installed" "phase" "2/6"

    return 0
}

# ---------------------------------------------------------------------------
# Phase 3: Bluetooth (Apple BCM2046B1)
# ---------------------------------------------------------------------------

_drivers_phase_bluetooth() {
    local host="$1"

    log "Phase 3/6: Setting up Bluetooth..."

    dry_run_exec "Enabling apt sources for Bluetooth packages on $host" \
        remote_toggle_apt_sources "$host" enable

    # Install bluez stack
    dry_run_exec "Installing bluez + rfkill on $host" \
        remote__exec "$host" "sudo apt-get update -qq && sudo apt-get install -y bluez bluez-tools rfkill" || {
        error "Bluetooth package installation failed"
        remote_toggle_apt_sources "$host" disable
        return 1
    }

    # Add Apple BCM2046B1 device ID to btusb driver
    # Device: 05ac:828d (Apple Bluetooth Host Controller)
    local btusb_bound
    btusb_bound=$(remote__exec "$host" "ls /sys/bus/usb/drivers/btusb/ 2>/dev/null | grep -c '5-'" || echo "0")

    if [ "$btusb_bound" -eq 0 ] 2>/dev/null; then
        log "Binding Apple BCM2046B1 to btusb driver..."
        dry_run_exec "Adding Apple BCM2046B1 device ID to btusb on $host" \
            remote__exec "$host" "echo '05ac 828d' | sudo tee /sys/bus/usb/drivers/btusb/new_id 2>/dev/null || true"
    else
        log "btusb already has device bound"
    fi

    # Create udev rule for automatic binding on hotplug
    dry_run_exec "Creating btusb udev rule on $host" \
        remote__exec "$host" "echo 'ACTION==\"add\", SUBSYSTEM==\"usb\", ATTR{idVendor}==\"05ac\", ATTR{idProduct}==\"828d\", RUN+=\"/sbin/modprobe btusb\"' | sudo tee /etc/udev/rules.d/99-btusb-apple.rules > /dev/null"

    # Unblock bluetooth via rfkill
    dry_run_exec "Unblocking Bluetooth via rfkill on $host" \
        remote__exec "$host" "sudo rfkill unblock bluetooth 2>/dev/null || true; sudo rfkill unblock all 2>/dev/null || true"

    # Verify HCI device appears
    local hci_check
    hci_check=$(remote__exec "$host" "hciconfig 2>/dev/null | grep -c 'hci'" || echo "0")
    if [ "$hci_check" -ge 1 ] 2>/dev/null; then
        log "Bluetooth HCI device detected"
    else
        warn "No HCI device detected — may require reboot for btusb binding to take effect"
    fi

    dry_run_exec "Disabling apt sources on $host" \
        remote_toggle_apt_sources "$host" disable

    log "Phase 3/6 complete: Bluetooth configured"
    agent_output "progress" "Bluetooth" "configured" "phase" "3/6"

    return 0
}

# ---------------------------------------------------------------------------
# Phase 4: Performance Tuning
# ---------------------------------------------------------------------------

_drivers_phase_performance() {
    local host="$1"

    log "Phase 4/6: Applying performance tuning..."

    # --- CPU Governor ---
    log "Setting CPU governor to performance..."
    dry_run_exec "Setting CPU governor to performance on $host" \
        remote__exec "$host" "for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do \
            echo performance | sudo tee \"\$cpu\" > /dev/null; \
        done"

    # Add intel_pstate=active to GRUB (changes intel_pstate from passive to active mode)
    local current_grub_perf
    current_grub_perf=$(remote__exec "$host" "cat /etc/default/grub" 2>/dev/null || echo "")
    if ! echo "$current_grub_perf" | grep -q "intel_pstate=active"; then
        dry_run_exec "Adding intel_pstate=active to GRUB on $host" \
            remote__exec "$host" "sudo sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/\"/intel_pstate=active /' /etc/default/grub"
        remote__exec "$host" "sudo update-grub"
    fi

    # Create persistent governor service (applies performance at boot)
    local gov_svc_configured
    gov_svc_configured=$(remote__exec "$host" "systemctl is-enabled set-governor.service 2>/dev/null || echo disabled")
    if [ "$gov_svc_configured" != "enabled" ]; then
        log "Creating persistent CPU governor service..."
        dry_run_exec "Creating set-governor service on $host" \
            remote__exec "$host" "sudo tee /etc/systemd/system/set-governor.service > /dev/null << 'GOVUNIT'
[Unit]
Description=Set CPU governor to performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor > /dev/null'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
GOVUNIT
sudo systemctl daemon-reload && sudo systemctl enable set-governor.service"
    fi

    # --- Disable GRUB drop-in that overrides our settings ---
    local grub_dropin
    grub_dropin=$(remote__exec "$host" "ls /etc/default/grub.d/macpro.cfg 2>/dev/null && echo PRESENT || echo NONE" || echo "CHECK_FAILED")
    if [ "$grub_dropin" = "PRESENT" ]; then
        log "Disabling /etc/default/grub.d/macpro.cfg drop-in (overrides GRUB_CMDLINE_LINUX_DEFAULT)..."
        dry_run_exec "Renaming macpro.cfg drop-in on $host" \
            remote__exec "$host" "sudo mv /etc/default/grub.d/macpro.cfg /etc/default/grub.d/macpro.cfg.disabled"
        remote__exec "$host" "sudo update-grub"
    fi

    # --- PCIe ASPM (Active State Power Management) ---
    # Set to 'performance' to prevent GPU link power savings causing latency
    local current_aspm
    current_aspm=$(remote__exec "$host" "cat /sys/module/pcie_aspm/parameters/policy 2>/dev/null | awk '{print \$1}'" || echo "")
    if [ "$current_aspm" != "[performance]" ]; then
        log "Setting PCIe ASPM to performance..."
        dry_run_exec "Setting PCIe ASPM to performance on $host" \
            remote__exec "$host" "echo performance | sudo tee /sys/module/pcie_aspm/parameters/policy > /dev/null"
        # Add pcie_aspm=performance to GRUB if not present
        if ! echo "$current_grub_perf" | grep -q "pcie_aspm=performance"; then
            dry_run_exec "Adding pcie_aspm=performance to GRUB on $host" \
                remote__exec "$host" "sudo sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/\"/pcie_aspm=performance /' /etc/default/grub"
            remote__exec "$host" "sudo update-grub"
        fi
    fi

    # --- Transparent Hugepages ---
    local current_thp
    current_thp=$(remote__exec "$host" "cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | awk -F'[][]' '{print \$2}'" || echo "")
    if [ "$current_thp" != "always" ]; then
        log "Setting transparent hugepages to always..."
        dry_run_exec "Setting transparent hugepages on $host" \
            remote__exec "$host" "echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null"
        # Persist via tmpfiles.d
        dry_run_exec "Persisting transparent hugepages on $host" \
            remote__exec "$host" "echo 'w /sys/kernel/mm/transparent_hugepage/enabled - - - - always' | sudo tee /etc/tmpfiles.d/thp.conf > /dev/null"
    fi

    # --- fstab noatime ---
    local fstab_root
    fstab_root=$(remote__exec "$host" "grep ' / ext4' /etc/fstab" || echo "")
    if echo "$fstab_root" | grep -q "defaults"; then
        log "Setting noatime on root partition..."
        dry_run_exec "Setting noatime on root partition on $host" \
            remote__exec "$host" "sudo sed -i 's/ext4 defaults/ext4 noatime,errors=remount-ro/' /etc/fstab"
    fi

    # --- NMI watchdog (disable on headless server) ---
    dry_run_exec "Disabling NMI watchdog on $host" \
        remote__exec "$host" "echo 0 | sudo tee /proc/sys/kernel/nmi_watchdog > /dev/null"

    # --- Sysctl tuning (consolidated in 99-macpro.conf) ---
    log "Applying sysctl tuning..."
    dry_run_exec "Writing sysctl performance config on $host" \
        remote__exec "$host" "sudo tee /etc/sysctl.d/99-macpro.conf > /dev/null << 'SYSCTL'
# Mac Pro Performance Tuning
# See lib/drivers.sh _drivers_phase_performance() for all settings

# --- VM ---
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
vm.min_free_kbytes = 131072

# --- Network buffers (WiFi throughput) ---
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 8192

# --- TCP ---
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1

# --- Kernel ---
kernel.nmi_watchdog = 0
SYSCTL"

    # --- Swappiness (runtime, in case sysctl not yet applied) ---
    log "Setting vm.swappiness=10..."
    dry_run_exec "Setting swappiness to 10 on $host" \
        remote__exec "$host" "echo 10 | sudo tee /proc/sys/vm/swappiness > /dev/null"

    # --- I/O Scheduler (none for SSD) ---
    log "Setting I/O scheduler to 'none' for sda..."
    dry_run_exec "Setting I/O scheduler to none for sda on $host" \
        remote__exec "$host" "echo none | sudo tee /sys/block/sda/queue/scheduler > /dev/null"

    dry_run_exec "Creating udev rule for SSD scheduler on $host" \
        remote__exec "$host" "echo 'ACTION==\"add|change\", KERNEL==\"sda\", ATTR{queue/scheduler}=\"none\"' | sudo tee /etc/udev/rules.d/99-macpro-ssd-scheduler.rules > /dev/null"

    # --- Apply sysctl ---
    dry_run_exec "Applying sysctl settings on $host" \
        remote__exec "$host" "sudo sysctl --system > /dev/null"

    # --- Disable unnecessary services for headless server ---
    log "Disabling unnecessary services..."
    dry_run_exec "Disabling ModemManager on $host" \
        remote__exec "$host" "sudo systemctl disable --now ModemManager 2>/dev/null || true"
    dry_run_exec "Masking plymouth-quit-wait on $host" \
        remote__exec "$host" "sudo systemctl mask plymouth-quit-wait.service 2>/dev/null || true"
    dry_run_exec "Disabling cloud-init on $host" \
        remote__exec "$host" "sudo systemctl disable --now cloud-init cloud-config cloud-final cloud-init-local 2>/dev/null || true; sudo systemctl mask cloud-init 2>/dev/null || true"
    dry_run_exec "Disabling apport on $host" \
        remote__exec "$host" "sudo systemctl disable --now apport 2>/dev/null || true"
    dry_run_exec "Disabling gpu-manager on $host" \
        remote__exec "$host" "sudo systemctl disable --now gpu-manager 2>/dev/null || true"

    # --- Blacklist amdkfd (Tahiti not supported, logs cosmetic error) ---
    local amdkfd_blacklisted
    amdkfd_blacklisted=$(remote__exec "$host" "grep -c 'blacklist amdkfd' /etc/modprobe.d/amdkfd.conf 2>/dev/null || echo 0")
    if [ "$amdkfd_blacklisted" = "0" ]; then
        log "Blacklisting amdkfd (Tahiti GPU not supported)..."
        dry_run_exec "Blacklisting amdkfd on $host" \
            remote__exec "$host" "echo 'blacklist amdkfd' | sudo tee /etc/modprobe.d/amdkfd.conf > /dev/null"
    fi

    log "Phase 4/6 complete: Performance tuning applied"
    agent_output "progress" "Performance Tuning" "applied" "phase" "4/6"

    return 0
}

# ---------------------------------------------------------------------------
# Phase 5: Audio (Cirrus Logic CS4208)
# ---------------------------------------------------------------------------

_drivers_phase_audio() {
    local host="$1"

    log "Phase 5/6: Setting up audio..."

    dry_run_exec "Enabling apt sources for audio packages on $host" \
        remote_toggle_apt_sources "$host" enable

    dry_run_exec "Installing ALSA + PipeWire audio stack on $host" \
        remote__exec "$host" "sudo apt-get update -qq && sudo apt-get install -y \
            alsa-utils pipewire pipewire-pulse wireplumber" || {
        error "Audio package installation failed"
        remote_toggle_apt_sources "$host" disable
        return 1
    }

    # Verify sound card detected
    local sound_cards
    sound_cards=$(remote__exec "$host" "cat /proc/asound/cards 2>/dev/null || echo 'NO CARDS'" || echo "CHECK_FAILED")
    log "Sound cards detected:\n$sound_cards"

    if echo "$sound_cards" | grep -qi "no cards\|check_failed" 2>/dev/null; then
        warn "No sound cards detected — amdgpu HDMI audio requires reboot (Phase 1)"
    fi

    dry_run_exec "Disabling apt sources on $host" \
        remote_toggle_apt_sources "$host" disable

    log "Phase 5/6 complete: Audio packages installed"
    agent_output "progress" "Audio" "installed" "phase" "5/6"

    return 0
}

# ---------------------------------------------------------------------------
# Phase 6: Verification
# ---------------------------------------------------------------------------

_drivers_phase_verify() {
    local host="$1"

    log "Phase 6/6: Running comprehensive verification..."

    local failures=0

    # --- Verify GPU ---
    local vulkan_icd mesa_ver env_check
    vulkan_icd=$(remote__exec "$host" "ls /usr/share/vulkan/icd.d/radeon_icd.json 2>/dev/null && echo PRESENT || echo MISSING" || echo "CHECK_FAILED")
    mesa_ver=$(remote__exec "$host" "dpkg -l mesa-vulkan-drivers 2>/dev/null | grep '^ii' | awk '{print \$3}'" || echo "NOT_INSTALLED")
    env_check=$(remote__exec "$host" "grep RADV_DEBUG /etc/environment 2>/dev/null || echo NOT_SET" || echo "NOT_SET")

    if [ "$vulkan_icd" = "MISSING" ] || [ "$vulkan_icd" = "CHECK_FAILED" ]; then
        warn "Vulkan ICD: MISSING — amdgpu drivers not installed or not found"
        failures=$((failures + 1))
    else
        log "Vulkan ICD: $vulkan_icd"
    fi
    log "Mesa Vulkan version: $mesa_ver"
    log "RADV_DEBUG: $env_check"

    # Check GRUB params — also check the actual booted cmdline, not just /etc/default/grub
    local grub_params boot_cmdline
    grub_params=$(remote__exec "$host" "grep -E 'GRUB_CMDLINE_LINUX' /etc/default/grub 2>/dev/null || echo EMPTY" || echo "CHECK_FAILED")
    boot_cmdline=$(remote__exec "$host" "cat /proc/cmdline 2>/dev/null || echo EMPTY" || echo "CHECK_FAILED")

    local grub_dropin_check
    grub_dropin_check=$(remote__exec "$host" "ls /etc/default/grub.d/macpro.cfg 2>/dev/null && echo PRESENT || echo NONE" || echo "CHECK_FAILED")
    if [ "$grub_dropin_check" = "PRESENT" ]; then
        warn "GRUB: /etc/default/grub.d/macpro.cfg still present — overrides /etc/default/grub"
        failures=$((failures + 1))
    fi

    if echo "$boot_cmdline" | grep -q "nomodeset"; then
        warn "GRUB: nomodeset in booted cmdline — amdgpu will not load until next reboot"
        failures=$((failures + 1))
    elif echo "$grub_params" | grep -q "nomodeset"; then
        warn "GRUB: nomodeset still in /etc/default/grub"
        failures=$((failures + 1))
    else
        log "GRUB: nomodeset removed (good)"
    fi

    if echo "$grub_params" | grep -q "amdgpu.si.modeset=1"; then
        log "GRUB: amdgpu.si.modeset=1 present"
    else
        warn "GRUB: amdgpu.si.modeset=1 NOT found — need to update GRUB config"
        failures=$((failures + 1))
    fi

    # --- Verify Microcode ---
    local ucode_rev
    ucode_rev=$(remote__exec "$host" "grep -m1 'microcode' /proc/cpuinfo | awk '{print \$3}'" || echo "unknown")
    local ucode_installed
    ucode_installed=$(remote__exec "$host" "dpkg -l intel-microcode 2>/dev/null | grep '^ii' | awk '{print \$3}'" || echo "NOT_INSTALLED")
    log "Microcode: revision=$ucode_rev, package=$ucode_installed"
    if [ "$ucode_installed" = "NOT_INSTALLED" ]; then
        warn "Intel microcode package not installed"
        failures=$((failures + 1))
    fi

    # --- Verify Bluetooth ---
    local bt_hci
    bt_hci=$(remote__exec "$host" "hciconfig 2>/dev/null | grep -c 'hci'" || echo "0")
    local btudev
    btudev=$(remote__exec "$host" "ls /etc/udev/rules.d/99-btusb-apple.rules 2>/dev/null && echo PRESENT || echo MISSING" || echo "CHECK_FAILED")
    log "Bluetooth: hci_devices=$bt_hci, udev_rule=$btudev"
    if [ "$bt_hci" = "0" ]; then
        warn "Bluetooth: no HCI devices — may need reboot"
    fi

    # --- Verify Performance Tuning ---
    local governor swappiness scheduler pstate aspm thp noatime tcp_cc
    governor=$(remote__exec "$host" "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo UNKNOWN" || echo "CHECK_FAILED")
    pstate=$(remote__exec "$host" "cat /sys/devices/system/cpu/intel_pstate/status 2>/dev/null || echo UNKNOWN" || echo "CHECK_FAILED")
    swappiness=$(remote__exec "$host" "cat /proc/sys/vm/swappiness 2>/dev/null || echo UNKNOWN" || echo "CHECK_FAILED")
    scheduler=$(remote__exec "$host" "cat /sys/block/sda/queue/scheduler 2>/dev/null || echo UNKNOWN" || echo "CHECK_FAILED")
    aspm=$(remote__exec "$host" "cat /sys/module/pcie_aspm/parameters/policy 2>/dev/null | awk -F'[][]' '{print \$2}' || echo UNKNOWN" || echo "CHECK_FAILED")
    thp=$(remote__exec "$host" "cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | awk -F'[][]' '{print \$2}' || echo UNKNOWN" || echo "CHECK_FAILED")
    noatime=$(remote__exec "$host" "grep ' / ext4' /etc/fstab 2>/dev/null | grep -c noatime || echo 0" || echo "CHECK_FAILED")
    tcp_cc=$(remote__exec "$host" "sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo UNKNOWN" || echo "CHECK_FAILED")
    local nmi_wd
    nmi_wd=$(remote__exec "$host" "cat /proc/sys/kernel/nmi_watchdog 2>/dev/null || echo UNKNOWN" || echo "CHECK_FAILED")
    local amdkfd_bl
    amdkfd_bl=$(remote__exec "$host" "grep -c 'blacklist amdkfd' /etc/modprobe.d/amdkfd.conf 2>/dev/null || echo 0" || echo "CHECK_FAILED")
    local gtt_conf radv_conf gov_svc
    gtt_conf=$(remote__exec "$host" "grep -c 'gttsize' /etc/modprobe.d/amdgpu-gtt.conf 2>/dev/null || echo 0" || echo "CHECK_FAILED")
    radv_conf=$(remote__exec "$host" "grep -c 'RADV_PERFTEST' /etc/systemd/system/ollama.service.d/10-radv.conf 2>/dev/null || echo 0" || echo "CHECK_FAILED")
    gov_svc=$(remote__exec "$host" "systemctl is-enabled set-governor.service 2>/dev/null || echo disabled" || echo "CHECK_FAILED")

    log "CPU governor: $governor (intel_pstate: $pstate)"
    log "Swappiness: $swappiness"
    log "I/O scheduler: $scheduler"
    log "PCIe ASPM: $aspm"
    log "Transparent hugepages: $thp"
    log "fstab noatime: $noatime"
    log "TCP congestion: $tcp_cc"
    log "NMI watchdog: $nmi_wd"
    log "amdkfd blacklisted: $amdkfd_bl"

    if [ "$governor" != "performance" ] && [ "$governor" != "CHECK_FAILED" ]; then
        warn "CPU governor is '$governor' (expected 'performance')"
        failures=$((failures + 1))
    fi
    if [ "$pstate" != "active" ] && [ "$pstate" != "CHECK_FAILED" ]; then
        warn "intel_pstate is '$pstate' (expected 'active')"
        failures=$((failures + 1))
    fi
    if [ "$swappiness" != "10" ] && [ "$swappiness" != "CHECK_FAILED" ]; then
        warn "Swappiness is '$swappiness' (expected '10')"
        failures=$((failures + 1))
    fi
    if echo "$scheduler" | grep -q "\[none\]"; then
        log "I/O scheduler: none (correct)"
    elif [ "$scheduler" != "CHECK_FAILED" ]; then
        warn "I/O scheduler: $scheduler (expected '[none]')"
        failures=$((failures + 1))
    fi
    if [ "$aspm" != "performance" ] && [ "$aspm" != "CHECK_FAILED" ]; then
        warn "PCIe ASPM is '$aspm' (expected 'performance')"
        failures=$((failures + 1))
    fi
    if [ "$thp" != "always" ] && [ "$thp" != "CHECK_FAILED" ]; then
        warn "Transparent hugepages is '$thp' (expected 'always')"
        failures=$((failures + 1))
    fi
    if [ "$noatime" = "0" ] && [ "$noatime" != "CHECK_FAILED" ]; then
        warn "fstab: noatime not set on root partition"
        failures=$((failures + 1))
    fi
    if [ "$tcp_cc" != "bbr" ] && [ "$tcp_cc" != "CHECK_FAILED" ]; then
        warn "TCP congestion is '$tcp_cc' (expected 'bbr')"
        failures=$((failures + 1))
    fi
    if [ "$gtt_conf" = "0" ] && [ "$gtt_conf" != "CHECK_FAILED" ]; then
        warn "amdgpu GTT size not configured (expected gttsize=8192)"
        failures=$((failures + 1))
    fi
    if [ "$radv_conf" = "0" ] && [ "$radv_conf" != "CHECK_FAILED" ]; then
        warn "RADV_PERFTEST not set for Ollama"
        failures=$((failures + 1))
    fi
    if [ "$gov_svc" != "enabled" ] && [ "$gov_svc" != "CHECK_FAILED" ]; then
        warn "Governor service not enabled ($gov_svc)"
        failures=$((failures + 1))
    fi

    local sysctl_conf
    sysctl_conf=$(remote__exec "$host" "cat /etc/sysctl.d/99-macpro.conf 2>/dev/null || echo MISSING" || echo "MISSING")
    log "sysctl config:\n$sysctl_conf"

    # --- Verify Audio ---
    local sound_check
    sound_check=$(remote__exec "$host" "cat /proc/asound/cards 2>/dev/null | head -5 || echo NO_CARDS" || echo "CHECK_FAILED")
    log "Sound cards:\n$sound_check"

    # --- Summary ---
    echo ""
    echo "=== Driver Installation Summary ==="
    echo ""
    printf "  %-25s %-15s %s\n" "COMPONENT" "STATUS" "DETAIL"
    printf "  %-25s %-15s %s\n" "-------------------------" "---------------" "-------------------------"
    printf "  %-25s %-15s %s\n" "GPU: Vulkan ICD" "$vulkan_icd" "Mesa $mesa_ver"
    printf "  %-25s %-15s %s\n" "GPU: RADV_DEBUG" "$(echo "$env_check" | head -1)" ""
    printf "  %-25s %-15s %s\n" "GPU: GRUB params" "$(echo "$grub_params" | grep -c 'amdgpu' || echo 0) amdgpu params" ""
    printf "  %-25s %-15s %s\n" "CPU: Microcode" "$ucode_installed" "rev=$ucode_rev"
    printf "  %-25s %-15s %s\n" "Bluetooth: HCI" "$bt_hci devices" "udev: $btudev"
    printf "  %-25s %-15s %s\n" "Perf: CPU governor" "$governor" "intel_pstate: $pstate"
    printf "  %-25s %-15s %s\n" "Perf: Swappiness" "$swappiness" ""
    printf "  %-25s %-15s %s\n" "Perf: I/O scheduler" "$scheduler" ""
    printf "  %-25s %-15s %s\n" "Perf: PCIe ASPM" "$aspm" ""
    printf "  %-25s %-15s %s\n" "Perf: THP" "$thp" ""
    printf "  %-25s %-15s %s\n" "Perf: TCP congestion" "$tcp_cc" ""
    printf "  %-25s %-15s %s\n" "Perf: fstab noatime" "$noatime" ""
    printf "  %-25s %-15s %s\n" "Perf: NMI watchdog" "$nmi_wd" ""
    printf "  %-25s %-15s %s\n" "Perf: amdkfd blacklisted" "$amdkfd_bl" ""
    printf "  %-25s %-15s %s\n" "Perf: amdgpu GTT size" "$gtt_conf" "8192M expected"
    printf "  %-25s %-15s %s\n" "Perf: RADV Ollama" "$radv_conf" "sam flag"
    printf "  %-25s %-15s %s\n" "Perf: Gov. service" "$gov_svc" "enabled expected"
    printf "  %-25s %-15s %s\n" "Audio: Sound cards" "$(echo "$sound_check" | wc -l | tr -d ' ')" ""
    echo ""

    if [ "$failures" -gt 0 ]; then
        warn "Verification completed with $failures issue(s)"
        if echo "$grub_params" | grep -q "amdgpu.si.modeset=1" 2>/dev/null; then
            echo "NOTE: amdgpu and microcode changes require a reboot to take effect."
        fi
    else
        log "All verifications passed"
        echo "NOTE: amdgpu and microcode changes require a reboot to take effect."
    fi

    agent_output "result" "Driver Installation" "complete" "failures" "$failures" "phase" "6/6"

    log "Phase 6/6 complete: Verification done ($failures issue(s))"
    return "$failures"
}

# ---------------------------------------------------------------------------
# Main entry point: remote_install_drivers [HOST]
# ---------------------------------------------------------------------------

remote_install_drivers() {
    local host
    host=$(remote__get_host "${1:-}")

    log "Starting driver installation and optimization on $host..."

    agent_output "msgbox" "Driver Installation" "Installing drivers and optimizing Mac Pro 2013 hardware"

    # Phase 1: GPU
    if ! _drivers_phase_gpu "$host"; then
        error "Phase 1 (GPU) failed — aborting"
        return 1
    fi

    # Phase 2: Intel Microcode
    if ! _drivers_phase_microcode "$host"; then
        error "Phase 2 (Microcode) failed — aborting"
        return 1
    fi

    # Phase 3: Bluetooth
    if ! _drivers_phase_bluetooth "$host"; then
        warn "Phase 3 (Bluetooth) failed — continuing with remaining phases"
        # Bluetooth failure is not fatal — WiFi works via wl, not btusb
    fi

    # Phase 4: Performance Tuning
    if ! _drivers_phase_performance "$host"; then
        error "Phase 4 (Performance) failed — aborting"
        return 1
    fi

    # Phase 5: Audio
    if ! _drivers_phase_audio "$host"; then
        warn "Phase 5 (Audio) failed — continuing to verification"
        # Audio failure is not fatal — sound may require amdgpu (Phase 1) after reboot
    fi

    # Phase 6: Verification
    local verify_result
    _drivers_phase_verify "$host"
    verify_result=$?

    if [ "$verify_result" -eq 0 ]; then
        log "Driver installation completed successfully"
    else
        warn "Driver installation completed with $verify_result verification issue(s)"
    fi

    echo ""
    echo "=== Reboot Required ==="
    echo "The following changes require a reboot to take effect:"
    echo "  - amdgpu kernel module (replaces simple-framebuffer)"
    echo "  - Intel microcode update"
    echo "  - Bluetooth btusb device binding"
    echo ""
    echo "Run: sudo ./prepare-deployment.sh --agent --yes --operation reboot --host $host"
    echo ""

    return "$verify_result"
}

# ---------------------------------------------------------------------------
# Driver & Performance Status: remote_driver_status [HOST]
# ---------------------------------------------------------------------------

remote_driver_status() {
    local host
    host=$(remote__get_host "${1:-}")

    log "Checking driver and performance status on $host..."

    # --- GPU ---
    local gpu_module vulkan_icd mesa_ver radv_debug grub_params amdgpu_params
    gpu_module=$(remote__exec "$host" "lsmod | grep -c 'amdgpu'" 2>/dev/null || echo "0")
    vulkan_icd=$(remote__exec "$host" "ls /usr/share/vulkan/icd.d/radeon_icd.json 2>/dev/null && echo PRESENT || echo MISSING" || echo "CHECK_FAILED")
    mesa_ver=$(remote__exec "$host" "dpkg -l mesa-vulkan-drivers 2>/dev/null | grep '^ii' | awk '{print \$3}'" 2>/dev/null || echo "NOT_INSTALLED")
    radv_debug=$(remote__exec "$host" "grep '^RADV_DEBUG=' /etc/environment 2>/dev/null || echo NOT_SET" || echo "NOT_SET")
    grub_params=$(remote__exec "$host" "grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub 2>/dev/null || echo NOT_SET" || echo "NOT_SET")
    amdgpu_params=$(remote__exec "$host" "cat /proc/cmdline 2>/dev/null" || echo "NOT_SET")

    echo "=== GPU ==="
    echo "  amdgpu module loaded: $([ "$gpu_module" -gt 0 ] && echo YES || echo NO)"
    echo "  Vulkan ICD: $vulkan_icd"
    echo "  Mesa version: $mesa_ver"
    echo "  RADV_DEBUG: $radv_debug"
    echo "  GRUB params: $grub_params"
    echo "  Boot params: $amdgpu_params"
    echo ""

    # --- CPU ---
    local governor pstate cpu_freq_max cpu_freq_cur microcode_rev microcode_pkg
    governor=$(remote__exec "$host" "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo UNKNOWN" || echo "CHECK_FAILED")
    pstate=$(remote__exec "$host" "cat /sys/devices/system/cpu/intel_pstate/status 2>/dev/null || echo NOT_AVAILABLE" || echo "NOT_AVAILABLE")
    cpu_freq_max=$(remote__exec "$host" "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null || echo N/A" || echo "N/A")
    cpu_freq_cur=$(remote__exec "$host" "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo N/A" || echo "N/A")
    microcode_rev=$(remote__exec "$host" "grep -m1 'microcode' /proc/cpuinfo | awk '{print \$3}'" 2>/dev/null || echo "unknown")
    microcode_pkg=$(remote__exec "$host" "dpkg -l intel-microcode 2>/dev/null | grep '^ii' | awk '{print \$3}'" 2>/dev/null || echo "NOT_INSTALLED")

    echo "=== CPU ==="
    echo "  Governor: $governor"
    echo "  intel_pstate: $pstate"
    echo "  Max freq: $([ "$cpu_freq_max" != "N/A" ] && echo "$((cpu_freq_max / 1000)) MHz" || echo "N/A")"
    echo "  Cur freq: $([ "$cpu_freq_cur" != "N/A" ] && echo "$((cpu_freq_cur / 1000)) MHz" || echo "N/A")"
    echo "  Microcode: rev=$microcode_rev, pkg=$microcode_pkg"
    echo ""

    # --- Bluetooth ---
    local bt_hci bt_udev
    bt_hci=$(remote__exec "$host" "hciconfig 2>/dev/null | grep -c 'hci'" || echo "0")
    bt_udev=$(remote__exec "$host" "ls /etc/udev/rules.d/99-btusb-apple.rules 2>/dev/null && echo PRESENT || echo MISSING" || echo "CHECK_FAILED")

    echo "=== Bluetooth ==="
    echo "  HCI devices: $bt_hci"
    echo "  udev rule: $bt_udev"
    echo ""

    # --- Performance ---
    local swappiness scheduler dirty_ratio dirty_bg
    swappiness=$(remote__exec "$host" "cat /proc/sys/vm/swappiness 2>/dev/null || echo UNKNOWN" || echo "CHECK_FAILED")
    scheduler=$(remote__exec "$host" "cat /sys/block/sda/queue/scheduler 2>/dev/null || echo UNKNOWN" || echo "CHECK_FAILED")
    dirty_ratio=$(remote__exec "$host" "cat /proc/sys/vm/dirty_ratio 2>/dev/null || echo UNKNOWN" || echo "CHECK_FAILED")
    dirty_bg=$(remote__exec "$host" "cat /proc/sys/vm/dirty_background_ratio 2>/dev/null || echo UNKNOWN" || echo "CHECK_FAILED")

    echo "=== Performance ==="
    echo "  Swappiness: $swappiness"
    echo "  I/O scheduler: $scheduler"
    echo "  vm.dirty_ratio: $dirty_ratio"
    echo "  vm.dirty_background_ratio: $dirty_bg"
    echo "  sysctl config:"
    remote__exec "$host" "cat /etc/sysctl.d/99-macpro.conf 2>/dev/null || echo '  (not found)'" || true
    echo ""

    # --- Audio ---
    local sound_cards
    sound_cards=$(remote__exec "$host" "cat /proc/asound/cards 2>/dev/null || echo 'NO CARDS'" || echo "CHECK_FAILED")

    echo "=== Audio ==="
    echo "$sound_cards"
    echo ""

    # --- Kernel ---
    local kernel dkms_status
    kernel=$(remote__exec "$host" "uname -r" 2>/dev/null || echo "unknown")
    dkms_status=$(remote__exec "$host" "dkms status 2>/dev/null || echo 'DKMS not available'" || echo "CHECK_FAILED")

    echo "=== Kernel ==="
    echo "  Version: $kernel"
    echo "  DKMS: $dkms_status"
}

# ---------------------------------------------------------------------------
# Set CPU Governor: remote_set_governor GOVERNOR [HOST]
# ---------------------------------------------------------------------------

remote_set_governor() {
    local governor="$1"
    local host
    host=$(remote__get_host "${2:-}")

    if [ -z "$governor" ]; then
        error "Governor not specified"
        return 1
    fi

    local available
    available=$(remote__exec "$host" "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null" || echo "")
    if ! echo "$available" | grep -qw "$governor"; then
        error "Governor '$governor' not available. Available: $available"
        return 1
    fi

    log "Setting CPU governor to '$governor' on $host..."

    dry_run_exec "Setting CPU governor to $governor on $host" \
        remote__exec "$host" "for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do \
            echo '$governor' | sudo tee \"\$cpu\" > /dev/null; \
        done"

    local current
    current=$(remote__exec "$host" "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor" 2>/dev/null || echo "unknown")
    log "CPU governor is now: $current"

    agent_output "result" "CPU Governor" "$current" "governor" "$governor"

    if [ "$current" != "$governor" ]; then
        warn "Governor set to '$governor' but reads back as '$current'"
        return 1
    fi

    return 0
}
# ---------------------------------------------------------------------------
# Fix WiFi: remote_fix_wifi [HOST]
# Disables wl power management, fixes any broken watchdog scripts,
# and restarts the WiFi interface to clear error state.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Fix WiFi: remote_fix_wifi [HOST]
# Disables wl power management, fixes any broken watchdog scripts,
# and restarts the WiFi interface to clear error state.
# ---------------------------------------------------------------------------

remote_fix_wifi() {
    local host
    host=$(remote__get_host "${1:-}")

    log "Fixing WiFi on $host..."

    # Step 1: Disable wl power management
    log "Step 1/3: Disabling wl power management..."
    dry_run_exec "Writing wl pm=0 to modprobe.d on $host" \
        remote__exec "$host" "echo 'options wl pm=0' | sudo tee /etc/modprobe.d/wl.conf > /dev/null"

    # Step 2: Clean up any broken watchdog files from previous attempts
    log "Step 2/3: Cleaning up broken watchdog files..."
    dry_run_exec "Removing broken wifi-watchdog on $host" \
        remote__exec "$host" "sudo rm -f /usr/local/bin/wifi-watchdog.sh \
            /etc/systemd/system/wifi-watchdog.service \
            /etc/systemd/system/multi-user.target.wants/wifi-watchdog.service 2>/dev/null
            sudo systemctl daemon-reload 2>/dev/null"

    # Step 3: Reload wl module with pm=0
    log "Step 3/3: Reloading wl module..."
    dry_run_exec "Reloading wl module with pm=0 on $host" \
        remote__exec "$host" "sudo modprobe -r wl 2>/dev/null; sleep 2; sudo modprobe wl 2>/dev/null"

    # Verify WiFi is up
    local wifi_status
    wifi_status=$(remote__exec "$host" "iwconfig wlp13s0 2>/dev/null | grep -o 'ESSID:[^ ]*' || echo 'NOT CONNECTED'" 2>/dev/null || echo "CHECK_FAILED")
    log "WiFi status: $wifi_status"

    # Restart WiFi watchdog (clean version - using printf to avoid heredoc issues)
    log "Creating clean WiFi watchdog..."
    dry_run_exec "Writing wifi-watchdog script on $host" \
        remote__exec "$host" "sudo printf '%s\n' \
            '#!/bin/bash' \
            '# WiFi watchdog for BCM4360 (wl driver)' \
            'WL_IFACE=\"wlp13s0\"' \
            'GW=\"192.168.1.254\"' \
            'LOG_TAG=\"wifi-watchdog\"' \
            'CHECK_INTERVAL=60' \
            '' \
            'log() { logger -t \"$LOG_TAG\" \"$1\"; }' \
            '' \
            'restart_wifi() {' \
            '    log \"Restarting WiFi (wl driver)...\"' \
            '    sudo modprobe -r wl 2>/dev/null' \
            '    sleep 3' \
            '    sudo modprobe wl 2>/dev/null' \
            '    sleep 5' \
            '    log \"WiFi restart complete\"' \
            '}' \
            '' \
            'count=0' \
            'while true; do' \
            '    if ! ping -c 2 -W 3 \"$GW\" >/dev/null 2>&1; then' \
            '        count=$((count + 1))' \
            '        log \"Ping failed ($count/3)\"' \
            '        if [ \"$count\" -ge 3 ]; then' \
            '            log \"Connection lost - restarting WiFi\"' \
            '            restart_wifi' \
            '            count=0' \
            '        fi' \
            '    else' \
            '        count=0' \
            '    fi' \
            '    sleep \"$CHECK_INTERVAL\"' \
            'done' \
            > /usr/local/bin/wifi-watchdog.sh && sudo chmod +x /usr/local/bin/wifi-watchdog.sh"

    dry_run_exec "Creating wifi-watchdog.service on $host" \
        remote__exec "$host" "echo '[Unit]' | sudo tee /etc/systemd/system/wifi-watchdog.service > /dev/null
            echo 'Description=WiFi Watchdog for BCM4360 (wl driver)' | sudo tee -a /etc/systemd/system/wifi-watchdog.service
            echo 'After=network-online.target' | sudo tee -a /etc/systemd/system/wifi-watchdog.service
            echo 'Wants=network-online.target' | sudo tee -a /etc/systemd/system/wifi-watchdog.service
            echo '' | sudo tee -a /etc/systemd/system/wifi-watchdog.service
            echo '[Service]' | sudo tee -a /etc/systemd/system/wifi-watchdog.service
            echo 'Type=simple' | sudo tee -a /etc/systemd/system/wifi-watchdog.service
            echo 'ExecStart=/usr/local/bin/wifi-watchdog.sh' | sudo tee -a /etc/systemd/system/wifi-watchdog.service
            echo 'Restart=always' | sudo tee -a /etc/systemd/system/wifi-watchdog.service
            echo 'RestartSec=10' | sudo tee -a /etc/systemd/system/wifi-watchdog.service
            echo 'StandardOutput=journal' | sudo tee -a /etc/systemd/system/wifi-watchdog.service
            echo 'StandardError=journal' | sudo tee -a /etc/systemd/system/wifi-watchdog.service
            echo '' | sudo tee -a /etc/systemd/system/wifi-watchdog.service
            echo '[Install]' | sudo tee -a /etc/systemd/system/wifi-watchdog.service
            echo 'WantedBy=multi-user.target' | sudo tee -a /etc/systemd/system/wifi-watchdog.service
            sudo systemctl daemon-reload && sudo systemctl enable wifi-watchdog.service && sudo systemctl restart wifi-watchdog.service"

    sleep 2
    local wd_status
    wd_status=$(remote__exec "$host" "systemctl is-active wifi-watchdog.service 2>/dev/null || echo 'FAILED'" 2>/dev/null || echo "UNKNOWN")
    log "WiFi watchdog: $wd_status"

    agent_output "msgbox" "Fix WiFi" "WiFi fixed on $host:
- wl power management disabled (pm=0)
- WiFi watchdog installed and running
- Module reloaded"
    log "WiFi fix complete on $host"
}
