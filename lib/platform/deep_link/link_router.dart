import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A handler a feature registers with the router to claim incoming URIs.
///
/// [match] is a cheap URI-only predicate: it returns a non-null "match key"
/// (usually an id) if the URI belongs to this handler, else null. It must
/// not touch state — the router calls it once per URI per handler in order.
///
/// [open] does the actual work — resolve the id, push the right screen,
/// surface errors. Because handlers live in the `state/` layer they have
/// a [WidgetRef] and can read any provider they need (catalog, auth, ...).
abstract class LinkHandler {
  const LinkHandler();

  String? match(Uri uri);

  Future<void> open(BuildContext context, WidgetRef ref, String matchKey);
}

/// Generic dispatcher. Iterates registered handlers in order, hands the
/// URI to the first one that matches. Unmatched URIs are the caller's
/// problem (e.g. [pendingLinkProvider] re-buffers them for a later
/// listener, or the app ignores them).
///
/// Deliberately zero feature knowledge — adding a new deep-link type
/// (mini-apps, cars, subscriptions, ...) means registering a new
/// [LinkHandler], never editing this class.
class LinkRouter {
  const LinkRouter(this._handlers);

  final List<LinkHandler> _handlers;

  /// Returns true iff some handler matched and completed. A false return
  /// lets the caller decide whether to drop the URI or buffer it — the
  /// router itself holds no state.
  Future<bool> route(BuildContext context, WidgetRef ref, Uri uri) async {
    for (final h in _handlers) {
      final key = h.match(uri);
      if (key == null) continue;
      await h.open(context, ref, key);
      return true;
    }
    return false;
  }
}
