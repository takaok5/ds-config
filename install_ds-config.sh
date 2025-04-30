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
  curl unzip vim-common python3 python3-pip python3-yaml python3-evdev
  usbip bluez evtest linux-tools-$(uname -r) linux-image-amd64
)
for pkg in "${base_pkgs[@]}"; do
  apt_try "$pkg" || echo "⚠️  Skip $pkg"
done

# ------------------- setup kernel modules -----------------------------
if ! modprobe -n dummy_hcd &>/dev/null; then
  echo "→ dummy_hcd mancante: installo kernel generico"
  apt_try linux-image-amd64 || die "Non posso installare kernel generico"
  echo "🔄 Riavvia e rilancia questo script su nuovo kernel"; exit 0
else
  echo "✔ dummy_hcd disponibile in $(uname -r)"
fi

# ------------------- scarica e installa gadget -------------------------
echo "→ Scarico l'archivio zip della repo ds-config"
REPO_URL="https://github.com/takaok5/ds-config/archive/refs/heads/main.zip"
TMP_DIR="/tmp/ds-config"
INSTALL_DIR="/opt/ds-config"

# Rimuovi vecchi file
rm -rf "$TMP_DIR" "$INSTALL_DIR"
mkdir -p "$TMP_DIR"

# Scarica e estrai
curl -L "$REPO_URL" -o "$TMP_DIR/main.zip" || die "Errore durante il download dello zip"
unzip "$TMP_DIR/main.zip" -d "$TMP_DIR" || die "Errore durante l'estrazione dello zip"
mv "$TMP_DIR/ds-config-main" "$INSTALL_DIR" || die "Errore durante lo spostamento dei file"

# ------------------- installa moduli e configura ----------------------
echo "→ Configuro i gadget USB"
chmod +x /opt/ds-config/bin/*.sh
/opt/ds-config/bin/setup_modules.sh || die "Errore durante la configurazione dei moduli"

cp /opt/ds-config/udev/rules.d/99-dualsense.rules /etc/udev/rules.d/
udevadm control --reload && udevadm trigger

getent group input >/dev/null || groupadd -r input
usermod -aG input root

cp /opt/ds-config/config/*.service /opt/ds-config/config/*.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now usbipd.service gadget-hid.service ds-mapper.service usbip-check.timer

echo -e "\n✅ Installazione completata! Riavvia per abilitare i gadget USB."
