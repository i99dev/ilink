part of 'compat_screen.dart';

// ────────────────────────────────────────────────────────────────────
// Models
// ────────────────────────────────────────────────────────────────────

class _ActionSpec {
  /// Tap-only action. Optional preset args (e.g. turn signals always
  /// fire with `on: true` in this bench).
  const _ActionSpec.tap(this.id, {Map<String, dynamic>? args})
    : kind = _Kind.tap,
      argName = '',
      hint = '',
      defaultValue = 0,
      presetArgs = args ?? const {};

  /// Action that takes a single int arg. `argName` defaults to "value"
  /// to match the encrypted table's argument-name conventions.
  const _ActionSpec.intArg(
    this.id, {
    this.argName = 'value',
    this.hint = '',
    this.defaultValue = 0,
  }) : kind = _Kind.intArg,
       presetArgs = const {};

  /// Action that takes a single boolean arg (`on`/`off` style).
  const _ActionSpec.boolArg(this.id, {this.argName = 'on'})
    : kind = _Kind.boolArg,
      hint = '',
      defaultValue = 0,
      presetArgs = const {};

  final String id;
  final _Kind kind;
  final String argName;
  final String hint;
  final int defaultValue;
  final Map<String, dynamic> presetArgs;
}

enum _Kind { tap, intArg, boolArg }

class _BinderProbe {
  const _BinderProbe({
    required this.label,
    required this.service,
    required this.method,
    required this.args,
  });
  final String label;
  final String service;
  final String method;
  final Map<String, dynamic> args;
}

class _Outcome {
  _Outcome._({
    required this.label,
    required this.color,
    required this.detail,
    required this.args,
    required this.ok,
    required this.isPending,
    this.code,
    this.errorText,
    this.runAt,
  });

  factory _Outcome.fromBridge(
    Map<String, dynamic> raw, {
    required Map<String, dynamic> args,
  }) {
    final ok = raw['ok'] == true;
    final code = raw['code'];
    final err = raw['error'];
    if (err != null) {
      return _Outcome._(
        label: 'ERR',
        color: AppColors.primary,
        detail: err.toString(),
        args: args,
        ok: false,
        isPending: false,
        code: code is int ? code : null,
        errorText: err.toString(),
        runAt: DateTime.now(),
      );
    }
    return _Outcome._(
      label: ok ? 'OK' : 'FAIL',
      color: ok ? AppColors.accent : AppColors.warning,
      detail: code == null ? raw.toString() : 'code=$code',
      args: args,
      ok: ok,
      isPending: false,
      code: code is int ? code : null,
      runAt: DateTime.now(),
    );
  }

  factory _Outcome.exception(
    String msg, {
    required Map<String, dynamic> args,
  }) => _Outcome._(
    label: 'EXC',
    color: AppColors.primary,
    detail: msg,
    args: args,
    ok: false,
    isPending: false,
    errorText: msg,
    runAt: DateTime.now(),
  );

  factory _Outcome.pending({required Map<String, dynamic> args}) => _Outcome._(
    label: '…',
    color: AppColors.secondary,
    detail: 'in flight',
    args: args,
    ok: false,
    isPending: true,
  );

  final String label;
  final Color color;
  final String detail;
  final Map<String, dynamic> args;
  final bool ok;
  final bool isPending;
  final int? code;
  final String? errorText;
  final DateTime? runAt;
}

/// Drives a fake 0 → 0.95 progress over ~2 s so the UI feels responsive
/// during a CompatProbe.run() — the probe itself runs in a single async
/// pass, so there's no real per-command progress to plot.
class _FakeProgressTicker {
  bool _cancelled = false;

  Future<void> start(void Function(double) onTick) async {
    var t = 0.0;
    while (!_cancelled && t < 0.95) {
      await Future.delayed(const Duration(milliseconds: 100));
      if (_cancelled) return;
      t = (t + 0.05).clamp(0.0, 0.95);
      onTick(t);
    }
  }

  void cancel() => _cancelled = true;
}
