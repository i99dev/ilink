#!/usr/bin/env bash
# Centralisation gate for the Dart side: every tool/app-action shell
# op MUST go through `lib/core/shell/shell_tool_bridge.dart` (which
# in turn routes via the `ilink/tools_shell` MethodChannel and the
# Kotlin-side `AdbShellBridge`).
#
# What this rule covers: Dart code reaching directly into the
# `ilink/adb_bootstrap` MethodChannel (the bootstrap-only API),
# OR a hypothetical second MethodChannel that bypasses ShellToolBridge.
# Existing Kotlin platform plugins (display, input, network, pkg,
# car) call `AdbShellBridge.shell()` directly — that's fine; they
# have their own MethodChannels and predate the Tools/AppActions
# centralisation.
#
# Wire this into CI: GitHub Actions, GitLab CI, Husky pre-push, etc.
# Exit 0 = clean. Exit 1 = found a violator.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# Dart-side patterns we forbid outside the bridge:
#   * `MethodChannel('ilink/adb_bootstrap')` — the bootstrap channel
#     is for status/retry only; new shell paths should use
#     `ilink/tools_shell` via ShellToolBridge.
#   * Any `MethodChannel('ilink/tools_shell')` instantiation outside
#     `lib/core/shell/` — the bridge owns the channel name.
PATTERN="MethodChannel\\(\\s*['\"]ilink/(adb_bootstrap|tools_shell)['\"]"

# Files we tolerate the pattern in — the bridge implementations.
ALLOWED='^(lib/core/shell/|lib/core/access/adb_bootstrap\.dart$|test/)'

violators="$(
  { grep -rEn "$PATTERN" lib --include='*.dart' 2>/dev/null || true; } \
    | { grep -vE "$ALLOWED" || true; }
)"

if [ -n "$violators" ]; then
  echo "ERROR: direct shell-channel access outside lib/core/shell/:"
  echo "$violators"
  echo
  echo "All Dart-side tool/app-action shell ops must route through"
  echo "ShellToolBridge / ShellOpsCoordinator."
  echo "See lib/features/tools/ARCHITECTURE.md."
  exit 1
fi
echo "OK — no direct shell-channel access outside lib/core/shell/."
