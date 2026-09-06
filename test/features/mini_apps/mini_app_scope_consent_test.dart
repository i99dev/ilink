import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/mini_apps/presentation/mini_app_install_consent.dart';

void main() {
  testWidgets(
    'consent selects only declared supported scopes, extras stay off',
    (tester) async {
      Set<String>? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showMiniAppScopeConsent(
                    context,
                    name: 'Test',
                    requested: ['car.read', '_admin.exec'],
                    network: [],
                  );
                },
                child: const Text('Review'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      final boxes = tester
          .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
          .toList();
      expect(boxes.where((box) => box.value == true), hasLength(1));
      expect(find.textContaining('Unsupported requests'), findsOneWidget);
      await tester.tap(find.text('Allow selected'));
      await tester.pumpAndSettle();
      expect(result, {'car.read'});
    },
  );

  testWidgets('owner can revoke every previous permission', (tester) async {
    Set<String>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showMiniAppScopeConsent(
                  context,
                  name: 'Test',
                  requested: ['car.read'],
                  network: [],
                  initialScopes: {'car.read'},
                );
              },
              child: const Text('Review'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Read vehicle signals and identity'));
    await tester.pump();
    await tester.tap(find.text('Allow selected'));
    await tester.pumpAndSettle();
    expect(result, isEmpty);
  });
}
