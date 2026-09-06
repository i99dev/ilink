import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../kernel/ui/theme/colors.dart';
import '../../../../kernel/i18n/generated/app_localizations.dart';
import '../../domain/mini_app.dart';
import '../../state/mini_app_update_checker.dart';

/// Compact horizontal strip of status chips for a [MiniApp]. Renders one
/// chip per applicable signal so users can see at a glance whether an
/// app:
///   * is in FLIGHT TEST (a beta-track build going through tester
///     review before promotion to production),
///   * uses legacy privileged issuer authority (cmdExec.* permissions),
///   * is safe to launch while moving,
///   * is already installed.
///
/// Chips are deliberately small and dense — the underlying tile / row
/// has limited vertical real estate. Wrap with [Wrap] so a tile that
/// doesn't fit them on one line still renders cleanly.
class MiniAppStatusChips extends ConsumerWidget {
  const MiniAppStatusChips({super.key, required this.app, this.dense = false});

  final MiniApp app;

  /// In dense mode, chips drop their leading icons and compress padding
  /// — used in the list-row variant where space is even tighter.
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = S.of(context);
    final chips = <Widget>[];

    // Surface the user-driven update check via a chip on every tile.
    // Only renders for apps the checker has flagged — so the moment
    // "Check for updates" runs and finds something, every relevant
    // tile lights up. Cheap O(n) lookup; n is the count of pending
    // updates (typically 0–3).
    final updateState = ref.watch(miniAppUpdateCheckerProvider);
    if (miniAppUpdateAvailable(updateState, app.id)) {
      chips.add(
        _chip(
          context,
          icon: Icons.system_update_alt_rounded,
          label: 'UPDATE',
          bg: AppColors.primary.withAlpha(40),
          fg: AppColors.primary,
        ),
      );
    }

    if (app.isBeta) {
      chips.add(
        _chip(
          context,
          icon: Icons.science_outlined,
          // FLIGHT TEST matches the developer-portal vocabulary (the
          // operational phase between `sdk beta promote` and
          // `sdk beta promote-production`). The predicate stays
          // `app.isBeta` — beta-track IS the flight-test cohort.
          label: t.miniAppsFlightTestBadge,
          bg: AppColors.secondary.withAlpha(40),
          fg: AppColors.secondary,
        ),
      );
    }
    if (app.privileged) {
      chips.add(
        _chip(
          context,
          icon: Icons.lock_outline_rounded,
          // Legacy issuer authority is separate from local scope consent.
          // A login cannot enable new privileged installs in standalone mode.
          label: t.miniAppsPrivilegedBadge,
          bg: AppColors.warning.withAlpha(40),
          fg: AppColors.warning,
        ),
      );
    }
    if (app.safeWhileDriving) {
      chips.add(
        _chip(
          context,
          icon: Icons.directions_car_filled_outlined,
          label: t.miniAppsSafeWhileDrivingBadge,
          bg: AppColors.accent.withAlpha(40),
          fg: AppColors.accent,
        ),
      );
    }

    if (chips.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 4, runSpacing: 4, children: chips);
  }

  Widget _chip(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Color bg,
    required Color fg,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 5 : 6,
        vertical: dense ? 1 : 2,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!dense) ...[
            Icon(icon, size: 11, color: fg),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: fg,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
              fontSize: dense ? 10 : null,
            ),
          ),
        ],
      ),
    );
  }
}
