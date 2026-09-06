/// App-wide navigator key + provider so background work (push
/// notifications, async tool dispatch, voice consent prompts) can
/// surface dialogs / sheets without holding a stale ``BuildContext``.
///
/// Wiring:
///
/// * ``main.dart`` constructs ``MaterialApp(navigatorKey:
///   appNavigatorKey, …)`` so the framework attaches it to the root
///   navigator at first build.
/// * Background callers read ``ref.read(appNavigatorKeyProvider)
///   .currentContext`` and call ``show*`` helpers against it. The
///   getter returns ``null`` when no route is mounted (cold-boot
///   race) — callers must handle that case (typically: skip the
///   prompt + fall back to a safe default like "deny").
///
/// Why one navigator key for the whole app, not per-feature: the
/// alternatives (NavigatorObserver tracking topmost context, a
/// service-locator) all duplicate Flutter's existing global state
/// without removing the GlobalKey under the hood. A single named
/// key is the smallest seam.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The single GlobalKey attached to ``MaterialApp.navigatorKey``.
/// Treated as immutable for the app lifetime — never reassigned.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>(
  debugLabel: 'app',
);

/// Riverpod-friendly accessor. Consumers that need the current
/// ``BuildContext`` (e.g. to show a bottom sheet from a non-widget
/// callback) read this provider and follow ``key.currentContext``.
final appNavigatorKeyProvider = Provider<GlobalKey<NavigatorState>>(
  (_) => appNavigatorKey,
);

final GlobalKey<ScaffoldMessengerState> appScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>(debugLabel: 'app-messenger');
