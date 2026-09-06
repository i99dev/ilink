#!/usr/bin/env bash
# Capture the live-feature dump for the currently-running car.
#
# Usage:
#   TARGET=192.168.4.72:5555 ./docs/featuresId/dump.sh <trim_name>
#
# Example:
#   ./docs/featuresId/dump.sh leopard8_dilink5.1
#
# Output:
#   docs/featuresId/<trim_name>.tsv        — name<TAB>value
#   docs/featuresId/<trim_name>.meta.json  — capture metadata
#
# Pre-reqs:
#   * The target car must be reachable over ADB at $TARGET (default
#     192.168.4.72:5555)
#   * The ilink app must be installed and running with the
#     AutoCarRegistry built (give it 30 s after cold boot)
#   * `adb` and `jq` on PATH
#
# Two-step capture flow:
#
#   1) On the car: open Settings → Diagnostics → Auto registry, then
#      tap the SD-card icon in the AppBar. The app writes
#      /sdcard/ilink_features.tsv with the current snapshot.
#
#   2) On the host: run this script with the trim name. It pulls the
#      file off /sdcard and writes the canonical files in this dir.
#
# This script does NOT need release secrets — it only reads. The
# captured TSV is checked into the repo unencrypted (catalog names
# are reflections of public framework constants).
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <trim_name>" >&2
  echo "  example: $0 leopard8_dilink5.1" >&2
  exit 1
fi

TRIM="$1"
TARGET="${TARGET:-192.168.4.72:5555}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_TSV="$ROOT/docs/featuresId/${TRIM}.tsv"
OUT_META="$ROOT/docs/featuresId/${TRIM}.meta.json"
SD_PATH="/sdcard/Android/data/com.i99dev.ilink/files/ilink_features.tsv"

echo "==> target: $TARGET"
echo "==> trim:   $TRIM"
echo "==> output: $OUT_TSV"

# Connect (no-op if already connected).
adb connect "$TARGET" >/dev/null

# Verify the snapshot file exists. If not, prompt the user to tap
# the in-app capture button.
if ! adb -s "$TARGET" shell "[ -f $SD_PATH ]" 2>/dev/null; then
  echo "" >&2
  echo "ERROR: $SD_PATH not present on the device." >&2
  echo "" >&2
  echo "  On the car: Settings → Diagnostics → Auto registry → tap" >&2
  echo "  the SD-card icon in the AppBar. Then re-run this script." >&2
  echo "" >&2
  exit 2
fi

# Pull and sort. The in-app dump is already sorted, but re-sort
# defensively for stable diffs across captures.
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
adb -s "$TARGET" pull "$SD_PATH" "$TMP" >/dev/null
mkdir -p "$(dirname "$OUT_TSV")"
sort "$TMP" > "$OUT_TSV"

LIVE_COUNT=$(wc -l < "$OUT_TSV" | tr -d ' ')
echo "==> wrote $LIVE_COUNT entries to $OUT_TSV"

# Pull metadata from the device props.
DILINK_VERSION=$(adb -s "$TARGET" shell getprop ro.build.dilink.version 2>/dev/null | tr -d '\r' || echo "unknown")
ANDROID_BUILD=$(adb -s "$TARGET" shell getprop ro.build.fingerprint 2>/dev/null | tr -d '\r' || echo "unknown")
APP_VERSION=$(adb -s "$TARGET" shell dumpsys package com.i99dev.ilink 2>/dev/null | grep -m1 versionName | sed 's/.*versionName=//' | tr -d '\r' || echo "unknown")

cat > "$OUT_META" <<EOF
{
  "trim": "$TRIM",
  "captured_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "dilink_version": "$DILINK_VERSION",
  "android_build": "$ANDROID_BUILD",
  "app_version": "$APP_VERSION",
  "live_feature_count": $LIVE_COUNT,
  "source": "AutoCarRegistry snapshot via in-app SD-card export",
  "notes": "Sample values are point-in-time at capture; treat as schema-only. The SDK reads name from this file and fetches fresh values at boot."
}
EOF

echo "==> wrote metadata to $OUT_META"
echo ""
echo "Cleanup on device (optional):"
echo "  adb -s $TARGET shell rm $SD_PATH"
echo ""
echo "Next steps:"
echo "  1. Diff against any previous capture for this trim — large"
echo "     deltas mean a ROM update on the car."
echo "  2. Commit both files."
echo "  3. The SDK seed will pick them up at next boot once Stage 2"
echo "     of the removal plan is wired (see docs/featuresId/README.md)."
