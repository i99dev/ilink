import 'package:flutter/services.dart';

/// Single MethodChannel identity shared by every OTA-domain bridge:
/// [ApkInstaller], [ApkSignerCheck], and any future helper that talks
/// to the host-side `OtaPlugin`. Held here so the wire name is
/// declared exactly once — Flutter requires every MethodChannel call
/// to use the same channel name string, and a typo on one side
/// silently routes invocations into the void.
const otaMethodChannel = MethodChannel('ilink/ota');
