#!/usr/bin/env bash
set -euo pipefail

# ------------------------------- funzioni -------------------------------
die()   { echo "❌ $*" >&2; exit 1; }
havepkg(){ dpkg -s "$1" &>/dev/null; }
apt_try(){ havepkg "$1" && echo "✔ $1 già installato" && return 0; \
           echo "→ installo $1..."; DEBIAN_FRONTEND=noninteractive apt-get install -y "$1"; }

# Assicurati di essere root
[ "$EUID" -eq 0 ] || die "Esegui lo script come root (sudo)."

echo "==> apt update"
apt-get update -y

# ------------------- installa dipendenze base --------------------------
base_pkgs=(
  git vim-common python3 python3-pip python3-yaml python3-evdev
  usbip bluez evtest curl unzip
)
for pkg in "${base_pkgs[@]}"; do
  apt_try "$pkg" || echo "⚠️  Skip $pkg"
done

# linux-tools (non critico)
if ! apt_try "linux-tools-$(uname -r)"; then
  echo "ℹ️  linux-tools specifico non trovato; provo linux-tools-amd64"
  apt_try linux-tools-amd64 || echo "ℹ️  tools generici non disponibili, continuo"
fi

# ------------------- setup kernel modules -----------------------------
if ! modprobe -n dummy_hcd &>/dev/null; then
  echo "→ dummy_hcd mancante: installo kernel generico"
  apt_try linux-image-amd64 || die "Non posso installare kernel generico"
  echo "🔄 Riavvia e rilancia questo script su nuovo kernel"; exit 0
else
  echo "✔ dummy_hcd disponibile in $(uname -r)"
fi

# ------------------- scarica e aggiorna repo ---------------------------
echo "→ Scarico l'archivio zip della repo ds-config"
REPO_URL="https://github.com/takaok5/ds-config/archive/refs/heads/main.zip"
TMP_DIR="/tmp/ds-config"
INSTALL_DIR="/opt/ds-config"

# Rimuovi vecchie versioni
rm -rf "$TMP_DIR" "$INSTALL_DIR"
mkdir -p "$TMP_DIR"

# Scarica e estrai
curl -L "$REPO_URL" -o "$TMP_DIR/main.zip" || die "Errore durante il download dello zip"
unzip "$TMP_DIR/main.zip" -d "$TMP_DIR" || die "Errore durante l'estrazione dello zip"
mv "$TMP_DIR/ds-config-main" "$INSTALL_DIR" || die "Errore durante lo spostamento dei file"

# ------------------- riscrivo gadget_hid.sh corretto -------------------
cat > /opt/ds-config/bin/gadget_hid.sh << 'EOF'
#!/bin/bash
set -euo pipefail

GADGET_NAME="ds_gamepad"
GADGET_DIR="/sys/kernel/config/usb_gadget/${GADGET_NAME}"
LOGI_VID="046d"; LOGI_PID="c332"; LOGI_BCD="0111"

cleanup() {
  set +e
  [ -d "$GADGET_DIR" ] && {
    [ -f "$GADGET_DIR/UDC" ] && grep -q . "$GADGET_DIR/UDC" \
      && echo > "$GADGET_DIR/UDC" 2>/dev/null
    rm -rf "$GADGET_DIR/functions/hid.usb0" "$GADGET_DIR/configs/c.1/hid.usb0"
    rmdir "$GADGET_DIR/configs/c.1/strings/0x409" 2>/dev/null
    rmdir "$GADGET_DIR/configs/c.1"               2>/dev/null
    rmdir "$GADGET_DIR/strings/0x409"             2>/dev/null
    rm -rf "$GADGET_DIR"
  }
  set -e
}

setup() {
  mkdir -p "$GADGET_DIR"
  echo 0x${LOGI_VID} > "$GADGET_DIR/idVendor"
  echo 0x${LOGI_PID} > "$GADGET_DIR/idProduct"
  echo 0x${LOGI_BCD} > "$GADGET_DIR/bcdDevice"
  echo 0x0200       > "$GADGET_DIR/bcdUSB"
  for f in bDeviceClass bDeviceSubClass bDeviceProtocol; do echo 0x00 > "$GADGET_DIR/$f"; done
  mkdir -p "$GADGET_DIR/strings/0x409"
  echo "0000000001"            > "$GADGET_DIR/strings/0x409/serialnumber"
  echo "Logitech"              > "$GADGET_DIR/strings/0x409/manufacturer"
  echo "Logitech USB Receiver" > "$GADGET_DIR/strings/0x409/product"
  mkdir -p "$GADGET_DIR/configs/c.1/strings/0x409"
  echo "HID Keyboard+Mouse"    > "$GADGET_DIR/configs/c.1/strings/0x409/configuration"
  echo 120                    > "$GADGET_DIR/configs/c.1/MaxPower"
  mkdir -p "$GADGET_DIR/functions/hid.usb0"
  echo 1  > "$GADGET_DIR/functions/hid.usb0/protocol"
  echo 0  > "$GADGET_DIR/functions/hid.usb0/subclass"
  echo 11 > "$GADGET_DIR/functions/hid.usb0/report_length"
  cat > "$GADGET_DIR/functions/hid.usb0/report_desc" << 'DESC'
05010906 A1010571 29E71500 25017509
50881029 01750195 08810195 06750815
00FF0005 0719002A FF008100 C0050109
02A10185 0109A10005 0A09150A25 01750195
01810829 02750195 0381C0...
DESC
  ln -s "$GADGET_DIR/functions/hid.usb0" "$GADGET_DIR/configs/c.1/"
  UDC=$(ls /sys/class/udc | head -n1) || { echo "No UDC"; exit 1; }
  echo "$UDC" > "$GADGET_DIR/UDC"
  echo "$UDC" > /tmp/ds_gadget_udc
  udevadm settle -t 2
  BUSID=$(usbip list -l | awk '/Logitech USB Receiver/ {print $2; exit}')
  [ -n "$BUSID" ] && { echo "$BUSID" > /tmp/ds_gadget_busid; usbip bind -b "$BUSID"; }
}

main() {
  [ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
  grep -q configfs /proc/mounts || mount -t configfs none /sys/kernel/config
  cleanup; setup
  echo "Gadget ready"
}

main
EOF

chmod +x /opt/ds-config/bin/*.sh

# ------------------- udev, moduli e servizi ----------------------------
cp /opt/ds-config/udev/rules.d/99-dualsense.rules /etc/udev/rules.d/
udevadm control --reload && udevadm trigger
/opt/ds-config/bin/setup_modules.sh

getent group input >/dev/null || groupadd -r input
usermod -aG input root

cp /opt/ds-config/config/*.service /opt/ds-config/config/*.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now usbipd.service gadget-hid.service ds-mapper.service usbip-check.timer

echo -e "\n✅ Installazione completata!"
