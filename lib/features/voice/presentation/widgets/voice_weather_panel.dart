/// Weather panel (get_weather) — current conditions + next-hours strip
/// in the side panel.
library;

import 'package:flutter/material.dart';

import 'package:ilink/features/voice/domain/voice_tool_def.dart';
import 'voice_result_models.dart';
import 'voice_side_panel.dart';

Future<void> showVoiceWeatherPanel(
  BuildContext context,
  VoiceToolDef tool,
  Map<String, dynamic> args,
) async {
  await showVoiceSidePanel<void>(
    context,
    autoDismiss: const Duration(seconds: 12),
    child: _WeatherPanel(weather: WeatherResult.fromArgs(args)),
  );
}

class _WeatherPanel extends StatelessWidget {
  const _WeatherPanel({required this.weather});
  final WeatherResult weather;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        VoicePanelHeader(
          icon: _wmoIcon(weather.weatherCode),
          title: weather.condition,
        ),
        VoicePanelBody(
          children: [
            if (weather.status.degraded)
              VoicePanelMessage(
                weather.status.message ?? 'Weather unavailable.',
              )
            else ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (weather.tempC != null)
                    Text(
                      '${weather.tempC}°',
                      style: TextStyle(
                        color: cs.onSurface,
                        fontSize: 52,
                        fontWeight: FontWeight.w800,
                        height: 1,
                      ),
                    ),
                  const Spacer(),
                  if (weather.windKmh != null)
                    _Chip(
                      icon: Icons.air_rounded,
                      label: '${weather.windKmh} km/h',
                    ),
                ],
              ),
              if (weather.highC != null || weather.lowC != null) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    if (weather.highC != null)
                      _Chip(
                        icon: Icons.arrow_upward,
                        label: '${weather.highC}°',
                      ),
                    if (weather.highC != null) const SizedBox(width: 8),
                    if (weather.lowC != null)
                      _Chip(
                        icon: Icons.arrow_downward,
                        label: '${weather.lowC}°',
                      ),
                  ],
                ),
              ],
              if (weather.hours.isNotEmpty) ...[
                const SizedBox(height: 18),
                SizedBox(
                  height: 64,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: weather.hours.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 10),
                    itemBuilder: (_, i) => _HourCell(hour: weather.hours[i]),
                  ),
                ),
              ],
              if (weather.footer != null) ...[
                const SizedBox(height: 14),
                Text(
                  weather.footer!,
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: 13,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ],
          ],
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: cs.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: cs.onSurface, fontSize: 13)),
        ],
      ),
    );
  }
}

class _HourCell extends StatelessWidget {
  const _HourCell({required this.hour});
  final WeatherHour hour;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            hour.label,
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
          ),
          const SizedBox(height: 4),
          Text(
            hour.tempC != null ? '${hour.tempC}°' : '—',
            style: TextStyle(
              color: cs.onSurface,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

IconData _wmoIcon(int? code) {
  if (code == null) return Icons.cloud_outlined;
  if (code == 0) return Icons.wb_sunny_rounded;
  if (code <= 3) return Icons.cloud_outlined;
  if (code <= 48) return Icons.foggy;
  if (code <= 67) return Icons.grain_rounded;
  if (code <= 77) return Icons.ac_unit_rounded;
  if (code <= 82) return Icons.water_drop_rounded;
  if (code <= 86) return Icons.ac_unit_rounded;
  return Icons.thunderstorm_rounded;
}
