import 'package:ilink/kernel/storage/local_first_image.dart';
import 'package:ilink/kernel/services/optional_services.dart';
import 'package:flutter/material.dart';

import '../../domain/channel.dart';

/// A single channel in the grid: logo, name, quality badge, and a favourite
/// toggle. The active channel gets an accent border.
class ChannelTile extends StatelessWidget {
  const ChannelTile({
    super.key,
    required this.channel,
    required this.playing,
    required this.favorite,
    required this.onTap,
    required this.onToggleFavorite,
  });

  final Channel channel;
  final bool playing;
  final bool favorite;
  final VoidCallback onTap;
  final VoidCallback onToggleFavorite;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: playing ? cs.primary : cs.outlineVariant.withAlpha(80),
              width: playing ? 2 : 1,
            ),
          ),
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              _Logo(url: channel.logo, cs: cs),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      channel.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: cs.onSurface,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    if (channel.quality != null) ...[
                      const SizedBox(height: 3),
                      _QualityBadge(quality: channel.quality!, cs: cs),
                    ],
                  ],
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  favorite ? Icons.favorite : Icons.favorite_border,
                  size: 18,
                  color: favorite ? cs.primary : cs.onSurfaceVariant,
                ),
                onPressed: onToggleFavorite,
                tooltip: favorite ? 'Remove favourite' : 'Add favourite',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo({required this.url, required this.cs});
  final String? url;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    const size = 44.0;
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(Icons.live_tv_rounded, size: 22, color: cs.onSurfaceVariant),
    );
    final logo = url;
    if (logo == null || logo.isEmpty) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: LocalFirstImage(
        service: OptionalService.streaming,
        imageUrl: logo,
        width: size,
        height: size,
        fit: BoxFit.contain,
        placeholder: (_, _) => fallback,
        errorWidget: (_, _, _) => fallback,
      ),
    );
  }
}

class _QualityBadge extends StatelessWidget {
  const _QualityBadge({required this.quality, required this.cs});
  final String quality;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: cs.primary.withAlpha(36),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        quality,
        style: TextStyle(
          color: cs.primary,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
