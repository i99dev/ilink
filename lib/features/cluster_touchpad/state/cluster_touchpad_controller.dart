import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../sdk/brands/byd/identity/byd_model_detector.dart';
import '../../mini_apps/packaging/pkg_native_bridge.dart';
import '../../mini_apps/runtime/display_native_bridge.dart';
import '../../mini_apps/runtime/display_visibility.dart';
import '../../mini_apps/runtime/gesture_native_bridge.dart';

/// Authoritative cluster-target snapshot for the touchpad surface.
///
/// One object, one source of truth — every consumer (the header
/// icon's enabled/disabled state, the sheet's aspect ratio, the
/// tap/swipe forwarder) reads the SAME [displayId] + [width] /
/// [height] so the touchpad can never disagree with the display
/// picker about which screen it's driving.
///
/// `null` ⇒ no cluster on this trim (single-display car, or all
/// secondaries dimmed). Callers hide the touchpad affordance.
@immutable
class ClusterTouchpadTarget {
  const ClusterTouchpadTarget({
    required this.displayId,
    required this.cursorDisplayId,
    required this.inputDisplayId,
    required this.width,
    required this.height,
    required this.label,
  });

  /// Driver-visible display id (post-profile remap). Same value the
  /// drop picker, the launch resolver and `pkg.launch_cluster` use —
  /// resolved once via [DisplaySnapshotForPicker.forPicker] so trims
  /// with shadow / mirror surfaces never expose a non-driver layer.
  final int displayId;

  /// Layer the cursor overlay should render on (`cursorRemap` in
  /// `VehicleProfile.kt`). On Di5.1/L8 the visible Driver layer is
  /// display 5 but the input window lives on display 3 — input goes
  /// to [inputDisplayId], cursor goes here. Equal to [displayId] on
  /// trims with no remap (Di5.0).
  final int cursorDisplayId;

  /// Layer `input -d N tap/swipe` must target (`inputRemap` in
  /// `VehicleProfile.kt`). On Di5.1/L8 the visible Driver layer 5 is
  /// render-only — its associated app's focusable input window
  /// lives on display 3, so taps to layer 5 land in the void. The
  /// profile's `inputRemap` records this `5 → 3` redirection (and
  /// L5L's `4 → 2`); equal to [displayId] on trims with no remap.
  /// Operator-attested 2026-05-20: "cursor visible, click not work"
  /// when this redirection is missed.
  final int inputDisplayId;

  /// Pixel extent of the driver cluster surface — width × height as
  /// reported by `display.list`. Drives the sheet's [AspectRatio]
  /// so the touchpad area matches the cluster's actual shape, and
  /// scales tap / swipe coordinates back to cluster-local pixels.
  final int width;
  final int height;

  /// Friendly label (`overrideLabel ?? name`) — surfaced in the
  /// sheet header so the operator confirms which screen is being
  /// driven before they touch.
  final String label;

  double get aspectRatio => width <= 0 || height <= 0 ? 16 / 9 : width / height;
}

/// The centralized input seam for the touchpad — the same
/// `ilink/gesture` channel the mini-app gesture family uses, so the
/// daemon-inject FAST tier is shared. Overridable in tests with a fake.
final clusterGestureBridgeProvider = Provider<GestureNativeBridge>(
  (ref) => PlatformGestureNativeBridge(),
);

