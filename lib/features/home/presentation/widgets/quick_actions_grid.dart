import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/_car_domain/_car_domain.dart';
import '../../../../features/_car_domain/consumer/car_consumer.dart';
import '../../../../sdk/car/client.dart';
import '../../../../kernel/i18n/command_labels.dart';
import '../../../../kernel/i18n/generated/app_localizations.dart';
import 'pressable_tile.dart';

/// Data-driven quick actions. Each tile uses PressableTile → visual press
/// feedback + teal/coral pulse on result. Adding a tile = add an id here
/// + an entry in command_registry.
class QuickActionsGrid extends ConsumerWidget {
  const QuickActionsGrid({
    super.key,
    required this.onResult,
    this.ids = const [
      'door.unlock',
      'door.lock',
      'door.trunk.open',
      'light.head.on',
    ],
  });

  final void Function(String) onResult;
  final List<String> ids;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final registry = ref.watch(commandRegistryProvider);
    final actions = [
      for (final id in ids)
        if (registry[id] != null) registry[id]!,
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.quickActions, style: _labelStyle(cs)),
            const SizedBox(height: 12),
            Expanded(
              child: GridView.count(
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  for (final c in actions)
                    PressableTile(
                      icon: c.icon,
                      label: localizedCommandLabel(t, c.id) ?? c.label,
                      color: c.color,
                      onTap: () async {
                        // Through the gate so the safety stack
                        // (integrity → rate → stationary → audit) runs
                        // for every quick-action tap. Caller=host_ui in
                        // the audit log.
                        final raw = await ref
                            .read(carClientProvider)
                            .dispatch(c.id, caller: HostUiConsumer.instance);
                        final outcome = CommandOutcome.fromBridge(
                          raw.cast<String, dynamic>(),
                        );
                        onResult(outcome.describe(c.id));
                        return outcome.ok;
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

TextStyle _labelStyle(ColorScheme cs) => TextStyle(
  fontSize: 10,
  color: cs.onSurfaceVariant,
  letterSpacing: 2,
  fontWeight: FontWeight.w600,
);
