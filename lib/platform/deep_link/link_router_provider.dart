import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'link_router.dart';

/// Features contribute their [LinkHandler]s by overriding this provider
/// in the root [ProviderScope] — keeps `LinkRouter` feature-agnostic
/// and makes the routing table reviewable in one file.
///
/// Default: empty list. The app composes the real list by overriding
/// this in `main.dart` (see `DashApp`'s ProviderScope.overrides).
final linkHandlersProvider = Provider<List<LinkHandler>>((_) => const []);

/// Single [LinkRouter] instance for the app. Built from whatever the
/// current override of [linkHandlersProvider] returns.
final linkRouterProvider = Provider<LinkRouter>(
  (ref) => LinkRouter(ref.watch(linkHandlersProvider)),
);
