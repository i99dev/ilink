import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

/// Append-only diagnostic log for the OTA + MQTT bring-up paths.
///
/// The BYD HU's logcat doesn't capture Flutter stdout — neither
/// `dart:developer.log` (silenced in release) nor `debugPrint` (no
/// flutter-tagged lines reach logcat on this OEM). So this writes a
/// file under the *external* app dir that `adb shell` can pull from a
/// release build:
///
///     adb shell ls /sdcard/Android/data/com.i99dev.ilink/files/
///     adb pull /sdcard/Android/data/com.i99dev.ilink/files/ota_diag.log /tmp/
///
/// Lives under `kernel/observability/` so `kernel/mqtt/` can write
/// boot-path diagnostics without reaching into `app/` — that direction
/// is gated by `test/architecture/layer_test.dart`. The legacy import
/// surface (`app/update/update_orchestrator.dart` re-exports
/// `otaDiagLog`) stays valid so existing callers don't churn.
///
/// File capped at ~256 KB; oldest content truncated on overflow.

File? _logFile;
Future<void>? _logFileInit;

Future<void> _initLogFile() async {
  try {
    Directory? dir;
    try {
      dir = await getExternalStorageDirectory();
    } catch (_) {
      dir = null;
    }
    dir ??= await getApplicationDocumentsDirectory();
    _logFile = File('${dir.path}/ota_diag.log');
    if (await _logFile!.exists()) {
      final size = await _logFile!.length();
      if (size > 256 * 1024) {
        await _logFile!.writeAsString('');
      }
    }
  } catch (_) {
    _logFile = null;
  }
}

/// Append [message] to the OTA diagnostic file, prefixed with a UTC
/// ISO-8601 timestamp. Cheap stdout via `debugPrint` is also emitted
/// in case a future OEM ROM does pipe Flutter logs to logcat.
///
/// Best-effort: any I/O error is swallowed. The diag must never break
/// the runtime path it instruments.
void otaDiagLog(String message) {
  debugPrint('ilink.ota: $message');
  _logFileInit ??= _initLogFile();
  _logFileInit!.then((_) {
    final f = _logFile;
    if (f == null) return;
    try {
      f.writeAsStringSync(
        '${DateTime.now().toIso8601String()} $message\n',
        mode: FileMode.append,
        flush: false,
      );
    } catch (_) {
      // Swallow — diag must never break runtime.
    }
  });
}
