import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/settings/state/keep_alive_provider.dart';

/// Records writes + serves a configurable current value so the controller
/// can be exercised without a platform channel.
class _FakeKeepAliveBridge implements KeepAliveBridge {
  _FakeKeepAliveBridge(this._enabled);

  bool _enabled;
  final List<bool> setCalls = [];

  @override
  Future<bool> isEnabled() async => _enabled;

  @override
  Future<void> setEnabled(bool enabled) async {
    setCalls.add(enabled);
    _enabled = enabled;
  }
}

void main() {
  ProviderContainer containerWith(_FakeKeepAliveBridge fake) {
    final c = ProviderContainer(
      overrides: [keepAliveBridgeProvider.overrideWithValue(fake)],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('build() reflects the native value (keep-alive OFF)', () async {
    final c = containerWith(_FakeKeepAliveBridge(false));
    final v = await c.read(keepAliveProvider.future);
    expect(v, isFalse);
  });

  test('set() flips state optimistically and persists natively', () async {
    final fake = _FakeKeepAliveBridge(true);
    final c = containerWith(fake);
    await c.read(keepAliveProvider.future); // ensure built

    await c.read(keepAliveProvider.notifier).set(false);

    expect(c.read(keepAliveProvider).value, isFalse);
    expect(fake.setCalls, [false]);
  });

  test('channel + method names are the contract the Kotlin side declares', () {
    expect(ConnectivityChannelNames.methodChannel, 'ilink/connectivity');
    expect(ConnectivityChannelNames.isKeepAliveEnabled, 'isKeepAliveEnabled');
    expect(ConnectivityChannelNames.setKeepAliveEnabled, 'setKeepAliveEnabled');
  });
}
