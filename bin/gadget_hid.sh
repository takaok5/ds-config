#!/bin/bash
set -euo pipefail

GADGET_DIR="/sys/kernel/config/usb_gadget/ds_gamepad"
VENDOR_ID="046d"  # Logitech
PRODUCT_ID="c332" # G502 Proteus Spectrum
BCD_DEVICE="0111"

cleanup() {
  echo "-> Eseguo cleanup del gadget $GADGET_NAME..."
  set +e # Ignora errori durante il cleanup, potrebbero non esistere tutte le parti
  if [ -d "$GADGET_DIR" ]; then
    # 1. Scollega dall'UDC prima di tutto!
    if [ -f "$GADGET_DIR/UDC" ] && [ -n "$(cat "$GADGET_DIR/UDC" 2>/dev/null)" ]; then
       echo "  - Scollego da UDC: $(cat "$GADGET_DIR/UDC")"
       echo "" > "$GADGET_DIR/UDC" # Scrive stringa vuota per scollegare
       sleep 0.5 # Breve pausa per permettere lo scollegamento
    fi

    # 2. Rimuovi il link simbolico della funzione dalla configurazione
    if [ -L "$GADGET_DIR/configs/c.1/hid.usb0" ]; then
       echo "  - Rimuovo link funzione: configs/c.1/hid.usb0"
       rm -f "$GADGET_DIR/configs/c.1/hid.usb0"
    fi

    # 3. Rimuovi le directory nell'ordine corretto (da dentro a fuori)
    if [ -d "$GADGET_DIR/functions/hid.usb0" ]; then
       echo "  - Rimuovo directory funzione: functions/hid.usb0"
       rmdir "$GADGET_DIR/functions/hid.usb0" 2>/dev/null
    fi
    if [ -d "$GADGET_DIR/configs/c.1/strings/0x409" ]; then
       echo "  - Rimuovo directory stringhe config: configs/c.1/strings/0x409"
       rmdir "$GADGET_DIR/configs/c.1/strings/0x409" 2>/dev/null
    fi
    if [ -d "$GADGET_DIR/configs/c.1" ]; then
       echo "  - Rimuovo directory config: configs/c.1"
       rmdir "$GADGET_DIR/configs/c.1" 2>/dev/null
    fi
    if [ -d "$GADGET_DIR/strings/0x409" ]; then
       echo "  - Rimuovo directory stringhe gadget: strings/0x409"
       rmdir "$GADGET_DIR/strings/0x409" 2>/dev/null
    fi

    # 4. Rimuovi la directory principale del gadget (solo se vuota)
    echo "  - Tento rimozione directory gadget: $GADGET_DIR"
    rmdir "$GADGET_DIR" 2>/dev/null
    if [ $? -eq 0 ]; then
       echo "  - Directory gadget rimossa con successo."
    else
       echo "  - Impossibile rimuovere la directory gadget (potrebbe non essere vuota o errore)."
    fi
  else
     echo "  - Directory gadget $GADGET_DIR non trovata, cleanup non necessario."
  fi
  set -e # Riabilita l'uscita in caso di errore per il resto dello script
  echo "-> Cleanup completato."
}

setup() {
    mkdir -p "${GADGET_DIR}"
    
    # Device identification
    echo "0x${VENDOR_ID}" > "${GADGET_DIR}/idVendor"
    echo "0x${PRODUCT_ID}" > "${GADGET_DIR}/idProduct"
    echo "0x${BCD_DEVICE}" > "${GADGET_DIR}/bcdDevice"
    echo "0x0200" > "${GADGET_DIR}/bcdUSB"
    
    # Device class (HID)
    echo "0x00" > "${GADGET_DIR}/bDeviceClass"
    echo "0x00" > "${GADGET_DIR}/bDeviceSubClass"
    echo "0x00" > "${GADGET_DIR}/bDeviceProtocol"
    echo "64" > "${GADGET_DIR}/bMaxPacketSize0"
    
    # Strings
    mkdir -p "${GADGET_DIR}/strings/0x409"
    echo "000000001" > "${GADGET_DIR}/strings/0x409/serialnumber"
    echo "Logitech" > "${GADGET_DIR}/strings/0x409/manufacturer"
    echo "G502 Proteus Spectrum" > "${GADGET_DIR}/strings/0x409/product"
    
    # Config
    mkdir -p "${GADGET_DIR}/configs/c.1/strings/0x409"
    echo "G502 Configuration" > "${GADGET_DIR}/configs/c.1/strings/0x409/configuration"
    echo "120" > "${GADGET_DIR}/configs/c.1/MaxPower"
    
    # HID Function
    mkdir -p "${GADGET_DIR}/functions/hid.usb0"
    echo "1" > "${GADGET_DIR}/functions/hid.usb0/protocol"
    echo "1" > "${GADGET_DIR}/functions/hid.usb0/subclass"    
    # G502 HID Report Descriptor
# Questo è il comando che DOVREBBE esserci nel tuo script
echo -ne '\x05\x01\x09\x06\xa1\x01\x85\x01\x05\x07\x19\xe0\x29\xe7\x15\x00\x25\x01\x75\x01\x95\x08\x81\x02\x95\x01\x75\x08\x81\x01\x95\x05\x75\x01\x05\x08\x19\x01\x29\x05\x91\x02\x95\x01\x75\x03\x91\x01\x95\x06\x75\x08\x15\x00\x26\xff\x00\x05\x07\x19\x00\x2a\xff\x00\x81\x00\xc0\x05\x01\x09\x02\xa1\x01\x09\x01\xa1\x00\x85\x02\x05\x09\x19\x01\x29\x05\x15\x00\x25\x01\x95\x05\x75\x01\x81\x02\x95\x01\x75\x03\x81\x01\x05\x01\x09\x30\x09\x31\x09\x38\x15\x81\x25\x7f\x75\x08\x95\x03\x81\x06\xc0\xc0' > "$GADGET_DIR/functions/hid.usb0/report_desc"    
echo 8 > "$GADGET_DIR/functions/hid.usb0/report_length"   
    # Link function to config
    ln -s "${GADGET_DIR}/functions/hid.usb0" "${GADGET_DIR}/configs/c.1/"
    
    # Enable gadget
    UDC=$(ls /sys/class/udc | head -n1)
    if [ -z "$UDC" ]; then
        echo "Error: No UDC available"
        exit 1
    fi
    echo "$UDC" > "${GADGET_DIR}/UDC"
}

main() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Must run as root"
        exit 1
    }
    
    # Mount configfs if needed
 if ! mountpoint -q /sys/kernel/config; then
  mount -t configfs none /sys/kernel/config \
    || { echo "Error: configfs mount failed" >&2; exit 1; }
fi
    
    cleanup
    setup
    
    # Wait for device to initialize
    sleep 2
    
    # Bind to USB/IP
    BUSID=$(usbip list -l | grep "046d:c332" | awk '{print $2}')
    if [ -n "$BUSID" ]; then
        echo "Binding USB/IP for G502 device $BUSID"
        usbip bind -b "$BUSID"
        echo "Device ready for USB/IP sharing"
    else
        echo "Error: G502 device not found in USB/IP list"
        usbip list -l
    fi
}

main
