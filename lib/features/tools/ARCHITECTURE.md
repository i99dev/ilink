# Tools + AppActions architecture

Two cooperating features that share `lib/core/shell/`:

- **`features/tools/`** — Tools strip on the home screen. Replaces
  `HeroPanel`. Currently exposes one circle (Network) that opens a
  bottom sheet with WiFi / Cellular / Roaming / Bluetooth / Hotspot
  rows. Adding a tool = one row in `tools_registry.dart` + one
  section file under `presentation/sheets/`.

- **`features/app_actions/`** — Long-press on any app tile (native
  installed apps; mini-apps when `FeatureFlags.unifiedMiniAppActionsSheet`
  flips) opens an actions sheet with display-launch chips + 7
  management actions (Enable, Disable, Uninstall, Move, Force-stop,
  Clear data, Whitelist).

Both features go through one shell bridge, one ops coordinator, and
share a generic `ActionDef<TTarget, TState>` registry shape.

## Why one shared `lib/core/shell/`

Two features with similar patterns (read shell output → parse →
write back via shell) would otherwise have two copies of:

- A MethodChannel
- A cache layer
- An in-flight dedup
- A cancellation surface
- A PII filter

Centralising the bridge means:

1. **One process-wide cache.** When the Tools poll fires
   `dumpsys wifi` and the AppActionsSheet opens 200ms later asking
   for the same dump, the second caller hits cache.
2. **In-flight dedup.** Two concurrent calls with the same
   `cacheKey` share one underlying Future — second caller doesn't
   re-shell.
3. **Coalesced writes.** Spam-tap a Force-stop button → 5 calls
   inside 1s coalesce to 1 exec.
4. **Cancellation.** Sheet dismissed mid-write → token cancelled →
   pending shell race resolves via `Future.any`, the orphan exec
   completes silently in the background.
5. **PII filter.** All shell breadcrumbs go through
   `ShellBreadcrumbFilter`. Package names + dotted system property
   keys are SHA-256 hashed (truncated to 32 bits). Bare commands
   (`pm`, `am`, `dumpsys`, `svc`, …) and flags (`--user`, `0`, etc.)
   pass through verbatim so support engineers can still triage by
   command shape.

Lint enforcement: `scripts/ci/check_no_direct_shell.sh` fails the
build if `AdbBootstrap.shell()` or `AdbShellBridge.shell()` is
referenced anywhere outside `lib/core/shell/`. Add new shell paths
inside the bridge — never reach around it.

## Registry pattern

`core/registry/action_def.dart` defines `ActionDef<TTarget, TState>`.
Both registries use it:

- `features/tools/registry/tools_registry.dart` — `Tool` (similar
  shape, kept distinct for the sheet-builder vs eligibility-only
  difference).
- `features/app_actions/registry/app_actions_registry.dart` —
  `ActionDef<AppTarget, AppMeta>`.

Each entry declares: id (analytics + tests), iconBuilder, labelKey,
eligibility, severity, optional confirmKey + typedToken.

**Adding a new action**:
1. Add an enum value to `AppActionKind` (or `ToolKind`).
2. Add a row to the registry file.
3. Add a writer mapping in `package_actions_writer.dart` (or
   `connectivity_writer.dart`).
4. Add `appAction<Name>` and any confirm strings to en + ar arb.
5. Add a row to `<feature>_registry_test.dart` if the registry
   validation test enumerates ids.

That's the entire change. The sheet, widget, controller, dispatcher
do not change.

## Performance properties

- **One MethodChannel crossing per shell call.** `ToolsBridgePlugin`
  joins argv on the platform side so we never serialise the join
  twice.
- **5s read TTL.** Polling cadence on the Tools strip is 5s; sheet
  opens reuse cached values transparently.
- **Throttled writes.** Coalesce window is 1s; same-key writes
  within the window share one exec.
- **Lazy bottom sheets.** `showModalBottomSheet(builder: ...)`
  defers widget construction to tap time. Sections in
  `presentation/sheets/` are tree-shakable.
- **`select()` projections.** Tool circles watch only the field
  they care about — a wifi tick doesn't repaint the bluetooth
  circle.
- **`RepaintBoundary` per circle.** Independent paint layers; a
  state flip on one tool doesn't repaint the others.
- **Optimistic UI with rollback.** Tap → meta patched immediately;
  shell write fires; on failure the snapshot is restored.

## Maintenance posture

- **No magic strings.** Action ids are an enum; commands are
  argv lists, not concatenated strings.
- **No direct AdbBootstrap.** Custom CI grep script enforces the
  bridge-only path.
- **Golden-file parser tests.** `connectivity_reader_test.dart`
  and `package_meta_reader_test.dart` pin parser behaviour to
  recorded BYD output. When DiLink rev N+1 changes a line format,
  the test fails before it hits production.
- **Registry validation tests.**
  `app_actions_registry_test.dart` and `tools_registry_test.dart`
  assert every entry resolves required fields (label key, severity
  matches confirm requirements, etc.).
- **Single ARCHITECTURE doc.** This file + inline registry
  docstrings. Avoid drift.

## Mini-app long-press migration

`FeatureFlags.unifiedMiniAppActionsSheet` is OFF by default.

- Default: mini-app long-press → legacy `showMiniAppActionsSheet`
  (display chips + uninstall).
- When flipped: mini-app long-press → unified `showAppActionsSheet`
  with the registry's full 7 actions. Most are filtered out by
  `eligible(meta)` since mini-apps lack a backing Android package
  — the sheet effectively renders display chips + Uninstall (via
  the catalog API, not `pm`).

Soak the unified sheet on the native-apps tab for a release before
flipping the flag.
