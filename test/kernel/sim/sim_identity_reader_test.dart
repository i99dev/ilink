import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ilink/kernel/shell/shell_command.dart';
import 'package:ilink/kernel/shell/shell_tool_bridge.dart';
import 'package:ilink/kernel/shell/shell_tool_bridge_provider.dart';
import 'package:ilink/kernel/sim/iccid_imsi_generator.dart';
import 'package:ilink/kernel/sim/sim_identity_override.dart';
import 'package:ilink/kernel/sim/sim_identity_reader.dart';

/// In-memory stand-in for the real shell bridge — every `getprop X`
/// is matched against [props] so tests can simulate "SIM missing",
/// "persistent key set", "volatile fallback only", etc.
class _FakeShellBridge implements ShellToolBridge {
  _FakeShellBridge(this.props);
  final Map<String, String> props;

  @override
  Future<String> exec(ShellCommand cmd) async {
    if (cmd.argv.length == 2 && cmd.argv[0] == 'getprop') {
      return props[cmd.argv[1]] ?? '';
    }
    throw UnimplementedError('fake bridge: ${cmd.argv}');
  }

  @override
  Future<String> debugExec(List<String> argv, {int timeoutMs = 5000}) =>
      exec(ShellCommand(argv, timeoutMs: timeoutMs));

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(const {}));

  ProviderContainer makeContainer(_FakeShellBridge bridge) => ProviderContainer(
    overrides: [shellToolBridgeProvider.overrideWithValue(bridge)],
  );

  test('passes through real persist.radio.iccid when no override', () async {
    final bridge = _FakeShellBridge({
      'persist.radio.iccid': '89971122127803077619',
    });
    final c = makeContainer(bridge);
    addTearDown(c.dispose);
    // Settle async providers before reading the resolved view.
    await c.read(simIdentityOverrideProvider.future);
    // The real reader is internal; force it to resolve by reading the
    // resolved provider after a microtask round-trip.
    await Future<void>.delayed(Duration.zero);
    // Need to flush the FutureProvider — Riverpod doesn't kick it off
    // until something `watch`es it. The resolved provider does watch
    // it, so reading the resolved value once schedules it. Then a
    // second microtask round-trip gives the fake bridge time to
    // complete its (synchronous) future.
    c.read(resolvedSimIdentityProvider);
    await Future<void>.delayed(Duration.zero);
    final resolved = c.read(resolvedSimIdentityProvider);
    expect(resolved.iccid, '89971122127803077619');
    expect(resolved.realIccid, '89971122127803077619');
    expect(resolved.overrideActive, isFalse);
    expect(resolved.imsi, isEmpty);
  });

  test(
    'falls back to ril.csim.iccid when persist.radio.iccid is empty',
    () async {
      final bridge = _FakeShellBridge({
        'persist.radio.iccid': '',
        'ril.csim.iccid': '89860612345678901234',
      });
      final c = makeContainer(bridge);
      addTearDown(c.dispose);
      await c.read(simIdentityOverrideProvider.future);
      c.read(resolvedSimIdentityProvider);
      await Future<void>.delayed(Duration.zero);
      final resolved = c.read(resolvedSimIdentityProvider);
      expect(resolved.iccid, '89860612345678901234');
      expect(resolved.overrideActive, isFalse);
    },
  );

  test('override wins when active; realIccid still echoes the prop', () async {
    final bridge = _FakeShellBridge({
      'persist.radio.iccid': '89971122127803077619',
    });
    final c = makeContainer(bridge);
    addTearDown(c.dispose);
    final ctrl = c.read(simIdentityOverrideProvider.notifier);
    await c.read(simIdentityOverrideProvider.future);
    ctrl.generator = IccidImsiGenerator(random: Random(11));
    final fresh = await ctrl.generateAndApply(ChineseCarrierPreset.cmcc);

    c.read(resolvedSimIdentityProvider);
    await Future<void>.delayed(Duration.zero);
    final resolved = c.read(resolvedSimIdentityProvider);
    expect(resolved.overrideActive, isTrue);
    expect(resolved.iccid, fresh.iccid);
    expect(resolved.imsi, fresh.imsi);
    expect(
      resolved.realIccid,
      '89971122127803077619',
      reason: 'real prop is preserved on the side for the UI badge',
    );
  });

  test(
    'deactivating override returns to real value without a re-read',
    () async {
      final bridge = _FakeShellBridge({
        'persist.radio.iccid': '89971122127803077619',
      });
      final c = makeContainer(bridge);
      addTearDown(c.dispose);
      final ctrl = c.read(simIdentityOverrideProvider.notifier);
      await c.read(simIdentityOverrideProvider.future);
      ctrl.generator = IccidImsiGenerator(random: Random(12));
      await ctrl.generateAndApply(ChineseCarrierPreset.ctcc);
      c.read(resolvedSimIdentityProvider);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(resolvedSimIdentityProvider).overrideActive, isTrue);

      await ctrl.deactivate();
      await Future<void>.delayed(Duration.zero);
      final resolved = c.read(resolvedSimIdentityProvider);
      expect(resolved.overrideActive, isFalse);
      expect(resolved.iccid, '89971122127803077619');
      expect(resolved.imsi, isEmpty);
    },
  );

  test(
    'shell read failure → empty real string, override still works',
    () async {
      // Bridge that throws on every exec — simulates daemon-down.
      final throwingBridge = _FakeShellBridge({});
      final c = ProviderContainer(
        overrides: [
          shellToolBridgeProvider.overrideWith((ref) => _ThrowingShellBridge()),
        ],
      );
      addTearDown(c.dispose);
      await c.read(simIdentityOverrideProvider.future);
      c.read(resolvedSimIdentityProvider);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(resolvedSimIdentityProvider).iccid, isEmpty);

      final ctrl = c.read(simIdentityOverrideProvider.notifier);
      ctrl.generator = IccidImsiGenerator(random: Random(13));
      final fresh = await ctrl.generateAndApply(ChineseCarrierPreset.cmcc);
      await Future<void>.delayed(Duration.zero);
      final resolved = c.read(resolvedSimIdentityProvider);
      expect(resolved.iccid, fresh.iccid);
      expect(resolved.overrideActive, isTrue);
      // Silence unused-variable warning for the unused bridge.
      expect(throwingBridge.props, isEmpty);
    },
  );
}

class _ThrowingShellBridge implements ShellToolBridge {
  @override
  Future<String> exec(ShellCommand cmd) async =>
      throw StateError('daemon-down');

  @override
  Future<String> debugExec(List<String> argv, {int timeoutMs = 5000}) =>
      exec(ShellCommand(argv, timeoutMs: timeoutMs));

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
