import 'package:ilink/features/assistant/state/assistant_card.dart';
import 'package:ilink/features/assistant/state/assistant_card_controller.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

ConfirmationCard _card([String title = 'LOCK']) => ConfirmationCard(
  icon: Icons.lock_rounded,
  color: const Color(0xFF22D3A8),
  title: title,
);

void main() {
  group('AssistantCardController', () {
    test('initial state is null', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(assistantCardProvider), isNull);
    });

    test('show() sets state, clear() resets to null', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(assistantCardProvider.notifier).show(_card());
      expect(c.read(assistantCardProvider), isA<ConfirmationCard>());
      c.read(assistantCardProvider.notifier).clear();
      expect(c.read(assistantCardProvider), isNull);
    });

    test('auto-dismiss timer clears the card after autoDismiss elapses', () {
      fakeAsync((async) {
        final c = ProviderContainer();
        addTearDown(c.dispose);
        c.read(assistantCardProvider.notifier).show(_card());
        expect(c.read(assistantCardProvider), isNotNull);
        async.elapse(
          AssistantCardController.autoDismiss - const Duration(seconds: 1),
        );
        expect(
          c.read(assistantCardProvider),
          isNotNull,
          reason: 'card should still be live before the dismiss deadline',
        );
        async.elapse(const Duration(seconds: 2));
        expect(
          c.read(assistantCardProvider),
          isNull,
          reason: 'card should auto-clear after autoDismiss elapsed',
        );
      });
    });

    test('show() twice in a row restarts the timer instead of dismissing', () {
      fakeAsync((async) {
        final c = ProviderContainer();
        addTearDown(c.dispose);
        final notifier = c.read(assistantCardProvider.notifier);
        notifier.show(_card('FIRST'));
        async.elapse(const Duration(seconds: 6));
        // 2 s remain on first timer; replace with a new card.
        notifier.show(_card('SECOND'));
        async.elapse(const Duration(seconds: 3));
        expect(
          (c.read(assistantCardProvider)! as ConfirmationCard).title,
          'SECOND',
          reason:
              'second card still alive — original timer must have been '
              'cancelled; otherwise it would have cleared at t≈8s',
        );
        // And the second card's timer fires on its own schedule.
        async.elapse(const Duration(seconds: 6));
        expect(c.read(assistantCardProvider), isNull);
      });
    });

    test('explicit clear() cancels the pending auto-dismiss timer', () {
      fakeAsync((async) {
        final c = ProviderContainer();
        addTearDown(c.dispose);
        final notifier = c.read(assistantCardProvider.notifier);
        notifier.show(_card());
        async.elapse(const Duration(seconds: 2));
        notifier.clear();
        // Advancing past the original deadline must not resurrect the card
        // or cause a second state change (which would be a leaked timer).
        async.elapse(const Duration(seconds: 30));
        expect(c.read(assistantCardProvider), isNull);
      });
    });
  });
}
