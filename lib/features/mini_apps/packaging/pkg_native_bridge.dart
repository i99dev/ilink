/// Thin Dart wrapper around the `ilink/pkg` MethodChannel.
///
/// THIS IS THE ONLY FILE in the `pkg/` Dart layer that imports
/// `package:flutter/services.dart` — the family code itself stays
/// platform-agnostic so unit tests can supply a fake bridge.
library;

import 'dart:async';

import 'package:flutter/services.dart';

import '../../../platform/observability/observability.dart';
import 'pkg_snapshot.dart';

/// Launch watchdog (P-C). The single chokepoint every foreign-app
/// launch (picker drag-drop, slide-panel sheet, chips, strips, tour)
/// flows through. A wedged native side — DiShare bind never returns,
/// or `am start --display N` is silently dropped by the Di5.0 BYD
/// container so the MethodChannel never completes — used to leave
/// the caller awaiting forever (the "drop card spins, nothing
/// shows" report). Bound here once so a non-response becomes an
/// honest `ok:false` [LaunchResult] every existing caller already
/// renders as a retryable failure — no per-widget timeout, no
/// duplication. Generous on purpose: DiShare cold-bind (~1.5 s) +
/// am-start bounce-back recovery are legitimate; 12 s unambiguously
/// means "the car isn't answering."
const Duration _pkgLaunchWatchdog = Duration(seconds: 12);

/// The active foreign-app cluster projection (L7). [vdDisplayId] is the
/// VirtualDisplay the cast app runs on — the touchpad forwards input
/// there; [hostDisplayId] is the cluster's own Android display (the
/// DISPLAYS-card id).
class ClusterProjectionInfo {
  const ClusterProjectionInfo({
    required this.packageName,
    required this.vdDisplayId,
    required this.hostDisplayId,
  });

  final String packageName;
  final int vdDisplayId;
  final int hostDisplayId;
}

abstract class PkgNativeBridge {
  /// Enumerate installed packages. [includeSystem] defaults to false
  /// — the typical mini-app wants the user-launchable subset (a
  /// custom launcher / "open app on cluster" picker).
  Future<List<PackageSnapshot>> list({bool includeSystem = false});

  /// Foreground app right now. Returns null when the host can't
  /// determine it (`UsageStatsManager` not granted, or the device
  /// is locked).
  Future<ForegroundPackage?> foreground();

  /// Per-package usage stats over the last [windowMs] millis.
  /// Backed by `UsageStatsManager.queryUsageStats`. Empty list when
  /// the permission isn't granted (instead of throwing — usage
  /// stats are inherently best-effort).
  Future<List<UsageRow>> usage({required int windowMs});

  /// Launch [packageName] on [displayId]. When [displayId] is null
  /// or the default display, the host uses `Context.startActivity`
  /// with the package's main launcher intent. When a non-default
  /// [displayId] is requested, the host falls back to
  /// `am start --display N` over the loopback ADB bridge — same
  /// pattern as the surface family's am-start path on cluster slots.
  Future<LaunchResult> launch({
    required String packageName,
    int? displayId,
    String? targetRole,
  });

  /// Move a running [packageName]'s task to [displayId]. Use this
  /// for "set the route on the IVI, then push the running app to
  /// the cluster" workflows where `launch({displayId})` would
  /// otherwise be foiled by the package's own router activity
  /// auto-redirecting to the home display (e.g. Waze).
  ///
  /// Returns `{ok: false, path: 'denied', error: 'package not
  /// running'}` if the package isn't currently running.
  Future<LaunchResult> move({
    required String packageName,
    required int displayId,
  });

  /// Cluster-targeted launch. Same wire shape as [launch] but the
  /// host's role-check rejects anything that isn't a `cluster`
  /// display (the BYD XDJA virtual presentation surfaces). Used by
  /// the `pkg.launch_cluster` op which is gated on the Tier-3
  /// `pkg.launch.cluster` permission.
  Future<LaunchResult> launchCluster({
    required String packageName,
    required int displayId,
  });

  /// Cluster-targeted move. Same posture as [launchCluster].
  Future<LaunchResult> moveCluster({
    required String packageName,
    required int displayId,
  });

