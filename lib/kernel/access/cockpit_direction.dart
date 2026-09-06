import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../settings/app_settings.dart';

/// The pinned cockpit text direction. Reads driverSide from settings
/// and maps to the matching [TextDirection]:
///   * [DriverSide.left]  → [TextDirection.ltr]  (driver on the left,
///     UI flows left-to-right as their dominant reach does)
///   * [DriverSide.right] → [TextDirection.rtl]  (driver on the right,
///     UI flows right-to-left so the controls they reach for sit
///     under their hand)
final cockpitDirectionProvider = Provider<TextDirection>((ref) {
  final side = ref.watch(
    settingsProvider.select(
      (s) => s.value?.driverSide ?? AppSettings.defaultDriverSide,
    ),
  );
  return switch (side) {
    DriverSide.left => TextDirection.ltr,
    DriverSide.right => TextDirection.rtl,
  };
});

/// Drop-in subtree wrapper that pins layout direction for every
/// descendant. Use it at the cockpit shell's root and at any other
/// screen the driver controls in motion. Cheap — it's a
/// `Directionality` plus one provider read; the text direction is
/// re-read only when the driver-side setting flips.
class CockpitDirectionality extends ConsumerWidget {
  const CockpitDirectionality({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Directionality(
      textDirection: ref.watch(cockpitDirectionProvider),
      child: child,
    );
  }
}
