#!/bin/bash
set -euo pipefail

echo "Testing DualSense controller and USB HID gadget setup..."

# Check if evtest is installed
if ! command -v evtest &> /dev/null; then
    echo "Error: evtest is not installed. Please install it with 'apt install evtest'."
    exit 1
fi

# Test controller connectivity (search for Sony controller)
CONTROLLER_DEV=$(grep -l "Wireless Controller" /sys/class/input/event*/device/name 2>/dev/null | head -n1 | sed 's/.*event\([0-9]*\).*/\1/')

if [ -z "$CONTROLLER_DEV" ]; then
    echo "Error: Could not find DualSense controller. Make sure it's connected."
    exit 1
fi

CONTROLLER_PATH="/dev/input/event${CONTROLLER_DEV}"
echo "Found DualSense controller at $CONTROLLER_PATH"

echo "Please press the Cross button (X) on your controller..."
if evtest --query "$CONTROLLER_PATH" EV_KEY BTN_SOUTH; then
    echo "Success: Button press detected!"
else
    echo "Error: Button press not detected. Please check controller connectivity."
    exit 1
fi

# Check virtual device (Logitech USB Receiver)
VIRTUAL_DEV=$(grep -l "Logitech USB Receiver" /sys/class/input/event*/device/name 2>/dev/null | head -n1 | sed 's/.*event\([0-9]*\).*/\1/')
if [ -z "$VIRTUAL_DEV" ]; then
    echo "Error: Virtual Logitech device not found. Check if ds_mapper.py is running."
    exit 1
fi

VIRTUAL_PATH="/dev/input/event${VIRTUAL_DEV}"
echo "Virtual Logitech device found at $VIRTUAL_PATH"

# Check USB gadget
if [ ! -d "/sys/kernel/config/usb_gadget/ds_gamepad" ]; then
    echo "Error: USB HID gadget not configured. Check if gadget_hid.sh has run."
    exit 1
fi

# Check if UDC is assigned (gadget is enabled)
UDC=$(cat /sys/kernel/config/usb_gadget/ds_gamepad/UDC 2>/dev/null || echo "")
if [ -z "$UDC" ]; then
    echo "Error: USB gadget not bound to any UDC. Check for errors in gadget_hid.sh."
    exit 1
fi
echo "USB HID gadget is bound to UDC: $UDC"

# Check USB/IP status
if ! command -v usbip &> /dev/null; then
    echo "Warning: usbip command not found. Cannot verify USB/IP status."
else
    echo "USB/IP device list:"
    usbip list -l || echo "Error listing USB/IP devices."
    
    echo "USB/IP port status:"
    usbip port || echo "Error checking USB/IP port status."
fi

# Check USB monitoring for HID reports if possible
if command -v usbmon &> /dev/null; then
    echo "Checking for HID reports with usbmon (press buttons on controller)..."
    echo "Press Ctrl+C after 5 seconds to continue..."
    
    # Run usbmon for 5 seconds to capture traffic
    timeout 5s usbmon -i 0 -f -t | grep -A 2 "Report ID:" || echo "No HID reports detected in the timeout period."
else
    echo "Note: usbmon binary not found; falling back to raw usbmon capture (kernel debugfs)"
   if [[ -r /sys/kernel/debug/usb/usbmon/0u ]]; then
      timeout 5s cat /sys/kernel/debug/usb/usbmon/0u | grep -A2 "Report ID:" || true
   fi
    
    # Alternative using basic sysfs checks
    echo "Basic HID gadget verification:"
    ls -l /sys/kernel/config/usb_gadget/ds_gamepad/functions/hid.usb0/
fi

echo "Testing complete!"
