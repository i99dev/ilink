import 'dart:developer' as dev;

/// SDK-internal copy of the tagged logger. Kept inside `lib/sdk/_internal/`
/// so the SDK has no outward imports — the original
/// `lib/kernel/logging/logger.dart` re-exports this one and shares its
/// type, so app and SDK callers see the same `Logger` / `LogLevel`.
///
/// Use [Logger.of] at the top of a class and call `.d/.i/.w/.e`. Goes
/// through `dart:developer` so messages show up in DevTools + logcat
/// under `flutter:I`. The global minimum level is set once at app
/// bootstrap via [Logger.configure]; default is [LogLevel.debug].

/// Log level — kept here so the SDK is self-contained. The app's
/// `AppConfig.logLevel` parses an env value into this enum at boot
/// and passes it to [Logger.configure].
enum LogLevel {
  debug,
  info,
  warn,
  error;

  static LogLevel parse(String raw) => switch (raw.toLowerCase()) {
    'info' => LogLevel.info,
    'warn' || 'warning' => LogLevel.warn,
    'error' => LogLevel.error,
    _ => LogLevel.debug,
  };
}

class Logger {
  const Logger(this.tag);
  final String tag;

  factory Logger.of(Object holder) => Logger(holder.runtimeType.toString());

  /// Global minimum level. `.d` below this is suppressed. Set once in
  /// `main.dart` before `runApp`.
  static LogLevel _minLevel = LogLevel.debug;

  /// Idempotent: safe to call from tests + main.
  static void configure(LogLevel min) {
    _minLevel = min;
  }

  void d(String msg) {
    if (_shouldLog(LogLevel.debug)) _log(msg, level: 500);
  }

  void i(String msg) {
    if (_shouldLog(LogLevel.info)) _log(msg, level: 800);
  }

  void w(String msg) {
    if (_shouldLog(LogLevel.warn)) _log(msg, level: 900);
  }

  void e(String msg, {Object? error, StackTrace? stack}) {
    if (_shouldLog(LogLevel.error)) {
      _log(msg, level: 1000, error: error, stack: stack);
    }
  }

  static bool _shouldLog(LogLevel level) => level.index >= _minLevel.index;

  void _log(
    String msg, {
    required int level,
    Object? error,
    StackTrace? stack,
  }) {
    dev.log(msg, name: tag, level: level, error: error, stackTrace: stack);
  }
}
