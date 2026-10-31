#!/usr/bin/env bash
# Build and flash the board (needs arduino-cli and the esp32 core 3.3.x).
# Usage: hardware/flash.sh [port] [--debug] [--sta] [--build-only] [--ota IP]
#   --debug       log commands and the AirPlay handshake on USB serial
#   --sta         test build: join the Wi-Fi in hid_bridge/secrets.h instead of opening a hotspot
#   --build-only  compile only (prints flash/RAM usage)
#   --ap-tune     A/B build: hotspot on a 20 MHz channel with 300 TU beacons (more airtime for BLE)
#   --ota IP      upload over Wi-Fi instead of USB; get IP and password from the board's `ota on`.
#                 The password is read from $OTA_PASS and never printed, so it stays out of logs.
#                 The board connects back on $OTA_CALLBACK_PORT (default 3233), so the host firewall
#                 needs that port open from the board's subnet: ufw allow from 192.168.5.0/24 to any
#                 port 3233 proto tcp
# BLE host: h2zero NimBLE-Arduino (arduino-cli lib install "NimBLE-Arduino"); its buffer sizes live in
# hid_bridge/nimble_cfg.h, force-included into every C/C++ file below.
# A running bridge is a TinyUSB device, so it is first kicked into the ROM
# bootloader with a 1200-baud touch; a blank board is flashed directly.
set -euo pipefail
cd "$(dirname "$0")"
FQBN="esp32:esp32:esp32s3:USBMode=default,CDCOnBoot=cdc,FlashSize=8M,PSRAM=opi,PartitionScheme=default_8MB"
ports() { for p in /dev/cu.usbmodem* /dev/ttyACM*; do [[ -e $p ]] && echo "$p"; done; return 0; }
PORT="" DEFS="" BUILD_ONLY=0 OTA=0 OTA_IP=""
for a in "$@"; do
  case $a in
    --debug) DEFS+=" -DDEBUG_SERIAL=1" ;;
    --sta) [[ -f hid_bridge/secrets.h ]] || { echo "--sta needs hid_bridge/secrets.h (see secrets.example.h)"; exit 1; }
           DEFS+=" -DSTA_FROM_SECRETS=1" ;;
    --build-only) BUILD_ONLY=1 ;;
    --ota) OTA=1 ;;
    --ap-tune) DEFS+=" -DAP_TUNE=1" ;;
    *) if (( OTA )) && [[ -z $OTA_IP ]]; then OTA_IP=$a; else PORT=$a; fi ;;
  esac
done
[[ $PWD != *" "* ]] || { echo "the -include path below cannot contain spaces: $PWD"; exit 1; }
DEFS+=" -include $PWD/hid_bridge/nimble_cfg.h"
FLAGS=(--build-property "compiler.cpp.extra_flags=$DEFS" --build-property "compiler.c.extra_flags=$DEFS")

arduino-cli compile -b "$FQBN" "${FLAGS[@]}" --output-dir build hid_bridge
(( BUILD_ONLY )) && exit 0
if (( OTA )); then
  [[ -n $OTA_IP ]] || { echo "--ota needs the board's IP: hardware/flash.sh --ota 192.168.x.y"; exit 1; }
  [[ -n ${OTA_PASS:-} ]] || { echo "set OTA_PASS to the password from the board's 'ota on' reply"; exit 1; }
  python3 /home/admin/.arduino15/packages/esp32/hardware/esp32/3.3.12/tools/espota.py \
    -i "$OTA_IP" -a "$OTA_PASS" -P "${OTA_CALLBACK_PORT:-3233}" -t "${OTA_TIMEOUT:-180}" -f build/hid_bridge.ino.bin
  exit 0
fi
BEFORE=$(ports)
PORT=${PORT:-$(head -n 1 <<<"$BEFORE")}
[[ -n $PORT ]] || { echo "no board found (looked for /dev/cu.usbmodem* and /dev/ttyACM*)"; exit 1; }
stty -f "$PORT" 1200 2>/dev/null || stty -F "$PORT" 1200 2>/dev/null || true
# The ROM bootloader may come back under a new name. Follow the port that appeared after the
# reset rather than the first one listed, so other connected boards are never picked up.
new_ports() { comm -13 <(sort <<<"$BEFORE") <(ports | sort); }
for _ in $(seq 20); do sleep 0.5; [[ -n $(new_ports) ]] && break; done
sleep 1  # let the ROM bootloader's serial come up
NEW=$(new_ports)
case $(grep -c . <<<"$NEW" || true) in
  0) [[ -e $PORT ]] || { echo "$PORT is gone after the reset and no new port appeared"; exit 1; } ;;
  1) PORT=$NEW ;;
  *) echo "several ports appeared after the reset, not guessing:" $NEW; exit 1 ;;
esac
arduino-cli upload -b "$FQBN" -p "$PORT" --input-dir build hid_bridge
