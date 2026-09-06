import 'package:flutter_test/flutter_test.dart';

import 'package:ilink/features/mini_apps/runtime/display_snapshot.dart';
import 'package:ilink/features/mini_apps/runtime/display_visibility.dart';

DisplaySnapshot _d(
  int id, {
  bool isDefault = false,
  bool isCluster = false,
  String? dimReason,
  bool hidden = false,
  String role = 'unknown',
}) => DisplaySnapshot(
  id: id,
  name: 'd$id',
  width: 1920,
  height: 1080,
  densityDpi: 240,
  isDefault: isDefault,
  isPresentation: false,
  isCluster: isCluster,
  role: role,
  dimReason: dimReason,
  hidden: hidden,
);

void main() {
  group('DisplayVisibilityX.isDimmed', () {
    test('false on a plain reachable display (Di5.0 path)', () {
      // L5 / L7 / HAN L never set dimReason or hidden — Di5.0
      // pickers must show every Display the OS reports.
      expect(_d(0).isDimmed, isFalse);
      expect(_d(0, isDefault: true).isDimmed, isFalse);
    });

    test('true when dimReason is set (Di5.1 new contract)', () {
      expect(_d(3, dimReason: 'mirrors Display 5').isDimmed, isTrue);
    });

    test('true when hidden=true even with no dimReason (legacy host)', () {
      // Older host (pre-`dimReason` rollout) only ships the deprecated
      // `hidden` bool. Helper must still treat it as dimmed so the
      // picker doesn't regress when paired with an old daemon.
      expect(_d(3, hidden: true).isDimmed, isTrue);
    });

    test('dimSubtitle echoes dimReason; null on legacy hidden-only', () {
      expect(_d(3, dimReason: 'mirrors 5').dimSubtitle, 'mirrors 5');
      // Legacy host: hidden=true but no dimReason → no subtitle to show.
      expect(_d(3, hidden: true).dimSubtitle, isNull);
      expect(_d(0).dimSubtitle, isNull);
    });
  });

  group('DisplayListVisibilityX.forPicker', () {
    test('Di5.0 reachable set is returned unchanged', () {
      // L7 typical: IVI + passenger, no shadows.
      final input = [_d(0, isDefault: true), _d(2, role: 'passenger')];
      expect(input.forPicker(), input);
    });

    test('Di5.1 dimmed shadow surfaces are dropped from the picker', () {
      // L8 typical: IVI(0), driver cluster(1), passenger(2), shadow(3).
      // Shadow is dropped — operators only see canonical targets.
      final input = [
        _d(0, isDefault: true),
        _d(1, isCluster: true, role: 'cluster'),
        _d(2, role: 'passenger'),
        _d(3, dimReason: 'mirrors Display 5'),
      ];
      final out = input.forPicker();
      expect(out.length, 3, reason: 'shadow must be dropped by default');
      expect(out.map((d) => d.id).toList(), [0, 1, 2]);
    });

    test('multiple dimmed surfaces all dropped; live order preserved', () {
      final input = [
        _d(3, dimReason: 'shadow'),
        _d(0, isDefault: true),
        _d(5, dimReason: 'shadow'),
        _d(1, role: 'passenger'),
      ];
      // Live only (0, 1) in their input order — dimmed gone.
      expect(input.forPicker().map((d) => d.id).toList(), [0, 1]);
    });

    test('excludeDefault drops the IVI; dimmed still dropped', () {
      final input = [
        _d(0, isDefault: true),
        _d(2, role: 'passenger'),
        _d(3, dimReason: 'mirrors 5'),
      ];
      final out = input.forPicker(excludeDefault: true);
      expect(out.map((d) => d.id).toList(), [2]);
    });

    test('includeDimmed=true brings shadows back (debug/calibration)', () {
      // Calibration / debug surfaces that need every Display the OS
      // reports opt in explicitly. Default behaviour drops them.
      final input = [
        _d(0, isDefault: true),
        _d(2, role: 'passenger'),
        _d(3, dimReason: 'mirrors 5'),
      ];
      final out = input.forPicker(includeDimmed: true);
      expect(out.map((d) => d.id).toList(), [0, 2, 3]);
    });

    test('empty input returns empty list', () {
      expect(<DisplaySnapshot>[].forPicker(), isEmpty);
    });

    test('L5 / Di5.0 measured topology — Small Panel dimmed away, '
        'IVI + FSE + Driver Dashboard remain', () {
      // From the 2026-05-16 read-only scan of a Leopard 5 Navigator
      // (car-profiles-out/l5-20260516-1326): IVI(0) + three
      // com.byd.containerservice passenger virtuals (2 FSE, 3 small
      // panel, 4 driver dash). The DI50_BYD_DISHARE profile flags
      // display 3 (Small Panel) as hidden — it's reserved for the
      // cluster cursor overlay (foreign-uid TYPE_APPLICATION_OVERLAY
      // host) and is not a useful cast target on its own. The
      // classifier propagates that as `dimReason` on the wire, and
      // the picker drops it. IVI + FSE + Driver Dashboard remain.
      final l5 = [
        _d(0, isDefault: true, role: 'ivi'),
        _d(2, role: 'passenger'),
        _d(3, role: 'passenger', dimReason: 'cursor-overlay layer'),
        _d(4, role: 'passenger'),
      ];
      expect(l5.forPicker().map((d) => d.id).toList(), [0, 2, 4]);
      // Non-empty with the default dropped → both surfaces offer the
      // remaining secondary targets (the slide panel does not
      // collapse on L5).
      expect(l5.forPicker(excludeDefault: true).map((d) => d.id).toList(), [
        2,
        4,
      ]);
    });

    test('legacy hidden=true display is dropped (parity with dimReason)', () {
      // The deprecated `hidden` bool flows through `isDimmed` and
      // is treated identically to dimReason — both drop the display.
      final input = [
        _d(0, isDefault: true),
        _d(2, role: 'passenger'),
        _d(3, hidden: true),
      ];
      final ids = input.forPicker().map((d) => d.id).toList();
      expect(ids, [0, 2], reason: 'legacy hidden=true is dropped');
    });

    test('returns an unmodifiable list', () {
      final input = [_d(0, isDefault: true)];
      final out = input.forPicker();
      expect(() => out.add(_d(1)), throwsUnsupportedError);
    });
  });

  group('DisplayListVisibilityX.classifierInput', () {
    test('strips dimmed/hidden so auto-seed never labels shadows', () {
      final input = [
        _d(0, isDefault: true),
        _d(2, role: 'passenger'),
        _d(3, dimReason: 'shadow'),
        _d(5, hidden: true),
      ];
      expect(input.classifierInput().map((d) => d.id).toList(), [0, 2]);
    });

    test('returns an unmodifiable list', () {
      final input = [_d(0, isDefault: true)];
      final out = input.classifierInput();
      expect(() => out.add(_d(1)), throwsUnsupportedError);
    });
  });
}
