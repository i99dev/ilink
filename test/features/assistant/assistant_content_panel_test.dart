import 'package:ilink/features/assistant/presentation/widgets/assistant_content_panel.dart';
import 'package:ilink/features/assistant/state/assistant_card.dart';
import 'package:ilink/features/assistant/state/assistant_card_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _harness({AssistantCard? initial}) {
  return ProviderScope(
    overrides: [
      if (initial != null)
        assistantCardProvider.overrideWith(() => _SeededController(initial)),
    ],
    child: const MaterialApp(
      home: Scaffold(body: Center(child: AssistantContentPanel())),
    ),
  );
}

class _SeededController extends AssistantCardController {
  _SeededController(this._seed);
  final AssistantCard _seed;
  @override
  AssistantCard? build() {
    super.build();
    return _seed;
  }
}

void main() {
  testWidgets('null card → nothing substantial rendered', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();
    // The empty-state branch returns SizedBox.shrink — no card frame
    // chrome should appear.
    expect(find.byIcon(Icons.radio_rounded), findsNothing);
    expect(find.byIcon(Icons.battery_charging_full_rounded), findsNothing);
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
  });

  testWidgets('StatusCard renders the populated metrics and skips nulls', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        initial: const StatusCard(
          batteryPct: 77,
          rangeEvKm: 320,
          doorsLocked: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('CAR STATUS'), findsOneWidget);
    expect(find.text('77%'), findsOneWidget);
    expect(find.text('320 km'), findsOneWidget);
    expect(find.text('LOCKED'), findsOneWidget);
    // Cabin / outside temps were null → those metric chips must not
    // render a placeholder.
    expect(find.byIcon(Icons.thermostat_rounded), findsNothing);
    expect(find.byIcon(Icons.air_rounded), findsNothing);
  });

  testWidgets('RadioCard shows station + action', (tester) async {
    await tester.pumpWidget(
      _harness(
        initial: const RadioCard(stationName: 'KISS FM', action: 'playing'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('RADIO'), findsOneWidget);
    expect(find.text('KISS FM'), findsOneWidget);
    expect(find.text('PLAYING'), findsOneWidget);
  });

  testWidgets('ConfirmationCard renders the command icon + label', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        initial: const ConfirmationCard(
          icon: Icons.lock_rounded,
          color: Color(0xFF22D3A8),
          title: 'LOCK',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.lock_rounded), findsOneWidget);
    expect(find.text('LOCK'), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
  });

  testWidgets('ErrorCard highlights the title + detail', (tester) async {
    await tester.pumpWidget(
      _harness(
        initial: const ErrorCard(
          title: "Couldn't lock",
          detail: 'Car is moving',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.text("Couldn't lock"), findsOneWidget);
    expect(find.text('Car is moving'), findsOneWidget);
  });

  testWidgets('tapping the card clears the provider', (tester) async {
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          assistantCardProvider.overrideWith(
            () => _SeededController(
              const ConfirmationCard(
                icon: Icons.lock_rounded,
                color: Color(0xFF22D3A8),
                title: 'LOCK',
              ),
            ),
          ),
        ],
        child: Consumer(
          builder: (context, ref, _) {
            container = ProviderScope.containerOf(context);
            return const MaterialApp(
              home: Scaffold(body: Center(child: AssistantContentPanel())),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(container.read(assistantCardProvider), isNotNull);
    await tester.tap(find.text('LOCK'));
    await tester.pumpAndSettle();
    expect(container.read(assistantCardProvider), isNull);
  });
}
