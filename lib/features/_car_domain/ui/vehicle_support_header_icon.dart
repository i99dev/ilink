/// Tiny icon-only badge for the top status bar.
///
/// Always-visible at-a-glance answer to "is ilink properly integrated
/// with this car?" — green check for [IntegrationTier.full], orange info
/// for [IntegrationTier.stock], red block for [IntegrationTier.unsupported].
/// No text — fits in the header next to the avatar + settings gear.
///
/// Tap behaviour: opens [DiagnosticsPage] so the user can see the full
/// state and tap any of the recovery actions (Grant all, Make default
/// home, Enable A11y) without going through Settings → About →
/// Open diagnostics.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/settings/presentation/pages/diagnostics_page.dart';
import '../../../../features/_car_domain/support/car_support_profile_provider.dart';
import 'integration_tier_x.dart';

class VehicleSupportHeaderIcon extends ConsumerWidget {
  const VehicleSupportHeaderIcon({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final profile = ref.watch(carSupportProfileSnapshotProvider);
    final color = profile.tier.tierColor(cs);
    final icon = profile.tier.tierIcon;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const DiagnosticsPage())),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: color, size: 22),
      ),
    );
  }
}
