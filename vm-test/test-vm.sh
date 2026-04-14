#!/bin/bash
set -e
set -o pipefail
set -u

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
readonly LIB_DIR="${PROJECT_DIR}/lib"
readonly VM_NAME="macpro-vmtest"

source "$LIB_DIR/colors.sh"
source "${LIB_DIR:-../lib}/dryrun.sh"

echo "========================================="
echo " Mac Pro VM Test Runner"
echo "========================================="
echo ""

check_vm() {
    if ! VBoxManage list vms 2>/dev/null | grep -q "\"$VM_NAME\""; then
        echo -e "${RED}ERROR${NC}: VM '$VM_NAME' not found. Run ./create-vm.sh first."
        exit 1
    fi
}

vm_state() {
    VBoxManage showvminfo "$VM_NAME" 2>/dev/null | grep "^State:" | sed 's/State:\s*//' | cut -d' ' -f1
}

wait_for_ssh() {
    local max_attempts=${1:-60}
    local attempt=1
    echo "Waiting for SSH on port 2222..."
    while [ $attempt -le $max_attempts ]; do
        if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -o PasswordAuthentication=yes -p 2222 teja@localhost "echo connected" 2>/dev/null; then
            echo -e "${GREEN}SSH connected!${NC}"
            return 0
        fi
        # Also try ubuntu user (installer default)
        if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -p 2222 ubuntu@localhost "echo connected" 2>/dev/null; then
            echo -e "${GREEN}SSH connected (ubuntu user)!${NC}"
            return 0
        fi
        printf "  Attempt %d/%d - waiting...\r" "$attempt" "$max_attempts"
        attempt=$((attempt + 1))
        sleep 5
    done
    echo -e "${YELLOW}SSH not available after ${max_attempts} attempts${NC}"
    return 1
}

grab_logs() {
    echo ""
    echo "========================================="
    echo " Grabbing installation logs"
    echo "========================================="
    local log_dir="${SCRIPT_DIR:-.}/vm-logs"
    mkdir -p "$log_dir"

    for user in teja ubuntu; do
        for passwd in "teja" "ubuntu"; do
            if sshpass -p "$passwd" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 "${user}@localhost" "echo ok" 2>/dev/null; then
                echo "Logged in as $user, grabbing logs..."
                SSH_CMD="sshpass -p $passwd ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 ${user}@localhost"

                $SSH_CMD "cat /var/log/macpro-install/early-commands.log 2>/dev/null || cat /run/macpro.log 2>/dev/null || echo 'No macpro log found'" > "$log_dir/macpro.log" 2>/dev/null || true
                $SSH_CMD "cat /var/log/installer/curtin-install.log 2>/dev/null || echo 'No curtin log'" > "$log_dir/curtin-install.log" 2>/dev/null || true
                $SSH_CMD "sudo cat /var/log/subiquity.log 2>/dev/null || echo 'No subiquity log'" > "$log_dir/subiquity.log" 2>/dev/null || true
                $SSH_CMD "dmesg 2>/dev/null || echo 'No dmesg'" > "$log_dir/dmesg.log" 2>/dev/null || true
                $SSH_CMD "dkms status 2>/dev/null || echo 'No dkms status'" > "$log_dir/dkms-status.log" 2>/dev/null || true
                $SSH_CMD "lsmod 2>/dev/null || echo 'No lsmod'" > "$log_dir/lsmod.log" 2>/dev/null || true
                $SSH_CMD "lspci -nn 2>/dev/null || echo 'No lspci'" > "$log_dir/lspci.log" 2>/dev/null || true
                $SSH_CMD "ls -la /target/var/log/macpro-install/ 2>/dev/null || echo 'No target logs'" > "$log_dir/target-logs.txt" 2>/dev/null || true
                $SSH_CMD "cat /target/var/log/macpro-install/early-commands.log 2>/dev/null || echo 'No target macpro log'" > "$log_dir/target-macpro.log" 2>/dev/null || true
                $SSH_CMD "ls -la /lib/modules/*/updates/dkms/wl.ko 2>/dev/null || echo 'No wl.ko'" > "$log_dir/wl-module.txt" 2>/dev/null || true
                $SSH_CMD "cat /target/etc/netplan/*.yaml 2>/dev/null || echo 'No netplan configs'" > "$log_dir/netplan-configs.txt" 2>/dev/null || true

                echo -e "${GREEN}Logs saved to $log_dir/${NC}"
                echo "Key log: $log_dir/macpro.log"
                return 0
            fi
        done
    done
    echo -e "${YELLOW}Could not SSH in to grab logs${NC}"
    echo "Try manually: ssh -p 2222 teja@localhost (or ubuntu@localhost)"
    return 1
}

take_screenshot() {
    local path="${1:-/tmp/vm-screenshot.png}"
    VBoxManage controlvm "$VM_NAME" screenshotpng "$path" 2>/dev/null || true
    if [ -f "$path" ]; then
        echo "Screenshot saved: $path"
    fi
}

