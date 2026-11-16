#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ILOADER="$SCRIPT_DIR/iloader"
IPA_FILE="$ROOT_DIR/companion-ios/RoundDashCompanion.ipa"

echo "========================================================"
echo "  RoundDash Copilot — iLoader v2.4.1 (403 Fix Included)"
echo "========================================================"

if [[ ! -f "$IPA_FILE" ]]; then
    echo "[ERROR] IPA file not found at: $IPA_FILE"
    exit 1
fi

echo "[1/2] Checking iPhone USB connection..."
UDID="$(timeout 3 idevice_id -l 2>/dev/null | head -n 1 || true)"

if [[ -z "$UDID" ]]; then
    echo "      Restarting usbmuxd with --no-preflight (-p)..."
    sudo killall -9 usbmuxd 2>/dev/null || true
    sleep 1
    sudo /usr/sbin/usbmuxd -p --user usbmux
    sleep 2
    UDID="$(timeout 5 idevice_id -l 2>/dev/null | head -n 1 || true)"
fi

echo "Found iPhone UDID: $UDID"
idevicepair -u "$UDID" validate >/dev/null 2>&1 || idevicepair -u "$UDID" pair

echo ""
echo "[2/2] Opening iLoader v2.4.1 window..."
echo "      1. Log in with your Apple ID (jornkorff1@gmail.com)"
echo "      2. Choose 'Custom IPA' -> select:"
echo "         $IPA_FILE"
echo "      3. Click Install!"
echo ""

"$ILOADER"
