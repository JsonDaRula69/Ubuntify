#!/bin/bash
set -e
set -o pipefail
set -u

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
readonly LIB_DIR="${PROJECT_DIR}/lib"
readonly ISO="${SCRIPT_DIR}/ubuntu-vmtest.iso"
readonly VM_NAME="macpro-vmtest"
readonly DISK_SIZE=25600

source "$LIB_DIR/colors.sh"
source "${LIB_DIR:-../lib}/dryrun.sh"

FORCE=false
if [ "$1" = "--force" ]; then
    FORCE=true
fi

echo "========================================="
echo " Mac Pro VM Test - VirtualBox Setup"
echo "========================================="
echo ""

# Check prerequisites
if ! command -v VBoxManage >/dev/null 2>&1; then
    echo -e "${RED}ERROR${NC}: VBoxManage not found. Install VirtualBox first."
    exit 1
fi

if [ ! -f "$ISO" ]; then
    echo -e "${RED}ERROR${NC}: VM test ISO not found: $ISO"
    echo "Run ./build-iso-vm.sh first."
    exit 1
fi

# Check if VM already exists
if VBoxManage list vms 2>/dev/null | grep -q "\"$VM_NAME\""; then
    if [ "$FORCE" = true ]; then
        echo -e "${YELLOW}WARN${NC}: VM '$VM_NAME' already exists. Force recreate enabled."
        dry_run_exec "Powering off existing VM $VM_NAME" \
            VBoxManage controlvm "$VM_NAME" poweroff 2>/dev/null || true
        if ! is_dry_run; then
            sleep 2
        fi
        dry_run_exec "Unregistering and deleting existing VM $VM_NAME" \
            VBoxManage unregistervm "$VM_NAME" --delete
        echo "Deleted existing VM."
    else
        echo -e "${YELLOW}WARN${NC}: VM '$VM_NAME' already exists."
        echo "Options:"
        echo "  1. Delete and recreate: VBoxManage unregistervm '$VM_NAME' --delete"
        echo "  2. Use existing VM with test-vm.sh"
        echo ""
        read -p "Delete existing VM and recreate? [y/N] " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            # Power off if running
            dry_run_exec "Powering off existing VM $VM_NAME" \
                VBoxManage controlvm "$VM_NAME" poweroff 2>/dev/null || true
            if ! is_dry_run; then
                sleep 2
            fi
            dry_run_exec "Unregistering and deleting existing VM $VM_NAME" \
                VBoxManage unregistervm "$VM_NAME" --delete
            echo "Deleted existing VM."
        else
            echo "Keeping existing VM. Exiting."
            exit 0
        fi
    fi
fi

DISK_PATH="$(VBoxManage list systemproperties | grep -m1 'Default machine folder' | sed 's/Default machine folder:[[:space:]]*//')/$VM_NAME/$VM_NAME.vdi"

echo "Creating VM: $VM_NAME"
echo "  EFI firmware (matches Mac Pro 2013)"
echo "  4 CPUs, 4.5GB RAM, 25GB disk"
echo "  NAT networking with SSH port forwarding (host 2222 -> guest 22)"
echo ""

# Create VM
dry_run_exec "Creating VM $VM_NAME" \
    VBoxManage createvm --name "$VM_NAME" --register --ostype "Ubuntu_64" 2>&1

# Set EFI firmware (Mac Pro 2013 uses EFI)
dry_run_exec "Setting EFI firmware for $VM_NAME" \
    VBoxManage modifyvm "$VM_NAME" --firmware efi

# Set resources
dry_run_exec "Setting VM resources (4 CPUs, 4.5GB RAM)" \
    VBoxManage modifyvm "$VM_NAME" --cpus 4 --memory 4576

# Set boot order: DVD first, then hard disk
dry_run_exec "Setting VM boot order (DVD first)" \
    VBoxManage modifyvm "$VM_NAME" --boot1 dvd --boot2 disk --boot3 none --boot4 none

# Create SATA controller and disk
dry_run_exec "Creating SATA controller for $VM_NAME" \
    VBoxManage storagectl "$VM_NAME" --name "SATA" --add sata --controller IntelAhci --portcount 2
mkdir -p "$(dirname "$DISK_PATH")" 2>/dev/null || true
dry_run_exec "Creating virtual disk $DISK_PATH" \
    VBoxManage createmedium disk --filename "$DISK_PATH" --size "$DISK_SIZE" --format VDI
dry_run_exec "Attaching SATA disk to $VM_NAME" \
    VBoxManage storageattach "$VM_NAME" --storagectl "SATA" --port 0 --device 0 --type hdd --medium "$DISK_PATH"

# Create IDE controller and attach ISO
dry_run_exec "Creating IDE controller for $VM_NAME" \
    VBoxManage storagectl "$VM_NAME" --name "IDE" --add ide --controller PIIX4
dry_run_exec "Attaching ISO to $VM_NAME IDE controller" \
    VBoxManage storageattach "$VM_NAME" --storagectl "IDE" --port 0 --device 0 --type dvddrive --medium "$ISO"

dry_run_exec "Configuring NAT network for $VM_NAME" \
    VBoxManage modifyvm "$VM_NAME" --nic1 nat --nictype1 82540EM
dry_run_exec "Configuring SSH port forwarding for $VM_NAME" \
    VBoxManage modifyvm "$VM_NAME" --natpf1 "ssh,tcp,,2222,,22"

# Enable headless mode
dry_run_exec "Enabling UART1 for serial logging" \
    VBoxManage modifyvm "$VM_NAME" --uart1 0x3F8 4 --uartmode1 file /tmp/vmtest-serial.log

dry_run_exec "Setting graphics controller for $VM_NAME" \
    VBoxManage modifyvm "$VM_NAME" --graphicscontroller vmsvga --vram 128

echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN} VM CREATED SUCCESSFULLY${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo "VM name:     $VM_NAME"
echo "Disk:        ${DISK_SIZE}MB VDI"
echo "ISO:         $ISO"
echo "SSH:         localhost:2222 -> guest:22"
echo ""
echo "To run the test:"
echo "  cd vm-test && ./test-vm.sh"
echo ""
echo "To start manually:"
echo "  VBoxManage startvm '$VM_NAME' --type headless"
echo ""
echo "To SSH in after install:"
echo "  ssh -p 2222 teja@localhost"