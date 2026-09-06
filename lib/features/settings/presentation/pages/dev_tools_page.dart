/// Dev tools page — operator/test surface, dev-mode only.
///
/// Standalone page reached from a button on [DiagnosticsPage]; before
/// this extraction the same sections lived inline in diagnostics and
/// pushed the list past three screens of scroll. Splitting keeps
/// diagnostics scannable while preserving every test affordance the
/// rich panels (climate / windows / comfort) need.
///
/// Sections:
///
///   * CLIMATE — full panel with +/- temp, fan picker, power pill.
///   * WINDOWS — per-window stop/open/close grid.
///   * QUICK ACTIONS — the four most-used commands (lock / unlock /
///     trunk / headlights).
///   * LIGHTS / DOORS / HEATED SEATS / VENTILATED SEATS — auto-generated
///     from [commandRegistryProvider] via [_CommandGrid]. Adding a new
///     command in `_car_domain/domain/<domain>.dart` shows up here on
///     the next rebuild with no edit to this file.
///   * COMFORT — massage / fragrance / atmosphere lighting rail.
///   * COMPAT SCANNER — feature-test cards + report.
///
/// **One dispatch path.** Every button — including the auto-generated
/// grids — goes through `carClient.dispatch(id, caller:
/// HostUiConsumer.instance)`, the same call quick-actions and the
/// rich panels use. Safety stack (integrity → rate → stationary →
/// audit) runs uniformly; no per-domain dispatch wrapper.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/_car_domain/_car_domain.dart';
import '../../../../features/_car_domain/consumer/car_consumer.dart';
import '../../../../kernel/i18n/command_labels.dart';
import '../../../../kernel/i18n/generated/app_localizations.dart';
import '../../../../sdk/car/client.dart';
import '../../../compat/presentation/compat_screen.dart';
import '../../../home/presentation/widgets/climate_panel.dart';
import '../../../home/presentation/widgets/feature_rail.dart';
import '../../../home/presentation/widgets/pressable_tile.dart';
import '../../../home/presentation/widgets/quick_actions_grid.dart';
import '../../../home/presentation/widgets/windows_panel.dart';

class DevToolsPage extends ConsumerWidget {
  const DevToolsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final registry = ref.watch(commandRegistryProvider);

    void snack(String msg) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(msg, style: const TextStyle(fontFamily: 'monospace')),
          duration: const Duration(seconds: 2),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Dev Tools')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          const _SectionHeader('VOICE TIMINGS'),
          const SizedBox(height: 16),
          const _SectionHeader('CLIMATE'),
          SizedBox(height: 360, child: ClimatePanel(onResult: snack)),
          const SizedBox(height: 16),
          const _SectionHeader('WINDOWS'),
          SizedBox(height: 320, child: WindowsPanel(onResult: snack)),
          const SizedBox(height: 16),
          const _SectionHeader('QUICK ACTIONS'),
          SizedBox(height: 300, child: QuickActionsGrid(onResult: snack)),
          const SizedBox(height: 16),
          const _SectionHeader('LIGHTS'),
          _CommandGrid(
            commands: _filter(
              registry,
              category: CommandCategory.light,
              buttonsOnly: true,
            ),
            onResult: snack,
          ),
          const SizedBox(height: 16),
          const _SectionHeader('DOORS'),
          _CommandGrid(
            commands: _filter(
              registry,
              category: CommandCategory.door,
              buttonsOnly: true,
            ),
            onResult: snack,
          ),
          const SizedBox(height: 16),
          const _SectionHeader('HEATED SEATS'),
          _CommandGrid(
            commands: _filter(
              registry,
              idPrefix: 'seat.heat.',
              buttonsOnly: true,
            ),
            onResult: snack,
          ),
          const SizedBox(height: 16),
          const _SectionHeader('VENTILATED SEATS'),
          _CommandGrid(
            commands: _filter(
              registry,
              idPrefix: 'seat.vent.',
              buttonsOnly: true,
            ),
            onResult: snack,
          ),
          const SizedBox(height: 16),
          const _SectionHeader('COMFORT'),
          SizedBox(height: 260, child: FeatureRail(onResult: snack)),
          const SizedBox(height: 24),
          const _SectionHeader('COMPAT SCANNER'),
          const CompatScreen(),
        ],
      ),
    );
  }

  /// Pick the subset of [registry] that matches either a [category]
  /// or an [idPrefix]. `buttonsOnly` drops any command that needs an
  /// input editor (params without defaults) — those are wired in the
  /// rich panels above (Climate, Windows, Comfort).
  static List<CarCommand> _filter(
    Map<String, CarCommand> registry, {
    CommandCategory? category,
    String? idPrefix,
    bool buttonsOnly = false,
  }) {
    return registry.values
        .where((c) {
          if (category != null && c.category != category) return false;
          if (idPrefix != null && !c.id.startsWith(idPrefix)) return false;
          if (buttonsOnly &&
              c.params.isNotEmpty &&
              c.params.length != c.paramDefaults.length) {
            return false;
          }
          return true;
        })
        .toList(growable: false);
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4),
      child: Text(
        label,
        style: TextStyle(
          color: cs.onSurfaceVariant,
          fontSize: 11,
          letterSpacing: 1.4,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Tile grid for a list of registered commands. Shared dispatch
/// path with [QuickActionsGrid].
class _CommandGrid extends ConsumerWidget {
  const _CommandGrid({required this.commands, required this.onResult});

  final List<CarCommand> commands;
  final void Function(String) onResult;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = S.of(context);
    final cs = Theme.of(context).colorScheme;
    if (commands.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Text(
          'No commands registered for this section.',
          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
        ),
      );
    }
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 2,
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 2.4,
      children: [
        for (final cmd in commands)
          PressableTile(
            icon: cmd.icon,
            label: localizedCommandLabel(t, cmd.id) ?? cmd.label,
            color: cmd.color,
            onTap: () async {
              final raw = await ref
                  .read(carClientProvider)
                  .dispatch(cmd.id, caller: HostUiConsumer.instance);
              final outcome = CommandOutcome.fromBridge(
                raw.cast<String, dynamic>(),
              );
              onResult(outcome.describe(cmd.id));
              return outcome.ok;
            },
          ),
      ],
    );
  }
}