/// Resolves the cluster touchpad target on demand. `autoDispose` so
/// the resolution cache lives only while the sheet (and the header
/// affordance) is mounted; a cluster hot-plug between opens re-
/// queries on the next read.
///
/// Resolution rules (must stay aligned with the drop picker —
/// `display_drop_picker.dart#_picketDisplaysProvider`):
///   1. Gate on [ModelDetector.detect] so a cold-boot open never
///      paints against the Generic fallback profile.
///   2. Read the native `display.list` (single source of truth) —
///      do NOT re-derive secondary surfaces in Dart.
///   3. Pick the first display in `forPicker(excludeDefault: true)`
///      with role `cluster` and `clusterAvailable: true`. Dimmed /
///      shadow surfaces are filtered upstream.
///   4. Return null if no such display exists — the trim has no
///      reachable cluster (single-display car, or profile flagged
///      every secondary as dimmed).
final clusterTouchpadTargetProvider =
    FutureProvider.autoDispose<ClusterTouchpadTarget?>((ref) async {
      await ModelDetector.detect();
      final displays = await PlatformDisplayNativeBridge().list();
      for (final d in displays.forPicker(excludeDefault: true)) {
        // L7 projection cluster: the cast app runs on OUR VirtualDisplay,
        // so the touchpad must forward input to that VD's id (resolved
        // live), not the cluster's Android display id. The touchpad is
        // only meaningful while something is actually casting — if no
        // projection is active, skip (no target → no touchpad icon).
        if (d.castMode == 'project') {
          final proj = await PlatformPkgNativeBridge().clusterProjection();
          if (proj == null) continue;
          return ClusterTouchpadTarget(
            displayId: d.id,
            cursorDisplayId: proj.vdDisplayId,
            inputDisplayId: proj.vdDisplayId,
            width: d.width,
            height: d.height,
            label: d.overrideLabel?.isNotEmpty == true
                ? d.overrideLabel!
                : 'Driver Cluster',
          );
        }
        final isCluster = d.role == 'cluster' || d.isCluster;
        if (!isCluster) continue;
        if (!d.clusterAvailable) continue;
        return ClusterTouchpadTarget(
          displayId: d.id,
          cursorDisplayId: d.cursorDisplayId,
          inputDisplayId: d.inputSourceDisplayId,
          width: d.width,
          height: d.height,
          label: d.overrideLabel?.isNotEmpty == true
              ? d.overrideLabel!
              : (d.name.isNotEmpty ? d.name : 'Cluster'),
        );
      }
      // DEBUG-ONLY fallback: dev/emulator builds have no real driver cluster,
      // so the strict gating above returns null and the touchpad icon never
      // shows — making the sheet impossible to smoke-test off-car. In a DEBUG
      // build, surface a synthetic target so the icon appears and the sheet
      // opens; it forwards to the first non-projection secondary display if one
      // exists (else a sentinel id that simply no-ops the inject), so it never
      // hijacks the main IVI. NEVER in release: production keeps the real
      // cluster / active-projection gating so single-display cars stay clean.
      if (kDebugMode) {
        final secondary = displays
            .forPicker(excludeDefault: true)
            .where((d) => d.castMode != 'project')
            .toList();
        final d = secondary.isEmpty ? null : secondary.first;
        return ClusterTouchpadTarget(
          displayId: d?.id ?? 7777,
          cursorDisplayId: d?.id ?? 7777,
          inputDisplayId: d?.id ?? 7777,
          width: d?.width ?? 1080,
          height: d?.height ?? 600,
          label: d == null
              ? 'Debug touchpad (no cluster)'
              : '${d.name.isNotEmpty ? d.name : "Display ${d.id}"} (debug)',
        );
      }
      return null;
    });

/// Input-forwarder bound to a [ClusterTouchpadTarget], working in
/// **cluster pixels** (the relative trackpad owns the cursor position; this
/// just forwards clicks / drags / keys at those pixels).
///
/// Two seams, by concern:
///   * **Input** (`tap` / `ptr*` / `key`) → the centralized `ilink/gesture`
///     channel ([GestureNativeBridge]). That seam's tier ladder is
///     daemon-inject (FAST, streams) → a11y dispatchGesture → ADB `input` —
///     so the cluster touchpad and mini-apps share one injector and the legacy
///     per-gesture `input -d N` shell fork is gone.
///   * **Cursor overlay + clear** (`showCursor` / `moveCursor` / `hideCursor`
///     / `clearCluster`) → the `ilink/pkg` channel ([PkgNativeBridge]).
///     These render the cluster-side dot + recover a frozen frame; they are a
///     display concern, not input, so they stay where they are.
///
/// Owns no gesture state — the sheet's [RelativeTrackpad] does — so a single
/// instance is safe across rebuilds. Coordinates arrive already in cluster px.
class ClusterTouchpadForwarder {
  ClusterTouchpadForwarder(this._gesture, this._pkg, this.target);

  final GestureNativeBridge _gesture;
  final PkgNativeBridge _pkg;
  final ClusterTouchpadTarget target;

  /// True when the daemon FAST tier handled the last streamed op — exposed so
  /// the sheet can fall back to coalesced [tapAt] clicks if streaming isn't
  /// available on this car (a11y/ADB can't stream).
  bool streamingAvailable = true;

