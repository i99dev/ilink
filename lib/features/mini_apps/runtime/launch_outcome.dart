/// One source of truth for "did launching a mini-app / app onto a
/// display actually succeed, and what do we tell the user?" — kept
/// separate from the wire-shape model and Flutter-free so the two
/// surfaces that render a launch result can never disagree.
///
/// Why this exists (the regression it closes):
///   * The home-screen drop picker (`display_drop_picker.dart`)
///     decoded the host's launch result correctly — it checked
///     `LaunchResult.ok` and showed an error on failure.
///   * The slide-panel actions sheet (`mini_app_actions_sheet.dart`)
///     used a *different* private decoder that read only `path` and
///     never checked `ok`. On a Di5.0 / Leopard 5 unit, when the
///     DiShare passenger/cluster cast was refused the host returns
///     `{ok: false, path: 'dishare-denied'}` — the sheet's `path`
///     switch fell through to its default arm and showed a green
///     "Opened on Driver Dashboard (path: dishare-denied)" while
///     nothing reached the screen. Two parallel decoders over the
///     same data, disagreeing exactly where L5 is most fragile.
///
/// Both surfaces now classify through [classifyLaunchKind]; the
/// success/failure boundary is single-sourced and unit-pinned in
/// `launch_outcome_test.dart`. Rendering (snackbar text vs terse
/// in-card text, colour) stays per-surface but is derived from the
/// shared [LaunchOutcomeKind] — so the *decision* can't drift even
/// though the presentation legitimately differs.
library;

/// What the host's launch/surface result means for the user.
///
///   * [success]   — landed on the requested display, nothing to say
///                   beyond a confirmation.
///   * [recovered] — landed, but only after the host auto-recovered a
///                   bounce (`am-start-rePinned`). Worth surfacing so
///                   the user (and observability) knows it bounced.
///   * [warning]   — a recoverable BYD WMS transient; the caller
///                   should offer a Retry affordance.
///   * [failure]   — did NOT land. Includes the L5 DiShare refusal
///                   (`ok:false` + `dishare*`/`denied`) and a failed
///                   bounce recovery (`am-start-bounced`). Must be
///                   rendered as an honest error, never as success.
enum LaunchOutcomeKind { success, recovered, warning, failure }

extension LaunchOutcomeKindX on LaunchOutcomeKind {
  /// True only when the app actually reached the requested display.
  bool get ok =>
      this == LaunchOutcomeKind.success || this == LaunchOutcomeKind.recovered;

  /// True when the user must be shown an honest failure (error
  /// styling, a fallback hint) — never a success confirmation.
  bool get isFailure => this == LaunchOutcomeKind.failure;
}

/// The single classifier. `ok` is authoritative: a host result with
/// `ok == false` is ALWAYS a [LaunchOutcomeKind.failure], regardless
/// of which `path` the host took or which family produced it (`pkg`
/// or `surface`). `wmsTransient` is checked first because it's a
/// recoverable sub-case the caller handles specially (Retry), and
/// the host reports it via `path`, not `ok`.
LaunchOutcomeKind classifyLaunchKind({
  required bool ok,
  required String? path,
  Object? error,
  bool wmsTransient = false,
}) {
  if (wmsTransient) return LaunchOutcomeKind.warning;
  if (!ok) return LaunchOutcomeKind.failure;
  if ((path ?? '') == 'am-start-rePinned') return LaunchOutcomeKind.recovered;
  return LaunchOutcomeKind.success;
}

/// Classify an `_admin.exec` `AdminExecOk.data` envelope (the slide-
/// panel path: `openMiniAppOnDisplay` → `surface`/`create`, or any
/// `pkg`-style `{ok,path}` map that reaches the OK branch).
///
/// `AdminExecOk` only means the executor did not *throw* — a returned
/// `{ok:false,…}` map is still a failure and must be treated as one.
/// When the envelope carries no `ok` key at all it is the surface-
/// family success envelope (`{surfaceId,path,displayId,route}`); a
/// genuine failure on that path throws and becomes `AdminExecError`
/// before it ever gets here, so a missing `ok` is safely read as
/// success.
LaunchOutcomeKind launchKindFromExecData(Map<String, Object?> data) {
  // `== true` (not `as bool?`) on purpose: a present-but-non-bool
  // `ok` (a malformed/tampered envelope) must read as not-ok, and a
  // hard cast there would throw instead of failing safe.
  final ok = data.containsKey('ok') ? data['ok'] == true : true;
  return classifyLaunchKind(
    ok: ok,
    path: data['path'] as String?,
    error: data['error'],
  );
}

/// Snackbar-style, label-aware message for the slide-panel sheet.
/// Honest on the L5 case: a refused DiShare passenger/cluster cast
/// reads as a clear failure with a fallback hint, not a confirmation.
String launchOutcomeMessage(
  LaunchOutcomeKind kind, {
  required String label,
  String? path,
  Object? error,
}) {
  switch (kind) {
    case LaunchOutcomeKind.success:
      return 'Opened on $label';
    case LaunchOutcomeKind.recovered:
      return 'Opened on $label (recovered after bounce)';
    case LaunchOutcomeKind.warning:
      return 'WMS hiccup on $label — tap to retry';
    case LaunchOutcomeKind.failure:
      final p = path ?? '';
      if (p.startsWith('dishare') || p == 'denied' || _isDishareError(error)) {
        return "Couldn't open on $label — this car refused the "
            'passenger/cluster cast. Open here instead.';
      }
      if (p.startsWith('am-start-bounced')) {
        return 'Tried $label but the app fell back to the IVI — '
            'try again or open here.';
      }
      final e = error?.toString();
      return (e != null && e.isNotEmpty)
          ? "Couldn't open on $label — $e"
          : "Couldn't open on $label.";
  }
}

/// The DiShare transport's typed failure strings (see
/// `DishareTransport.fastCast` — `dishare_not_installed`,
/// `quick_share_failed`, `bind_failed`, `register_failed`,
/// `video_size_failed`, `arm_failed`). Recognised so a Di5.0 / L5
/// cast refusal reads as the passenger/cluster-cast message even
/// when the host reported it via `error` rather than `path`.
bool _isDishareError(Object? error) {
  if (error == null) return false;
  final e = error.toString();
  return e.contains('dishare') ||
      e.contains('quick_share_failed') ||
      e.contains('bind_failed') ||
      e.contains('register_failed') ||
      e.contains('video_size_failed') ||
      e.contains('arm_failed');
}
