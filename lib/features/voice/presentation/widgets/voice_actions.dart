/// Reusable action chips for voice-result panels (Navigate, Open in
/// Maps, Call, Website, Show on map). One styling + one wiring to the
/// geo/dial/web intent helpers, reused by the place list, place detail,
/// and route panels.
library;

import 'package:flutter/material.dart';

import 'package:ilink/kernel/ui/theme/colors.dart';
import 'geo_launch.dart';

class VoiceActionChip extends StatelessWidget {
  const VoiceActionChip({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (primary) {
      return FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: Colors.black,
        ),
        onPressed: onTap,
        icon: Icon(icon, size: 18),
        label: Text(label),
      );
    }
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        foregroundColor: cs.onSurface,
        side: BorderSide(color: cs.outlineVariant),
      ),
      onPressed: onTap,
      icon: Icon(icon, size: 18),
      label: Text(label),
    );
  }
}

/// Primary "Navigate" action — opens the destination in the nav app.
VoiceActionChip navigateChip({
  required double lat,
  required double lng,
  required String label,
}) => VoiceActionChip(
  icon: Icons.navigation_rounded,
  label: 'Navigate',
  primary: true,
  onTap: () => launchGeoIntent(lat: lat, lng: lng, label: label),
);

/// "Open in Maps" — same geo intent, secondary styling (used where
/// Navigate is already primary or for a single place).
VoiceActionChip openInMapsChip({
  required double lat,
  required double lng,
  required String label,
}) => VoiceActionChip(
  icon: Icons.map_outlined,
  label: 'Open in Maps',
  onTap: () => launchGeoIntent(lat: lat, lng: lng, label: label),
);

/// "Show all on map" — opens the nav app to a search near [lat],[lng]
/// so every match in the area renders (we can't draw our own map on
/// GMS-less hardware).
VoiceActionChip showAllOnMapChip({
  required double lat,
  required double lng,
  required String query,
}) => VoiceActionChip(
  icon: Icons.travel_explore_rounded,
  label: 'Show all on map',
  onTap: () => launchGeoSearch(lat: lat, lng: lng, query: query),
);

VoiceActionChip callChip(String phone) => VoiceActionChip(
  icon: Icons.call_rounded,
  label: 'Call',
  onTap: () => launchDial(phone),
);

VoiceActionChip websiteChip(String url) => VoiceActionChip(
  icon: Icons.public_rounded,
  label: 'Website',
  onTap: () => launchWeb(url),
);