  /// Which tier handled the most recent discrete op — `daemon` (FAST inject),
  /// `a11y` (dispatchGesture), or `adb` (`input -d N`). Surfaced in the sheet
  /// so on-car triage can confirm the FAST path is live without logcat. Null
  /// until the first gesture lands.
  String? lastPath;

  // ── input → gesture seam (cluster px on the input display) ──────────────

  Future<bool> tapAt(int xPx, int yPx) async {
    final r = await _gesture.tap(
      displayId: target.inputDisplayId,
      x: xPx.toDouble(),
      y: yPx.toDouble(),
    );
    lastPath = r.path;
    return r.dispatched;
  }

  Future<bool> longPressAt(int xPx, int yPx, {int durationMs = 600}) async {
    final r = await _gesture.longPress(
      displayId: target.inputDisplayId,
      x: xPx.toDouble(),
      y: yPx.toDouble(),
      durationMs: durationMs,
    );
    lastPath = r.path;
    return r.dispatched;
  }

  /// Begin a streamed drag (ACTION_DOWN). Records whether the daemon FAST tier
  /// is actually streaming; if not, [streamingAvailable] flips false and the
  /// sheet uses discrete [swipeFallback] for drags instead.
  Future<bool> ptrDown(int xPx, int yPx) async {
    final r = await _gesture.ptrDown(
      displayId: target.inputDisplayId,
      x: xPx.toDouble(),
      y: yPx.toDouble(),
    );
    streamingAvailable = r.reason != 'stream_unavailable';
    return r.dispatched;
  }

  Future<bool> ptrMove(int xPx, int yPx) async {
    final r = await _gesture.ptrMove(
      displayId: target.inputDisplayId,
      x: xPx.toDouble(),
      y: yPx.toDouble(),
    );
    if (r.reason == 'stream_unavailable') streamingAvailable = false;
    return r.dispatched;
  }

  Future<bool> ptrUp(int xPx, int yPx) async {
    final r = await _gesture.ptrUp(x: xPx.toDouble(), y: yPx.toDouble());
    if (r.path != null) lastPath = r.path;
    return r.dispatched;
  }

  Future<bool> ptrCancel() async => (await _gesture.ptrCancel()).dispatched;

  /// Discrete swipe — the fallback drag when the daemon stream isn't available
  /// (a11y/ADB tier). Coalesces a whole drag into one call.
  Future<bool> swipeFallback(
    int x1,
    int y1,
    int x2,
    int y2, {
    int durationMs = 200,
  }) async {
    final r = await _gesture.swipe(
      displayId: target.inputDisplayId,
      fromX: x1.toDouble(),
      fromY: y1.toDouble(),
      toX: x2.toDouble(),
      toY: y2.toDouble(),
      durationMs: durationMs,
    );
    lastPath = r.path;
    return r.dispatched;
  }

  /// Single key onto the cluster's input display (e.g. `KEYCODE_BACK` = 4).
  Future<bool> key(int keycode) async {
    final r = await _gesture.key(
      displayId: target.inputDisplayId,
      keycode: keycode,
    );
    lastPath = r.path;
    return r.dispatched;
  }

  // ── cursor overlay + clear → pkg seam (display concern) ─────────────────

  /// Paint the cluster-side cursor dot. With a relative trackpad the cursor is
  /// load-bearing (no absolute mapping to fall back on), so this is shown for
  /// the whole session. Renders on the visible Driver layer
  /// ([target.cursorDisplayId]).
  Future<bool> showCursor() => _pkg.clusterCursorShow(
    target.cursorDisplayId,
    target.width,
    target.height,
  );

  /// Move the cluster cursor to a cluster-pixel point. The sheet throttles to
  /// display refresh.
  Future<bool> moveCursor(int xPx, int yPx) => _pkg.clusterCursorMove(xPx, yPx);

  /// Tear down the cursor overlay. Idempotent.
  Future<bool> hideCursor() => _pkg.clusterCursorHide();

  /// Force-stop non-host cluster packages + paint a blank overlay — recovers a
  /// frozen leftover frame (operator-attested 2026-05-20).
  Future<bool> clearCluster() => _pkg.clusterClear();
}
