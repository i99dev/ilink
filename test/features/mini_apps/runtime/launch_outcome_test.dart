import 'package:flutter_test/flutter_test.dart';

import 'package:ilink/features/mini_apps/runtime/launch_outcome.dart';

void main() {
  group('classifyLaunchKind — ok is authoritative', () {
    test('ok:true clean paths → success', () {
      for (final p in <String?>[
        null,
        '',
        'intent-launch',
        'am-start',
        'move-task',
        'move-task-front',
        'dishare-quickshare',
        'dishare-quickshare-cached',
      ]) {
        expect(
          classifyLaunchKind(ok: true, path: p),
          LaunchOutcomeKind.success,
          reason: 'ok:true path=$p must be success',
        );
      }
    });

    test('ok:true + am-start-rePinned → recovered (surfaced bounce)', () {
      expect(
        classifyLaunchKind(ok: true, path: 'am-start-rePinned'),
        LaunchOutcomeKind.recovered,
      );
    });

    test('REGRESSION: L5 ok:false + dishare-denied → failure (was a green '
        '"Opened on …")', () {
      expect(
        classifyLaunchKind(ok: false, path: 'dishare-denied'),
        LaunchOutcomeKind.failure,
      );
    });

    test('ok:false is failure regardless of path string', () {
      for (final p in <String?>[
        null,
        '',
        'denied',
        'dishare-denied',
        'am-start-bounced',
        'some-unknown-future-path',
      ]) {
        expect(
          classifyLaunchKind(ok: false, path: p),
          LaunchOutcomeKind.failure,
          reason: 'ok:false path=$p must be failure',
        );
      }
    });

    test('wmsTransient wins → warning even when ok:false', () {
      expect(
        classifyLaunchKind(
          ok: false,
          path: 'wms_transient',
          wmsTransient: true,
        ),
        LaunchOutcomeKind.warning,
      );
    });
  });

  group('LaunchOutcomeKindX', () {
    test('.ok only for success/recovered', () {
      expect(LaunchOutcomeKind.success.ok, isTrue);
      expect(LaunchOutcomeKind.recovered.ok, isTrue);
      expect(LaunchOutcomeKind.warning.ok, isFalse);
      expect(LaunchOutcomeKind.failure.ok, isFalse);
    });

    test('.isFailure only for failure', () {
      expect(LaunchOutcomeKind.failure.isFailure, isTrue);
      expect(LaunchOutcomeKind.success.isFailure, isFalse);
      expect(LaunchOutcomeKind.recovered.isFailure, isFalse);
      expect(LaunchOutcomeKind.warning.isFailure, isFalse);
    });
  });

  group('launchKindFromExecData — slide-panel AdminExecOk envelope', () {
    test('REGRESSION: {ok:false, path:dishare-denied} → failure (the slide '
        'panel used to ignore ok)', () {
      expect(
        launchKindFromExecData(<String, Object?>{
          'ok': false,
          'path': 'dishare-denied',
        }),
        LaunchOutcomeKind.failure,
      );
    });

    test('{ok:true, path:dishare-quickshare} → success', () {
      expect(
        launchKindFromExecData(<String, Object?>{
          'ok': true,
          'path': 'dishare-quickshare',
        }),
        LaunchOutcomeKind.success,
      );
    });

    test('no ok key (surface-family success envelope) → success — a real '
        'surface failure throws and becomes AdminExecError before here', () {
      expect(
        launchKindFromExecData(<String, Object?>{
          'surfaceId': 'sfc_abc',
          'path': 'overlay',
          'displayId': 2,
          'route': '/',
        }),
        LaunchOutcomeKind.success,
      );
    });

    test('{ok:false} with no path → failure', () {
      expect(
        launchKindFromExecData(<String, Object?>{'ok': false}),
        LaunchOutcomeKind.failure,
      );
    });

    test('present-but-non-bool ok is treated as not-ok → failure', () {
      expect(
        launchKindFromExecData(<String, Object?>{'ok': 'nope'}),
        LaunchOutcomeKind.failure,
      );
    });
  });

  group('launchKindFromExecData == classifyLaunchKind (anti-drift)', () {
    // The whole point of the shared decoder: the slide panel and the
    // home picker must reach the SAME verdict for the same host data.
    for (final ok in <bool>[true, false]) {
      for (final p in <String?>[
        null,
        'intent-launch',
        'am-start-rePinned',
        'am-start-bounced',
        'dishare-quickshare',
        'dishare-denied',
      ]) {
        test('ok=$ok path=$p agree across both entry points', () {
          final viaPicker = classifyLaunchKind(ok: ok, path: p);
          final viaSheet = launchKindFromExecData(<String, Object?>{
            'ok': ok,
            'path': ?p,
          });
          expect(viaSheet, viaPicker);
        });
      }
    }
  });

  group('launchOutcomeMessage — honest, label-aware', () {
    test('success / recovered / warning', () {
      expect(
        launchOutcomeMessage(LaunchOutcomeKind.success, label: 'Passenger'),
        'Opened on Passenger',
      );
      expect(
        launchOutcomeMessage(LaunchOutcomeKind.recovered, label: 'Cluster'),
        'Opened on Cluster (recovered after bounce)',
      );
      expect(
        launchOutcomeMessage(LaunchOutcomeKind.warning, label: 'Cluster'),
        contains('tap to retry'),
      );
    });

    test('L5 DiShare refusal → honest "this car refused" + fallback hint', () {
      final m = launchOutcomeMessage(
        LaunchOutcomeKind.failure,
        label: 'Driver Dashboard',
        path: 'dishare-denied',
      );
      expect(m, contains('Driver Dashboard'));
      expect(m, contains('refused'));
      expect(m, contains('Open here instead'));
      expect(m, isNot(contains('Opened on')));
    });

    test(
      'DiShare typed error string (path generic) still reads as refusal',
      () {
        final m = launchOutcomeMessage(
          LaunchOutcomeKind.failure,
          label: 'Small Panel',
          path: 'denied',
          error: 'quick_share_failed',
        );
        expect(m, contains('refused'));
      },
    );

    test('bounce-failed → "fell back to the IVI"', () {
      final m = launchOutcomeMessage(
        LaunchOutcomeKind.failure,
        label: 'Cluster',
        path: 'am-start-bounced',
      );
      expect(m, contains('fell back to the IVI'));
    });

    test('generic failure echoes the host error when present', () {
      final m = launchOutcomeMessage(
        LaunchOutcomeKind.failure,
        label: 'Passenger',
        path: '',
        error: 'no launcher activity',
      );
      expect(m, contains("Couldn't open on Passenger"));
      expect(m, contains('no launcher activity'));
    });

    test('generic failure with no error is still not a success string', () {
      final m = launchOutcomeMessage(
        LaunchOutcomeKind.failure,
        label: 'Passenger',
      );
      expect(m, isNot(contains('Opened on')));
      expect(m, contains("Couldn't open on Passenger"));
    });
  });
}