  /// Project a FOREIGN app onto an XDJA fission cluster display via our
  /// own VirtualDisplay (the reference mechanism). Used where `move-task` /
  /// a direct `am start --display` onto the XDJA OWN_CONTENT_ONLY display
  /// hangs the head unit (Leopard 7). Native launches our ClusterActivity
  /// in projection mode; it creates a private VD and am-starts the app
  /// onto THAT, so the foreign task never enters the IVI's display group.
  Future<LaunchResult> projectToCluster({
    required String packageName,
    required int displayId,
  });

  /// Project iLINK's OWN UI (a mini-app bundle [bundleUri], optional
  /// [route]) onto a cluster [displayId] via the same own-VirtualDisplay
  /// mechanism as [projectToCluster] — but hosting a Presentation of our
  /// WebView instead of a foreign app, so the cluster shows an iLINK
  /// dashboard. A passive display surface: it takes no touchpad input (our
  /// own UI needs no synthetic touch), unlike a foreign-app cast.
  Future<LaunchResult> projectContentToCluster({
    required String bundleUri,
    required int displayId,
    String route = '/',
    String appId = '',
  });

  /// The active foreign-app cluster projection, or null if none. The
  /// touchpad routes input to [ClusterProjectionInfo.vdDisplayId] — the
  /// VirtualDisplay where the cast app actually runs (the cluster's own
  /// Android display id won't receive the app's input).
  Future<ClusterProjectionInfo?> clusterProjection();

  /// Stop the active foreign-app cluster projection. Returns the package
  /// that was being cast (so the caller can relaunch it on the IVI for
  /// "return to Head Unit"), or null if nothing was projecting. The
  /// projected app runs on our VirtualDisplay, so the normal
  /// topOnDisplay/move path can't reach it — this is its dedicated stop.
  Future<String?> stopClusterProjection();

  /// `am force-stop <packageName>`. Used by the pkg-launcher's
  /// "Clear Cluster" affordance to tear down whatever the mini-app
  /// last launched on the cluster, so XDJA's normal projection
  /// reclaims the surface. Same `pkg.launch` permission as the
  /// matching launch op — symmetric: if you can put it there, you
  /// can take it off.
  Future<LaunchResult> stop({required String packageName});

  /// Fresh-launch-only policy (native `ClusterLaunchPolicy`): apps
  /// that can't survive the cross-display Activity recreate a move
  /// forces (rule: ReVanced/-patched builds; plus any the user
  /// marked). The host fresh-launches them on the target display
  /// instead of same-pid `move-stack`.
  ///
  /// [clusterPolicyAdded] is the USER-added set only — rule-matched
  /// packages are implicit; use [clusterPolicyClassify] for the
  /// effective per-package verdict (ONE batched call per app-list
  /// refresh — the rule stays native, never re-implemented in Dart,
  /// and the badge never does per-icon round-trips).
  Future<List<String>> clusterPolicyAdded();

  /// Effective verdict: the subset of [packages] that are
  /// fresh-launch-only. Empty in → empty out (no channel hop).
  Future<Set<String>> clusterPolicyClassify(List<String> packages);

  /// Add a USER entry (an app the user observed bounce/crash on the
  /// cluster). Returns the new user-added set.
  Future<List<String>> clusterPolicyAdd(String packageName);

  /// Remove a USER entry. Rule-matched packages (e.g. ReVanced) are
  /// unaffected — the rule still applies. Returns the new set.
  Future<List<String>> clusterPolicyRemove(String packageName);

  // NB: synthetic input (tap / swipe / key / streamed pointer) for the
  // cluster is NOT here anymore — it moved to the centralized
  // `ilink/gesture` seam (`GestureNativeBridge` →
  // `InputPlatformPlugin`), whose daemon FAST tier injects MotionEvent
  // streams via `InputManager.injectInputEvent`. This bridge keeps only
  // the cluster-side *display* concerns (the cursor overlay + clear).

  /// Cluster-side pointer indicator. The driver looks at the
  /// cluster while their finger is on the IVI trackpad — these
  /// place a small overlay dot on the cluster display so they can
  /// see where the tap will land. [clusterCursorShow] centres it
  /// at the resolved window; [clusterCursorMove] tracks the finger
  /// (caller throttles); [clusterCursorHide] removes it.
  Future<bool> clusterCursorShow(int displayId, int width, int height);
  Future<bool> clusterCursorMove(int x, int y);
  Future<bool> clusterCursorHide();

