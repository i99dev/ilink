import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ilink/kernel/shell/shell_command.dart';
import 'package:ilink/kernel/shell/shell_tool_bridge.dart';
import 'package:ilink/kernel/shell/shell_tool_bridge_provider.dart';
import 'package:ilink/kernel/sim/sim_live_info.dart';

class _FakeShellBridge implements ShellToolBridge {
  _FakeShellBridge(this.batchedReply);
  final String batchedReply;

  @override
  Future<String> exec(ShellCommand cmd) async {
    // Provider sends ['sh', '-c', 'getprop a; getprop b; …'].
    expect(cmd.argv.first, 'sh');
    expect(cmd.argv[1], '-c');
    return batchedReply;
  }

  @override
  Future<String> debugExec(List<String> argv, {int timeoutMs = 5000}) =>
      exec(ShellCommand(argv, timeoutMs: timeoutMs));

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ThrowingBridge implements ShellToolBridge {
  @override
  Future<String> exec(ShellCommand cmd) async => throw StateError('boom');
  @override
  Future<String> debugExec(List<String> argv, {int timeoutMs = 5000}) =>
      exec(ShellCommand(argv, timeoutMs: timeoutMs));
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('SimLiveInfo', () {
    test('empty has UNKNOWN simState, simPresent=false', () {
      expect(SimLiveInfo.empty.simState, 'UNKNOWN');
      expect(SimLiveInfo.empty.simPresent, isFalse);
    });

    test('simPresent ignores ABSENT and UNKNOWN', () {
      const absent = SimLiveInfo(
        imsi: '',
        imei: '867829060439746',
        simState: 'ABSENT',
        operatorName: '',
        operatorNumeric: '',
      );
      expect(absent.simPresent, isFalse);
    });

    test('simPresent true for READY / LOADED', () {
      for (final state in ['READY', 'LOADED', 'ready', 'loaded']) {
        final info = SimLiveInfo(
          imsi: '424021830470042',
          imei: '867829060439746',
          simState: state,
          operatorName: 'etisalat',
          operatorNumeric: '42402',
        );
        expect(info.simPresent, isTrue, reason: 'state=$state');
      }
    });

    test('simPresent true even for PIN_REQUIRED (card is in slot)', () {
      const locked = SimLiveInfo(
        imsi: '',
        imei: '867829060439746',
        simState: 'PIN_REQUIRED',
        operatorName: '',
        operatorNumeric: '',
      );
      // The slot has a card — IMSI is just hidden until PIN is entered.
      expect(locked.simPresent, isTrue);
    });
  });

  group('readSimLiveInfo (parser)', () {
    test('parses 5-line batched getprop output', () async {
      final info = await readSimLiveInfo(
        _FakeShellBridge(
          '424021830470042\n867829060439746\nLOADED\netisalat\n42402\n',
        ),
      );
      expect(info.imsi, '424021830470042');
      expect(info.imei, '867829060439746');
      expect(info.simState, 'LOADED');
      expect(info.operatorName, 'etisalat');
      expect(info.operatorNumeric, '42402');
      expect(info.simPresent, isTrue);
    });

    test('blank lines yield empty fields without crashing', () async {
      final info = await readSimLiveInfo(_FakeShellBridge('\n\n\n\n\n'));
      expect(info.imsi, '');
      expect(info.imei, '');
      // Empty raw → normalised to 'UNKNOWN' so UI can distinguish "modem
      // reported absent" from "we haven't read yet".
      expect(info.simState, 'UNKNOWN');
      expect(info.simPresent, isFalse);
    });

    test('short output (only 3 lines) → remaining fields empty', () async {
      final info = await readSimLiveInfo(
        _FakeShellBridge('99\n867829060439746\nABSENT\n'),
      );
      expect(info.imsi, '99');
      expect(info.imei, '867829060439746');
      expect(info.simState, 'ABSENT');
      expect(info.operatorName, '');
      expect(info.operatorNumeric, '');
    });

    test('shell exception yields SimLiveInfo.empty', () async {
      final info = await readSimLiveInfo(_ThrowingBridge());
      expect(info, SimLiveInfo.empty);
    });
  });

  group('simLiveInfoProvider lifecycle', () {
    test('first value flows; dispose cancels the poll loop cleanly', () async {
      final c = ProviderContainer(
        overrides: [
          shellToolBridgeProvider.overrideWithValue(
            _FakeShellBridge(
              '424021830470042\n867829060439746\nLOADED\netisalat\n42402\n',
            ),
          ),
        ],
      );
      // Explicit subscribe so the stream is hot before we read .future.
      final sub = c.listen(simLiveInfoProvider, (_, _) {});
      final info = await c
          .read(simLiveInfoProvider.future)
          .timeout(const Duration(seconds: 5));
      expect(info.simState, 'LOADED');
      sub.close();
      // Disposing must NOT throw, even though the polling loop is
      // mid-`Future.delayed`. The completer cancel path covers this.
      c.dispose();
    });
  });
}
