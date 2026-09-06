import 'dart:async';

import 'shell_command.dart';

/// Coordinates concurrent shell ops across the whole app.
///
/// Three responsibilities:
///   * **In-flight dedup** — N callers asking for the same `cacheKey`
///     share one underlying Future. Critical when both ToolsPanel
///     (background poll) and AppActionsSheet (foreground) ask for
///     `pm list packages -3` in the same second.
///   * **Coalesce** — same-key writes within [coalesceWindow] (default
///     1s) collapse into one execution. Defends against spam-taps on
///     a Force-Stop button.
///   * **TTL cache** — read-path results are cached by `cacheKey` for
///     [readTtl]. A write that declares `invalidates: {keyA, keyB}`
///     drops those cache entries so the next read re-fetches.
///
/// Cancellation: every public method takes a `CancelToken`. When the
/// caller cancels (e.g. the sheet was dismissed mid-flight), the
/// pending Future completes with [CancelException]. Other callers
/// sharing the same in-flight op are NOT affected — they get their
/// own results.
class ShellOpsCoordinator {
  ShellOpsCoordinator({
    required Future<String> Function(ShellCommand) exec,
    Duration readTtl = const Duration(seconds: 5),
    Duration coalesceWindow = const Duration(seconds: 1),
  }) : _exec = exec,
       _readTtl = readTtl,
       _coalesceWindow = coalesceWindow;

  final Future<String> Function(ShellCommand) _exec;
  final Duration _readTtl;
  final Duration _coalesceWindow;

  // Cache: cacheKey → (value, expiresAt)
  final Map<String, _Cached> _cache = {};

  // In-flight reads: cacheKey → Future. Subsequent callers with the
  // same key get the existing Future.
  final Map<String, Future<String>> _inFlightReads = {};

  // Coalesce: cacheKey → (lastFiredAt, lastFuture). A second caller
  // arriving inside [_coalesceWindow] reuses the existing Future
  // instead of firing again.
  final Map<String, _CoalesceEntry> _coalesce = {};

  /// Read path. Honors cache → in-flight dedup → fresh exec.
  Future<String> read(ShellCommand cmd, {CancelToken? cancel}) async {
    final key = cmd.cacheKey;
    if (key == null) {
      // Caller opted out of dedup. Fire directly.
      return _runWithCancel(cmd, cancel);
    }
    // 1. Cache hit.
    final cached = _cache[key];
    if (cached != null && DateTime.now().isBefore(cached.expiresAt)) {
      return cached.value;
    }
    // 2. In-flight dedup — concurrent callers share one Future.
    final pending = _inFlightReads[key];
    if (pending != null) return pending;
    // 3. Fresh exec — cache on success, always clear in-flight.
    final fut = _runWithCancel(cmd, cancel);
    _inFlightReads[key] = fut;
    try {
      final value = await fut;
      _cache[key] = _Cached(value, DateTime.now().add(_readTtl));
      return value;
    } finally {
      // .remove returns the removed Future; we already awaited it above.
      // ignore: unawaited_futures
      _inFlightReads.remove(key);
    }
  }

  /// Write path. Coalesces same-key calls within [_coalesceWindow] and
  /// invalidates the listed cache keys on success.
  Future<String> write(
    ShellCommand cmd, {
    Set<String> invalidates = const {},
    String? coalesceKey,
    CancelToken? cancel,
  }) {
    final key = coalesceKey ?? cmd.cacheKey;
    if (key != null) {
      final entry = _coalesce[key];
      if (entry != null &&
          DateTime.now().difference(entry.firedAt) < _coalesceWindow) {
        return entry.future;
      }
    }
    final fut = _runWithCancel(cmd, cancel).then((out) {
      for (final k in invalidates) {
        _cache.remove(k);
      }
      return out;
    });
    if (key != null) {
      _coalesce[key] = _CoalesceEntry(DateTime.now(), fut);
    }
    return fut;
  }

  /// Drop a cache entry without exec'ing anything. Use when the truth
  /// for a key changed externally (e.g. an MQTT subscription event).
  void invalidate(String cacheKey) => _cache.remove(cacheKey);

  /// Drop EVERY cached value. Use sparingly — e.g. user pulled to
  /// refresh, or the sheet's REFRESH button.
  void invalidateAll() => _cache.clear();

  Future<String> _runWithCancel(ShellCommand cmd, CancelToken? cancel) {
    if (cancel?.isCancelled ?? false) {
      return Future.error(CancelException(cancel!.reason ?? 'pre-cancelled'));
    }
    final execFuture = _exec(
      cmd,
    ).timeout(Duration(milliseconds: cmd.timeoutMs));
    if (cancel == null) return execFuture;
    // Race exec against a cancel signal. Whichever resolves first
    // wins; the loser's result/error is silently dropped (Future.any
    // only surfaces the first to settle).
    final cancelCompleter = Completer<String>();
    cancel.whenCancelled(() {
      if (!cancelCompleter.isCompleted) {
        cancelCompleter.completeError(
          CancelException(cancel.reason ?? 'cancelled'),
        );
      }
    });
    return Future.any([execFuture, cancelCompleter.future]);
  }
}

class _Cached {
  _Cached(this.value, this.expiresAt);
  final String value;
  final DateTime expiresAt;
}

class _CoalesceEntry {
  _CoalesceEntry(this.firedAt, this.future);
  final DateTime firedAt;
  final Future<String> future;
}

/// Caller-controlled cancellation. Pattern matches Dio's CancelToken
/// since the rest of the app already speaks that idiom.
class CancelToken {
  CancelToken({this.reason});
  final String? reason;
  bool _cancelled = false;
  final List<void Function()> _listeners = [];

  bool get isCancelled => _cancelled;

  void cancel({String? reason}) {
    if (_cancelled) return;
    _cancelled = true;
    for (final l in _listeners) {
      try {
        l();
      } catch (_) {}
    }
    _listeners.clear();
  }

  /// Fires once when the token cancels. If already cancelled, fires
  /// synchronously.
  void whenCancelled(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }
}

class CancelException implements Exception {
  CancelException(this.reason);
  final String reason;
  @override
  String toString() => 'CancelException: $reason';
}