  /// Force-stop the leftover **non-system** packages on cluster
  /// displays AND paint a black `ClusterActivity` overlay on each
  /// display we cleared (recovers the "frozen leftover frame" that
  /// survives a task vacating a projected secondary surface —
  /// operator-attested 2026-05-20). System/ROM apps (the cluster
  /// projection chain, SystemUI, launchers) are spared so the clear
  /// can't tear down the cluster. Returns true on success; false on
  /// shell failure.
  Future<bool> clusterClear();

  /// Calibration-tour marker. Spawns the host's own ClusterActivity
  /// in tour mode on [displayId] — a full-screen coloured tile with
  /// "DISPLAY N" text. Bypasses the launch resolver so every probe
  /// gets a fresh marker (Resume/Migrate would defeat the point of
  /// "show me a new marker"). Used only by the display-calibration
  /// tour; not exposed to mini-apps.
  ///
  /// Returns a [TourMarkerResult] so the overlay can distinguish a
  /// recoverable WMS transient (Retry button) from a hard failure
  /// (Skip-this-display affordance).
  Future<TourMarkerResult> tourMarker({
    required int displayId,
    required int colorArgb,
    String label = '',
  });

  /// Finish every live tour-marker activity. Idempotent — calling
  /// when no markers are up returns `finished: 0` without erroring.
  /// Called by the calibration overlay when leaving the marker phase
  /// (commit / cancel / advance into the DiShare probe) so the last
  /// rendered colour doesn't stay pinned on the cluster.
  Future<void> tourFinish();

  /// Per-display task topology. One entry per running task with the
  /// `(taskId, packageName, displayId, isForeground)` quadruple. Backed
  /// by the same `am stack list` parser the launch decision path uses,
  /// so the UI's "what's on screen X" view is guaranteed to agree with
  /// what the launch resolver sees on the next launch.
  ///
  /// Empty list when the host can't shell `am stack list` (typically
  /// only seen on emulator builds without loopback ADB). Mini-apps
  /// don't have access to this op — it's host-internal so the running-
  /// apps controller doesn't have to round-trip through the dispatcher.
  Future<List<RunningTask>> running();

  /// Host-authoritative "which app is on display [displayId] right
  /// now" — reads the live `am stack list`, not the polled chip
  /// cache. Returns the package name, or null when nothing
  /// non-host is on that display. Used by the per-card "send back"
  /// action so moving an app *off* a secondary display doesn't
  /// depend on a running-chip that can be absent (poll lag, host
  /// filter, a bouncy foreign app mid-relaunch on the XDJA cluster).
  Future<String?> topOnDisplay(int displayId);

  /// Phase D: launcher-icon delivery. Renders the package's icon to
  /// a 96 px PNG, base64-encoded for the bridge. Cached host-side by
  /// `pkg@versionCode` so a 50-app launcher hits the renderer at most
  /// once per app per version. Mini-apps key their own dataUrl cache
  /// by the iconHash returned in `pkg.list`.
  ///
  /// Permission tier: `pkg.read` (read-only). Returns
  /// `{ok: false, error: …}` on failure — never throws for
  /// "no icon", since some kiosk-mode packages legitimately have no
  /// loadable launcher drawable.
  Future<PkgIconResult> icon({required String packageName});
}

class PlatformPkgNativeBridge implements PkgNativeBridge {
  PlatformPkgNativeBridge({MethodChannel? methodChannel})
    : _ch = methodChannel ?? const MethodChannel('ilink/pkg');

  final MethodChannel _ch;

  @override
  Future<List<PackageSnapshot>> list({bool includeSystem = false}) async {
    final raw =
        await _ch.invokeMapMethod<String, Object?>('list', {
          'includeSystem': includeSystem,
        }) ??
        const <String, Object?>{};
    final packages = (raw['packages'] as List?) ?? const [];
    return packages
        .map((e) => PackageSnapshot.fromMap((e as Map).cast<String, Object?>()))
        .toList(growable: false);
  }

  @override
  Future<ForegroundPackage?> foreground() async {
    final raw = await _ch.invokeMapMethod<String, Object?>('foreground');
    if (raw == null || raw['packageName'] == null) return null;
    return ForegroundPackage.fromMap(raw);
  }

  @override
  Future<List<UsageRow>> usage({required int windowMs}) async {
    final raw =
        await _ch.invokeMapMethod<String, Object?>('usage', {
          'windowMs': windowMs,
        }) ??
        const <String, Object?>{};
    final rows = (raw['rows'] as List?) ?? const [];
    return rows
        .map((e) => UsageRow.fromMap((e as Map).cast<String, Object?>()))
        .toList(growable: false);
  }

