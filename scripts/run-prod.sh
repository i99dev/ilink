#!/usr/bin/env bash
# Release build with production defines.
#
# For development sanity: `./scripts/run-prod.sh` builds + installs a release
# APK to a connected device — the `flutter run` form keeps a hot-reload
# debugger session, BUT obfuscation is intentionally OMITTED here because
# `--obfuscate` plus a debug session breaks Flutter's symbolicated stack
# traces. Use `./scripts/build-prod-apk.sh` for the shippable artifact.
set -euo pipefail
cd "$(dirname "$0")/.."

exec flutter run \
  --release \
  --dart-define-from-file=config/prod.json \
  "$@"
