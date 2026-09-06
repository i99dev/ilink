import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Discriminator for a registered tool. Adding a tool = adding an
/// entry here + one row in `tools_registry.dart` + one section file
/// + one l10n key. Nothing else changes.
enum ToolKind {
  network,
  doctor,
  fab,
  navHud,
  workflow /* future: audio, climate, display */,
}

/// Registry row. Resolves three things at runtime:
///   * The icon to render in the circle on the Tools strip.
///   * The label key to look up in l10n.
///   * The bottom-sheet builder when the user taps the circle.
///
/// Status semantics live on each tool's own state model — the strip
/// doesn't introspect it; the registry tells the strip which ring
/// color via [ringStatusFor], a pure function of the WidgetRef so the
/// strip can call `select()` for fine-grained rebuild control.
@immutable
class Tool {
  const Tool({
    required this.kind,
    required this.iconBuilder,
    required this.labelKey,
    required this.sheetBuilder,
    required this.ringStatusFor,
  });

  final ToolKind kind;

  /// Icon shown inside the circle. Builder (not static IconData) so
  /// future tools can render a state-aware glyph (e.g. WiFi bar count).
  final Widget Function(BuildContext context) iconBuilder;

  final String labelKey;

  /// Returns the bottom sheet to show when the circle is tapped.
  /// Lazy: only invoked on tap, never at registry build time.
  final Widget Function(BuildContext context) sheetBuilder;

  /// Pure function: ref → ring color. Implementations should use
  /// `ref.watch(toolStateProvider.select(...))` to scope rebuilds.
  final ToolStatusRing Function(WidgetRef ref) ringStatusFor;
}

/// 4-state ring color enum. Maps to the outer circle border color +
/// the small status pill below the label. Kept tiny on purpose —
/// the per-tool sheet is where richer state lives.
enum ToolStatusRing {
  /// Solid green — at least one capability of this tool is live.
  online,

  /// Amber — a capability is mid-toggle (transitioning).
  transitioning,

  /// Gray — every capability is off.
  offline,

  /// Pre-load skeleton.
  unknown,
}
