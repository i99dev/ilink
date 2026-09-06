import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../kernel/ui/theme/colors.dart';
import '../../../../features/_car_domain/safety/integrity_health_provider.dart';
import '../../../../kernel/i18n/generated/app_localizations.dart';

/// Banner that surfaces when the on-device integrity monitor has flipped
/// the app unhealthy. Two user-visible effects:
///
///  - A persistent red strip above the screen body telling the driver
///    commands are disabled (the router already refuses to dispatch —
///    see [CarCommandRouter] integrity gate — but the driver needs to
///    know *why* a tap isn't doing anything).
///  - Nothing else: no modal, no forced logout, no network calls. The
///    banner is the floor of the user-facing reaction; recovery is
///    automatic once the next periodic check sees a clean state.
///
/// Hidden in the happy path ([SizedBox.shrink]) so the layout doesn't
/// shift when the banner appears — the [AnimatedSwitcher] in the caller
/// handles the transition.
class IntegrityBanner extends ConsumerWidget {
  const IntegrityBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final healthy = ref
        .watch(integrityHealthyProvider)
        .maybeWhen(
          data: (v) => v,
          orElse: () => true, // fail-open while loading / on error
        );
    if (healthy) return const SizedBox.shrink();
    final t = S.of(context);
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: AppColors.primary.withValues(alpha: 0.18),
      child: Row(
        children: [
          const Icon(Icons.shield_outlined, color: AppColors.primary, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.integrityCheckFailedTitle,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  t.integrityCheckFailedBody,
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
