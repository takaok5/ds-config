#!/bin/bash
set -euo pipefail
MODULES=( uinput hid_playstation dummy_hcd libcomposite btusb usbip_host )
# Required kernel modules
MODULES=(
   uinput
   hid_playstation
   dummy_hcd
   libcomposite
   btusb
   usbip_host
 )
 # Aggiungi usb_f_hid solo se effettivamente presente
 if [[ -e /lib/modules/$(uname -r)/kernel/drivers/usb/gadget/function/usb_f_hid.ko* ]]; then
   MODULES+=(usb_f_hid)
 fi

echo "Loading required kernel modules..."
for module in "${MODULES[@]}"; do
 if modprobe "$module"; then
   echo "Loaded $module"
 else
   echo "Warning: failed to load $module"
 fi
done

# Create persistent configuration
CONFIG_FILE="/etc/modules-load.d/dualSense.conf"
echo "Creating persistent module configuration at $CONFIG_FILE..."

# Create or truncate the file
> "$CONFIG_FILE"

# Add modules to configuration file
for module in "${MODULES[@]}"; do
    echo "$module" | tee -a "$CONFIG_FILE"
done

echo "Configuration complete. Modules will be loaded on boot."
