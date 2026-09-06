import 'package:flutter/material.dart';

import '../../../../kernel/ui/theme/colors.dart';
import '../../../../kernel/i18n/generated/app_localizations.dart';
import '../../domain/permission_kind.dart';

/// One row in the onboarding permissions list. Renders a coloured
/// icon, the title + reason, the on/off switch, and (after `finish()`
/// runs) a status pill summarising the OS dialog outcome.
class PermissionTile extends StatelessWidget {
  const PermissionTile({
    super.key,
    required this.kind,
    required this.title,
    required this.reason,
    required this.enabled,
    required this.onToggle,
    this.result = PermissionRequestResult.idle,
  });

  final PermissionKind kind;
  final String title;
  final String reason;
  final bool enabled;
  final ValueChanged<bool> onToggle;
  final PermissionRequestResult result;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.accent.withAlpha(24),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(kind.icon, color: AppColors.accent, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: cs.onSurface,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      reason,
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Switch.adaptive(
                value: enabled,
                onChanged: onToggle,
                activeThumbColor: AppColors.accent,
              ),
            ],
          ),
          if (result != PermissionRequestResult.idle) ...[
            const SizedBox(height: 10),
            _StatusPill(result: result),
          ],
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.result});
  final PermissionRequestResult result;

  @override
  Widget build(BuildContext context) {
    final t = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final (color, label) = switch (result) {
      PermissionRequestResult.granted => (
        AppColors.accent,
        t.onboardingPermissionGranted,
      ),
      PermissionRequestResult.denied => (
        AppColors.error,
        t.onboardingPermissionDenied,
      ),
      PermissionRequestResult.skipped => (
        cs.outline,
        t.onboardingPermissionSkipped,
      ),
      PermissionRequestResult.unavailable => (
        AppColors.secondary,
        t.onboardingPermissionUnavailable,
      ),
      PermissionRequestResult.idle => (cs.outline, ''),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(28),
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: color.withAlpha(140)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}
