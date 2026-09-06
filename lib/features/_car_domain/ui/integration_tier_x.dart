/// Presentation-only extensions on the [IntegrationTier] enum.
///
/// Lives in the `presentation/` subtree so the domain enum stays pure
/// — the bare [IntegrationTier] knows nothing about Material colours,
/// icons, or theme. Widgets that need to render a tier reach for these
/// extensions instead of duplicating switch statements per call site
/// (3-site duplication caught in the audit: VehicleSupportBadge,
/// VehicleSupportHeaderIcon, and the Diagnostics card all had their
/// own copy).
library;

import 'package:flutter/material.dart';

import '../../../../features/_car_domain/support/integration_tier.dart';

extension IntegrationTierPresentation on IntegrationTier {
  /// Semantic colour for the tier — green for full integration
  /// (driver can trust everything), warning-orange for stock
  /// (telemetry only), error-red for unsupported.
  Color tierColor(ColorScheme cs) {
    switch (this) {
      case IntegrationTier.full:
        return Colors.green.shade400;
      case IntegrationTier.stock:
        return Colors.orange.shade400;
      case IntegrationTier.unsupported:
        return cs.error;
    }
  }

  /// Material icon paired with the tier colour. Verified-check for
  /// full, info-outline for stock, block for unsupported.
  IconData get tierIcon {
    switch (this) {
      case IntegrationTier.full:
        return Icons.verified_rounded;
      case IntegrationTier.stock:
        return Icons.info_outline_rounded;
      case IntegrationTier.unsupported:
        return Icons.block_rounded;
    }
  }
}