  @override
  Future<LaunchResult> launch({
    required String packageName,
    int? displayId,
    String? targetRole,
  }) async {
    // Breadcrumb the call. We log displayId + result-path/ok only —
    // packageName stays out of the breadcrumb so a Sentry event from
    // a crash doesn't leak the user's installed-app inventory.
    Observability.breadcrumb(
      category: 'pkg.launch',
      message: 'enter',
      data: {'displayId': displayId, 'targetRole': targetRole},
    );
    try {
      final raw = await _ch
          .invokeMapMethod<String, Object?>('launch', {
            'packageName': packageName,
            // ignore: use_null_aware_elements -- key is a non-null literal
            if (displayId != null) 'displayId': displayId,
            // ignore: use_null_aware_elements
            if (targetRole != null) 'targetRole': targetRole,
          })
          .timeout(_pkgLaunchWatchdog);
      final result = LaunchResult.fromMap(raw ?? const <String, Object?>{});
      Observability.breadcrumb(
        category: 'pkg.launch',
        message: 'exit',
        data: {
          'displayId': displayId,
          'targetRole': targetRole,
          'ok': result.ok,
          'path': result.path,
          if (result.error != null)
            'errCat': result.error.runtimeType.toString(),
        },
      );
      return result;
    } on TimeoutException {
      // Watchdog tripped — convert the non-response into an honest,
      // retryable failure instead of an awaited-forever future.
      Observability.breadcrumb(
        category: 'pkg.launch',
        message: 'watchdog',
        data: {'displayId': displayId, 'targetRole': targetRole},
      );
      return const LaunchResult(
        ok: false,
        path: 'watchdog-timeout',
        error: 'No response from the car — tap to retry',
      );
    } catch (e) {
      Observability.breadcrumb(
        category: 'pkg.launch',
        message: 'throw',
        data: {
          'displayId': displayId,
          'targetRole': targetRole,
          'errCat': e.runtimeType.toString(),
        },
      );
      rethrow;
    }
  }

  @override
  Future<LaunchResult> move({
    required String packageName,
    required int displayId,
  }) async {
    Observability.breadcrumb(
      category: 'pkg.move',
      message: 'enter',
      data: {'displayId': displayId},
    );
    try {
      final raw = await _ch.invokeMapMethod<String, Object?>('move', {
        'packageName': packageName,
        'displayId': displayId,
      });
      final result = LaunchResult.fromMap(raw ?? const <String, Object?>{});
      Observability.breadcrumb(
        category: 'pkg.move',
        message: 'exit',
        data: {
          'displayId': displayId,
          'ok': result.ok,
          'path': result.path,
          if (result.error != null)
            'errCat': result.error.runtimeType.toString(),
        },
      );
      return result;
    } catch (e) {
      Observability.breadcrumb(
        category: 'pkg.move',
        message: 'throw',
        data: {'displayId': displayId, 'errCat': e.runtimeType.toString()},
      );
      rethrow;
    }
  }

  @override
  Future<LaunchResult> launchCluster({
    required String packageName,
    required int displayId,
  }) async {
    Observability.breadcrumb(
      category: 'pkg.launch_cluster',
      message: 'enter',
      data: {'displayId': displayId},
    );
    try {
      // Reuses the `launch` channel method; the `expectCluster` flag
      // tells the native side to reject ivi/passenger/unknown
      // displayIds. Keeps the native surface area small (one method
      // per verb) and lets the role-check live in one Kotlin path.
      final raw = await _ch
          .invokeMapMethod<String, Object?>('launch', {
            'packageName': packageName,
            'displayId': displayId,
            'expectCluster': true,
          })
          .timeout(_pkgLaunchWatchdog);
      final result = LaunchResult.fromMap(raw ?? const <String, Object?>{});
      Observability.breadcrumb(
        category: 'pkg.launch_cluster',
        message: 'exit',
        data: {
          'displayId': displayId,
          'ok': result.ok,
          'path': result.path,
          if (result.error != null)
            'errCat': result.error.runtimeType.toString(),
        },
      );
      return result;
    } on TimeoutException {
      Observability.breadcrumb(
        category: 'pkg.launch_cluster',
        message: 'watchdog',
        data: {'displayId': displayId},
      );
      return const LaunchResult(
        ok: false,
        path: 'watchdog-timeout',
        error: 'No response from the car — tap to retry',
      );
    } catch (e) {
      Observability.breadcrumb(
        category: 'pkg.launch_cluster',
        message: 'throw',
        data: {'displayId': displayId, 'errCat': e.runtimeType.toString()},
      );
      rethrow;
    }
  }

