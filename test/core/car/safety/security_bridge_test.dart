import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:ilink/features/_car_domain/safety/security_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// `_canonicalise` and `_sha256` are private, but we can verify their
/// behaviour end-to-end by capturing the payload the channel actually
/// receives. If the canonicalisation is stable, identical-content-but-
/// different-iteration-order maps must produce identical hashes.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ilink/security');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final captured = <MethodCall>[];

  setUp(() {
    captured.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      captured.add(call);
      switch (call.method) {
        case 'integrityHealthy':
          return true;
        default:
          return true;
      }
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('SecurityBridge.logDispatch', () {
    test('hashes commandId as sha256 hex of the UTF-8 bytes', () async {
      await const SecurityBridge().logDispatch(
        commandId: 'door.lock',
        args: const {},
        outcome: 'ok',
        latency: const Duration(milliseconds: 5),
      );
      expect(captured, hasLength(1));
      final sentCmd = captured.single.arguments['cmd'] as String;
      final expected = sha256.convert(utf8.encode('door.lock')).toString();
      expect(sentCmd, expected);
    });

    test('canonicalises args — map order does not change the hash', () async {
      await const SecurityBridge().logDispatch(
        commandId: 'x',
        args: const {'b': 2, 'a': 1, 'c': 3},
        outcome: 'ok',
        latency: Duration.zero,
      );
      await const SecurityBridge().logDispatch(
        commandId: 'x',
        args: const {'c': 3, 'a': 1, 'b': 2},
        outcome: 'ok',
        latency: Duration.zero,
      );
      expect(captured[0].arguments['args'], captured[1].arguments['args']);
    });

    test('canonicalises nested maps recursively', () async {
      await const SecurityBridge().logDispatch(
        commandId: 'x',
        args: const {
          'outer': {'y': 2, 'x': 1},
          'leaf': 'v',
        },
        outcome: 'ok',
        latency: Duration.zero,
      );
      await const SecurityBridge().logDispatch(
        commandId: 'x',
        args: const {
          'leaf': 'v',
          'outer': {'x': 1, 'y': 2},
        },
        outcome: 'ok',
        latency: Duration.zero,
      );
      expect(captured[0].arguments['args'], captured[1].arguments['args']);
    });

    test('distinct args produce distinct hashes', () async {
      await const SecurityBridge().logDispatch(
        commandId: 'x',
        args: const {'v': 1},
        outcome: 'ok',
        latency: Duration.zero,
      );
      await const SecurityBridge().logDispatch(
        commandId: 'x',
        args: const {'v': 2},
        outcome: 'ok',
        latency: Duration.zero,
      );
      expect(
        captured[0].arguments['args'],
        isNot(captured[1].arguments['args']),
      );
    });

    test('passes outcome + latency through without modification', () async {
      await const SecurityBridge().logDispatch(
        commandId: 'x',
        args: const {},
        outcome: 'RATE_LIMITED',
        latency: const Duration(milliseconds: 1234),
      );
      expect(captured.single.arguments['outcome'], 'RATE_LIMITED');
      expect(captured.single.arguments['latency_ms'], 1234);
    });
  });

  group('SecurityBridge.integrityHealthy', () {
    test('returns channel value when plugin present', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        return false;
      });
      expect(await const SecurityBridge().integrityHealthy(), isFalse);
    });

    test(
      'fails open on MissingPluginException (no plugin registered)',
      () async {
        // Clear the mock so the channel has no handler — this is what tests
        // and mock runs actually experience.
        messenger.setMockMethodCallHandler(channel, null);
        expect(await const SecurityBridge().integrityHealthy(), isTrue);
      },
    );
  });
}
