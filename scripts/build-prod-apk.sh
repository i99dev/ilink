#!/usr/bin/env bash
# Build with standalone production settings. Debug is the default.
# For --release, supply the original external keystore and signing environment.
# See RELEASE.md. Never create a replacement release signing identity.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="config/prod.json"

if [ ! -f "$CONFIG" ]; then
  echo "error: $CONFIG missing — re-clone or check working dir." >&2
  exit 1
fi

mode="apk"
defines=(--dart-define-from-file="$CONFIG")

# Optional layered local override — same shape scripts/run-dev.sh uses.
if [ -f "config/local.json" ]; then
  defines+=(--dart-define-from-file=config/local.json)
fi

# Default to debug so this script doubles as a "verify the dart-defines
# are wired" smoke build. Pass --release to opt into the release-mode
# build that mirrors the CI artifact shape.
if [ "${1:-}" = "--release" ]; then
  shift
  exec flutter build apk --release "${defines[@]}" "$@"
fi

exec flutter build apk --debug "${defines[@]}" "$@"