  @override
  Future<LaunchResult> projectToCluster({
    required String packageName,
    required int displayId,
  }) async {
    Observability.breadcrumb(
      category: 'pkg.project_cluster',
      message: 'enter',
      data: {'displayId': displayId},
    );
    try {
      final raw = await _ch
          .invokeMapMethod<String, Object?>('projectCluster', {
            'packageName': packageName,
            'displayId': displayId,
          })
          .timeout(_pkgLaunchWatchdog);
      return LaunchResult.fromMap(raw ?? const <String, Object?>{});
    } on TimeoutException {
      return const LaunchResult(
        ok: false,
        path: 'watchdog-timeout',
        error: 'No response from the car — tap to retry',
      );
    } catch (e) {
      return LaunchResult(ok: false, path: 'denied', error: e.toString());
    }
  }

  @override
  Future<LaunchResult> projectContentToCluster({
    required String bundleUri,
    required int displayId,
    String route = '/',
    String appId = '',
  }) async {
    Observability.breadcrumb(
      category: 'pkg.project_content_cluster',
      message: 'enter',
      data: {'displayId': displayId},
    );
    try {
      final raw = await _ch
          .invokeMapMethod<String, Object?>('projectContentCluster', {
            'bundleUri': bundleUri,
            'displayId': displayId,
            'route': route,
            if (appId.isNotEmpty) 'appId': appId,
          })
          .timeout(_pkgLaunchWatchdog);
      return LaunchResult.fromMap(raw ?? const <String, Object?>{});
    } on TimeoutException {
      return const LaunchResult(
        ok: false,
        path: 'watchdog-timeout',
        error: 'No response from the car — tap to retry',
      );
    } catch (e) {
      return LaunchResult(ok: false, path: 'denied', error: e.toString());
    }
  }

  @override
  Future<ClusterProjectionInfo?> clusterProjection() async {
    try {
      final raw = await _ch
          .invokeMapMethod<String, Object?>('clusterProjection')
          .timeout(_pkgLaunchWatchdog);
      if (raw == null || raw['active'] != true) return null;
      return ClusterProjectionInfo(
        packageName: raw['packageName'] as String? ?? '',
        vdDisplayId: (raw['vdDisplayId'] as num).toInt(),
        hostDisplayId: (raw['hostDisplayId'] as num).toInt(),
      );
    } catch (e) {
      return null;
    }
  }

  @override
  Future<String?> stopClusterProjection() async {
    try {
      final raw = await _ch
          .invokeMapMethod<String, Object?>('stopClusterProjection')
          .timeout(_pkgLaunchWatchdog);
      return raw?['packageName'] as String?;
    } catch (e) {
      return null;
    }
  }

  @override
  Future<LaunchResult> moveCluster({
    required String packageName,
    required int displayId,
  }) async {
    Observability.breadcrumb(
      category: 'pkg.move_cluster',
      message: 'enter',
      data: {'displayId': displayId},
    );
    try {
      final raw = await _ch.invokeMapMethod<String, Object?>('move', {
        'packageName': packageName,
        'displayId': displayId,
        'expectCluster': true,
      });
      final result = LaunchResult.fromMap(raw ?? const <String, Object?>{});
      Observability.breadcrumb(
        category: 'pkg.move_cluster',
        message: 'exit',
        data: {
          'displayId': displayId,
          'ok': result.ok,
          'path': result.path,
          if (result.error != null)
            'errCat': result.error.runtimeType.toString(),
        },
      );
      return result;
    } catch (e) {
      Observability.breadcrumb(
        category: 'pkg.move_cluster',
        message: 'throw',
        data: {'displayId': displayId, 'errCat': e.runtimeType.toString()},
      );
      rethrow;
    }
  }

