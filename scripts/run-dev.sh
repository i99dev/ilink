#!/usr/bin/env bash
# Wrapper around `flutter run` for the dev profile. Layers config/local.json
# on top of config/dev.json when present — later --dart-define-from-file
# files override earlier ones.
set -euo pipefail
cd "$(dirname "$0")/.."

args=(--dart-define-from-file=config/dev.json)
if [ -f config/local.json ]; then
  args+=(--dart-define-from-file=config/local.json)
fi

exec flutter run "${args[@]}" "$@"
