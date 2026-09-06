import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../kernel/shell/shell_tool_bridge_provider.dart';
import '../data/package_actions_writer.dart';
import '../domain/app_action.dart';
import '../domain/app_meta.dart';
import '../domain/app_target.dart';
import 'app_meta_provider.dart';

/// Performs an action on a target.
///
/// Optimistic UI: the cached meta is patched immediately based on the
/// action's expected effect (Enable → enabled=true, etc.), the shell
/// write fires; on failure we restore the snapshot.
class AppActionController extends Notifier<void> {
  late final PackageActionsWriter _writer;

  @override
  void build() {
    _writer = PackageActionsWriter(ref.read(shellOpsCoordinatorProvider));
  }

  Future<AppActionOutcome> run({
    required AppActionKind kind,
    required AppTarget target,
    int? displayId,
    int? taskId,
  }) async {
    if (target is! NativeAppTarget) {
      return AppActionOutcome.ineligible;
    }
    final cache = ref.read(appMetaCacheProvider.notifier);
    final snapshot = cache.patch(target, (m) => _projectExpected(m, kind));
    try {
      if (kind == AppActionKind.transferRunning) {
        final tid = taskId ?? snapshot.runningTaskId;
        if (tid == null || displayId == null) {
          cache.restore(target, snapshot);
          return AppActionOutcome.ineligible;
        }
        await _writer.execMoveTask(
          taskId: tid,
          displayId: displayId,
          target: target,
        );
      } else {
        await _writer.exec(kind: kind, target: target, displayId: displayId);
      }
      await cache.refresh(target);
      return AppActionOutcome.ok;
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint(
          'app action ${kind.name} on ${target.packageName} failed: $e\n$st',
        );
      }
      cache.restore(target, snapshot);
      return AppActionOutcome.failed;
    }
  }

  AppMeta _projectExpected(AppMeta m, AppActionKind kind) => switch (kind) {
    AppActionKind.enable => m.copyWith(enabled: true),
    AppActionKind.disable => m.copyWith(enabled: false),
    AppActionKind.uninstall => m.copyWith(enabled: false),
    AppActionKind.forceStop => m.copyWith(runningTaskId: null),
    AppActionKind.clearData => m,
    AppActionKind.whitelist => m.copyWith(inDozeWhitelist: true),
    AppActionKind.transferRunning => m,
  };
}

final appActionControllerProvider = NotifierProvider<AppActionController, void>(
  AppActionController.new,
);
