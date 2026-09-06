import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/dashboard/dashboard.dart';

void main() {
  group('DashboardPageController', () {
    test('starts at page 0', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(dashboardPageControllerProvider), 0);
    });

    test('set(N) updates state', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(dashboardPageControllerProvider.notifier).set(1);
      expect(container.read(dashboardPageControllerProvider), 1);
    });

    test('set(N) is idempotent — equal value does not trigger rebuild', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      var rebuilds = 0;
      container.listen<int>(
        dashboardPageControllerProvider,
        (_, _) => rebuilds++,
      );
      container.read(dashboardPageControllerProvider.notifier).set(0);
      container.read(dashboardPageControllerProvider.notifier).set(0);
      expect(rebuilds, 0, reason: 'set(equal) should not notify listeners');
    });

    test('set(negative) is rejected', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(dashboardPageControllerProvider.notifier).set(2);
      container.read(dashboardPageControllerProvider.notifier).set(-1);
      expect(
        container.read(dashboardPageControllerProvider),
        2,
        reason: 'negative index ignored',
      );
    });
  });
}