  @override
  Future<LaunchResult> stop({required String packageName}) async {
    Observability.breadcrumb(category: 'pkg.stop', message: 'enter');
    try {
      final raw = await _ch.invokeMapMethod<String, Object?>('stop', {
        'packageName': packageName,
      });
      final result = LaunchResult.fromMap(raw ?? const <String, Object?>{});
      Observability.breadcrumb(
        category: 'pkg.stop',
        message: 'exit',
        data: {
          'ok': result.ok,
          'path': result.path,
          if (result.error != null)
            'errCat': result.error.runtimeType.toString(),
        },
      );
      return result;
    } catch (e) {
      Observability.breadcrumb(
        category: 'pkg.stop',
        message: 'throw',
        data: {'errCat': e.runtimeType.toString()},
      );
      rethrow;
    }
  }

  @override
  Future<List<String>> clusterPolicyAdded() async {
    final raw =
        await _ch.invokeMapMethod<String, Object?>('clusterPolicy.list') ??
        const <String, Object?>{};
    return ((raw['added'] as List?) ?? const [])
        .map((e) => e as String)
        .toList(growable: false);
  }

  @override
  Future<Set<String>> clusterPolicyClassify(List<String> packages) async {
    if (packages.isEmpty) return <String>{};
    final raw =
        await _ch.invokeMapMethod<String, Object?>('clusterPolicy.classify', {
          'packages': packages,
        }) ??
        const <String, Object?>{};
    return ((raw['freshLaunchOnly'] as List?) ?? const [])
        .map((e) => e as String)
        .toSet();
  }

  @override
  Future<List<String>> clusterPolicyAdd(String packageName) =>
      _clusterPolicyMutate('clusterPolicy.add', packageName);

  @override
  Future<List<String>> clusterPolicyRemove(String packageName) =>
      _clusterPolicyMutate('clusterPolicy.remove', packageName);

  Future<List<String>> _clusterPolicyMutate(
    String method,
    String packageName,
  ) async {
    final raw =
        await _ch.invokeMapMethod<String, Object?>(method, {
          'packageName': packageName,
        }) ??
        const <String, Object?>{};
    return ((raw['added'] as List?) ?? const [])
        .map((e) => e as String)
        .toList(growable: false);
  }

  @override
  Future<bool> clusterCursorShow(int displayId, int width, int height) =>
      _clusterInject('clusterInput.cursor.show', {
        'displayId': displayId,
        'width': width,
        'height': height,
      });

  @override
  Future<bool> clusterCursorMove(int x, int y) =>
      _clusterInject('clusterInput.cursor.move', {'x': x, 'y': y});

  @override
  Future<bool> clusterCursorHide() =>
      _clusterInject('clusterInput.cursor.hide', const {});

