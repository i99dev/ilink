import '../../../kernel/shell/shell_command.dart';
import '../../../kernel/shell/shell_ops_coordinator.dart';
import '../domain/app_action.dart';
import '../domain/app_target.dart';

/// Maps an [AppActionKind] + target to the right shell command.
///
/// The writer is pure dispatch — eligibility checks live on the
/// registry's `eligible(meta)`, which the sheet evaluates BEFORE
/// dispatching here. We still defend against bad inputs (e.g.
/// `transferRunning` with no displayId) by throwing — call sites
/// must populate the optional args.
class PackageActionsWriter {
  PackageActionsWriter(this._coord);

  final ShellOpsCoordinator _coord;

  // Cache keys used to invalidate state after a successful write.
  static String packageDumpKey(String pkg) => 'dumpsys package $pkg';
  static const String dozeWhitelistKey = 'dumpsys deviceidle whitelist';
  static const String thirdPartyListKey = 'pm list packages -3';
  static const String disabledListKey = 'pm list packages -d';

  Future<String> exec({
    required AppActionKind kind,
    required AppTarget target,
    int? displayId,
    CancelToken? cancel,
  }) {
    final pkg = _packageNameOrThrow(target);
    final invalidates = <String>{
      packageDumpKey(pkg),
      thirdPartyListKey,
      disabledListKey,
    };
    final argv = switch (kind) {
      AppActionKind.enable => ['pm', 'enable', '--user', '0', pkg],
      AppActionKind.disable => ['pm', 'disable-user', '--user', '0', pkg],
      AppActionKind.uninstall => ['pm', 'uninstall', '--user', '0', pkg],
      AppActionKind.forceStop => ['am', 'force-stop', pkg],
      AppActionKind.clearData => ['pm', 'clear', pkg],
      AppActionKind.whitelist => [
        'dumpsys',
        'deviceidle',
        'whitelist',
        '+$pkg',
      ],
      AppActionKind.transferRunning => () {
        if (displayId == null) {
          throw ArgumentError(
            'transferRunning requires displayId on the call site',
          );
        }
        // Move-task uses the task id, not the package name. Caller
        // must look up the running task id from AppMeta and supply
        // it via the extension below, NOT this enum branch — we
        // throw here as a defensive guard rather than silently
        // doing nothing.
        throw StateError(
          'transferRunning must be dispatched via execMoveTask()',
        );
      }(),
    };
    if (kind == AppActionKind.whitelist) {
      invalidates.add(dozeWhitelistKey);
    }
    return _coord.write(
      ShellCommand(argv),
      invalidates: invalidates,
      coalesceKey: '${kind.name}:$pkg',
      cancel: cancel,
    );
  }

  /// Specialised entry for transferRunning since the shell argv
  /// depends on a runtime taskId + displayId, not just the kind.
  /// The sheet's "Move" picker hands these in.
  Future<String> execMoveTask({
    required int taskId,
    required int displayId,
    required AppTarget target,
    CancelToken? cancel,
  }) {
    final pkg = _packageNameOrThrow(target);
    return _coord.write(
      ShellCommand([
        'am',
        'stack',
        'move-task',
        '$taskId',
        '$displayId',
        'true',
      ]),
      invalidates: {packageDumpKey(pkg)},
      coalesceKey: 'transferRunning:$pkg',
      cancel: cancel,
    );
  }

  String _packageNameOrThrow(AppTarget target) {
    if (target is NativeAppTarget) return target.packageName;
    throw StateError(
      'PackageActionsWriter only supports NativeAppTarget; '
      'got ${target.runtimeType}',
    );
  }
}
