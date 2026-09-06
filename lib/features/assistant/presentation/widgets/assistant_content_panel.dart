import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../kernel/ui/theme/colors.dart';
import '../../state/assistant_card.dart';
import '../../state/assistant_card_controller.dart';

/// Transient overlay panel — renders whatever [assistantCardProvider]
/// currently holds. Slides up from the bottom when a card appears,
/// slides out when the controller clears it. Non-modal: the driver can
/// keep tapping the dock, hero panel, etc. through this card's sibling
/// space in the shell Stack.
///
/// Placement: see `dash_shell.dart` — this sits above the PageView and
/// below the pill dock.
class AssistantContentPanel extends ConsumerWidget {
  const AssistantContentPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final card = ref.watch(assistantCardProvider);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 240),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, anim) {
        final slide = Tween<Offset>(
          begin: const Offset(0, 0.25),
          end: Offset.zero,
        ).animate(anim);
        return SlideTransition(
          position: slide,
          child: FadeTransition(opacity: anim, child: child),
        );
      },
      child: card == null
          ? const SizedBox.shrink(key: ValueKey('empty'))
          : _render(context, card, ref),
    );
  }

  Widget _render(BuildContext ctx, AssistantCard card, WidgetRef ref) {
    void dismiss() => ref.read(assistantCardProvider.notifier).clear();
    // ValueKey distinct per variant so AnimatedSwitcher animates on a
    // type change (e.g. Status → Radio) instead of snapping the
    // content inside the same frame.
    switch (card) {
      case StatusCard():
        return _CardFrame(
          key: const ValueKey('status'),
          onTap: dismiss,
          child: _StatusBody(card),
        );
      case RadioCard():
        return _CardFrame(
          key: const ValueKey('radio'),
          onTap: dismiss,
          child: _RadioBody(card),
        );
      case ConfirmationCard():
        return _CardFrame(
          key: ValueKey('confirm:${card.title}'),
          onTap: dismiss,
          child: _ConfirmationBody(card),
        );
      case ErrorCard():
        return _CardFrame(
          key: const ValueKey('error'),
          onTap: dismiss,
          child: _ErrorBody(card),
        );
    }
  }
}

/// Shared card shell — dark elevated surface, rounded corners, tap to
/// dismiss. Padding + typography match the home panels' visual language.
class _CardFrame extends StatelessWidget {
  const _CardFrame({super.key, required this.child, required this.onTap});

  final Widget child;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHigh.withAlpha(240),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: cs.outlineVariant.withAlpha(140)),
            boxShadow: const [
              BoxShadow(
                color: Colors.black54,
                blurRadius: 32,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

// ── Body widgets ──────────────────────────────────────────────────────

class _StatusBody extends StatelessWidget {
  const _StatusBody(this.card);
  final StatusCard card;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const _Header(label: 'CAR STATUS', color: AppColors.accent),
        const SizedBox(height: 12),
        Wrap(
          spacing: 16,
          runSpacing: 12,
          children: [
            if (card.batteryPct != null)
              _Metric(
                icon: Icons.battery_charging_full_rounded,
                label: 'Battery',
                value: '${card.batteryPct}%',
                color: AppColors.accent,
              ),
            if (card.rangeEvKm != null)
              _Metric(
                icon: Icons.route_rounded,
                label: 'Range',
                value: '${card.rangeEvKm} km',
                color: AppColors.secondary,
              ),
            if (card.cabinTempC != null)
              _Metric(
                icon: Icons.thermostat_rounded,
                label: 'Cabin',
                value: '${card.cabinTempC}°',
                color: AppColors.primary,
              ),
            if (card.outsideTempC != null)
              _Metric(
                icon: Icons.air_rounded,
                label: 'Outside',
                value: '${card.outsideTempC}°',
                color: cs.onSurfaceVariant,
              ),
            if (card.doorsLocked != null)
              _Metric(
                icon: card.doorsLocked!
                    ? Icons.lock_rounded
                    : Icons.lock_open_rounded,
                label: 'Doors',
                value: card.doorsLocked! ? 'LOCKED' : 'UNLOCKED',
                color: card.doorsLocked! ? AppColors.accent : AppColors.warning,
              ),
          ],
        ),
      ],
    );
  }
}

class _RadioBody extends StatelessWidget {
  const _RadioBody(this.card);
  final RadioCard card;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.accent.withAlpha(40),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(
            Icons.radio_rounded,
            color: AppColors.accent,
            size: 28,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const _Header(label: 'RADIO', color: AppColors.accent),
              const SizedBox(height: 4),
              Text(
                card.stationName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                card.action.toUpperCase(),
                style: TextStyle(
                  color: cs.onSurfaceVariant,
                  fontSize: 11,
                  letterSpacing: 1.1,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ConfirmationBody extends StatelessWidget {
  const _ConfirmationBody(this.card);
  final ConfirmationCard card;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: card.color.withAlpha(40),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(card.icon, color: card.color, size: 28),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                card.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: card.color,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
              if (card.detail != null)
                Text(
                  card.detail!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                ),
            ],
          ),
        ),
        const Icon(Icons.check_rounded, color: AppColors.accent, size: 22),
      ],
    );
  }
}

class _ErrorBody extends StatelessWidget {
  const _ErrorBody(this.card);
  final ErrorCard card;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.warning.withAlpha(40),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(
            Icons.warning_amber_rounded,
            color: AppColors.warning,
            size: 28,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                card.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.warning,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
              if (card.detail != null)
                Text(
                  card.detail!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.label, required this.color});
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Text(
    label,
    style: TextStyle(
      color: color,
      fontSize: 11,
      letterSpacing: 1.4,
      fontWeight: FontWeight.w700,
    ),
  );
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: color.withAlpha(32),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: color, size: 18),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                color: cs.onSurfaceVariant,
                fontSize: 10,
                letterSpacing: 0.6,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              value,
              style: TextStyle(
                color: cs.onSurface,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
