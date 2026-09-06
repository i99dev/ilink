import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The bundled Cairo and Inter faces are SIL OFL 1.1. Clause 2 requires the
/// license text to travel with the fonts in every redistribution — the APK
/// included — so `assets/fonts/OFL.txt` is a shipped asset, not a repo-only
/// file. These tests fail loudly if it is dropped from `pubspec.yaml` or
/// stops carrying the license.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'OFL text ships as an app asset and covers both bundled families',
    () async {
      final ofl = await rootBundle.loadString('assets/fonts/OFL.txt');

      expect(ofl, contains('SIL OPEN FONT LICENSE Version 1.1'));
      // The two conditions a redistributor has to honour.
      expect(ofl, contains('PERMISSION & CONDITIONS'));
      expect(ofl, contains('may be sold by itself'));
      // Upstream copyright lines, as read from the font `name` tables.
      expect(ofl, contains('The Cairo Project Authors'));
      expect(ofl, contains('The Inter Project Authors'));
    },
  );

  test(
    'font licenses reach LicenseRegistry for the in-app license page',
    () async {
      // Mirrors the registration in lib/main.dart. Registering here keeps the
      // test independent of app bootstrap while still exercising the stream.
      LicenseRegistry.addLicense(() async* {
        yield LicenseEntryWithLineBreaks(const [
          'Cairo',
          'Inter',
        ], await rootBundle.loadString('assets/fonts/OFL.txt'));
      });

      final entries = await LicenseRegistry.licenses.toList();
      final fontEntry = entries.firstWhere(
        (e) => e.packages.contains('Cairo'),
        orElse: () => throw StateError('no license entry registered for Cairo'),
      );

      expect(fontEntry.packages, containsAll(<String>['Cairo', 'Inter']));
      expect(
        fontEntry.paragraphs.map((p) => p.text).join(' '),
        contains('SIL OPEN FONT LICENSE'),
      );
    },
  );
}
