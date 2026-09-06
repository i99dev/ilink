import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/apps/app_launch_catalog.dart';

void main() {
  group('resolveAppSpec', () {
    test(
      'matches by alias, key, and display name (case/space-insensitive)',
      () {
        expect(resolveAppSpec('YouTube')?.key, 'youtube');
        expect(resolveAppSpec('you tube')?.key, 'youtube');
        expect(resolveAppSpec('  SPOTIFY ')?.key, 'spotify');
        expect(resolveAppSpec('Google Maps')?.key, 'maps');
        expect(resolveAppSpec('navigate')?.key, 'maps');
        expect(resolveAppSpec('waze')?.key, 'waze');
      },
    );

    test('loose containment still resolves ("open the youtube app")', () {
      expect(resolveAppSpec('the youtube app')?.key, 'youtube');
    });

    test(
      'Yandex Maps resolves (incl. Cyrillic); "yandex" defaults to Maps',
      () {
        expect(resolveAppSpec('Yandex Maps')?.package, 'ru.yandex.yandexmaps');
        expect(resolveAppSpec('яндекс карты')?.package, 'ru.yandex.yandexmaps');
        expect(resolveAppSpec('yandex')?.package, 'ru.yandex.yandexmaps');
        expect(
          resolveAppSpec('yandex navigator')?.package,
          'ru.yandex.yandexnavi',
        );
      },
    );

    test('unknown app → null', () {
      expect(resolveAppSpec('teleport'), isNull);
      expect(resolveAppSpec(''), isNull);
    });
  });

  group('matchPackageByName', () {
    const packages = [
      'com.android.settings',
      'com.whatsapp',
      'com.google.android.youtube',
      'com.spotify.music',
    ];

    test('exact last-segment match wins', () {
      expect(matchPackageByName(packages, 'whatsapp'), 'com.whatsapp');
      expect(matchPackageByName(packages, 'settings'), 'com.android.settings');
    });

    test('containment match when no exact segment', () {
      expect(matchPackageByName(packages, 'spotify'), 'com.spotify.music');
    });

    test('de-spaces the spoken name', () {
      expect(matchPackageByName(packages, 'what s app'), 'com.whatsapp');
    });

    test('no plausible match → null', () {
      expect(matchPackageByName(packages, 'teleporter'), isNull);
      expect(matchPackageByName(packages, ''), isNull);
    });
  });

  group('argv builders', () {
    test('viewIntentArgv appends the package as the trailing intent token', () {
      expect(
        viewIntentArgv('spotify:search:jazz', package: 'com.spotify.music'),
        [
          'am',
          'start',
          '-a',
          'android.intent.action.VIEW',
          '-d',
          'spotify:search:jazz',
          'com.spotify.music',
        ],
      );
    });

    test('viewIntentArgv omits the trailing token when no package', () {
      final argv = viewIntentArgv('geo:0,0?q=home');
      expect(argv.last, 'geo:0,0?q=home');
      expect(argv.length, 6);
    });

    test('launcherArgv targets the LAUNCHER category via monkey', () {
      expect(launcherArgv('com.whatsapp'), [
        'monkey',
        '-p',
        'com.whatsapp',
        '-c',
        'android.intent.category.LAUNCHER',
        '1',
      ]);
    });

    test('fillUri URL-encodes the query into {q}', () {
      expect(
        fillUri('spotify:search:{q}', 'lo fi beats'),
        'spotify:search:lo%20fi%20beats',
      );
      expect(
        fillUri(
          'https://www.youtube.com/results?search_query={q}',
          'jazz & blues',
        ),
        'https://www.youtube.com/results?search_query=jazz%20%26%20blues',
      );
    });
  });
}
