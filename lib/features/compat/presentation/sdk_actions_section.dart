/// Dev-page section for SDK features that don't have a sibling
/// surface on the rest of the Compat screen:
///   * `dispatchAndConfirm(actionId, name, expect)` — write + observe
///   * `freshness(name)` — per-name staleness readout
///
/// Plain `client.dispatch` is exercised by the Manual press +
/// Fast actions cards; not duplicated here.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../sdk/car/client.dart';

class SdkActionsSection extends ConsumerStatefulWidget {
  const SdkActionsSection({super.key});

  @override
  ConsumerState<SdkActionsSection> createState() => _SdkActionsSectionState();
}

class _SdkActionsSectionState extends ConsumerState<SdkActionsSection> {
  /// Last dispatch outcome per action id (raw map or `confirmed` flag).
  final Map<String, String> _outcomes = <String, String>{};
  bool _busy = false;
  Timer? _ticker;

  /// Re-emit every second so the freshness readouts tick visibly.
  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _runConfirm(String id, _ConfirmSpec spec) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _outcomes[id] = '⋯ dispatching + waiting for ${spec.name}…';
    });
    final client = ref.read(carClientProvider);
    final start = DateTime.now();
    try {
      final res = await client.dispatchAndConfirm(
        id,
        name: spec.name,
        expect: spec.expect,
        timeout: const Duration(seconds: 4),
      );
      final ms = DateTime.now().difference(start).inMilliseconds;
      final mark = res.confirmed ? '✓' : '✗';
      final tail = res.confirmed
          ? 'observed=${res.observedValue}'
          : 'timeout — read still ${client.value(spec.name)}';
      setState(() => _outcomes[id] = '$mark ${ms}ms · $tail');
    } catch (e) {
      setState(() => _outcomes[id] = '✗ $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(carClientProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Heading('Dispatch + Confirm'),
        const Text(
          'Calls CarClient.dispatchAndConfirm — write + wait for the read '
          'to flip into the expected state, with a 4 s timeout.',
          style: TextStyle(fontSize: 12, color: Color(0xFF888888)),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final entry in _confirmable.entries)
              _ActionButton(
                label: entry.key,
                outcome: _outcomes[entry.key],
                onTap: _busy ? null : () => _runConfirm(entry.key, entry.value),
              ),
          ],
        ),
        const SizedBox(height: 16),
        const _Heading('Freshness inspector'),
        const Text(
          'CarClient.freshness — duration since the last value arrived. '
          'Kill the daemon (adb shell kill <pid>) and watch this climb.',
          style: TextStyle(fontSize: 12, color: Color(0xFF888888)),
        ),
        const SizedBox(height: 8),
        for (final name in _freshnessWatch)
          _FreshnessRow(name: name, client: client),
      ],
    );
  }
}

class _ConfirmSpec {
  const _ConfirmSpec(this.name, this.expect);
  final String name;
  final bool Function(int) expect;
}

final _confirmable = <String, _ConfirmSpec>{
  'door.lock': _ConfirmSpec(
    'Door.DOOR_LOCK_COMMAND_AREA_LEFT_FRONT',
    (v) => v == 0,
  ),
  'door.unlock': _ConfirmSpec(
    'Door.DOOR_LOCK_COMMAND_AREA_LEFT_FRONT',
    (v) => v == 1,
  ),
  'trunk.open': _ConfirmSpec('Bodywork.BODYWORK_LUGGAGE_DOOR', (v) => v == 1),
  'trunk.close': _ConfirmSpec('Bodywork.BODYWORK_LUGGAGE_DOOR', (v) => v == 0),
};

const _freshnessWatch = <String>[
  'Statistic.STATISTIC_SOC_BATTERY_PERCENTAGE',
  'Ac.AC_TEMP_INSIDE',
  'Bodywork.BODYWORK_LEFT_HAND_FRONT_DOOR',
  'Door.DOOR_LOCK_COMMAND_AREA_LEFT_FRONT',
];

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 4),
    child: Text(
      text,
      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
    ),
  );
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.onTap,
    required this.outcome,
  });
  final String label;
  final VoidCallback? onTap;
  final String? outcome;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 200, maxWidth: 360),
      child: OutlinedButton(
        onPressed: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
            if (outcome != null)
              Text(
                outcome!,
                style: const TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: Color(0xFF888888),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _FreshnessRow extends StatelessWidget {
  const _FreshnessRow({required this.name, required this.client});
  final String name;
  final CarClient client;

  @override
  Widget build(BuildContext context) {
    final value = client.value(name);
    final age = client.freshness(name);
    final ageText = age == null
        ? 'never'
        : age.inSeconds < 1
        ? '<1s'
        : '${age.inSeconds}s ago';
    final stale = age != null && age > const Duration(seconds: 5);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(
              color: age == null
                  ? const Color(0xFF6E6E6E)
                  : stale
                  ? const Color(0xFFD9A227)
                  : const Color(0xFF2EA66B),
              shape: BoxShape.circle,
            ),
          ),
          Expanded(
            child: Text(
              name,
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 60,
            child: Text(
              value?.toString() ?? '—',
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 70,
            child: Text(
              ageText,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: stale
                    ? const Color(0xFFD9A227)
                    : const Color(0xFF888888),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
