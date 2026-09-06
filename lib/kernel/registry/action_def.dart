import 'package:flutter/widgets.dart';

/// Severity classifies how the UI should treat a tap on the action.
enum ActionSeverity {
  /// Fires immediately on tap. No confirm. (Force-stop, Whitelist.)
  safe,

  /// Shows a yes/no confirm sheet first. (Disable.)
  confirm,

  /// Shows a typed-token confirm — user must type a fixed
  /// English token before the destructive button enables. (Uninstall,
  /// Clear-data.) Token is locale-independent; hint text is localised.
  typedConfirm,
}

/// One row of any action registry — Tools, AppActions, future.
///
/// `TTarget` parameterises what the action operates on:
///   * AppActions: `AppTarget` (sealed: NativeApp | MiniApp)
///   * Tools:      `ToolKind` enum
///
/// `TState` parameterises the meta passed to [eligible]/[severity]
/// — typically the cached state of the target (AppMeta /
/// ConnectivityState slice).
///
/// The registry is a `final List<ActionDef<...>>` per feature. The
/// presentation layer iterates the list to build circles/rows; nothing
/// else (UI, command dispatch) needs to know the action's identity.
@immutable
class ActionDef<TTarget, TState> {
  const ActionDef({
    required this.id,
    required this.iconBuilder,
    required this.labelKey,
    required this.eligible,
    required this.severity,
    this.typedToken,
    this.confirmKey,
  });

  /// Stable id used for analytics + tests + provider keys.
  final String id;

  /// Returns the icon widget. We use a builder (not a static IconData
  /// or an asset path) because some actions want the icon to change
  /// shape based on state — e.g. Enable vs "Already enabled".
  final Widget Function(BuildContext context, TState state) iconBuilder;

  /// Localisation key. Validated at build time by the registry-
  /// validation test in `test/...registry_validation_test.dart`.
  final String labelKey;

  /// Returns true when this action should be tappable for the given
  /// state. False = render dimmed, non-tappable. Hidden state is
  /// not modelled — registry size is fixed; eligibility flips visual
  /// affordance only.
  final bool Function(TState state) eligible;

  final ActionSeverity severity;

  /// Required when [severity] is [ActionSeverity.typedConfirm].
  /// Locale-independent (fixed English token) on purpose: gives
  /// an unambiguous gating string regardless of the user's locale,
  /// and makes the confirm widget testable without locale wiring.
  final String? typedToken;

  /// Localisation key for the confirm body text. Required when
  /// severity ≠ safe.
  final String? confirmKey;
}

/// Validates a registry entry's invariants. Called by the per-feature
/// `*_registry_validation_test.dart` so a typo'd l10n key or a missing
/// confirm body fails the build.
String? validateActionDef<TTarget, TState>(ActionDef<TTarget, TState> def) {
  if (def.id.isEmpty) return '${def.runtimeType}: id is empty';
  if (def.labelKey.isEmpty) return '${def.id}: labelKey is empty';
  switch (def.severity) {
    case ActionSeverity.safe:
      if (def.typedToken != null) {
        return '${def.id}: safe action must not declare typedToken';
      }
      break;
    case ActionSeverity.confirm:
      if (def.confirmKey == null) {
        return '${def.id}: confirm severity needs confirmKey';
      }
      break;
    case ActionSeverity.typedConfirm:
      if (def.confirmKey == null || def.typedToken == null) {
        return '${def.id}: typedConfirm needs both confirmKey + typedToken';
      }
      if (def.typedToken!.isEmpty) {
        return '${def.id}: typedToken must not be empty';
      }
      break;
  }
  return null;
}
