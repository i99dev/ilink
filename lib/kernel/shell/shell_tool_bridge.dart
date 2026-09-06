import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'shell_breadcrumb_filter.dart';
import 'shell_command.dart';

/// Single point of access to the device's loopback ADB shell.
///
/// Why a separate channel instead of reusing `ilink/adb_bootstrap`:
/// the bootstrap channel is intentionally narrow (status/retry only)
/// to keep its surface auditable. Tools and AppActions need a write-
/// path; we expose it on `ilink/tools_shell` so adding routes here
/// doesn't expand the bootstrap channel's blast radius.
///
/// Threading: the platform side runs `AdbShellBridge.shell()` on a
/// worker thread and posts back. The Dart `Future` resolves on the
/// platform thread. Callers that touch UI state must `mounted` check.
///
/// PII: every command flows through [ShellBreadcrumbFilter] before
/// reaching observability. Package names are SHA-256 hashed; raw
/// argv never leaves the device.
class ShellToolBridge {
  ShellToolBridge({
    MethodChannel? channel,
    ShellBreadcrumbFilter filter = const ShellBreadcrumbFilter(),
    void Function(String op, String scrubbedCmd, {bool ok, int? tookMs})?
    breadcrumb,
  }) : _channel = channel ?? const MethodChannel(_kChannelName),
       _filter = filter,
       _breadcrumb = breadcrumb;

  static const _kChannelName = 'ilink/tools_shell';

  final MethodChannel _channel;
  final ShellBreadcrumbFilter _filter;
  final void Function(String op, String scrubbedCmd, {bool ok, int? tookMs})?
  _breadcrumb;

  /// Run a shell command and return its raw stdout. The caller owns
  /// parsing — readers in `data/` are pure functions consuming this.
  ///
  /// Errors:
  ///   * [PlatformException] for channel-level failures (plugin not
  ///     registered, daemon unreachable, etc.).
  ///   * [TimeoutException] if the command exceeds [ShellCommand.timeoutMs].
  Future<String> exec(ShellCommand cmd) async {
    final scrubbed = _filter.scrub(cmd.argv);
    final stopwatch = Stopwatch()..start();
    try {
      final out = await _channel.invokeMethod<String>('exec', {
        // The platform side joins argv with single-arg quoting. Sending
        // the list (not a pre-joined string) keeps the quoting policy
        // on one side of the boundary.
        'argv': cmd.argv,
        'timeoutMs': cmd.timeoutMs,
      });
      stopwatch.stop();
      _breadcrumb?.call(
        'shell.exec',
        scrubbed,
        ok: true,
        tookMs: stopwatch.elapsedMilliseconds,
      );
      return out ?? '';
    } catch (e) {
      stopwatch.stop();
      _breadcrumb?.call(
        'shell.exec',
        scrubbed,
        ok: false,
        tookMs: stopwatch.elapsedMilliseconds,
      );
      rethrow;
    }
  }

  /// Convenience that builds a [ShellCommand] from argv. Intended for
  /// throwaway diagnostics; production code paths should construct
  /// the command via the typed constructors in `data/`.
  @visibleForTesting
  Future<String> debugExec(List<String> argv, {int timeoutMs = 5000}) =>
      exec(ShellCommand(argv, timeoutMs: timeoutMs));
}
