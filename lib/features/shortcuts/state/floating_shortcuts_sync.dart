import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../kernel/access/app_shortcut_overlay.dart';
import '../../../kernel/settings/app_settings.dart';

/// Keeps the native floating app-shortcut buttons in lockstep with the
/// [AppSettings.floatingAppShortcuts] list. Must be kept alive — `ref.watch`ed
/// once at the app root (see main.dart) — so it reacts for the app's lifetime.
///
/// Inert by default: the list is empty until the user pins apps, and an empty
/// list tears the overlay down. Pushing on every change is safe — the native
/// side reconciles (adds new buttons, removes dropped ones, leaves the rest).
final floatingShortcutsSyncProvider = Provider<void>((ref) {
  ref.listen<List<String>>(
    settingsProvider.select(
      (s) => s.value?.floatingAppShortcuts ?? const <String>[],
    ),
    (prev, next) {
      if (prev != null && listEquals(prev, next)) return;
      final channel = ref.read(appShortcutOverlayChannelProvider);
      unawaited(channel.set(next));
    },
    fireImmediately: true,
  );
});
