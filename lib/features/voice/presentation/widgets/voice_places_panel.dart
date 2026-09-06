/// Places result panel (find_nearby + find_place) — a list of compact
/// cards in the side panel, each with a Navigate action and tap→detail.
/// Header offers "show all on map". A specific place opens a detail
/// sub-panel (master→detail via stacked side panels).
library;

import 'package:flutter/material.dart';

import 'package:ilink/kernel/ui/theme/colors.dart';
import 'package:ilink/features/voice/domain/voice_tool_def.dart';
import 'voice_actions.dart';
import 'voice_result_models.dart';
import 'voice_side_panel.dart';

/// registerDisplay entry for find_nearby + find_place.
Future<void> showVoicePlacesPanel(
  BuildContext context,
  VoiceToolDef tool,
  Map<String, dynamic> args,
) async {
  await showVoiceSidePanel<void>(
    context,
    child: _PlacesList(result: PlacesResult.fromArgs(args)),
  );
}

/// Open the detail sub-panel for one place (stacks over the list).
Future<void> showVoicePlaceDetail(BuildContext context, PlaceResult place) {
  return showVoiceSidePanel<void>(context, child: _PlaceDetail(place: place));
}

class _PlacesList extends StatelessWidget {
  const _PlacesList({required this.result});

  final PlacesResult result;

  @override
  Widget build(BuildContext context) {
    final places = result.places;
    final center = places.isNotEmpty ? places.first : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        VoicePanelHeader(
          icon: Icons.place_rounded,
          title: result.title,
          subtitle: places.isNotEmpty ? '${places.length} found' : null,
          trailing: (center != null)
              ? IconButton(
                  tooltip: 'Show all on map',
                  icon: const Icon(
                    Icons.travel_explore_rounded,
                    color: AppColors.accent,
                  ),
                  onPressed: () => showAllOnMapChip(
                    lat: center.lat,
                    lng: center.lng,
                    query: result.query,
                  ).onTap(),
                )
              : null,
        ),
        if (result.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: VoicePanelMessage(
              result.status.message ?? 'Nothing found nearby.',
            ),
          )
        else
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              itemCount: places.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (_, i) => _PlaceCard(
                place: places[i],
                onTap: () => showVoicePlaceDetail(context, places[i]),
              ),
            ),
          ),
      ],
    );
  }
}

class _PlaceCard extends StatelessWidget {
  const _PlaceCard({required this.place, required this.onTap});
  final PlaceResult place;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sub = _subtitle(place);
    return Material(
      color: cs.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      place.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: cs.onSurface,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (sub != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (place.distanceLabel != null)
                _DistanceChip(place.distanceLabel!),
              IconButton(
                tooltip: 'Navigate',
                icon: const Icon(
                  Icons.navigation_rounded,
                  color: AppColors.accent,
                ),
                onPressed: () => navigateChip(
                  lat: place.lat,
                  lng: place.lng,
                  label: place.name,
                ).onTap(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String? _subtitle(PlaceResult p) {
  final parts = <String>[];
  if (p.rating != null) {
    parts.add(
      p.ratingCount != null
          ? '★ ${p.rating!.toStringAsFixed(1)} (${p.ratingCount})'
          : '★ ${p.rating!.toStringAsFixed(1)}',
    );
  }
  if (p.openNow == true) {
    parts.add('Open');
  } else if (p.openNow == false) {
    parts.add('Closed');
  }
  if (p.address != null && p.address!.isNotEmpty) parts.add(p.address!);
  return parts.isEmpty ? null : parts.join(' · ');
}

class _DistanceChip extends StatelessWidget {
  const _DistanceChip(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.accent.withAlpha(28),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: AppColors.accent,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _PlaceDetail extends StatelessWidget {
  const _PlaceDetail({required this.place});
  final PlaceResult place;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        VoicePanelHeader(icon: Icons.place_rounded, title: place.name),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            children: [
              if (place.openNow != null)
                _InfoRow(
                  icon: place.openNow!
                      ? Icons.check_circle_rounded
                      : Icons.cancel_rounded,
                  color: place.openNow! ? Colors.green : cs.error,
                  text: place.openNow! ? 'Open now' : 'Closed',
                ),
              if (place.rating != null)
                _InfoRow(
                  icon: Icons.star_rounded,
                  color: Colors.amber,
                  text: place.ratingCount != null
                      ? '${place.rating!.toStringAsFixed(1)} (${place.ratingCount} reviews)'
                      : place.rating!.toStringAsFixed(1),
                ),
              if (place.distanceLabel != null)
                _InfoRow(
                  icon: Icons.straighten_rounded,
                  color: cs.onSurfaceVariant,
                  text: '${place.distanceLabel} away',
                ),
              if (place.address != null && place.address!.isNotEmpty)
                _InfoRow(
                  icon: Icons.location_on_outlined,
                  color: cs.onSurfaceVariant,
                  text: place.address!,
                ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  navigateChip(
                    lat: place.lat,
                    lng: place.lng,
                    label: place.name,
                  ),
                  showAllOnMapChip(
                    lat: place.lat,
                    lng: place.lng,
                    query: place.name,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.color, required this.text});
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: cs.onSurface, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}
