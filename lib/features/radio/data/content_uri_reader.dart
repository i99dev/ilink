import 'package:flutter/services.dart';

/// Dart-side proxy for `ContentUriBridge.kt` — reads a `content://` URI
/// to UTF-8 text via the native ContentResolver. Sole consumer is
/// [UserPlaylistImporter.importFromUri] when handling "Open with"
/// intents (`ACTION_VIEW` on a `.m3u` content URI) that `dart:io File`
/// cannot open directly.
///
/// The channel is injectable for tests; in production the default
/// matches `ContentUriBridge.CHANNEL`. No state, no caches — one call
/// per import.
class ContentUriReader {
  ContentUriReader({MethodChannel? channel})
    : _ch = channel ?? const MethodChannel('com.i99dev.ilink/content_uri');

  final MethodChannel _ch;

  /// Returns the UTF-8 text contents of [contentUri] (typically a
  /// `content://...` SAF URI granted by an ACTION_VIEW intent).
  /// Throws [ContentUriReadException] on any platform-side failure
  /// (revoked permission, payload too large, decode failure, …) — the
  /// importer surfaces the message verbatim to the user.
  Future<String> readText(Uri contentUri) async {
    try {
      final s = await _ch.invokeMethod<String>('readText', {
        'uri': contentUri.toString(),
      });
      return s ?? '';
    } on PlatformException catch (e) {
      throw ContentUriReadException(e.code, e.message ?? e.code);
    } on MissingPluginException {
      // Non-Android targets (web / tests without the bridge registered)
      // — degrade with a clear error rather than a cryptic missing-
      // plugin trace.
      throw const ContentUriReadException(
        'UNSUPPORTED',
        'content:// is not supported on this platform',
      );
    }
  }
}

/// Surfaced by [ContentUriReader.readText] for any native-side failure.
/// [code] mirrors the Kotlin `MethodChannel.Result.error` codes
/// (`NOT_FOUND`, `PAYLOAD_TOO_LARGE`, `DECODE_FAILED`, `PERMISSION_DENIED`,
/// `IO_ERROR`, `UNSUPPORTED`, `UNKNOWN`).
class ContentUriReadException implements Exception {
  const ContentUriReadException(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => 'ContentUriReadException($code): $message';
}
