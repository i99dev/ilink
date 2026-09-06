/// Card on the Diagnostics page that opens the gate-probe screen
/// (live read-surface validator). Shows the current count of live
/// features the SDK is tracking — sourced from
/// `CarClient.liveFeatures` directly, no hardcoded field list.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../../sdk/brands/byd/byd_status_labels.dart';
import '../../../../../../sdk/car/client.dart';
import 'gate_probe_screen.dart';

class GateProbeCard extends ConsumerWidget {
  const GateProbeCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final liveCount = ref
        .watch(_liveCountProvider)
        .maybeWhen(data: (n) => n, orElse: () => 0);
    final knownTotal = bydStatusLabelToCatalog.values.toSet().length;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        title: const Text('Gate probe'),
        subtitle: Text(
          '$liveCount live / $knownTotal known fields '
          '(${bydBootWarmSet.length} in warm set)',
          style: TextStyle(
            color: liveCount > 0
                ? const Color(0xFF2EA66B)
                : const Color(0xFF6E6E6E),
            fontSize: 13,
          ),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const GateProbeScreen())),
      ),
    );
  }
}

/// Cheap counter — refreshes every 5 s. Sourced from the SDK's hot
/// cache (`CarClient.liveFeatures`) so the count is the union of the
/// boot warm set, push frames, and any lazy fallback fetches.
final _liveCountProvider = StreamProvider.autoDispose<int>((ref) async* {
  final client = ref.watch(carClientProvider);
  yield (await client.liveFeatures()).length;
  await for (final _ in Stream<void>.periodic(const Duration(seconds: 5))) {
    yield (await client.liveFeatures()).length;
  }
});
