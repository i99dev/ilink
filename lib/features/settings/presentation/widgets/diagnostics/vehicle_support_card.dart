/// Vehicle-support card — surfaces the resolved (HU vendor, vehicle
/// variant, integration tier) tuple plus any known quirks for the
/// detected combination.
///
/// Reads M3's `carSupportProfileProvider` (async; the detection runs
/// once and is cached) and renders M4's [VehicleSupportBadge] in its
/// non-compact form. The two-row "huVendor / variant" surface beneath
/// the badge gives triage the raw detection result without needing to
/// hit Sentry — useful when a quirk is mis-attributed to the wrong
/// trim.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../features/_car_domain/support/car_support_profile.dart';
import '../../../../../features/_car_domain/support/car_support_profile_provider.dart';
import '../../../../../features/_car_domain/support/known_quirk.dart';
import '../../../../../features/_car_domain/ui/quirk_severity_x.dart';
import '../../../../../features/_car_domain/ui/vehicle_support_badge.dart';
import '../../../../../kernel/i18n/generated/app_localizations.dart';
import 'diagnostics_card.dart';

class VehicleSupportCard extends ConsumerWidget {
  const VehicleSupportCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final t = S.of(context);
    final asyncProfile = ref.watch(carSupportProfileProvider);
    return DiagnosticsCard(
      title: t.vehicleSupportLabel,
      trailing: IconButton(
        tooltip: 'Refresh',
        icon: const Icon(Icons.refresh),
        onPressed: () => ref.invalidate(carSupportProfileProvider),
        visualDensity: VisualDensity.compact,
      ),
      child: asyncProfile.when(
        loading: () => const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (e, _) =>
            Text('Detection failed: $e', style: TextStyle(color: cs.error)),
        data: (profile) => _VehicleSupportBody(profile: profile, cs: cs, t: t),
      ),
    );
  }
}

class _VehicleSupportBody extends StatelessWidget {
  const _VehicleSupportBody({
    required this.profile,
    required this.cs,
    required this.t,
  });
  final CarSupportProfile profile;
  final ColorScheme cs;
  final S t;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const VehicleSupportBadge(compact: false),
        const SizedBox(height: 12),
        _SupportRow(
          label: t.vehicleSupportHuVendorRow,
          value: profile.huVendor.displayLabel,
        ),
        _SupportRow(
          label: t.vehicleSupportVariantRow,
          // Empty variant string = vendor-wildcard fallback row.
          value: profile.variant.isEmpty ? '—' : profile.variant,
        ),
        const SizedBox(height: 12),
        Text(
          t.vehicleSupportQuirksHeading,
          style: TextStyle(
            color: cs.onSurfaceVariant,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(height: 6),
        if (profile.quirks.isEmpty)
          Text(
            t.vehicleSupportNoQuirks,
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
          )
        else
          for (final q in profile.quirks) _QuirkRow(quirk: q, cs: cs),
      ],
    );
  }
}

class _SupportRow extends StatelessWidget {
  const _SupportRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: cs.onSurface,
                fontSize: 13,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _QuirkRow extends StatelessWidget {
  const _QuirkRow({required this.quirk, required this.cs});
  final KnownQuirk quirk;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    final color = quirk.severity.severityColor(cs);
    final icon = quirk.severity.severityIcon;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 14, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  quirk.actionId,
                  style: TextStyle(
                    color: color,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  quirk.message,
                  style: TextStyle(color: cs.onSurface, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
