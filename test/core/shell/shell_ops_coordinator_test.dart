import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/kernel/shell/shell_command.dart';
import 'package:ilink/kernel/shell/shell_ops_coordinator.dart';

void main() {
  group('ShellOpsCoordinator', () {
    test('caches reads within ttl', () async {
      var calls = 0;
      final coord = ShellOpsCoordinator(
        exec: (_) async {
          calls += 1;
          return 'value-$calls';
        },
        readTtl: const Duration(seconds: 5),
      );
      const cmd = ShellCommand(['dumpsys', 'wifi'], cacheKey: 'k');
      expect(await coord.read(cmd), 'value-1');
      expect(await coord.read(cmd), 'value-1');
      expect(calls, 1);
    });

    test('dedupes in-flight reads with same cacheKey', () async {
      var calls = 0;
      final completer = Completer<String>();
      final coord = ShellOpsCoordinator(
        exec: (_) async {
          calls += 1;
          return completer.future;
        },
      );
      const cmd = ShellCommand(['x'], cacheKey: 'k');
      final f1 = coord.read(cmd);
      final f2 = coord.read(cmd);
      // Both Futures are alive; only one underlying exec.
      expect(calls, 1);
      completer.complete('done');
      expect(await f1, 'done');
      expect(await f2, 'done');
      expect(calls, 1);
    });

    test('coalesces same-key writes within window', () async {
      var calls = 0;
      final coord = ShellOpsCoordinator(
        exec: (_) async {
          calls += 1;
          return 'ok';
        },
        coalesceWindow: const Duration(seconds: 1),
      );
      const cmd = ShellCommand(['svc', 'wifi', 'enable']);
      // Two rapid writes with same coalesceKey share one exec.
      final fA = coord.write(cmd, coalesceKey: 'wifi');
      final fB = coord.write(cmd, coalesceKey: 'wifi');
      await fA;
      await fB;
      expect(calls, 1);
    });

    test('write invalidates cache so next read re-fetches', () async {
      var calls = 0;
      final coord = ShellOpsCoordinator(
        exec: (cmd) async {
          calls += 1;
          if (cmd.argv.first == 'svc') return 'wrote';
          return 'read-$calls';
        },
      );
      const readCmd = ShellCommand([
        'dumpsys',
        'wifi',
      ], cacheKey: 'dumpsys wifi');
      const writeCmd = ShellCommand(['svc', 'wifi', 'enable']);
      await coord.read(readCmd); // calls=1, cached
      await coord.read(readCmd); // cache hit, still calls=1
      await coord.write(writeCmd, invalidates: {'dumpsys wifi'}); // calls=2
      await coord.read(readCmd); // cache miss → exec, calls=3
      expect(calls, 3);
    });

    test('cancellation propagates as CancelException', () async {
      final coord = ShellOpsCoordinator(
        exec: (_) async {
          await Future.delayed(const Duration(milliseconds: 50));
          return 'late';
        },
      );
      final tok = CancelToken(reason: 'user dismissed');
      final fut = coord.read(const ShellCommand(['x']), cancel: tok);
      tok.cancel();
      await expectLater(fut, throwsA(isA<CancelException>()));
    });
  });

  group('CancelToken', () {
    test('whenCancelled fires synchronously when already cancelled', () {
      final tok = CancelToken()..cancel();
      var fired = false;
      tok.whenCancelled(() => fired = true);
      expect(fired, isTrue);
    });

    test('whenCancelled fires once on later cancel', () {
      final tok = CancelToken();
      var fired = 0;
      tok.whenCancelled(() => fired += 1);
      tok.cancel();
      tok.cancel(); // second cancel is no-op
      expect(fired, 1);
    });
  });
}
