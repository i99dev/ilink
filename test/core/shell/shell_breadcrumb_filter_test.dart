import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/kernel/shell/shell_breadcrumb_filter.dart';

void main() {
  group('ShellBreadcrumbFilter', () {
    const filter = ShellBreadcrumbFilter();

    test('does NOT scrub bare command tokens', () {
      expect(
        filter.scrub(['pm', 'list', 'packages', '-3']),
        'pm list packages -3',
      );
      expect(filter.scrub(['dumpsys', 'wifi']), 'dumpsys wifi');
      expect(filter.scrub(['svc', 'wifi', 'enable']), 'svc wifi enable');
    });

    test('scrubs Android package names', () {
      final out = filter.scrub(['pm', 'uninstall', 'com.example.private']);
      expect(out, startsWith('pm uninstall pkg:'));
      expect(out, isNot(contains('com.example')));
    });

    test('hash is stable across calls — same package → same digest', () {
      final a = filter.scrub(['pm', 'enable', 'com.foo.bar']);
      final b = filter.scrub(['pm', 'enable', 'com.foo.bar']);
      expect(a, b);
    });

    test('different packages produce different hashes', () {
      final a = filter.scrub(['pm', 'enable', 'com.foo.bar']);
      final b = filter.scrub(['pm', 'enable', 'com.baz.qux']);
      expect(a, isNot(b));
    });

    test('numeric / flag tokens unchanged', () {
      expect(
        filter.scrub(['pm', 'enable', '--user', '0', 'com.foo.bar']),
        startsWith('pm enable --user 0 pkg:'),
      );
    });

    test('settings system-property keys also scrubbed', () {
      // These dotted tokens encode car-specific identity (e.g.
      // persist.sys.cloud.last_vin); treat as PII-equivalent.
      final out = filter.scrub(['getprop', 'persist.sys.cloud.last_vin']);
      expect(out, startsWith('getprop pkg:'));
      expect(out, isNot(contains('cloud')));
    });
  });
}
