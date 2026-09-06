/// Tiny convenience extensions on `ScaffoldMessengerState` so call
/// sites that snackbar a one-line message after an async action don't
/// repeat the `.showSnackBar(SnackBar(content: Text(...)))` boilerplate.
///
/// **Pattern this enables:**
///
/// ```dart
/// final messenger = ScaffoldMessenger.maybeOf(context);
/// final result = await someAsyncAction();
/// if (!context.mounted) return;
/// messenger?.showText('Result: $result');
/// ```
///
/// The extension is on the **non-nullable** [ScaffoldMessengerState]
/// (Dart's `strict-casts` mode rejects extension calls on nullable
/// receivers), so call sites use the `?.` operator. That's the same
/// shape Dart uses for any null-safe member call — fits the rest of
/// the codebase's idiom.
///
/// Use the variant that fits your need:
///   * [showText] — single-line snackbar, default duration.
///   * [showTextWithDuration] — same but with explicit duration (used
///     when the message needs to linger longer than the default 4 s).
library;

import 'package:flutter/material.dart';

extension SnackBarMessenger on ScaffoldMessengerState {
  /// Shorthand for `showSnackBar(SnackBar(content: Text(text)))`.
  /// Pair with the `?.` operator at the call site to keep the
  /// no-Scaffold case safe.
  void showText(String text) {
    showSnackBar(SnackBar(content: Text(text)));
  }

  /// Same as [showText] with a custom duration. Use sparingly — the
  /// Material default (4 s) is right for most one-line confirmations;
  /// longer durations interrupt the user's flow.
  void showTextWithDuration(String text, Duration duration) {
    showSnackBar(SnackBar(content: Text(text), duration: duration));
  }
}
