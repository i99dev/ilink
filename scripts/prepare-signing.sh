#!/usr/bin/env bash
# Validate the release signing identity. Never creates a keystore.
#
# The expected certificate fingerprint comes from DASH_EXPECTED_SIGNER_SHA
# (shell env, or the gitignored .env — see .env.example). It is deliberately
# NOT hardcoded: iLINK ships under its own applicationId with its own signing
# key, so pinning a fingerprint in the repository would both leak which key is
# in use and make rotating it a source change.
#
# The check still has teeth. Android will not install an update signed by a
# different key than the installed app, so silently building with the wrong
# keystore produces artifacts that no existing install can accept. Set the
# variable once, and every later build is checked against it.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -f .env ]; then set -a; source .env; set +a; fi
: "${DASH_KEYSTORE_PATH:?Set the release keystore path outside the repository}"
: "${DASH_KEYSTORE_PASSWORD:?Store password is required}"
: "${DASH_KEY_PASSWORD:?Key password is required}"
: "${DASH_EXPECTED_SIGNER_SHA:?Set the expected certificate SHA-256 (see .env.example)}"
# Validate the fingerprint before touching the keystore, so a typo is reported
# as a typo rather than as a missing-keystore error.
# Accept it with or without colons, in either case.
EXPECTED=$(printf '%s' "$DASH_EXPECTED_SIGNER_SHA" | tr -d ': \r\n' | tr '[:upper:]' '[:lower:]')
if ! printf '%s' "$EXPECTED" | grep -Eq '^[0-9a-f]{64}$'; then
  echo "DASH_EXPECTED_SIGNER_SHA must be a SHA-256 (64 hex characters)" >&2
  exit 1
fi

test -s "$DASH_KEYSTORE_PATH" || { echo "Keystore not found or empty: $DASH_KEYSTORE_PATH" >&2; exit 1; }
export DASH_KEYSTORE_PASSWORD

SIGNER=$(keytool -list -v -keystore "$DASH_KEYSTORE_PATH" -alias "${DASH_KEY_ALIAS:-dash}" -storepass:env DASH_KEYSTORE_PASSWORD 2>/dev/null | awk '/SHA256:/ {gsub(":", ""); print tolower($2); exit}')
test -n "$SIGNER" || { echo "Could not read a certificate from the keystore (wrong alias or password?)" >&2; exit 1; }
test "$SIGNER" = "$EXPECTED" || {
  echo "Release signer does not match DASH_EXPECTED_SIGNER_SHA." >&2
  echo "  keystore: $SIGNER" >&2
  echo "  expected: $EXPECTED" >&2
  exit 1
}
echo "Release signing identity verified."
