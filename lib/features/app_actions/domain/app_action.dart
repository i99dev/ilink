/// Public discriminator for the 7 app management actions.
/// Adding an 8th = add an enum value + a registry row + an SVG +
/// l10n keys.
enum AppActionKind {
  enable,
  disable,
  uninstall,
  transferRunning,
  forceStop,
  clearData,
  whitelist,
}

/// Result returned to the UI after a tap. The sheet shows a brief
/// success / failure flash before dismissing.
enum AppActionOutcome { ok, failed, cancelled, ineligible }
