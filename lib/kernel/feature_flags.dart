/// Compile-time feature flags. Single source of truth.
///
/// Why compile-time and not runtime: every flag below gates an
/// **architectural** rollout, not user-facing settings. Toggling a
/// flag means re-running the build, not editing a settings screen
/// — keeps the runtime surface lean and avoids two parallel codepaths
/// shipping in the same binary.
///
/// Convention: every flag defaults to `false` (the safe state).
/// Flipping a default to `true` is a deliberate release decision and
/// should land in its own commit so the bisect history shows the
/// rollout point.
class FeatureFlags {
  const FeatureFlags._();

  /// Routes mini-app long-press to the unified [AppActionsSheet]
  /// (shared with native installed apps). When `false` the legacy
  /// per-tile [showMiniAppActionsSheet] is used. Flip to `true` after
  /// a one-week soak with users on the new sheet for native apps —
  /// the unified path needs the mini-app target writers in place
  /// before the flip is safe.
  static const bool unifiedMiniAppActionsSheet = false;
}
