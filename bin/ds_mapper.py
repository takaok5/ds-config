#!/usr/bin/env python3
set -euo pipefail

"""
DualSense → Mouse/Keyboard mapper with HID gadget reports

Updated: 2025-04-29

- Multi-device support (controller, dedicated touchpad, sensors) via path list
- Rapid-fire controlled by R2 trigger (BTN_RIGHT)
- L2 = continuous left click
- **NEW**: HID reports (keyboard and mouse) sent to /dev/hidg0 (Report ID 1 and 2)
"""

from __future__ import annotations

import argparse
import logging
import os
import threading
import time
import yaml
import sys
from pathlib import Path
from select import select
from typing import Dict, List, Tuple

from evdev import InputDevice, UInput, ecodes, list_devices
base_pkgs=( git vim-common python3 python3-pip python3-yaml python3-evdev usbip bluez evtest )
MODULES=( uinput hid_playstation dummy_hcd libcomposite btusb usbip_host )
# -----------------------------------------------------------
# General constants
# -----------------------------------------------------------

DEFAULT_CONFIG = "/opt/ds-config/config/dualSense_map.yaml"

SONY_VENDOR = 0x054C
PRODUCTS_DS = {0x0CE6, 0x0DF2}  # DualSense & DualSense Edge

# ---------------------------------------------------------------------------
# Conversion tables evdev → USB HID (scancode / usage)
# ---------------------------------------------------------------------------

EVDEV_TO_HID: Dict[int, int] = {
    # letters
    ecodes.KEY_A: 0x04, ecodes.KEY_B: 0x05, ecodes.KEY_C: 0x06, ecodes.KEY_D: 0x07,
    ecodes.KEY_E: 0x08, ecodes.KEY_F: 0x09, ecodes.KEY_G: 0x0A, ecodes.KEY_H: 0x0B,
    ecodes.KEY_I: 0x0C, ecodes.KEY_J: 0x0D, ecodes.KEY_K: 0x0E, ecodes.KEY_L: 0x0F,
    ecodes.KEY_M: 0x10, ecodes.KEY_N: 0x11, ecodes.KEY_O: 0x12, ecodes.KEY_P: 0x13,
    ecodes.KEY_Q: 0x14, ecodes.KEY_R: 0x15, ecodes.KEY_S: 0x16, ecodes.KEY_T: 0x17,
    ecodes.KEY_U: 0x18, ecodes.KEY_V: 0x19, ecodes.KEY_W: 0x1A, ecodes.KEY_X: 0x1B,
    ecodes.KEY_Y: 0x1C, ecodes.KEY_Z: 0x1D,
    # numbers
    ecodes.KEY_1: 0x1E, ecodes.KEY_2: 0x1F, ecodes.KEY_3: 0x20, ecodes.KEY_4: 0x21,
    ecodes.KEY_5: 0x22, ecodes.KEY_6: 0x23, ecodes.KEY_7: 0x24, ecodes.KEY_8: 0x25,
    ecodes.KEY_9: 0x26, ecodes.KEY_0: 0x27,
    # basic symbols
    ecodes.KEY_ENTER: 0x28, ecodes.KEY_ESC: 0x29, ecodes.KEY_BACKSPACE: 0x2A,
    ecodes.KEY_TAB: 0x2B, ecodes.KEY_SPACE: 0x2C,
    # More commonly used keys
    ecodes.KEY_MINUS: 0x2D, ecodes.KEY_EQUAL: 0x2E, ecodes.KEY_LEFTBRACE: 0x2F,
    ecodes.KEY_RIGHTBRACE: 0x30, ecodes.KEY_BACKSLASH: 0x31, ecodes.KEY_SEMICOLON: 0x33,
    ecodes.KEY_APOSTROPHE: 0x34, ecodes.KEY_GRAVE: 0x35, ecodes.KEY_COMMA: 0x36,
    ecodes.KEY_DOT: 0x37, ecodes.KEY_SLASH: 0x38, ecodes.KEY_CAPSLOCK: 0x39,
    # Function keys
    ecodes.KEY_F1: 0x3A, ecodes.KEY_F2: 0x3B, ecodes.KEY_F3: 0x3C, ecodes.KEY_F4: 0x3D,
    ecodes.KEY_F5: 0x3E, ecodes.KEY_F6: 0x3F, ecodes.KEY_F7: 0x40, ecodes.KEY_F8: 0x41,
    ecodes.KEY_F9: 0x42, ecodes.KEY_F10: 0x43, ecodes.KEY_F11: 0x44, ecodes.KEY_F12: 0x45,
}

