/// Shared building blocks for the Diagnostics page cards.
///
/// Every card on the Diagnostics page shares the same outer shell
/// (rounded surfaceContainer + outlineVariant border + bold-title
/// header with optional trailing icon button). Pulling that shell into
/// [DiagnosticsCard] here keeps the per-card files focused on their
/// own content and guarantees visual consistency: tweak the border
/// radius / padding / title weight in one place and every card moves
/// together.
///
/// Also hosts the small key-value / action-row / error-text helpers
/// that the App-info and Maintenance cards both reach for.
library;

import 'package:flutter/material.dart';

import '../../../../../kernel/ui/theme/colors.dart';
import '../../../../../kernel/i18n/generated/app_localizations.dart';

/// Outer surface used by every Diagnostics card. Pure layout — no
/// state, no Riverpod — so it stays cheap to mount inside the page's
/// `ListView`.
class DiagnosticsCard extends StatelessWidget {
  const DiagnosticsCard({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

/// Two-column key/value list used inside [DiagnosticsCard]. The label
/// column is a fixed 110 px so multiple lists on the same page line up
/// even when their values have wildly different lengths.
class DiagnosticsKvList extends StatelessWidget {
  const DiagnosticsKvList({super.key, required this.items});
  final Map<String, String> items;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        for (final e in items.entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 110,
                  child: Text(
                    e.key,
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                  ),
                ),
                Expanded(
                  child: Text(
                    e.value,
                    style: TextStyle(
                      color: cs.onSurface,
                      fontSize: 13,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Single row in the Maintenance card: leading icon + title /
/// description column + a Run/Soon button on the right. When
/// [onPressed] is null the row dims to 50 % opacity and the button
/// label flips from "Run" to "Soon" — used by the stubbed log-export
/// slot.
class DiagnosticsActionRow extends StatelessWidget {
  const DiagnosticsActionRow({
    super.key,
    required this.icon,
    required this.label,
    required this.description,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final String description;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final t = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Row(
        children: [
          Icon(icon, color: cs.onSurface, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  description,
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: onPressed,
            child: Text(enabled ? t.actionRun : t.actionSoon),
          ),
        ],
      ),
    );
  }
}

/// Small inline error label used inside cards when an `AsyncValue`
/// resolves to an error. Uses [AppColors.error] (not the colour
/// scheme's error) so the message stays legible regardless of theme.
class DiagnosticsErrorText extends StatelessWidget {
  const DiagnosticsErrorText({super.key, required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Text(
    message,
    style: const TextStyle(color: AppColors.error, fontSize: 12),
  );
}
