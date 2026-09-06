/// Presentation-only extensions on the [QuirkSeverity] enum.
///
/// Same posture as `integration_tier_x.dart` — keeps the domain
/// [KnownQuirk] type free of Material colours / icons. Two duplicate
/// switch sites caught in the audit (ActionQuirkChip + the Diagnostics
/// quirk row) converge here.
library;

import 'package:flutter/material.dart';

import '../../../../features/_car_domain/support/known_quirk.dart';

extension QuirkSeverityPresentation on QuirkSeverity {
  /// Semantic colour — neutral surface variant for info, orange for
  /// warning, error for blocked. Theme-aware via the passed-in
  /// [ColorScheme] so dark/light themes render correctly.
  Color severityColor(ColorScheme cs) {
    switch (this) {
      case QuirkSeverity.info:
        return cs.onSurfaceVariant;
      case QuirkSeverity.warning:
        return Colors.orange.shade400;
      case QuirkSeverity.blocked:
        return cs.error;
    }
  }

  /// Material icon paired with the severity colour.
  IconData get severityIcon {
    switch (this) {
      case QuirkSeverity.info:
        return Icons.info_outline_rounded;
      case QuirkSeverity.warning:
        return Icons.warning_amber_rounded;
      case QuirkSeverity.blocked:
        return Icons.block_rounded;
    }
  }
}
