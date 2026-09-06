import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../kernel/ui/theme/colors.dart';
import '../../domain/user_playlist.dart';
import '../../providers.dart';
import 'add_playlist_sheet.dart';

/// Modal sheet for managing user-imported playlists.
///
/// Pops the id of a playlist the user picked to load (so the radio
/// screen can show its stations), or null if dismissed. In-sheet
/// actions (Add / Refresh / Remove) mutate state without closing —
/// the user usually wants to manage a few before backing out.
class MyPlaylistsSheet extends ConsumerWidget {
  const MyPlaylistsSheet({super.key});

  static Future<String?> show(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => const MyPlaylistsSheet(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final playlists = ref.watch(userPlaylistsProvider);
    return FractionallySizedBox(
      heightFactor: 0.8,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _grabber(cs),
              const SizedBox(height: 4),
              _header(context, cs),
              const SizedBox(height: 12),
              Expanded(
                child: playlists.isEmpty
                    ? _emptyState(cs)
                    : ListView.separated(
                        itemCount: playlists.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, i) =>
                            _PlaylistTile(playlist: playlists[i]),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _grabber(ColorScheme cs) => Center(
    child: Container(
      margin: const EdgeInsets.only(bottom: 10),
      height: 4,
      width: 44,
      decoration: BoxDecoration(
        color: cs.outlineVariant,
        borderRadius: BorderRadius.circular(2),
      ),
    ),
  );

  Widget _header(BuildContext context, ColorScheme cs) => Row(
    children: [
      Text(
        'MY PLAYLISTS',
        style: TextStyle(
          letterSpacing: 3,
          fontSize: 12,
          color: cs.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
      const Spacer(),
      FilledButton.icon(
        key: const Key('my_playlists.add'),
        style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
        onPressed: () async {
          // Don't pop this sheet — let the user keep managing after add.
          await AddPlaylistSheet.show(context);
        },
        icon: const Icon(Icons.add_rounded, size: 18),
        label: const Text('Add'),
      ),
    ],
  );

  Widget _emptyState(ColorScheme cs) => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.playlist_play_rounded,
            size: 48,
            color: cs.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            'No imported playlists yet',
            style: TextStyle(color: cs.onSurface, fontSize: 14),
          ),
          const SizedBox(height: 6),
          Text(
            'Tap Add to import an .m3u / .m3u8 file from your device or paste an M3U URL.',
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
          ),
        ],
      ),
    ),
  );
}

class _PlaylistTile extends ConsumerWidget {
  const _PlaylistTile({required this.playlist});

  final UserPlaylist playlist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainer,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        // Tap to load this playlist into the radio screen.
        onTap: () => Navigator.of(context).pop(playlist.id),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
          child: Row(
            children: [
              const Icon(Icons.playlist_play_rounded, color: AppColors.accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      playlist.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: cs.onSurface,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${playlist.entryCount} stations · ${playlist.source.displayHint}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              if (playlist.source is UserPlaylistUrlSource)
                IconButton(
                  key: Key('my_playlists.refresh.${playlist.id}'),
                  tooltip: 'Refresh',
                  icon: Icon(Icons.refresh_rounded, color: cs.onSurfaceVariant),
                  onPressed: () => _refresh(context, ref),
                ),
              IconButton(
                key: Key('my_playlists.remove.${playlist.id}'),
                tooltip: 'Remove',
                icon: Icon(
                  Icons.delete_outline_rounded,
                  color: cs.onSurfaceVariant,
                ),
                onPressed: () => _confirmRemove(context, ref),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _refresh(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final out = await ref
        .read(userPlaylistControllerProvider.notifier)
        .refresh(playlist.id);
    if (!context.mounted) return;
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          out.ok
              ? 'Refreshed "${playlist.name}"'
              : (out.message ?? 'Refresh failed'),
        ),
      ),
    );
  }

  Future<void> _confirmRemove(BuildContext context, WidgetRef ref) async {
    final cs = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: cs.surface,
        title: Text('Remove "${playlist.name}"?'),
        content: const Text(
          'This removes the imported playlist from this app. The source '
          '(file/URL) is not deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await ref.read(userPlaylistControllerProvider.notifier).remove(playlist.id);
  }
}
