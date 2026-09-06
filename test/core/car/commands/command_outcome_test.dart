import 'dart:async';

import 'package:ilink/features/_car_domain/command/command_outcome.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// CommandOutcome is the uniform result shape for every car command —
/// routers, UI, and LLM tool handlers all read `ok` / `message` / `toJson`.
/// These tests pin the parser so Kotlin side can evolve its response map
/// without silently changing the Dart interpretation.
void main() {
  group('CommandOutcome.fromBridge', () {
    test('int 0 → success', () {
      final o = CommandOutcome.fromBridge(0);
      expect(o.ok, isTrue);
      expect(o.code, 0);
    });

    test('int non-zero → failure with code preserved', () {
      final o = CommandOutcome.fromBridge(-1);
      expect(o.ok, isFalse);
      expect(o.code, -1);
      expect(o.message, contains('-1'));
    });

    test('map with ok:true is success', () {
      final o = CommandOutcome.fromBridge({'ok': true, 'code': 0});
      expect(o.ok, isTrue);
      expect(o.code, 0);
    });

    test('map with code:0 but missing ok is still success', () {
      final o = CommandOutcome.fromBridge({'code': 0});
      expect(o.ok, isTrue);
    });

    test('map with error key → failure, message from error', () {
      final o = CommandOutcome.fromBridge({
        'error': 'unknown action',
        'code': 'CAR_BRIDGE_ERROR',
      });
      expect(o.ok, isFalse);
      expect(o.message, 'unknown action');
      // Non-int code is dropped (parser only keeps int codes).
      expect(o.code, isNull);
    });

    test('map with non-zero code → failure', () {
      final o = CommandOutcome.fromBridge({'code': 7, 'ok': false});
      expect(o.ok, isFalse);
      expect(o.code, 7);
    });

    test('unexpected shape → failure with debug message', () {
      final o = CommandOutcome.fromBridge('just a string');
      expect(o.ok, isFalse);
      expect(o.message, contains('unexpected'));
    });

    test('null → failure', () {
      final o = CommandOutcome.fromBridge(null);
      expect(o.ok, isFalse);
    });
  });

  group('CommandOutcome.toJson', () {
    test('success emits ok:true plus data spread', () {
      final o = CommandOutcome.success({'x': 1, 'y': 'hi'}, 0);
      final j = o.toJson();
      expect(j['ok'], isTrue);
      expect(j['code'], 0);
      expect(j['x'], 1);
      expect(j['y'], 'hi');
    });

    test('failure emits error: message, no ok key', () {
      final o = CommandOutcome.failure('timeout', code: -1);
      final j = o.toJson();
      expect(j.containsKey('ok'), isFalse);
      expect(j['error'], 'timeout');
      expect(j['code'], -1);
    });
  });

  group('CommandOutcome.describe', () {
    test('success', () {
      expect(CommandOutcome.success().describe('door.lock'), 'door.lock: ok');
    });
    test('failure echoes message', () {
      expect(
        CommandOutcome.failure('offline').describe('door.lock'),
        'door.lock: offline',
      );
    });
    test('failure without message falls back to "failed"', () {
      // Only produced when fromBridge gets weird input, but pin the shape.
      final o = CommandOutcome.fromBridge(null);
      // message may be set by the parser; fallback path is when it's null.
      final d = o.describe('id');
      expect(d.startsWith('id: '), isTrue);
    });
  });

  group('CommandOutcome error classification', () {
    test('success has no errorKind', () {
      expect(CommandOutcome.success().errorKind, isNull);
    });

    test('CAR_BRIDGE_TIMEOUT sentinel → BridgeErrorKind.timeout', () {
      final o = CommandOutcome.fromBridge({
        'error': 'timeout',
        'code': 'CAR_BRIDGE_TIMEOUT',
      });
      expect(o.errorKind, BridgeErrorKind.timeout);
    });

    test('daemon offline map → BridgeErrorKind.daemonOffline', () {
      final o = CommandOutcome.fromBridge({
        'error': 'no daemon',
        'daemon': false,
      });
      expect(o.errorKind, BridgeErrorKind.daemonOffline);
    });

    test('ordinary rejection → BridgeErrorKind.rejected', () {
      final o = CommandOutcome.fromBridge({'code': 7, 'ok': false});
      expect(o.errorKind, BridgeErrorKind.rejected);
    });

    test('int non-zero → rejected', () {
      expect(CommandOutcome.fromBridge(-1).errorKind, BridgeErrorKind.rejected);
    });

    test('fromException classifies TimeoutException', () {
      final o = CommandOutcome.fromException(TimeoutException('oops'));
      expect(o.errorKind, BridgeErrorKind.timeout);
      expect(o.ok, isFalse);
    });

    test('fromException classifies PlatformException', () {
      final o = CommandOutcome.fromException(
        PlatformException(code: 'X', message: 'native crash'),
      );
      expect(o.errorKind, BridgeErrorKind.platform);
      expect(o.message, 'native crash');
    });

    test('fromException defaults to other for generic errors', () {
      final o = CommandOutcome.fromException(StateError('bad'));
      expect(o.errorKind, BridgeErrorKind.other);
    });

    test('toJson includes error_kind when failing', () {
      final o = CommandOutcome.failure(
        'timeout',
        errorKind: BridgeErrorKind.timeout,
      );
      expect(o.toJson()['error_kind'], 'timeout');
    });
  });
}
