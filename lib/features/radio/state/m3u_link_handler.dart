import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../platform/deep_link/link_router.dart';
import '../../shell/state/active_screen_controller.dart';
import '../providers.dart';

/// LinkHandler that claims `.m3u` / `.m3u8` URIs and imports them into
/// the BYO playlist set.
///
/// Wires up the manifest's `ACTION_VIEW` intent filters (mime types +
/// `file:`/`content:`/`http(s):` schemes with path patterns) to the
/// already-built import pipeline:
///
///   match(uri) → URI string when the URI looks like a playlist
///   open(...)  → controller.addFromUri → claim pending id → go to
///                radio tab → SnackBar feedback
///
/// Feature-local (registered by the root ProviderScope via
/// `linkHandlersProvider` override). The generic [LinkRouter] in
/// `platform/deep_link/` stays radio-agnostic.
class M3uPlaylistLinkHandler implements LinkHandler {
  const M3uPlaylistLinkHandler();

  /// Returns the URI string when the URI is a plausible M3U playlist.
  ///
  /// `file:`, `http:`, `https:` require a `.m3u` / `.m3u8` extension
  /// on the last path segment — strict, so we don't accidentally
  /// swallow another feature's https deep link. `content:` is accepted
  /// for any path because Android's intent system already gated it
  /// through our mime-type intent filter; the URI rarely carries the
  /// original filename.
  @override
  String? match(Uri uri) {
    switch (uri.scheme) {
      case 'file':
      case 'http':
      case 'https':
        return _looksLikeM3u(uri) ? uri.toString() : null;
      case 'content':
        return uri.toString();
      default:
        return null;
    }
  }

  @override
  Future<void> open(
    BuildContext context,
    WidgetRef ref,
    String uriString,
  ) async {
    final uri = Uri.parse(uriString);
    final name = _deriveName(uri);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final outcome = await ref
        .read(userPlaylistControllerProvider.notifier)
        .addFromUri(uri, name: name);

    if (!context.mounted) return;
    if (!outcome.ok) {
      messenger?.showSnackBar(
        SnackBar(content: Text(outcome.message ?? 'Import failed')),
      );
      return;
    }

    final id = outcome.data?['id'] as String?;
    final count = outcome.data?['count'] as int? ?? 0;
    final deduped = outcome.data?['deduped'] as bool? ?? false;

    if (id != null) {
      // The radio screen reads + clears this on its next build, switching
      // to the My Playlists category with the new id selected.
      ref.read(pendingUserPlaylistProvider.notifier).claim(id);
    }
    // Land the user on the radio tab even if they were elsewhere when
    // the intent arrived. activeScreenProvider is the only state the
    // shell's PageView reads — same surface tapping the dock uses.
    ref.read(activeScreenProvider.notifier).go(DashScreen.radio);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          deduped
              ? 'Refreshed "$name" ($count stations)'
              : 'Imported "$name" ($count stations)',
        ),
      ),
    );
  }

  // --- helpers ------------------------------------------------------------

  bool _looksLikeM3u(Uri uri) {
    if (uri.pathSegments.isEmpty) return false;
    final last = uri.pathSegments.last.toLowerCase();
    // Use endsWith to catch dotted extensions even when the path has
    // query/fragment trailers (those don't appear in pathSegments).
    return last.endsWith('.m3u') || last.endsWith('.m3u8');
  }

  /// Filename minus extension when present; falls back to the host or a
  /// generic "Shared playlist" so the user sees a sensible chip label
  /// for content-URI imports that don't carry a filename.
  String _deriveName(Uri uri) {
    if (uri.pathSegments.isNotEmpty) {
      final tail = uri.pathSegments.last;
      if (tail.isNotEmpty) {
        final dot = tail.lastIndexOf('.');
        final base = dot > 0 ? tail.substring(0, dot) : tail;
        if (base.isNotEmpty) return base;
      }
    }
    if (uri.host.isNotEmpty) return uri.host;
    return 'Shared playlist';
  }
}
