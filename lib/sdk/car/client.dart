/// Brand-agnostic reactive client interface.
///
/// Each brand adapter implements [CarClient] by wrapping its own
/// MethodChannel + EventChannel pair. Consumers ALWAYS read through
/// [carClientProvider] — the runtime resolves to the correct brand
/// adapter via [currentBrandProvider].
///
/// The interface is intentionally narrow:
///   - `value(name)` — sync read of last-seen value
///   - `watch(name)` — push-driven `Stream<int?>`
///   - `liveFeatures()` — bulk snapshot
///   - `invoke(actionId)` — write API
///
/// Brand-specific extensions (e.g. BYD's setInt area parameter,
/// Geely's binder transactions) live on the concrete adapter; cast
/// the [CarClient] to the brand class to access them when needed.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../brands/byd/byd_client.dart';
import 'brand.dart';
import 'car_caller.dart';

abstract class CarClient {
  /// Sync read of the most-recent value for [name]. Null when the
  /// feature has never produced a value (push not yet received,
  /// brand framework absent, etc.).
  int? value(String name);

  /// Force a LIVE read of [name] from the brand host, updating the hot
  /// cache (and [freshness]) on success. Returns null if the host can't
  /// supply it (offline / unknown / timeout — caller decides the fallback).
  ///
  /// Use when a decision needs a TRUSTWORTHY current value rather than the
  /// last pushed one. The motivating case is the stationary speed gate:
  /// brands that push deltas (BYD) can miss the "now stopped" frame, leaving
  /// a stale "moving" value cached — a plain [value] read would then wrongly
  /// block actuators (open window, unlock) on a parked car. A constant-cruise
  /// value is the mirror risk (few deltas → stale, but really moving), so a
  /// freshness check alone can't decide; this forces the ground truth.
  Future<int?> refreshValue(String name);

  /// Push-driven stream of value changes. Emits the current value
  /// (or null) immediately, then whenever the brand framework
  /// dispatches a new value for [name].
  Stream<int?> watch(String name);

  /// Snapshot of all currently-live features. Bulk read from the
  /// brand host; cached locally and refreshed on subsequent calls.
  Future<Map<String, int>> liveFeatures();

  /// Sync read of the current hot cache — every catalog name we've
  /// seen at least one push for. Returns an empty map before the
  /// first push frame lands. Use for snapshot-style consumers that
  /// can't await (sync getters, voice tool's `car_status` wire shape).
  Map<String, int> liveFeaturesSync();

  /// Catalog-name → integer-id for every feature this brand's
  /// framework exposes. Stable across the app's lifetime; pulled
  /// from the bundled catalog asset, NOT runtime reflection.
  Future<Map<String, int>> allCatalogNames();

  /// Gated write — routes through `CarCommandRouter` which runs
  /// audit log, integrity check, rate limit, and stationary speed
  /// gate. **Use this for normal app code** (tiles, mini-app `_admin`,
  /// voice tools).
  ///
  /// Action ids come from the brand's catalog (`.secrets/car_table/`
  /// for BYD's fast_actions / unit_actions). Returns the gate's reply
  /// — typically `{ok: true}` on success or `{error: <code>}` when a
  /// gate refuses.
  Future<Map<String, Object?>> dispatch(
    String actionId, {
    Map<String, Object?> args = const {},
    CarCaller? caller,
  });

  /// Dispatch then wait for [name]'s value to satisfy [expect] within
  /// [timeout]. Returns a [DispatchResult] carrying the dispatch reply
  /// AND a `confirmed` flag indicating whether the expected state was
  /// observed. Use this for write-then-verify flows ("door.lock then
  /// confirm DOOR_LOCK_COMMAND_AREA_LEFT_FRONT == 0").
  Future<DispatchResult> dispatchAndConfirm(
    String actionId, {
    required String name,
    required bool Function(int) expect,
    Duration timeout = const Duration(seconds: 5),
    Map<String, Object?> args = const {},
    CarCaller? caller,
  });

