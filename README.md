# DualSense to USB HID Gadget

Questo progetto mappa un controller Sony DualSense a un dispositivo HID virtuale (combinazione tastiera+mouse) 
che appare come un "Logitech USB Receiver". Il dispositivo virtuale viene poi esportato via USB/IP 
per essere utilizzato da altre macchine sulla rete.

## Caratteristiche

- Mappa gli input del controller DualSense a eventi tastiera e mouse
- Crea un singolo gadget USB HID che combina funzionalità di tastiera e mouse
- Esporta il dispositivo via USB/IP per la condivisione in rete
- Funziona sia con connessioni USB che Bluetooth
- Mappatura dei pulsanti configurabile tramite file YAML

## Requisiti

- Debian 12 (Bookworm)
- Kernel Linux con supporto gadget (dummy_hcd, libcomposite)
- Python 3.9+ con librerie evdev e pyyaml
- Strumenti USB/IP 
- evtest (per il testing)
+  * **Dipendenze Python:** `pip install -r /opt/ds-config/requirements.txt`

## Installazione

1. Creare le directory e copiare i file:
 
     sudo mkdir -p /opt/ds-config/bin /opt/ds-config/config
     # Copia qui:
     sudo cp bin/* /opt/ds-config/bin/
     sudo cp config/* /opt/ds-config/config/
     sudo cp config/dualSense_map.yaml /opt/ds-config/config/
 2. Imposta i permessi:

     sudo chmod +x /opt/ds-config/bin/*.sh /opt/ds-config/bin/*.py
 
   3. Installa le dipendenze Python:
 
     pip3 install -r /opt/ds-config/requirements.txt
 
   4. Installa e avvia i systemd unit:
 
     sudo cp config/*.service /etc/systemd/system/
     sudo systemctl daemon-reload
     sudo systemctl enable gadget-hid.service ds-mapper.service usbip-check.timer usbip@.service
     sudo systemctl start gadget-hid.service ds-mapper.service
