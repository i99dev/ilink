import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/app/lifecycle/session_bootstrap.dart';

void main() {
  group('SessionBootstrap.run', () {
    test('runs every step in registration order', () async {
      final order = <String>[];
      final boot = SessionBootstrap([
        (id: 'a', required: false, run: () async => order.add('a')),
        (id: 'b', required: false, run: () async => order.add('b')),
        (id: 'c', required: false, run: () async => order.add('c')),
      ]);

      final report = await boot.run();

      expect(order, ['a', 'b', 'c']);
      expect(report.allOk, isTrue);
      expect(report.failed, isEmpty);
      expect(report.outcomes.keys, ['a', 'b', 'c']);
    });

    test('a failing step is fail-open — later steps still run', () async {
      final ran = <String>[];
      final boot = SessionBootstrap([
        (id: 'tables', required: false, run: () async => ran.add('tables')),
        (
          id: 'catalog',
          required: false,
          run: () async => throw StateError('catalog down'),
        ),
        (id: 'themes', required: false, run: () async => ran.add('themes')),
      ]);

      final report = await boot.run();

      // The throw in the middle step did not abort the run.
      expect(ran, ['tables', 'themes']);
      expect(report.allOk, isFalse);
      expect(report.failed, ['catalog']);
      expect(report.outcomes['tables'], isNull);
      expect(report.outcomes['themes'], isNull);
      expect(report.outcomes['catalog'], isA<StateError>());
    });

    test('all steps failing still completes (never throws)', () async {
      final boot = SessionBootstrap([
        (id: 'x', required: false, run: () async => throw Exception('x')),
        (id: 'y', required: false, run: () async => throw Exception('y')),
      ]);

      final report = await boot.run();

      expect(report.allOk, isFalse);
      expect(report.failed, ['x', 'y']);
    });

    test('empty step list is a no-op success', () async {
      final report = await SessionBootstrap(const []).run();
      expect(report.allOk, isTrue);
      expect(report.outcomes, isEmpty);
    });
  });
}
