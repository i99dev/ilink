/// Compact badge widget rendering the resolved vehicle support state.
/// Reused across the About section (single-line summary) and the
/// Diagnostics card (full surface with quirks).
///
/// Pulls from [carSupportProfileSnapshotProvider] so the rendering
/// path is sync — the FutureProvider's loading-state collapses to the
/// `unknownVehicle` sentinel which is the right thing to show during
/// boot anyway. After the future settles every consumer rebuilds
/// automatically through the snapshot provider.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../kernel/i18n/generated/app_localizations.dart';
import '../../../../features/_car_domain/support/car_support_profile_provider.dart';
import '../../../../features/_car_domain/support/integration_tier.dart';
import 'integration_tier_x.dart';

class VehicleSupportBadge extends ConsumerWidget {
  const VehicleSupportBadge({super.key, this.compact = true});

  /// `true` (default) renders the single-line "tier · vehicle" badge
  /// suitable for an inline About row. `false` renders the full
  /// two-line stack used by the Diagnostics card.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final t = S.of(context);
    final profile = ref.watch(carSupportProfileSnapshotProvider);
    final tierLabel = _tierLabel(t, profile.tier);
    final color = profile.tier.tierColor(cs);
    final icon = profile.tier.tierIcon;

    if (compact) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              '$tierLabel · ${profile.displayName}',
              style: TextStyle(
                color: cs.onSurface,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
        ],
      );
    }

    // Full layout — used by the Diagnostics card.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Text(
              tierLabel,
              style: TextStyle(
                color: color,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          profile.displayName,
          style: TextStyle(
            color: cs.onSurface,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  /// Maps the IntegrationTier enum to the locale-bound display string
  /// (which the .arb owns). Kept private to this widget so the
  /// IntegrationTier enum stays presentation-agnostic.
  String _tierLabel(S t, IntegrationTier tier) {
    switch (tier) {
      case IntegrationTier.full:
        return t.vehicleSupportTierFull;
      case IntegrationTier.stock:
        return t.vehicleSupportTierStock;
      case IntegrationTier.unsupported:
        return t.vehicleSupportTierUnsupported;
    }
  }
}
