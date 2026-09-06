#!/usr/bin/env bash
# Validate the existing external signing identity. Never creates a keystore.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -f .env ]; then set -a; source .env; set +a; fi
: "${DASH_KEYSTORE_PATH:?Set the existing keystore path outside the repository}"
: "${DASH_KEYSTORE_PASSWORD:?Existing store password is required}"
: "${DASH_KEY_PASSWORD:?Existing key password is required}"
test -s "$DASH_KEYSTORE_PATH"
export DASH_KEYSTORE_PASSWORD
SIGNER=$(keytool -list -v -keystore "$DASH_KEYSTORE_PATH" -alias "${DASH_KEY_ALIAS:-dash}" -storepass:env DASH_KEYSTORE_PASSWORD 2>/dev/null | awk '/SHA256:/ {gsub(":", ""); print tolower($2); exit}')
test "$SIGNER" = 2a4700925fe0c230c9bac63ab194ff9500a58a4ac0825c2196ee9ac7f33fc264 || { echo "Release signer differs from existing installs" >&2; exit 1; }
echo "Existing release signing identity verified."