MODIFIER_BITS: Dict[int, int] = {
    ecodes.KEY_LEFTCTRL: 0x01,  ecodes.KEY_LEFTSHIFT: 0x02,  ecodes.KEY_LEFTALT: 0x04,
    ecodes.KEY_LEFTMETA: 0x08,  ecodes.KEY_RIGHTCTRL: 0x10, ecodes.KEY_RIGHTSHIFT: 0x20,
    ecodes.KEY_RIGHTALT: 0x40,  ecodes.KEY_RIGHTMETA: 0x80,
}

MOUSE_BUTTON_BITS: Dict[int, int] = {
    ecodes.BTN_LEFT: 0x01, ecodes.BTN_RIGHT: 0x02, ecodes.BTN_MIDDLE: 0x04,
}

# DualSense constants
ABS_RX = ecodes.ABS_RX
ABS_RY = ecodes.ABS_RY
ABS_X = ecodes.ABS_X
ABS_Y = ecodes.ABS_Y
ABS_Z = ecodes.ABS_Z      # L2 Trigger
ABS_RZ = ecodes.ABS_RZ    # R2 Trigger

# DualSense button constants
BTN_SOUTH = ecodes.BTN_SOUTH        # X
BTN_EAST = ecodes.BTN_EAST          # O  
BTN_WEST = ecodes.BTN_WEST          # Square
BTN_NORTH = ecodes.BTN_NORTH        # Triangle
BTN_TL = ecodes.BTN_TL              # L1
BTN_TR = ecodes.BTN_TR              # R1
BTN_TL2 = ecodes.BTN_TL2            # L2 button
BTN_TR2 = ecodes.BTN_TR2            # R2 button
BTN_SELECT = ecodes.BTN_SELECT      # Share/Create
BTN_START = ecodes.BTN_START        # Options
BTN_MODE = ecodes.BTN_MODE          # PS Button
BTN_THUMBL = ecodes.BTN_THUMBL      # L3
BTN_THUMBR = ecodes.BTN_THUMBR      # R3

# ---------------------------------------------------------------------------
# Main class
# ---------------------------------------------------------------------------


