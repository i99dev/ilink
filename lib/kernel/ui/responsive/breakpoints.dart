import 'package:flutter/widgets.dart';

// Three breakpoints, car-first. Production runs on 2560×1600 — firmly
// ultrawide. The other two exist so Chrome/desktop dev doesn't crash or
// overflow at narrower windows; they are not shipping targets.
enum Breakpoint {
  compact, // <900 px — dev only (narrow Chrome window, laptop side-by-side)
  expanded, // 900-1600 — dev (desktop Chrome)
  ultrawide, // ≥1600 — the car head unit, the one polished layout
}

const double _compactMax = 900.0;
const double _expandedMax = 1600.0;

Breakpoint breakpointFor(double width) {
  if (width < _compactMax) return Breakpoint.compact;
  if (width < _expandedMax) return Breakpoint.expanded;
  return Breakpoint.ultrawide;
}

// InheritedWidget so every widget in the tree resolves the breakpoint
// in O(1) without each one running its own LayoutBuilder.
class BreakpointScope extends InheritedWidget {
  const BreakpointScope({
    super.key,
    required this.breakpoint,
    required super.child,
  });

  final Breakpoint breakpoint;

  static Breakpoint of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<BreakpointScope>();
    assert(scope != null, 'BreakpointScope missing above $context');
    return scope!.breakpoint;
  }

  @override
  bool updateShouldNotify(BreakpointScope oldWidget) =>
      oldWidget.breakpoint != breakpoint;
}

// Mount once near the root; subsequent rebuilds only propagate when the
// bucket actually changes, not on every pixel resize.
class BreakpointProvider extends StatelessWidget {
  const BreakpointProvider({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => BreakpointScope(
        breakpoint: breakpointFor(constraints.maxWidth),
        child: child,
      ),
    );
  }
}

// Sugar for branching code on the breakpoint.
extension BreakpointX on BuildContext {
  Breakpoint get bp => BreakpointScope.of(this);
  bool get isCompact => bp == Breakpoint.compact;
  bool get isExpanded => bp == Breakpoint.expanded;
  bool get isUltrawide => bp == Breakpoint.ultrawide;
}
