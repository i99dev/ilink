import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:ilink/sdk/_internal/logger.dart';
import 'link_router_provider.dart';

/// Mounts the app-wide deep-link listener.
///
/// One subscription for the whole session — tied to the lifetime of the
/// widget, which is itself mounted by `main.dart` only on the data
/// branch of the settings gate. That guarantees [Navigator] is ready
/// when the first URI arrives.
///
/// Cold-start URIs come in through [AppLinks.getInitialAppLink]; warm-
/// start URIs arrive on [AppLinks.uriLinkStream]. Both go through the
/// same [LinkRouter] so the feature-specific handling lives in the
/// registered [LinkHandler]s, not here.
///
/// Intentionally stateful + Consumer: we need initState/dispose for
/// the subscription AND `ref` to reach the router. The child is
/// rendered unchanged — this widget adds no chrome.
class DeepLinkListener extends ConsumerStatefulWidget {
  const DeepLinkListener({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<DeepLinkListener> createState() => _DeepLinkListenerState();
}

class _DeepLinkListenerState extends ConsumerState<DeepLinkListener> {
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _sub;
  final Logger _log = const Logger('DeepLinkListener');

  @override
  void initState() {
    super.initState();
    // Wait until the first frame is drawn before we consider the
    // Navigator attachable — otherwise a very-fast cold-start URI
    // could race the widget-tree's mount and try to push into a
    // not-yet-built Navigator.
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    if (!mounted) return;
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) {
        _log.i('cold-start deep link: $initial');
        await _route(initial);
      }
    } catch (e, s) {
      _log.e('initial link fetch failed', error: e, stack: s);
    }
    if (!mounted) return;
    _sub = _appLinks.uriLinkStream.listen(
      (uri) {
        _log.i('warm deep link: $uri');
        unawaited(_route(uri));
      },
      onError: (Object e, StackTrace s) {
        _log.e('uriLinkStream error', error: e, stack: s);
      },
    );
  }

  Future<void> _route(Uri uri) async {
    if (!mounted) return;
    final router = ref.read(linkRouterProvider);
    final handled = await router.route(context, ref, uri);
    if (!handled) {
      _log.w('no handler matched $uri — dropping');
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _sub = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