class DSMapper:
    """Maps a DualSense Pad to UInput *and* HID gadget."""

    # ------------------------------------------------------------------ #
    # init / config
    # ------------------------------------------------------------------ #

    def __init__(self, cfg_path: str, *, debug: bool = False, auto: bool = False) -> None:
        cfg_path = Path(cfg_path).expanduser()
        try:
            with cfg_path.open("r", encoding="utf-8") as fp:
                self.cfg = yaml.safe_load(fp) or {}
        except Exception as e:
            logging.error("Error reading YAML %s: %s", cfg_path, e)
            sys.exit(1)

        self.debug = debug
        self.running = True
        self._lock = threading.Lock()

        # --------------- configure ---------------
        self._parse_cfg()

        # --------------- auto-detect --------------
        if auto or not self.cfg.get("devices") or self.cfg["devices"] in ("auto", None):
            self.cfg["devices"] = self._auto_detect_devices()

        # --------------- open devices --------------
        self.dev_objs: List[InputDevice] = []
        for name, path in self.cfg["devices"].items():
            try:
                dev = InputDevice(path)
                dev.grab()
                self.dev_objs.append(dev)
                logging.info("Opened %s: %s", name, dev.name)
            except Exception as exc:
                logging.warning("Unable to open %s: %s", path, exc)

        if not self.dev_objs:
            raise RuntimeError("No DualSense found")

        # --------------- UInput -------------------
        cap_keys = list(range(ecodes.KEY_MAX + 1)) + list(MOUSE_BUTTON_BITS.keys())
        self.uin = UInput(
            events={
                ecodes.EV_KEY: cap_keys,
                ecodes.EV_REL: [ecodes.REL_X, ecodes.REL_Y],
            },
            name="DS-Mapper",
            version=0x0100,
        )

        # --------------- /dev/hidg0 ---------------
        try:
            # Try to create device if it doesn't exist (may require root)
            if not os.path.exists("/dev/hidg0") and os.geteuid() == 0:
                try:
                    import subprocess
                    subprocess.run(["mknod", "/dev/hidg0", "c", "240", "0"], check=True)
                    subprocess.run(["chmod", "666", "/dev/hidg0"], check=True)
                except Exception as e:
                    logging.warning("Failed to create /dev/hidg0: %s", e)
            
            self.hid_fd = open("/dev/hidg0", "wb")
            logging.info("Connected to HID gadget device")
        except Exception as e:
            logging.error("/dev/hidg0 not available: %s (continuing with uinput only)", e)
            self.hid_fd = None

        # --------------- HID state ----------------
        self._mod_state = 0
        self._keys_down: List[int] = []
        self._mouse_buttons = 0
        self._last_abs_values = {
            ABS_X: 0, ABS_Y: 0,
            ABS_RX: 0, ABS_RY: 0,
            ABS_Z: 0, ABS_RZ: 0
        }

        # --------------- rapid-fire ---------------
        self._rf_thread = threading.Thread(target=self._rapid_fire_loop, daemon=True)
        self._rf_thread.start()

    # ------------------------------------------------------------------ #
    # auto-detect
    # ------------------------------------------------------------------ #

    def _auto_detect_devices(self) -> Dict[str, str]:
        paths: Dict[str, str] = {}
        for d in list_devices():
            try:
                dev = InputDevice(d)
                if dev.info.vendor != SONY_VENDOR or dev.info.product not in PRODUCTS_DS:
                    dev.close()
                    continue
                caps = dev.capabilities()
                if ecodes.EV_ABS in caps:
                    paths.setdefault("controller", d)
                dev.close()
            except Exception as e:
                logging.warning("Error examining device %s: %s", d, e)
        
        if not paths:
            logging.warning("No DualSense controllers found. Looking for any input device...")
            # Fallback: try to find any gamepad-like device
            for d in list_devices():
                try:
                    dev = InputDevice(d)
                    caps = dev.capabilities()
                    if ecodes.EV_ABS in caps and ecodes.EV_KEY in caps:
                        # Check if it has enough buttons and axes to be a gamepad
                        if len(caps.get(ecodes.EV_KEY, [])) > 10 and len(caps.get(ecodes.EV_ABS, [])) > 4:
                            paths.setdefault("controller", d)
                            logging.info("Found alternative controller: %s", dev.name)
                    dev.close()
                except Exception:
                    pass
        
        return paths

    # ------------------------------------------------------------------ #
    # wrapper write + state
    # ------------------------------------------------------------------ #

    def _w(self, ev_type: int, code: int, value: int) -> None:
        with self._lock:
            self.uin.write(ev_type, code, value)

            if self.hid_fd is None:
                return

            if ev_type == ecodes.EV_KEY:
                if code in MOUSE_BUTTON_BITS:  # mouse buttons
                    bit = MOUSE_BUTTON_BITS[code]
                    if value:
                        self._mouse_buttons |= bit
                    else:
                        self._mouse_buttons &= ~bit
                    self._send_mouse_report(0, 0)

                elif code in MODIFIER_BITS:    # modifiers
                    bit = MODIFIER_BITS[code]
                    if value:
                        self._mod_state |= bit
                    else:
                        self._mod_state &= ~bit
                    self._send_keyboard_report()

                else:                          # "normal" keys
                    hid = EVDEV_TO_HID.get(code, 0)
                    if hid:
                        if value and hid not in self._keys_down:
                            if len(self._keys_down) >= 6:
                                self._keys_down.pop(0)
                            self._keys_down.append(hid)
                        elif not value and hid in self._keys_down:
                            self._keys_down.remove(hid)
                        self._send_keyboard_report()

            elif ev_type == ecodes.EV_REL:     # mouse movement
                if code == ecodes.REL_X:
                    self._send_mouse_report(value, 0)
                elif code == ecodes.REL_Y:
                    self._send_mouse_report(0, value)

    def _syn(self) -> None:
        with self._lock:
            self.uin.syn()

    # ------------------------------------------------------------------ #
    # HID Reports
    # ------------------------------------------------------------------ #

    def _send_keyboard_report(self) -> None:
        if self.hid_fd is None:
            return
        report = bytes(
            [0x01, self._mod_state, 0x00] +
            self._keys_down + [0x00] * (6 - len(self._keys_down)) +
            [0x00, 0x00]
        )
        try:
            self.hid_fd.write(report)
            self.hid_fd.flush()
        except Exception as e:
            logging.error("Failed to write keyboard report: %s", e)
            self.hid_fd = None  # Disable further attempts

    def _send_mouse_report(self, dx: int, dy: int) -> None:
        if self.hid_fd is None:
            return
        dx = max(-127, min(127, dx))
        dy = max(-127, min(127, dy))
        report = bytes([0x02, self._mouse_buttons, dx & 0xFF, dy & 0xFF] + [0x00] * 7)
        try:
            self.hid_fd.write(report)
            self.hid_fd.flush()
        except Exception as e:
            logging.error("Failed to write mouse report: %s", e)
            self.hid_fd = None  # Disable further attempts

    # ------------------------------------------------------------------ #
    # Config
    # ------------------------------------------------------------------ #

    def _parse_cfg(self) -> None:
        stick = self.cfg.get("stick", {})
        self.center = stick.get("center", {"x": 0, "y": 0})
        self.deadzone = stick.get("deadzone", 10)
        self.sens = stick.get("sens", 1.0)
        self.invert_y = stick.get("invert_y", False)

        # Mouse configuration
        mouse_cfg = self.cfg.get("mouse", {})
        self.mouse_sens_x = mouse_cfg.get("sens_x", 0.5)
        self.mouse_sens_y = mouse_cfg.get("sens_y", 0.5)
        
        # Rapid fire configuration
        rf = mouse_cfg.get("rapid_fire", {})
        self.rf_button = getattr(ecodes, rf.get("button", "BTN_RIGHT"), ecodes.BTN_RIGHT)
        self.rf_rate = rf.get("rate_hz", 15)
        self.rf_enabled = rf.get("enabled_by_default", False)
        
        # Key mappings
        self.key_map = self.cfg.get("key_mapping", {
            # Default basic mappings
            "BTN_SOUTH": ecodes.KEY_SPACE,        # X button -> Space
            "BTN_EAST": ecodes.KEY_ENTER,         # Circle -> Enter
            "BTN_NORTH": ecodes.KEY_E,            # Triangle -> E
            "BTN_WEST": ecodes.KEY_Q,             # Square -> Q
            "BTN_START": ecodes.KEY_ESC,          # Options -> Esc
            "BTN_SELECT": ecodes.TAB,             # Share -> Tab
            "BTN_TL": ecodes.KEY_LEFTSHIFT,       # L1 -> Left Shift
            "BTN_TR": ecodes.KEY_LEFTCTRL,        # R1 -> Left Control
        })

    # ------------------------------------------------------------------ #
    # Main loop
    # ------------------------------------------------------------------ #

    def start(self) -> None:
        try:
            while self.running:
                r, _, _ = select(self.dev_objs, [], [], 0.01)
                for dev in r:
                    for ev in dev.read():
                        self._handle_event(ev)
        except KeyboardInterrupt:
            pass
        finally:
            self.cleanup()

    def _handle_event(self, ev) -> None:
        if ev.type == ecodes.EV_KEY:
            self._handle_key(ev.code, ev.value)
        elif ev.type == ecodes.EV_ABS:
            self._handle_abs(ev.code, ev.value)

    # -------------- keys --------------

    def _handle_key(self, code: int, value: int) -> None:
        # Get button name from code
        button_name = None
        for name in dir(ecodes):
            if name.startswith("BTN_") and getattr(ecodes, name) == code:
                button_name = name
                break
        
        # Check if we have a mapping for this button
        if button_name and button_name in self.key_map:
            target_key = self.key_map[button_name]
            self._w(ecodes.EV_KEY, target_key, value)
            self._syn()
            return
            
        # Special case for rapid fire toggle
        if code == BTN_TR2 and value == 1:  # R2 press
            self.rf_enabled = not self.rf_enabled
            logging.info("Rapid fire %s", "enabled" if self.rf_enabled else "disabled")
            
        # Special case for L2 to mouse left button
        if code == BTN_TL2:
            self._w(ecodes.EV_KEY, ecodes.BTN_LEFT, value)
            self._syn()

    # -------------- axes --------------

    def _handle_abs(self, code: int, value: int) -> None:
        # Store last axis value
        self._last_abs_values[code] = value
        
        # Right stick (RX/RY) for mouse movement
        if code == ABS_RX or code == ABS_RY:
            self._process_right_stick()
            
        # Left stick (X/Y) for WASD movement
        elif code == ABS_X or code == ABS_Y:
            self._process_left_stick()
            
        # Triggers
        elif code == ABS_Z:  # L2 trigger
            # Map L2 analog to mouse left button pressure
            if value > 200:  # Apply some deadzone
                self._w(ecodes.EV_KEY, ecodes.BTN_LEFT, 1)
            else:
                self._w(ecodes.EV_KEY, ecodes.BTN_LEFT, 0)
            self._syn()
            
        elif code == ABS_RZ:  # R2 trigger
            # Could be used for variable speed in games
            pass

    def _process_right_stick(self) -> None:
        rx = self._last_abs_values[ABS_RX] - 128
        ry = self._last_abs_values[ABS_RY] - 128
        
        # Apply deadzone
        if abs(rx) < self.deadzone:
            rx = 0
        if abs(ry) < self.deadzone:
            ry = 0
            
        # Skip if no significant movement
        if rx == 0 and ry == 0:
            return
            
        # Apply sensitivity and send mouse movement
        dx = int(rx * self.mouse_sens_x / 10)
        dy = int(ry * self.mouse_sens_y / 10)
        
        # Invert Y if configured
        if self.invert_y:
            dy = -dy
            
        if dx != 0:
            self._w(ecodes.EV_REL, ecodes.REL_X, dx)
        if dy != 0:
            self._w(ecodes.EV_REL, ecodes.REL_Y, dy)
        self._syn()

    def _process_left_stick(self) -> None:
        x = self._last_abs_values[ABS_X] - 128
        y = self._last_abs_values[ABS_Y] - 128
        
        # Apply deadzone
        if abs(x) < self.deadzone:
            x = 0
        if abs(y) < self.deadzone:
            y = 0
            
        # Map to WASD keys
        keys_state = {
            ecodes.KEY_W: 0,  # Up
            ecodes.KEY_S: 0,  # Down
            ecodes.KEY_A: 0,  # Left
            ecodes.KEY_D: 0,  # Right
        }
        
        if y < -self.deadzone:
            keys_state[ecodes.KEY_W] = 1
        elif y > self.deadzone:
            keys_state[ecodes.KEY_S] = 1
            
        if x < -self.deadzone:
            keys_state[ecodes.KEY_A] = 1
        elif x > self.deadzone:
            keys_state[ecodes.KEY_D] = 1
            
        # Send key states
        for key, state in keys_state.items():
            self._w(ecodes.EV_KEY, key, state)
        self._syn()

    # ------------------------------------------------------------------ #
    # Rapid-fire
    # ------------------------------------------------------------------ #

    def _rapid_fire_loop(self) -> None:
        period = 1.0 / max(self.rf_rate, 1)
        while self.running:
            if self.rf_enabled:
                self._w(ecodes.EV_KEY, self.rf_button, 1)
                self._syn()
                time.sleep(period / 2)  # Half period down
                self._w(ecodes.EV_KEY, self.rf_button, 0)
                self._syn()
                time.sleep(period / 2)  # Half period up
            else:
                time.sleep(0.05)

    # ------------------------------------------------------------------ #
    # Cleanup
    # ------------------------------------------------------------------ #

    def cleanup(self) -> None:
        self.running = False
        try:
            self.uin.close()
            if self.hid_fd:
                self.hid_fd.close()
        finally:
            for d in self.dev_objs:
                try:
                    d.ungrab()
                except Exception:
                    pass
                d.close()


# ---------------------------------------------------------------------- #

def main() -> None:
    ap = argparse.ArgumentParser(description="DualSense → HID mapper")
    ap.add_argument("-c", "--config", default=DEFAULT_CONFIG)
    ap.add_argument("-d", "--debug", action="store_true")
    ap.add_argument("-a", "--auto", action="store_true")
    args = ap.parse_args()

    logging.basicConfig(level=logging.DEBUG if args.debug else logging.INFO,
                        format="%(asctime)s %(levelname)s: %(message)s")

    try:
        mapper = DSMapper(args.config, debug=args.debug, auto=args.auto)
        logging.info("Mapper initialized, starting event loop")
        mapper.start()
    except Exception as e:
        logging.error("Failed to start mapper: %s", e)
        sys.exit(1)


if __name__ == "__main__":
    main()
