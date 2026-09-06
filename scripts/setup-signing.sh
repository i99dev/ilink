#!/usr/bin/env bash
# One-shot signing setup for iLINK releases.
#
# Generates the release keystore, derives its certificate fingerprint, and
# uploads the five secrets the release workflow needs to the `prod` GitHub
# environment. Run it yourself: passwords are read from your terminal with
# echo disabled and are never printed, logged, or passed as arguments.
#
#   bash scripts/setup-signing.sh
#
# Re-running with an existing keystore is safe — it will reuse that file and
# only refresh the secrets.
set -euo pipefail

REPO="${REPO:-i99dev/ilink}"
ALIAS="${ALIAS:-dash}"
# Deliberately outside the repository so the key can never be committed.
KEYSTORE="${KEYSTORE:-$HOME/ilink-release.jks}"

command -v keytool >/dev/null || { echo "keytool not found — install a JDK or add Android Studio's jbr/bin to PATH" >&2; exit 1; }
command -v gh >/dev/null      || { echo "gh not found — install the GitHub CLI" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh is not authenticated — run: gh auth login" >&2; exit 1; }

echo "Repository : $REPO"
echo "Keystore   : $KEYSTORE"
echo "Alias      : $ALIAS"
echo

if [ -f "$KEYSTORE" ]; then
  echo "Keystore already exists — reusing it (no new key is generated)."
  read -r -s -p "Store password: " STORE_PW; echo
  read -r -s -p "Key password  : " KEY_PW; echo
else
  echo "Creating a new keystore. Choose a strong password and store it in a"
  echo "password manager — losing it means no future build can ever update an"
  echo "installed iLINK."
  echo
  read -r -s -p "Store password        : " STORE_PW; echo
  read -r -s -p "Confirm store password: " STORE_PW2; echo
  [ "$STORE_PW" = "$STORE_PW2" ] || { echo "Passwords do not match." >&2; exit 1; }
  [ ${#STORE_PW} -ge 12 ] || { echo "Use at least 12 characters." >&2; exit 1; }
  # One password for both is normal for a release keystore and keeps Gradle simple.
  KEY_PW="$STORE_PW"

  keytool -genkeypair -v \
    -keystore "$KEYSTORE" \
    -alias "$ALIAS" \
    -keyalg RSA -keysize 4096 -validity 10000 \
    -storepass:env STORE_PW -keypass:env KEY_PW \
    -dname "CN=iLINK, OU=iLINK, O=iLINK, L=, ST=, C=" \
    >/dev/null
  chmod 600 "$KEYSTORE" 2>/dev/null || true
  echo "Created $KEYSTORE"
fi
export STORE_PW KEY_PW

SIGNER=$(keytool -list -v -keystore "$KEYSTORE" -alias "$ALIAS" \
  -storepass:env STORE_PW 2>/dev/null \
  | awk '/SHA256:/ {gsub(":", ""); print tolower($2); exit}')
printf '%s' "$SIGNER" | grep -Eq '^[0-9a-f]{64}$' || {
  echo "Could not read the certificate — wrong password or alias?" >&2; exit 1; }
echo "Certificate SHA-256: $SIGNER"

# base64 of the keystore, written with a restrictive umask and removed after upload.
B64=$(mktemp)
trap 'rm -f "$B64"' EXIT
( umask 077; base64 -w0 "$KEYSTORE" > "$B64" 2>/dev/null || base64 -i "$KEYSTORE" | tr -d '\n' > "$B64" )

echo
echo "Uploading secrets to the '$REPO' prod environment..."
gh secret set DASH_RELEASE_KEYSTORE_B64 --env prod --repo "$REPO" < "$B64"
printf '%s' "$STORE_PW" | gh secret set DASH_KEYSTORE_PASSWORD   --env prod --repo "$REPO"
printf '%s' "$KEY_PW"   | gh secret set DASH_KEY_PASSWORD        --env prod --repo "$REPO"
printf '%s' "$ALIAS"    | gh secret set DASH_KEY_ALIAS           --env prod --repo "$REPO"
printf '%s' "$SIGNER"   | gh secret set DASH_EXPECTED_SIGNER_SHA --env prod --repo "$REPO"

echo
echo "Done. Secrets now set (names only):"
gh secret list --env prod --repo "$REPO"
echo
echo "Back up $KEYSTORE somewhere encrypted and off this machine before releasing."
