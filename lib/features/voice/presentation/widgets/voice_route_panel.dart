/// Route result panel (get_route) — ETA + distance + traffic + EV range
/// check, with Start-navigation / Open-in-Maps actions.
library;

import 'package:flutter/material.dart';

import 'package:ilink/features/voice/domain/voice_tool_def.dart';
import 'voice_actions.dart';
import 'voice_result_models.dart';
import 'voice_side_panel.dart';

Future<void> showVoiceRoutePanel(
  BuildContext context,
  VoiceToolDef tool,
  Map<String, dynamic> args,
) async {
  await showVoiceSidePanel<void>(
    context,
    child: _RoutePanel(route: RouteResult.fromArgs(args)),
  );
}

class _RoutePanel extends StatelessWidget {
  const _RoutePanel({required this.route});
  final RouteResult route;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        VoicePanelHeader(
          icon: Icons.directions_rounded,
          title: 'Route to ${route.destination}',
        ),
        VoicePanelBody(
          children: [
            if (route.status.degraded)
              VoicePanelMessage(
                route.status.message ?? "Couldn't work out a route.",
              )
            else ...[
              if (route.durationText != null)
                Text(
                  route.durationText!,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 40,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              if (route.distanceText != null)
                Text(
                  route.distanceText!,
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 16),
                ),
              if (route.hasTrafficDelay) ...[
                const SizedBox(height: 10),
                _Banner(
                  icon: Icons.traffic_rounded,
                  color: Colors.orange,
                  text:
                      'About ${route.trafficDelayMin} min slower than usual in traffic',
                ),
              ],
              if (route.rangeOk == false && route.rangeWarning != null) ...[
                const SizedBox(height: 10),
                _Banner(
                  icon: Icons.battery_alert_rounded,
                  color: cs.error,
                  text: route.rangeWarning!,
                ),
              ] else if (route.rangeOk == true) ...[
                const SizedBox(height: 10),
                const _Banner(
                  icon: Icons.battery_charging_full_rounded,
                  color: Colors.green,
                  text: 'Within your current range',
                ),
              ],
              const SizedBox(height: 18),
              if (route.hasCoords)
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    VoiceActionChip(
                      icon: Icons.navigation_rounded,
                      label: 'Start navigation',
                      primary: true,
                      onTap: () => navigateChip(
                        lat: route.lat!,
                        lng: route.lng!,
                        label: route.destination,
                      ).onTap(),
                    ),
                    openInMapsChip(
                      lat: route.lat!,
                      lng: route.lng!,
                      label: route.destination,
                    ),
                  ],
                ),
            ],
          ],
        ),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.color, required this.text});
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withAlpha(24),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: cs.onSurface, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
