/// Diagnostics page — operator drilldown from the Status section.
///
/// The page itself is just an `AppBar` + `ListView` of cards; every
/// card lives in its own file under `widgets/diagnostics/` so each
/// one can evolve (and be tested) independently. Adding a new card
/// here is a one-line edit: import + insert into the children list.
///
/// Card order matters — it's the operator's mental model:
///   1. App info (always-cheap version surface)
///   2. Tables & pairing (is this car paired / are dispatch tables synced)
///   3. Vehicle support (resolved HU vendor / variant + known quirks)
///   4. Launcher-mode privileges (grant grid + bootstrap actions)
///   5. Maintenance (radio refresh, cache wipe, log export stub)
///
/// Dev-mode-gated tail: when `devCarControlsEnabled` is on, the page
/// appends GPS keepalive, Gate Probe, and an "Open Dev Tools" card
/// that pushes [DevToolsPage]. The dev tools page itself holds the
/// rich actuator surfaces (climate / windows / lights / doors /
/// heated + vented seats / comfort / compat scanner) — kept off
/// diagnostics so the operator drilldown stays scannable.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../kernel/i18n/generated/app_localizations.dart';
import '../../../../kernel/settings/app_settings.dart';
import '../../../shell/presentation/widgets/gps_status_card.dart';
import '../widgets/diagnostics/app_info_card.dart';
import '../widgets/diagnostics/gate_probe/gate_probe_card.dart';
import '../widgets/diagnostics/launcher_privilege_card.dart';
import '../widgets/diagnostics/maintenance_card.dart';
import '../widgets/diagnostics/tables_sync_card.dart';
import '../widgets/diagnostics/vehicle_support_card.dart';
import 'dev_tools_page.dart';

class DiagnosticsPage extends ConsumerWidget {
  const DiagnosticsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = S.of(context);
    final devOn = ref.watch(
      settingsProvider.select((s) => s.value?.devCarControlsEnabled ?? false),
    );

    return Scaffold(
      appBar: AppBar(title: Text(t.diagnosticsTitle)),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const AppInfoCard(),
          const SizedBox(height: 16),
          // Tables & pairing sits directly under the App card and is
          // always visible (no longer dev-mode-gated) — it's the
          // operator's primary "is this car paired / are the dispatch
          // tables synced" surface.
          const TablesSyncCard(),
          const SizedBox(height: 16),
          const VehicleSupportCard(),
          const SizedBox(height: 16),
          const LauncherPrivilegeCard(),
          const SizedBox(height: 16),
          const MaintenanceCard(),
          if (devOn) ...[
            const SizedBox(height: 24),
            const _DevSectionDivider(),
            const SizedBox(height: 16),
            const GpsStatusCard(),
            const SizedBox(height: 16),
            const GateProbeCard(),
            const SizedBox(height: 12),
            const _OpenDevToolsCard(),
          ],
        ],
      ),
    );
  }
}

/// Tappable card under Gate Probe that pushes [DevToolsPage]. Sits
/// at the bottom of the dev tail so the diagnostics list stays
/// scannable; the rich actuator surfaces live on the pushed page.
class _OpenDevToolsCard extends StatelessWidget {
  const _OpenDevToolsCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: const Icon(Icons.science_outlined),
        title: const Text('Dev Tools'),
        subtitle: const Text(
          'Climate · Windows · Lights · Doors · Heated/Vented Seats · '
          'Comfort · Compat Scanner',
          style: TextStyle(fontSize: 12),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const DevToolsPage())),
      ),
    );
  }
}

/// Visual break between the always-on diagnostics cards and the
/// dev-mode-gated tail.
class _DevSectionDivider extends StatelessWidget {
  const _DevSectionDivider();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(child: Divider(color: cs.outlineVariant)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            'DEVELOPER MODE',
            style: TextStyle(
              color: cs.onSurfaceVariant,
              fontSize: 11,
              letterSpacing: 1.4,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Expanded(child: Divider(color: cs.outlineVariant)),
      ],
    );
  }
}
