import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'shell_command.dart';
import 'shell_ops_coordinator.dart';
import 'shell_tool_bridge.dart';

/// One [ShellToolBridge] per app process. The platform-side singleton
/// (`AdbShellBridge` Kotlin object) is process-scoped; mirroring that
/// shape here means every Riverpod-watched read goes through the same
/// MethodChannel instance — nothing else in the codebase should
/// instantiate this directly.
final shellToolBridgeProvider = Provider<ShellToolBridge>((ref) {
  return ShellToolBridge(
    breadcrumb: kReleaseMode
        ? null // Sentry hook wired separately via observability layer.
        : (op, scrubbed, {ok = true, tookMs}) {
            // ignore: avoid_print
            debugPrint(
              '[shell] $op '
              'cmd=$scrubbed ok=$ok '
              '${tookMs == null ? '' : 'took=${tookMs}ms'}',
            );
          },
  );
});

/// One coordinator per app process. Reads/writes from any feature
/// (Tools, AppActions, future) go through here so cache + dedup +
/// coalesce are consistent across the codebase.
final shellOpsCoordinatorProvider = Provider<ShellOpsCoordinator>((ref) {
  final bridge = ref.watch(shellToolBridgeProvider);
  return ShellOpsCoordinator(exec: (ShellCommand cmd) => bridge.exec(cmd));
});
