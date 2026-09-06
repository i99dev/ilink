import 'package:flutter/widgets.dart';

import 'breakpoints.dart';

// Design tokens keyed to the three breakpoints. Values grow with the
// screen so the car (ultrawide) gets generous breathing room while
// compact-Chrome dev fits without overflow.
//
// Usage:
//   Padding(padding: EdgeInsets.all(Spacing.md(context)), ...)
//   SizedBox(height: Spacing.lg(context))
class Spacing {
  const Spacing._();

  static double xs(BuildContext c) => _pick(c, 4, 6, 8);
  static double sm(BuildContext c) => _pick(c, 8, 12, 14);
  static double md(BuildContext c) => _pick(c, 12, 18, 22);
  static double lg(BuildContext c) => _pick(c, 16, 24, 28);
  static double xl(BuildContext c) => _pick(c, 24, 32, 40);

  // Gutter between the shell's nav rail and content.
  static double gutter(BuildContext c) => _pick(c, 8, 14, 20);

  static double _pick(
    BuildContext c,
    double compact,
    double expanded,
    double ultrawide,
  ) => switch (c.bp) {
    Breakpoint.compact => compact,
    Breakpoint.expanded => expanded,
    Breakpoint.ultrawide => ultrawide,
  };
}

// Convenience widgets that avoid EdgeInsets allocations at every build.
class Gap extends StatelessWidget {
  const Gap.xs({super.key}) : _size = _Size.xs;
  const Gap.sm({super.key}) : _size = _Size.sm;
  const Gap.md({super.key}) : _size = _Size.md;
  const Gap.lg({super.key}) : _size = _Size.lg;
  const Gap.xl({super.key}) : _size = _Size.xl;

  final _Size _size;

  @override
  Widget build(BuildContext context) {
    final v = switch (_size) {
      _Size.xs => Spacing.xs(context),
      _Size.sm => Spacing.sm(context),
      _Size.md => Spacing.md(context),
      _Size.lg => Spacing.lg(context),
      _Size.xl => Spacing.xl(context),
    };
    return SizedBox(width: v, height: v);
  }
}

enum _Size { xs, sm, md, lg, xl }