  @override
  Future<bool> clusterClear() async {
    try {
      final raw =
          await _ch.invokeMapMethod<String, Object?>('cluster.clear') ??
          const <String, Object?>{};
      return raw['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _clusterInject(String method, Map<String, Object?> args) async {
    // Breadcrumb only on failure / exception. Taps + swipes can fire
    // many per second from the trackpad — breadcrumbing every one
    // would spam Sentry and crowd out the signal. The success path
    // is silent; failures (hard shell fail, throw) are surfaced.
    try {
      final raw =
          await _ch.invokeMapMethod<String, Object?>(method, args) ??
          const <String, Object?>{};
      final ok = raw['ok'] == true;
      if (!ok) {
        Observability.breadcrumb(
          category: 'pkg.cluster_input.inject',
          message: 'fail',
          data: {
            'method': method,
            if (args['displayId'] is int) 'displayId': args['displayId'],
          },
        );
      }
      return ok;
    } catch (e) {
      Observability.breadcrumb(
        category: 'pkg.cluster_input.inject',
        message: 'throw',
        data: {
          'method': method,
          'errCat': e.runtimeType.toString(),
          if (args['displayId'] is int) 'displayId': args['displayId'],
        },
      );
      rethrow;
    }
  }

  @override
  Future<TourMarkerResult> tourMarker({
    required int displayId,
    required int colorArgb,
    String label = '',
  }) async {
    Observability.breadcrumb(
      category: 'pkg.tourMarker',
      message: 'enter',
      data: {'displayId': displayId},
    );
    try {
      final raw = await _ch.invokeMapMethod<String, Object?>('tourMarker', {
        'displayId': displayId,
        'colorArgb': colorArgb,
        'label': label,
      });
      final ok = raw?['ok'] as bool? ?? false;
      Observability.breadcrumb(
        category: 'pkg.tourMarker',
        message: 'exit',
        data: {'displayId': displayId, 'ok': ok},
      );
      if (ok) return TourMarkerResult.ok();
      return TourMarkerResult.failure(
        errorCode: raw?['errorCode'] as String? ?? 'tour_marker_failed',
        error: raw?['error'] as String?,
      );
    } on PlatformException catch (e) {
      // Native-side `result.error(code, message, _)` lands here. Map
      // the typed error code straight through so the calibration UI
      // can branch on `tour_marker_wms_transient` vs the hard fail.
      Observability.breadcrumb(
        category: 'pkg.tourMarker',
        message: 'throw',
        data: {'errCat': 'PlatformException', 'code': e.code},
      );
      return TourMarkerResult.failure(errorCode: e.code, error: e.message);
    } catch (e) {
      Observability.breadcrumb(
        category: 'pkg.tourMarker',
        message: 'throw',
        data: {'errCat': e.runtimeType.toString()},
      );
      return TourMarkerResult.failure(
        errorCode: 'tour_marker_failed',
        error: e.toString(),
      );
    }
  }

  @override
  Future<void> tourFinish() async {
    Observability.breadcrumb(category: 'pkg.tourFinish', message: 'enter');
    try {
      final raw = await _ch.invokeMapMethod<String, Object?>('tourFinish');
      Observability.breadcrumb(
        category: 'pkg.tourFinish',
        message: 'exit',
        data: {'finished': raw?['finished'] ?? 0},
      );
    } catch (e) {
      // Best-effort cleanup. The user already moved past the marker
      // phase; surfacing an error here would just confuse them.
      Observability.breadcrumb(
        category: 'pkg.tourFinish',
        message: 'throw',
        data: {'errCat': e.runtimeType.toString()},
      );
    }
  }

  @override
  Future<List<RunningTask>> running() async {
    Observability.breadcrumb(category: 'pkg.running', message: 'enter');
    try {
      final raw = await _ch.invokeMapMethod<String, Object?>('running');
      final rows = (raw?['rows'] as List?) ?? const [];
      final out = rows
          .map((e) => RunningTask.fromMap((e as Map).cast<String, Object?>()))
          .toList(growable: false);
      Observability.breadcrumb(
        category: 'pkg.running',
        message: 'exit',
        data: {'count': out.length},
      );
      return out;
    } catch (e) {
      Observability.breadcrumb(
        category: 'pkg.running',
        message: 'throw',
        data: {'errCat': e.runtimeType.toString()},
      );
      rethrow;
    }
  }

  @override
  Future<String?> topOnDisplay(int displayId) async {
    Observability.breadcrumb(
      category: 'pkg.topOnDisplay',
      message: 'enter',
      data: {'displayId': displayId},
    );
    try {
      final raw = await _ch.invokeMapMethod<String, Object?>('topOnDisplay', {
        'displayId': displayId,
      });
      final pkg = raw?['packageName'] as String?;
      Observability.breadcrumb(
        category: 'pkg.topOnDisplay',
        message: 'exit',
        data: {'displayId': displayId, 'found': pkg != null},
      );
      return pkg;
    } catch (e) {
      Observability.breadcrumb(
        category: 'pkg.topOnDisplay',
        message: 'throw',
        data: {'displayId': displayId, 'errCat': e.runtimeType.toString()},
      );
      return null;
    }
  }

  @override
  Future<PkgIconResult> icon({required String packageName}) async {
    // Breadcrumb the call shape — packageName stays out of the
    // breadcrumb to avoid leaking the user's installed-app inventory
    // into a Sentry crash dump (same posture as pkg.launch).
    Observability.breadcrumb(category: 'pkg.icon', message: 'enter');
    try {
      final raw = await _ch.invokeMapMethod<String, Object?>('icon', {
        'packageName': packageName,
      });
      final result = PkgIconResult.fromMap(raw ?? const <String, Object?>{});
      Observability.breadcrumb(
        category: 'pkg.icon',
        message: 'exit',
        data: {
          'ok': result.ok,
          // Don't breadcrumb the bytes themselves — too noisy and
          // not useful for debugging. A length signal is enough.
          'sizeB64': result.pngBase64?.length ?? 0,
        },
      );
      return result;
    } catch (e) {
      Observability.breadcrumb(
        category: 'pkg.icon',
        message: 'throw',
        data: {'errCat': e.runtimeType.toString()},
      );
      rethrow;
    }
  }
}
