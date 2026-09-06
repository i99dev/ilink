import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/_car_domain/command/command.dart';
import 'package:ilink/features/_car_domain/command/registry.dart';
import 'package:ilink/features/_car_domain/command/workflow_catalog.dart';
import 'package:ilink/features/_car_domain/safety/rate_limiter.dart';

/// Unit tests for [workflowActionEntries] — the pure serializer behind
/// the `workflow.catalog` bridge handler. Mirrors the SDK wire shape in
/// ilink-sdk `types/workflow.ts` (`WorkflowActionEntrySchema`).
void main() {
  final entries = workflowActionEntries(commandRegistry);
  Map<String, Object?> byId(String id) => entries.firstWhere(
    (e) => e['id'] == id,
    orElse: () => <String, Object?>{},
  );

  group('workflowActionEntries', () {
    test('emits a non-empty, id-sorted palette', () {
      expect(entries, isNotEmpty);
      final ids = entries.map((e) => e['id'] as String).toList();
      final sorted = [...ids]..sort();
      expect(ids, sorted);
    });

    test(
      'excludes status + raw categories (reads / internal, not actions)',
      () {
        for (final e in entries) {
          expect(e['category'], isNot('status'));
          expect(e['category'], isNot('raw'));
        }
        // car.status is the canonical status read and must not appear.
        expect(byId('car.status'), isEmpty);
      },
    );

    test('every entry carries the required safety flags', () {
      for (final e in entries) {
        expect(e['requiresStationary'], isA<bool>(), reason: e['id'] as String);
        expect(e['reversible'], isA<bool>(), reason: e['id'] as String);
        expect(
          SecurityClass.values.map((s) => s.name),
          contains(e['securityClass']),
        );
        // rateClass key is always present (nullable).
        expect(e.containsKey('rateClass'), isTrue, reason: e['id'] as String);
      }
    });

    test('door.unlock serializes as security + stationary', () {
      final e = byId('door.unlock');
      expect(e['securityClass'], 'security');
      expect(e['requiresStationary'], true);
      expect(e['reversible'], false);
    });

    test('rateClass maps to the SDK wire form', () {
      expect(rateClassWire(RateClass.actuator), 'actuator');
      expect(rateClassWire(RateClass.statusRead), 'status_read');
      expect(rateClassWire(null), isNull);
      // hood.open declares RateClass.actuator.
      expect(byId('hood.open')['rateClass'], 'actuator');
    });

    test('grouped commands surface their voiceGroup for canvas collapsing', () {
      final win = byId('window.fl.close');
      expect(win['securityClass'], 'safety');
      expect(win['voiceGroup'], 'window_control');
      expect(win['voiceGroupParams'], isA<Map<String, Object?>>());
    });
  });
}