case "${1:-run}" in
    run)
        check_vm
        STATE=$(vm_state)
        if [ "$STATE" = "running" ]; then
            echo -e "${YELLOW}VM is already running${NC}"
        else
            echo "Starting VM..."
            dry_run_exec "Starting VM $VM_NAME" \
                VBoxManage startvm "$VM_NAME" --type headless
            echo "VM started (headless). Installation will begin automatically."
        fi
        echo ""
        echo "Monitor options:"
        echo "  ./test-vm.sh screenshot    - Take a screenshot of the VM"
        echo "  ./test-vm.sh logs           - Try to grab logs via SSH"
        echo "  ./test-vm.sh ssh            - SSH into the VM"
        echo "  ./test-vm.sh stop            - Power off the VM"
        echo ""

        echo "Waiting for installation to complete..."
        echo "(This can take 5-15 minutes. The VM auto-reboots when done.)"
        echo ""
        echo "Use './test-vm.sh serial' to check serial log"
        echo "Use './test-vm.sh monitor' to start webhook monitor on port 8081"
        echo ""

        if wait_for_ssh 180; then
            echo ""
            echo "SSH is available! Grabbing logs..."
            grab_logs
            echo ""
            echo -e "${GREEN}VM test installation appears complete!${NC}"
            echo "To check the installed system: ssh -p 2222 teja@localhost"
        else
            echo ""
            echo "SSH not reachable. Take a screenshot to check status:"
            echo "  ./test-vm.sh screenshot"
        fi
        ;;

    ssh)
        check_vm
        echo "Trying to SSH into VM..."
        echo "  User: teja or ubuntu"
        echo "  Port: 2222"
        for user in teja ubuntu; do
            echo "Trying $user@localhost:2222..."
            if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PasswordAuthentication=yes -p 2222 "${user}@localhost" 2>/dev/null; then
                break
            fi
        done
        ;;

    logs)
        check_vm
        grab_logs
        ;;

    screenshot)
        check_vm
        take_screenshot
        ;;

    stop)
        check_vm
        echo "Powering off VM..."
        dry_run_exec "Powering off VM $VM_NAME" \
            VBoxManage controlvm "$VM_NAME" poweroff 2>/dev/null || true
        echo "VM powered off."
        ;;

    reset)
        check_vm
        dry_run_exec "Powering off VM $VM_NAME" \
            VBoxManage controlvm "$VM_NAME" poweroff 2>/dev/null || true
        if ! is_dry_run; then
            sleep 2
        fi
        DISK=$(VBoxManage showvminfo "$VM_NAME" 2>/dev/null | grep "SATA.*UUID" | head -1 | grep -oE '/[^ ]+\.vdi' || true)
        if [ -n "$DISK" ]; then
            echo "Resetting disk: $DISK"
            DISK_UUID=$(VBoxManage showvminfo "$VM_NAME" 2>/dev/null | grep "SATA.*UUID" | head -1 | grep -oE '{[^}]+}' | head -1)
            dry_run_exec "Resetting disk medium $DISK_UUID" \
                VBoxManage mediumproperty reset "$DISK_UUID" 2>/dev/null || true
        fi
        echo "Disk reset. Start fresh with: ./test-vm.sh run"
        ;;

    destroy)
        check_vm
        dry_run_exec "Powering off VM $VM_NAME" \
            VBoxManage controlvm "$VM_NAME" poweroff 2>/dev/null || true
        if ! is_dry_run; then
            sleep 2
        fi
        dry_run_exec "Unregistering and deleting VM $VM_NAME" \
            VBoxManage unregistervm "$VM_NAME" --delete
        echo -e "${GREEN}VM destroyed.${NC}"
        ;;

    serial)
        check_vm
        if [ -f /tmp/vmtest-serial.log ]; then
            echo "=== Last 100 lines of serial log ==="
            tail -100 /tmp/vmtest-serial.log
        else
            echo "No serial log found at /tmp/vmtest-serial.log"
        fi
        ;;

    monitor)
        MONITOR_DIR="$(cd "$(dirname "$0")" && pwd)/../macpro-monitor"
        if [ -f "$MONITOR_DIR/server.js" ]; then
            echo "Starting installation monitor on port 8081..."
            PORT=8081 nohup node "$MONITOR_DIR/server.js" > /tmp/vm-monitor.log 2>&1 &
            VM_MONITOR_PID=$!
            echo "Monitor started (PID: $VM_MONITOR_PID)"
            echo "Dashboard: http://localhost:8081"
            echo "Webhook:   http://localhost:8081/webhook"
            echo "Logs:      /tmp/vm-monitor.log"
            echo ""
            echo "To stop: kill $VM_MONITOR_PID"
        else
            echo "ERROR: Monitor server not found"
        fi
        ;;

    *)
        echo "Usage: $0 {run|ssh|logs|screenshot|stop|reset|destroy|serial|monitor}"
        echo ""
        echo "Commands:"
        echo "  run        Start VM and wait for SSH (default)"
        echo "  ssh        SSH into the VM"
        echo "  logs       Grab installation logs via SSH"
        echo "  screenshot Take a screenshot of the VM display"
        echo "  stop       Power off the VM"
        echo "  reset      Reset VM disk (power off + medium reset)"
        echo "  destroy    Delete the VM entirely"
        echo "  serial     Show last 100 lines of serial log"
        echo "  monitor    Start webhook monitor on port 8081"
        ;;
esac