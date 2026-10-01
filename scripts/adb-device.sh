#!/usr/bin/env bash
# adb with the right device selected, on a machine where adb is not on PATH.
#
#   ./scripts/adb-device.sh devices            # list, with model names
#   ./scripts/adb-device.sh shell              # shell on the chosen device
#   ./scripts/adb-device.sh install -r build/singular80.apk
#   PREFER_MODEL="Pad" ./scripts/adb-device.sh logcat
#
# Why this exists: the workstation has TWO Xiaomi devices attached — a Pad 5
# and an 11T Pro. Bare `adb` picks whichever the daemon happens to list first,
# so an install or a logcat can silently land on the wrong one.
set -uo pipefail

ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
export ANDROID_HOME
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$PATH:$ANDROID_HOME/platform-tools"

command -v adb >/dev/null 2>&1 || { echo "adb nicht gefunden unter $ANDROID_HOME/platform-tools" >&2; exit 127; }

# Prints "serial<TAB>model" per attached device.
list_devices() {
  adb devices | awk 'NR>1 && $2=="device" {print $1}' | while read -r serial; do
    model=$(adb -s "$serial" shell getprop ro.product.model 2>/dev/null | tr -d '\r\n')
    printf '%s\t%s\n' "$serial" "${model:-unbekannt}"
  done
}

# The product string of an attached Xiaomi by USB id, e.g. "2 Xiaomi 11T Pro".
# The workstation has a Pad 5 and an 11T Pro, and both show up as the same
# RNDIS device — so this is what separates "plug the tablet in" (an action only
# the owner can take) from "switch USB debugging on" (an action at the device).
usb_product() {
  lsusb -v -d "$1" 2>/dev/null | sed -n 's/.*iProduct *\(.*\)/\1/p' | head -1
}

cmd="${1:-devices}"
[ $# -gt 0 ] && shift

case "$cmd" in
  devices)
    # Silence here would read as "no problem": an empty list and a working
    # device look the same on stdout. So an empty result states its cause, and
    # the cause decides who has to act — the owner plugs the tablet in, or
    # switches USB debugging on at whichever device is attached.
    found=$(list_devices)
    if [ -z "$found" ]; then
      if usb_product 2717:ff80 >/dev/null 2>&1 || lsusb | grep -qi xiaomi; then
        product=$(usb_product 2717:ff80); product=${product:-unbekanntes Gerät}
        cat >&2 <<MSG
Kein adb-Gerät erreichbar, aber am Kabel hängt: $product

Es ist angesteckt, exponiert aber nur USB-Tethering (RNDIS) statt der
adb-Schnittstelle. Am Gerät: Entwickleroptionen → USB-Debugging einschalten,
dann den RSA-Dialog bestätigen. Ist das ein 11T Pro und gefragt war das
Pad 5, dann zusätzlich das Tablet anstecken.
MSG
      else
        cat >&2 <<'MSG'
Kein adb-Gerät erreichbar, und nichts Xiaomi hängt am USB-Bus.

Das Tablet (Xiaomi Pad 5) ist nicht angesteckt. Bitte einstecken und am
Gerät USB-Debugging einschalten, dann den RSA-Dialog bestätigen.
MSG
      fi
      exit 1
    fi
    printf '%s\n' "$found"
    exit 0
    ;;
  wait)
    # Blocks until at least one device is present. Use this before an install
    # instead of polling by hand.
    for _ in $(seq 1 "${1:-60}"); do
      [ -n "$(list_devices)" ] && { list_devices; exit 0; }
      sleep 1
    done
    echo "Kein adb-Gerät nach ${1:-60}s. USB-Debugging auf dem Gerät aktiv?" >&2
    exit 1
    ;;
esac

devices=$(list_devices)
if [ -z "$devices" ]; then
  cat >&2 <<'MSG'
Kein Gerät über adb erreichbar.

`lsusb` zeigt die Geräte gern an, adb aber nicht: ohne aktiviertes
USB-Debugging exponiert ein Xiaomi-Gerät nur MTP (2717:ff40) oder RNDIS
(2717:ff80) und damit gar keine adb-Schnittstelle. Am Gerät:
Entwickleroptionen → USB-Debugging an, dann den RSA-Dialog bestätigen.
Als Ausweg ohne Kabel: Drahtloses Debugging → "Kopplung mit Code", dann
  adb pair <IP>:<Port>
MSG
  exit 1
fi

count=$(printf '%s\n' "$devices" | wc -l)

# Auswahl: explizite Serial, dann Modell-Präferenz, dann bei mehreren Geräten
# nachfragen statt zu raten.
if [ -n "${DEVICE_SERIAL:-}" ]; then
  serial="$DEVICE_SERIAL"
elif [ -n "${PREFER_MODEL:-}" ] && [ "$count" -gt 1 ]; then
  serial=$(printf '%s\n' "$devices" | grep -i "$PREFER_MODEL" | head -1 | cut -f1)
  [ -z "$serial" ] && serial=$(printf '%s\n' "$devices" | head -1 | cut -f1)
elif [ "$count" -gt 1 ]; then
  echo "Mehrere Geräte verbunden — eines wählen (oder PREFER_MODEL=… setzen):" >&2
  printf '%s\n' "$devices" | sed 's/^/  /' >&2
  exit 2
else
  serial=$(printf '%s\n' "$devices" | head -1 | cut -f1)
fi

model=$(printf '%s\n' "$devices" | grep -F "$serial" | cut -f2)
[ "$cmd" = "shell" ] || echo "# $model ($serial)" >&2
exec adb -s "$serial" "$cmd" "$@"
