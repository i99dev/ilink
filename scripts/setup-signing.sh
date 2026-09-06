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

# On Windows, `bash` launched from PowerShell is often WSL rather than Git
# Bash. WSL can *find* a Windows keytool.exe through interop but then hands it
# Linux paths (/home/... , /tmp/...) that it cannot open, so the keystore would
# be written somewhere unexpected or not at all. Fail early with the fix rather
# than half-working.
if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
  cat >&2 <<'WSL'
This is running under WSL, where Windows keytool cannot use Linux paths.

Run it in Git Bash instead — from PowerShell:

  & "C:\Program Files\Git\bin\bash.exe" scripts/setup-signing.sh

(or open "Git Bash" from the Start menu, cd to the repo, and run
 bash scripts/setup-signing.sh)
WSL
  exit 1
fi

# Resolve tools without depending on PATH. Windows shells disagree about it:
# Git Bash sees C:\ as /c, WSL as /mnt/c, and a `bash` launched from
# PowerShell may be either — so a PATH that works in one is empty in the other.
find_tool() {
  local name="$1"; shift
  local found
  if found=$(command -v "$name" 2>/dev/null); then printf '%s' "$found"; return 0; fi
  local prefix
  for prefix in "" /c /mnt/c /cygdrive/c; do
    local candidate
    for candidate in "$@"; do
      if [ -x "${prefix}${candidate}" ]; then printf '%s' "${prefix}${candidate}"; return 0; fi
      if [ -x "${prefix}${candidate}.exe" ]; then printf '%s' "${prefix}${candidate}.exe"; return 0; fi
    done
  done
  return 1
}

# JAVA_HOME may be a Windows path (C:\...) that this shell cannot use directly,
# so normalise it into the same /c or /mnt/c form as everything else.
java_home_bin() {
  [ -n "${JAVA_HOME:-}" ] || return 0
  printf '%s' "$JAVA_HOME" \
    | sed -e 's|\\|/|g' -e 's|^\([A-Za-z]\):|/\L\1|' \
    | sed -e 's|$|/bin/keytool|'
}

KEYTOOL=$(find_tool keytool \
  "$(java_home_bin)" \
  "/Program Files/Android/Android Studio/jbr/bin/keytool" \
  "/Program Files/Android/Android Studio1/jbr/bin/keytool" \
  "/Program Files/Java/jdk-21/bin/keytool" \
  "/Program Files/Java/jdk-17/bin/keytool" \
  "/Program Files/Eclipse Adoptium/jdk-17/bin/keytool" \
  || true)
[ -n "$KEYTOOL" ] || {
  echo "keytool not found." >&2
  echo "Tried PATH, JAVA_HOME, and the usual Android Studio / JDK locations." >&2
  echo "Set it explicitly, e.g.:" >&2
  echo "  KEYTOOL='/c/Program Files/Android/Android Studio/jbr/bin/keytool' bash scripts/setup-signing.sh" >&2
  exit 1
}

GH=$(find_tool gh "/Program Files/GitHub CLI/gh" "/Program Files (x86)/GitHub CLI/gh" || true)
[ -n "$GH" ] || { echo "gh not found — install the GitHub CLI" >&2; exit 1; }
"$GH" auth status >/dev/null 2>&1 || { echo "gh is not authenticated — run: gh auth login" >&2; exit 1; }

echo "keytool    : $KEYTOOL"
echo "gh         : $GH"

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

  "$KEYTOOL" -genkeypair -v \
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

SIGNER=$("$KEYTOOL" -list -v -keystore "$KEYSTORE" -alias "$ALIAS" \
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
"$GH" secret set DASH_RELEASE_KEYSTORE_B64 --env prod --repo "$REPO" < "$B64"
printf '%s' "$STORE_PW" | "$GH" secret set DASH_KEYSTORE_PASSWORD   --env prod --repo "$REPO"
printf '%s' "$KEY_PW" | "$GH" secret set DASH_KEY_PASSWORD        --env prod --repo "$REPO"
printf '%s' "$ALIAS" | "$GH" secret set DASH_KEY_ALIAS           --env prod --repo "$REPO"
printf '%s' "$SIGNER" | "$GH" secret set DASH_EXPECTED_SIGNER_SHA --env prod --repo "$REPO"

echo
echo "Done. Secrets now set (names only):"
"$GH" secret list --env prod --repo "$REPO"
echo
echo "Back up $KEYSTORE somewhere encrypted and off this machine before releasing."
