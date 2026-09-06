import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../kernel/ui/theme/colors.dart';
import '../../../../kernel/i18n/generated/app_localizations.dart';
import '../../state/active_screen_controller.dart';
import '../dash_shell.dart' show visibleScreensProvider;

/// Floating glass pill at the bottom of [DashShell]. Holds the visible
/// screen icons. The mic moved to a standalone [FloatingMic] anchored
/// to the driver-side corner — the dock is now nav-only.
///
/// Invariants:
/// - The active indicator is a slid/animated pill behind the selected icon,
///   not a destination color swap (matches modern nav conventions).
/// - The dock is decoupled from shell layout: it positions itself, consumes
///   no layout slot in the shell's `Column`, and can be hidden/shown without
///   affecting the PageView sizing.
class DashPillDock extends ConsumerWidget {
  const DashPillDock({super.key});

  static const _itemSize = 52.0;
  static const _horizontalPad = 14.0;
  static const _verticalPad = 8.0;
  static const _itemGap = 6.0;
  static const _border = 2.0;

  /// Compute total dock width for [navItemCount] nav icons. The `+ _border`
  /// term covers the Container's outline so the inner Row doesn't overflow.
  static double totalWidthFor(int navItemCount) =>
      _horizontalPad * 2 +
      _itemSize * navItemCount +
      _itemGap * (navItemCount - 1) +
      _border;

  static const _totalHeight = _itemSize + _verticalPad * 2 + _border;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final active = ref.watch(activeScreenProvider);
    final visible = ref.watch(visibleScreensProvider);
    final items = [
      for (final screen in visible) _DockItem.forScreen(screen, t),
    ];
    // Clamp the active indicator position so a just-hidden Climate doesn't
    // leave the pill sliding to index -1 while the reset-to-home
    // animation is still in flight.
    final activeIndex = visible.indexOf(active).clamp(0, visible.length - 1);

    // RepaintBoundary isolates the BackdropFilter (very expensive on
    // the head-unit GPU) from sibling repaint work in the shell Stack
    // — AssistantContentPanel + the floating mic + the active-pill
    // animation all sit in the same Stack. Without this boundary,
    // any of those animating siblings dirties the dock's layer and
    // forces a full blur re-render every frame.
    return RepaintBoundary(
      child: SizedBox(
        width: totalWidthFor(items.length),
        height: _totalHeight,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(36),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: _horizontalPad,
                vertical: _verticalPad,
              ),
              decoration: BoxDecoration(
                color: cs.surfaceContainerLow.withAlpha(168),
                borderRadius: BorderRadius.circular(36),
                border: Border.all(color: cs.outlineVariant.withAlpha(120)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha(120),
                    blurRadius: 32,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: _IndicatorRow(
                items: items,
                activeIndex: activeIndex,
                onTap: (s) => ref.read(activeScreenProvider.notifier).go(s),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Horizontal row of tappable nav icons with a single animated pill that
/// slides to the active index. The pill is a [Stack] layer behind the row
/// so swapping icons doesn't reset its transform.
class _IndicatorRow extends StatelessWidget {
  const _IndicatorRow({
    required this.items,
    required this.activeIndex,
    required this.onTap,
  });

  final List<_DockItem> items;
  final int activeIndex;
  final void Function(DashScreen) onTap;

  @override
  Widget build(BuildContext context) {
    const slot = DashPillDock._itemSize + DashPillDock._itemGap;
    final width = items.isEmpty
        ? 0.0
        : slot * items.length - DashPillDock._itemGap;
    return SizedBox(
      height: DashPillDock._itemSize,
      width: width,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Pill indicator slides behind the active item.
          AnimatedPositioned(
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
            left: activeIndex * slot,
            top: 0,
            width: DashPillDock._itemSize,
            height: DashPillDock._itemSize,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppColors.accent.withAlpha(40),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: AppColors.accent.withAlpha(110)),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.accent.withAlpha(80),
                    blurRadius: 18,
                    spreadRadius: 1,
                  ),
                ],
              ),
            ),
          ),
          // Tappable icons, positioned via explicit left offsets so the
          // non-positioned Row doesn't need MainAxisSize.max (which wants
          // infinity inside a Stack with loose constraints on its main
          // axis, exploding the parent Row).
          for (var i = 0; i < items.length; i++)
            Positioned(
              left: i * slot,
              top: 0,
              width: DashPillDock._itemSize,
              height: DashPillDock._itemSize,
              child: _DockIcon(
                item: items[i],
                active: i == activeIndex,
                onTap: () => onTap(items[i].screen),
              ),
            ),
        ],
      ),
    );
  }
}

class _DockIcon extends StatelessWidget {
  const _DockIcon({
    required this.item,
    required this.active,
    required this.onTap,
  });

  final _DockItem item;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: active,
      label: item.label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: SizedBox(
            width: DashPillDock._itemSize,
            height: DashPillDock._itemSize,
            child: Icon(
              item.icon,
              size: 24,
              color: active ? AppColors.accent : cs.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

class _DockItem {
  const _DockItem(this.screen, this.icon, this.label);

  factory _DockItem.forScreen(DashScreen screen, S t) {
    switch (screen) {
      case DashScreen.home:
        return _DockItem(screen, Icons.dashboard_rounded, t.screenHome);
      case DashScreen.radio:
        return _DockItem(screen, Icons.radio_rounded, t.screenRadio);
      case DashScreen.miniApps:
        return _DockItem(screen, Icons.apps_rounded, t.screenMiniApps);
      case DashScreen.tv:
        return _DockItem(screen, Icons.live_tv_rounded, t.screenTv);
    }
  }

  final DashScreen screen;
  final IconData icon;
  final String label;
}