  /// Bypass the command-router gate — straight to the brand's
  /// `runAction`. **Only for trusted callers** (test bench, admin
  /// surfaces that have already enforced safety). Most code should
  /// use [dispatch].
  Future<Map<String, Object?>> invoke(
    String actionId, [
    Map<String, Object?> args = const {},
  ]);

  /// Broadcast tick on every push frame. The event carries the catalog
  /// name that changed, or an EMPTY string for a batch/unknown frame
  /// (boot seed, persist-restore, multi-name recompute) where the caller
  /// must re-check all the names it tracks.
  ///
  /// Snapshot-style consumers (typed gate builders, mini-app fan-out)
  /// subscribe once here instead of allocating one [watch] per field, and
  /// can O(1)-skip a per-name frame for a name they don't track instead of
  /// re-walking their whole label set every push. Use [value] inside the
  /// listener to read whichever fields the consumer cares about — the hot
  /// cache is up-to-date by the time this fires.
  Stream<String> changes();

  /// How long ago the last value for [name] arrived. Returns `null`
  /// if the SDK has never received a value for [name]. Use to render
  /// a stale chip on tiles when the daemon disconnects:
  ///
  /// ```dart
  /// final age = client.freshness('Statistic.STATISTIC_SOC_BATTERY_PERCENTAGE');
  /// final stale = age != null && age > const Duration(seconds: 10);
  /// ```
  Duration? freshness(String name);

  // ── Diagnostics + orthogonal surfaces ───────────────────────────
  // None of these are "car data" per se — they're host-side probes
  // (daemon health, HU identity), orthogonal channels (BYD
  // ContentProvider observation), or build-time contracts. Lifted
  // onto CarClient so consumers don't reach past the SDK to the
  // raw transport.

  /// Daemon health probe — returns `{adb: bool, daemon: bool, ...}`.
  /// Used by the Compat dev page + dash shell startup check.
  Future<Map<String, dynamic>> daemonStatus();

  /// Head-unit identity (build, model, framework version, signer
  /// presence). Pass [localOnly] = true for the no-daemon-roundtrip
  /// variant used by device fingerprint at boot.
  Future<Map<String, dynamic>> identity({bool localOnly = false});

  /// Action ids the daemon's encrypted action table currently
  /// exposes. Used by the Compat probe to classify "known to daemon"
  /// vs "unknown" registry commands.
  Future<List<String>> knownActions();

  /// Auto-discovery / push-pipeline stats — frame counters, sub
  /// counts, registry size. Surfaced on the Auto Registry diagnostic
  /// screen.
  Future<Map<String, dynamic>> registryStats();

  /// Raw AC binder transact for the dev-bench AIDL probes. Bypasses
  /// the action gate; only the dev surface should use this.
  Future<Map<String, dynamic>> acTransact(
    String service,
    String method, {
    Map<String, dynamic>? args,
  });

  /// Observe a BYD ContentProvider family — settings DB, etc.
  /// Each event is the family's full snapshot map. Stream auto-
  /// subscribes the host on first listen and unobserves on cancel.
  Stream<Map<String, dynamic>> observeFamily(String family);

  /// One-shot read of a ContentProvider family snapshot. Use as a
  /// seed before listening to [observeFamily] so the consumer has a
  /// value before the first push frame.
  Future<Map<String, dynamic>?> readFamily(String family);

  /// Build-time action-contract verification (debug-only no-op in
  /// release). Caller passes the [expected] wire-id set (typically
  /// the app's `ActionIds.all`); the SDK compares against what the
  /// Kotlin `UnitDispatcher.knownActions()` reports and logs drift.
  Future<void> verifyActionContract({required Set<String> expected});

  /// Daemon connection state — `connected` / `reconnecting` /
  /// `disconnected`. Tiles that need to render a "connection lost"
  /// chip listen here. Emits the current state immediately on listen;
  /// subsequent emissions only when state actually changes.
  Stream<DaemonState> connectionState();

  /// Synchronous read of the current connection state.
  DaemonState get currentConnectionState;

