#!/usr/bin/env bash
# Validate checked-in offline assets and prepare the existing release signer pin.
# Command tables, unit DEX and BYD metadata are public checked-in assets.
# This script never reads a fleet ADB credential or private command source.
set -euo pipefail
cd "$(dirname "$0")/../.."

STRICT="${CI:-false}"
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=true ;;
    --no-strict) STRICT=false ;;
  esac
done

for required in \
  android/app/src/main/assets/offline/car_table.textproto \
  android/app/src/main/assets/offline/mini_app_table.textproto \
  android/app/src/main/assets/offline/units/manifest.json \
  android/app/src/main/assets/offline/voice/en-0.15.zip \
  assets/byd/catalog.tsv assets/byd/catalog_meta.yaml; do
  test -s "$required" || { echo "Missing public offline asset: $required" >&2; exit 1; }
done
# Old incremental builds may have left the retired shared private-key asset.
rm -f android/app/src/main/assets/adb_key.enc

KEYSTORE="${DASH_KEYSTORE_PATH:-${DASH_KEYSTORE:-}}"
if [ -z "${KEYSTORE_PASSWORD:-}" ] && [ -f .env ]; then
  KEYSTORE_PASSWORD="$(awk -F= '/^DASH_KEYSTORE_PASSWORD=/ {sub(/^DASH_KEYSTORE_PASSWORD=/, ""); print; exit}' .env)"
fi
ALIAS="${KEYSTORE_ALIAS:-${DASH_KEY_ALIAS:-dash}}"
if [ ! -f "$KEYSTORE" ] || [ -z "${KEYSTORE_PASSWORD:-}" ]; then
  if [ "$STRICT" = true ]; then
    echo "Release signer unavailable: supply your keystore path, alias and password." >&2
    exit 1
  fi
  echo "Public offline assets ready; no release signer configured."
  exit 0
fi
export KEYSTORE_PASSWORD
SIGNER_SHA="$(keytool -list -v -keystore "$KEYSTORE" -alias "$ALIAS" \
  -storepass:env KEYSTORE_PASSWORD 2>/dev/null \
  | awk '/SHA256:/ {gsub(":", ""); print tolower($2); exit}')"
[[ "$SIGNER_SHA" =~ ^[0-9a-f]{64}$ ]] || { echo "Could not derive release signer SHA-256." >&2; exit 1; }
export DASH_EXPECTED_SIGNER_SHA="$SIGNER_SHA"
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "DASH_EXPECTED_SIGNER_SHA=$SIGNER_SHA" >> "$GITHUB_ENV"
fi
echo "Public offline assets ready; release signer pin prepared."
