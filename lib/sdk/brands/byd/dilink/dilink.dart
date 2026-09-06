/// Barrel — single import for DiLink adapter clients. Registers the
/// concrete adapter map at first use so
/// [BydDilinkAdapter.detect] / [BydDilinkAdapter.forTesting] can
/// resolve any [DilinkVersion]. Keep this import at the top of
/// `byd_client.dart` to make sure the registration runs before any
/// adapter lookup.
library;

import 'byd_dilink_5_0.dart';
import 'byd_dilink_5_1.dart';
import 'byd_dilink_8_x.dart';
import 'byd_dilink_adapter.dart';
import 'byd_dilink_unknown.dart';

export 'byd_dilink_adapter.dart' show BydDilinkAdapter, DilinkVersion;

bool _registered = false;

/// Idempotent. Called by `byd_client.dart` at top of its file —
/// safe to call multiple times. Tests can also call this explicitly
/// before constructing adapters.
void ensureBydDilinkAdaptersRegistered() {
  if (_registered) return;
  registerBydDilinkAdapters(<DilinkVersion, BydDilinkAdapter>{
    DilinkVersion.dilink_5_0: const BydDilink50Adapter(),
    DilinkVersion.dilink_5_1: const BydDilink51Adapter(),
    DilinkVersion.dilink_8_x: const BydDilink8XAdapter(),
    DilinkVersion.unknown: const BydDilinkUnknownAdapter(),
  });
  _registered = true;
}