  // ── Derived signals ─────────────────────────────────────────────

  /// Register a derived (computed) feature under [name] that auto-
  /// recomputes whenever any of its [sources] changes. The derived
  /// value flows through the same [value] / [watch] / [freshness]
  /// surfaces — consumers don't know it isn't a native push frame.
  ///
  /// Example — any-door-open as the OR of five door reads:
  ///
  /// ```dart
  /// client.derive(
  ///   name: 'derived.any_door_open',
  ///   sources: const [
  ///     'Bodywork.BODYWORK_LEFT_HAND_FRONT_DOOR',
  ///     'Bodywork.BODYWORK_RIGHT_HAND_FRONT_DOOR',
  ///     'Bodywork.BODYWORK_LEFT_HAND_REAR_DOOR',
  ///     'Bodywork.BODYWORK_RIGHT_HAND_REAR_DOOR',
  ///     'Bodywork.BODYWORK_LUGGAGE_DOOR',
  ///   ],
  ///   compute: (vals) => vals.values.any((v) => v == 1) ? 1 : 0,
  /// );
  /// // every tile can now: ref.watchFeatureInt('derived.any_door_open');
  /// ```
  ///
  /// Idempotent — a second [derive] for the same [name] replaces the
  /// prior compute fn. Returns a [DerivedHandle] so callers can drop
  /// the registration when their widget tree disposes.
  DerivedHandle derive({
    required String name,
    required List<String> sources,
    required int? Function(Map<String, int?> sources) compute,
  });
}

/// Daemon liveness — observed via [CarClient.connectionState].
enum DaemonState {
  /// Daemon is reachable; reads / writes / push are flowing.
  connected,

  /// Daemon was up but a recent ping timed out. Tiles can keep
  /// showing cached values; we're retrying transparently.
  reconnecting,

  /// Daemon hasn't responded across the watchdog's retry budget.
  /// Cached values still surface but consumers should style stale.
  disconnected,
}

/// Handle returned by [CarClient.derive]. Calling [dispose] removes
/// the derived feature from the cache and stops recomputing.
class DerivedHandle {
  DerivedHandle({required this.name, required void Function() onDispose})
    : _onDispose = onDispose;
  final String name;
  final void Function() _onDispose;
  void dispose() => _onDispose();
}

/// Result of a [CarClient.dispatchAndConfirm] call. [result] is the
/// command-router's reply (same shape as [CarClient.dispatch]);
/// [confirmed] indicates whether [expect] was satisfied within the
/// timeout; [observedValue] is the value that satisfied [expect] (or
/// null on timeout / no observation).
class DispatchResult {
  const DispatchResult({
    required this.result,
    required this.confirmed,
    this.observedValue,
  });
  final Map<String, dynamic> result;
  final bool confirmed;
  final int? observedValue;
}

/// App-wide [CarClient] singleton — wired to whichever brand adapter
/// matches the current car. Use this in widgets / mini-apps:
///
/// ```dart
/// final api = ref.watch(carClientProvider);
/// final battery = api.value('Statistic.STATISTIC_SOC_BATTERY_PERCENTAGE');
/// ```
final carClientProvider = Provider<CarClient>((ref) {
  // Brand-detection is async, but the client provider needs to be
  // sync-readable for widget code. We accept that the very first
  // reads on cold boot may target the (likely BYD) default before
  // detection completes. Detection is fast (< 100ms) so this is a
  // momentary issue, not a correctness one.
  final brand = ref
      .watch(currentBrandProvider)
      .maybeWhen(
        data: (b) => b,
        orElse: () => CarBrand.byd, // optimistic default
      );
  switch (brand) {
    case CarBrand.byd:
      return BydClient(ref);
    case CarBrand.geely:
    case CarBrand.nio:
    case CarBrand.tesla:
    case CarBrand.unknown:
      // Adapters not yet implemented — fall back to BYD client
      // which gracefully reports `null` for everything when the
      // framework is absent.
      return BydClient(ref);
  }
});
