import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../kernel/ui/theme/colors.dart';
import '../../../../features/_car_domain/command/command_outcome.dart';
import '../../../../kernel/i18n/generated/app_localizations.dart';
import '../../../../sdk/car/client.dart';

// Bottom feature rail. Data-driven — each chip declares its icon + label +
// the level rows to show when expanded. Adding a new feature = one entry.
class FeatureRail extends ConsumerStatefulWidget {
  const FeatureRail({super.key, required this.onResult});
  final void Function(String) onResult;
  @override
  ConsumerState<FeatureRail> createState() => _FeatureRailState();
}

class _FeatureRailState extends ConsumerState<FeatureRail> {
  String? _expanded;

  @override
  Widget build(BuildContext context) {
    final t = S.of(context);
    final chips = <_ChipSpec>[
      _ChipSpec('massage', Icons.spa, t.massage),
      _ChipSpec('heat', Icons.whatshot, t.seatHeat),
      _ChipSpec('vent', Icons.air_rounded, t.seatVent),
      _ChipSpec('frag', Icons.local_florist, t.fragrance),
      _ChipSpec('ambient', Icons.auto_awesome, t.ambient),
      _ChipSpec('lights', Icons.flare, t.lights),
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          child: _expanded == null ? const SizedBox.shrink() : _expansion(),
        ),
        SizedBox(
          height: 64,
          child: Row(children: [for (final c in chips) _chip(c)]),
        ),
      ],
    );
  }

  Widget _chip(_ChipSpec c) {
    final cs = Theme.of(context).colorScheme;
    final active = _expanded == c.id;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: InkWell(
          onTap: () => setState(() => _expanded = active ? null : c.id),
          borderRadius: BorderRadius.circular(16),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            decoration: BoxDecoration(
              color: active
                  ? AppColors.accent.withAlpha(30)
                  : cs.surfaceContainer,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: active ? AppColors.accent : cs.outlineVariant,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  c.icon,
                  size: 16,
                  color: active ? AppColors.accent : cs.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text(
                  c.label,
                  style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 2,
                    fontWeight: FontWeight.w700,
                    color: active ? AppColors.accent : cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _expansion() {
    final t = S.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: switch (_expanded!) {
        // Verified on this car: val=1 is OFF, val=2-4 are the actual modes.
        'massage' => _LevelRow(
          label: t.railDriverMassage,
          entries: [
            (t.off, 1),
            (t.levelMode1, 2),
            (t.levelMode2, 3),
            (t.levelMode3, 4),
          ],
          onPick: (v) =>
              _dispatch('massage=$v', 'massage.drv.mode', {'value': v}),
        ),
        'heat' => _LevelRow(
          label: t.railDriverHeat,
          entries: [(t.off, 0), ('1', 1), ('2', 2), ('3', 3)],
          onPick: (v) =>
              _dispatch('heat.drv=$v', 'seat.heat.drv', {'value': v}),
        ),
        'vent' => _LevelRow(
          label: t.railDriverVent,
          entries: [(t.off, 0), ('1', 1), ('2', 2), ('3', 3)],
          onPick: (v) =>
              _dispatch('vent.drv=$v', 'seat.vent.drv', {'value': v}),
        ),
        'frag' => _LevelRow(
          label: t.fragrance,
          entries: [
            (t.off, -1),
            (t.levelLight, 1),
            (t.levelMid, 2),
            (t.levelDense, 3),
          ],
          onPick: (v) => v == -1
              ? _dispatch('frag.off', 'comfort.fragrance.off', const {})
              : _dispatch('frag=$v', 'comfort.fragrance.on', {'value': v}),
        ),
        'ambient' => _LevelRow(
          label: t.railAmbientLight,
          entries: [
            (t.off, 0),
            (t.levelDim, 1),
            (t.levelMid, 2),
            (t.levelHigh, 3),
          ],
          onPick: (v) => _dispatch('atmos=${v * 80}', 'comfort.atmos', {
            'field': 'bright',
            'value': v * 80,
          }),
        ),
        'lights' => _LevelRow(
          label: t.railExterior,
          entries: [
            (t.off, 0),
            (t.levelHead, 1),
            (t.levelFogFront, 2),
            (t.levelFogRear, 3),
          ],
          onPick: (v) => switch (v) {
            0 => _dispatch('light.head.off', 'light.head.off', const {}),
            1 => _dispatch('light.head.on', 'light.head.on', const {}),
            2 => _dispatch(
              'light.fog.front.on',
              'light.fog.front.on',
              const {},
            ),
            3 => _dispatch('light.fog.rear.on', 'light.fog.rear.on', const {}),
            _ => _dispatch('light.head.off', 'light.head.off', const {}),
          },
        ),
        _ => const SizedBox.shrink(),
      },
    );
  }

  void _dispatch(String label, String actionId, Map<String, Object?> args) {
    ref
        .read(carClientProvider)
        .dispatch(actionId, args: args)
        .then(
          (raw) => widget.onResult(
            CommandOutcome.fromBridge(
              raw.cast<String, dynamic>(),
            ).describe(label),
          ),
        )
        .catchError((e) => widget.onResult('$label error: $e'));
  }
}

class _ChipSpec {
  const _ChipSpec(this.id, this.icon, this.label);
  final String id;
  final IconData icon;
  final String label;
}

class _LevelRow extends StatelessWidget {
  const _LevelRow({
    required this.label,
    required this.entries,
    required this.onPick,
  });

  final String label;
  final List<(String, int)> entries;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 10,
                color: cs.onSurfaceVariant,
                letterSpacing: 2,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          for (final e in entries)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: InkWell(
                  onTap: () => onPick(e.$2),
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    height: 40,
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      e.$1,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                        color: cs.onSurface,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
