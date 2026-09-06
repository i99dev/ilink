import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../kernel/ui/theme/colors.dart';
import '../../../../features/_car_domain/_car_domain.dart';
import '../../../../sdk/car/client.dart';
import '../../../../features/_car_domain/consumer/car_consumer.dart';
import '../../../../kernel/i18n/generated/app_localizations.dart';
import '../../../../sdk/car/byd_features.dart';
import '../../../../sdk/car/widget_helpers.dart';

/// Climate tile. Reads target-temp/fan/power from the SDK
/// (`featureValueProvider` per field — same source the dashboard
/// tiles and Gate Probe consume). Writes go through
/// `client.dispatch` (the registry's `climate.*` actions); the SDK's
/// push stream refreshes the displayed value once the daemon confirms.
class ClimatePanel extends ConsumerWidget {
  const ClimatePanel({super.key, required this.onResult});
  final void Function(String) onResult;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final labelStyle = _labelStyle(cs);
    final temp = ref.watchFeatureInt(BydFeatures.acTempMain) ?? 22;
    final fan = ref.watchFeatureInt(BydFeatures.acWindLevel) ?? 3;
    final acState = ref.watchFeatureInt(BydFeatures.acPowerState);
    // Default to "on" when unknown so the toggle button feels alive
    // before the first push lands — matches the legacy behavior that
    // defaulted `climate.acPower ?? true`.
    final power = acState == null ? true : acState == 1;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Text(t.climate, style: labelStyle),
                const Spacer(),
                _PowerPill(on: power, onTap: () => _togglePower(ref, power)),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _round(cs, '−', () => _setTemp(ref, temp - 1)),
                Column(
                  children: [
                    Text(
                      '$temp',
                      style: TextStyle(
                        fontSize: 88,
                        fontWeight: FontWeight.w200,
                        letterSpacing: -4,
                        color: cs.onSurface,
                        height: 1,
                      ),
                    ),
                    Text(
                      '°C',
                      style: TextStyle(
                        fontSize: 14,
                        color: cs.onSurfaceVariant,
                        letterSpacing: 2,
                      ),
                    ),
                  ],
                ),
                _round(cs, '+', () => _setTemp(ref, temp + 1)),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.air, size: 16, color: cs.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Text(t.fan, style: labelStyle),
                  ],
                ),
                const SizedBox(height: 10),
                _FanStrip(value: fan, onPick: (v) => _setFan(ref, v)),
                const SizedBox(height: 18),
                Row(
                  children: [
                    _ModePill(
                      icon: Icons.landscape,
                      label: t.face,
                      active: true,
                    ),
                    const SizedBox(width: 8),
                    _ModePill(icon: Icons.waves, label: t.feet, active: false),
                    const SizedBox(width: 8),
                    _ModePill(
                      icon: Icons.ac_unit,
                      label: t.defrost,
                      active: false,
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _round(ColorScheme cs, String label, VoidCallback onTap) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(100),
    child: Container(
      width: 54,
      height: 54,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w400,
          color: cs.onSurface,
        ),
      ),
    ),
  );

  // The router looks up the action in `commandRegistryProvider`, which
  // is keyed by REGISTRY ids (`climate.temp`), not wire ids
  // (`ac.temp`). Sending the wire id falls through to the router's
  // default case and returns `tool_not_found` — the optimistic update
  // shows briefly, then WARM polling restores the unchanged car state.
  // Use the registry id; the registered command's `exec` ultimately
  // dispatches the matching `ActionIds.*` wire id through the bridge.
  static const _registryTemp = 'climate.temp';
  static const _registryFan = 'climate.fan';
  static const _registryPower = 'climate.power';

  void _setTemp(WidgetRef ref, int v) {
    final next = v.clamp(16, 32);
    ref
        .read(carClientProvider)
        .dispatch(
          _registryTemp,
          args: {'value': next},
          caller: HostUiConsumer.instance,
        )
        .then(
          (raw) =>
              onResult(CommandOutcome.fromBridge(raw).describe('temp=$next')),
        );
  }

  void _setFan(WidgetRef ref, int v) {
    ref
        .read(carClientProvider)
        .dispatch(
          _registryFan,
          args: {'value': v},
          caller: HostUiConsumer.instance,
        )
        .then(
          (raw) => onResult(CommandOutcome.fromBridge(raw).describe('fan=$v')),
        );
  }

  void _togglePower(WidgetRef ref, bool current) {
    final next = !current;
    ref
        .read(carClientProvider)
        .dispatch(
          _registryPower,
          args: {'on': next},
          caller: HostUiConsumer.instance,
        )
        .then(
          (raw) => onResult(
            CommandOutcome.fromBridge(
              raw,
            ).describe('ac=${next ? 'on' : 'off'}'),
          ),
        );
  }
}

class _FanStrip extends StatelessWidget {
  const _FanStrip({required this.value, required this.onPick});
  final int value;
  final ValueChanged<int> onPick;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        for (var i = 1; i <= 7; i++)
          Expanded(
            child: InkWell(
              onTap: () => onPick(i),
              borderRadius: BorderRadius.circular(4),
              child: Container(
                height: 32,
                margin: const EdgeInsets.symmetric(horizontal: 1),
                decoration: BoxDecoration(
                  color: i <= value
                      ? AppColors.accent
                      : cs.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(4),
                  boxShadow: i <= value
                      ? [
                          BoxShadow(
                            color: AppColors.accent.withAlpha(60),
                            blurRadius: 8,
                          ),
                        ]
                      : null,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _ModePill extends StatelessWidget {
  const _ModePill({
    required this.icon,
    required this.label,
    required this.active,
  });
  final IconData icon;
  final String label;
  final bool active;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: Container(
        height: 56,
        decoration: BoxDecoration(
          color: active
              ? AppColors.accent.withAlpha(36)
              : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: active ? AppColors.accent : Colors.transparent,
            width: 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 18,
              color: active ? AppColors.accent : cs.onSurfaceVariant,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 9,
                letterSpacing: 1.5,
                fontWeight: FontWeight.w600,
                color: active ? AppColors.accent : cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PowerPill extends StatelessWidget {
  const _PowerPill({required this.on, required this.onTap});
  final bool on;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final t = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final color = on ? AppColors.accent : cs.outline;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(100),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: color.withAlpha(32),
          borderRadius: BorderRadius.circular(100),
          border: Border.all(color: color.withAlpha(120)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.power_settings_new, size: 12, color: color),
            const SizedBox(width: 6),
            Text(
              on ? t.on : t.off,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 2,
                color: color,
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
