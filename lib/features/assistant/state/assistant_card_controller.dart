import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'assistant_card.dart';

/// Single slot for "what visual card is on screen right now". Notifier
/// rather than a StreamProvider because the card transitions are always
/// triggered by imperative events (tool result, ResponseDone,
/// user tap) — there's no stream to subscribe to.
///
/// The 8 s auto-dismiss covers the case where the model produces a tool
/// call but the session ends (disconnect, interruption) before
/// ResponseDone fires. Without the timer, a disconnect mid-response
/// would leave a card stuck on screen.
class AssistantCardController extends Notifier<AssistantCard?> {
  Timer? _timeout;

  /// Pick something generous enough that the driver can glance + read,
  /// but short enough that the card doesn't outlast the assistant's
  /// audio reply on most turns. 8 s lands roughly at the tail of a
  /// typical spoken response.
  static const Duration autoDismiss = Duration(seconds: 8);

  @override
  AssistantCard? build() {
    ref.onDispose(() {
      _timeout?.cancel();
      _timeout = null;
    });
    return null;
  }

  /// Replace the current card (if any) with [card] and restart the
  /// auto-dismiss timer. Calling [show] consecutively is a real flow —
  /// the model sometimes fires two tool calls in one turn.
  void show(AssistantCard card) {
    _timeout?.cancel();
    state = card;
    _timeout = Timer(autoDismiss, clear);
  }

  /// Hide the current card. Safe to call when nothing is shown — a
  /// no-op in that case, plus it cancels any running timer so we don't
  /// leak ticks past the notifier's lifetime.
  void clear() {
    _timeout?.cancel();
    _timeout = null;
    state = null;
  }
}

final assistantCardProvider =
    NotifierProvider<AssistantCardController, AssistantCard?>(
      AssistantCardController.new,
    );
