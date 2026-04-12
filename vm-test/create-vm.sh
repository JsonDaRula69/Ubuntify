#!/bin/bash
set -e

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly ISO="${SCRIPT_DIR}/ubuntu-vmtest.iso"
readonly VM_NAME="macpro-vmtest"
readonly DISK_SIZE=25600

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

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
    echo -e "${YELLOW}WARN${NC}: VM '$VM_NAME' already exists."
    echo "Options:"
    echo "  1. Delete and recreate: VBoxManage unregistervm '$VM_NAME' --delete"
    echo "  2. Use existing VM with test-vm.sh"
    echo ""
    read -p "Delete existing VM and recreate? [y/N] " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Power off if running
        VBoxManage controlvm "$VM_NAME" poweroff 2>/dev/null || true
        sleep 2
        VBoxManage unregistervm "$VM_NAME" --delete
        echo "Deleted existing VM."
    else
        echo "Keeping existing VM. Exiting."
        exit 0
    fi
fi

# Find VirtualBox VMs directory
VBOX_DIR="$HOME/VirtualBox VMs"
if [ -d "$VBOX_DIR" ]; then
    DISK_PATH="$VBOX_DIR/$VM_NAME/$VM_NAME.vdi"
else
    DISK_PATH="$SCRIPT_DIR/$VM_NAME.vdi"
fi

echo "Creating VM: $VM_NAME"
echo "  EFI firmware (matches Mac Pro 2013)"
echo "  4 CPUs, 4.5GB RAM, 25GB disk"
echo "  NAT networking with SSH port forwarding (host 2222 -> guest 22)"
echo "  Monitor webhook: host 8080 -> guest 8080"
echo ""

# Create VM
VBoxManage createvm --name "$VM_NAME" --register --ostype "Ubuntu_64" 2>&1

# Set EFI firmware (Mac Pro 2013 uses EFI)
VBoxManage modifyvm "$VM_NAME" --firmware efi

# Set resources
VBoxManage modifyvm "$VM_NAME" --cpus 4 --memory 4576

# Set boot order: DVD first, then hard disk
VBoxManage modifyvm "$VM_NAME" --boot1 dvd --boot2 disk --boot3 none --boot4 none

# Create SATA controller and disk
VBoxManage storagectl "$VM_NAME" --name "SATA" --add sata --controller IntelAhci --portcount 2
mkdir -p "$(dirname "$DISK_PATH")" 2>/dev/null || true
VBoxManage createmedium disk --filename "$DISK_PATH" --size "$DISK_SIZE" --format VDI
VBoxManage storageattach "$VM_NAME" --storagectl "SATA" --port 0 --device 0 --type hdd --medium "$DISK_PATH"

# Create IDE controller and attach ISO
VBoxManage storagectl "$VM_NAME" --name "IDE" --add ide --controller PIIX4
VBoxManage storageattach "$VM_NAME" --storagectl "IDE" --port 0 --device 0 --type dvddrive --medium "$ISO"

# Network: NAT with port forwarding for SSH and webhook monitor
VBoxManage modifyvm "$VM_NAME" --nic1 nat --nictype1 82540EM
VBoxManage modifyvm "$VM_NAME" --natpf1 "ssh,tcp,,2222,,22"
VBoxManage modifyvm "$VM_NAME" --natpf1 "webhook,tcp,,8080,,8080"

# Enable headless mode
VBoxManage modifyvm "$VM_NAME" --uart1 0x3F8 4 --uartmode1 file /tmp/vmtest-serial.log

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
echo "Webhook:     localhost:8080 -> guest:8080 (for installer monitoring)"
echo ""
echo "To run the test:"
echo "  cd vm-test && ./test-vm.sh"
echo ""
echo "To start manually:"
echo "  VBoxManage startvm '$VM_NAME' --type headless"
echo ""
echo "To SSH in after install:"
echo "  ssh -p 2222 teja@localhost"