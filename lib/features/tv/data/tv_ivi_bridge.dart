import 'package:flutter/services.dart';

import '../domain/channel.dart';
import '../../../kernel/services/optional_services.dart';
import '../../../kernel/services/local_media.dart';

/// Launches the native full-screen IVI player (`ilink/tv_ivi`).
///
/// Embedded Flutter video can't render on this BYD ROM, so the IVI TV is a
/// native Activity. The browser hands it the browsable [channels] (for the
/// in-player ◀/▶ playlist), the [startIndex] to begin on, and the quality
/// cap.
class TvIviBridge {
  TvIviBridge({MethodChannel? channel, bool Function()? streamingEnabled})
    : _channel = channel ?? const MethodChannel('ilink/tv_ivi'),
      _streamingEnabled = streamingEnabled ?? (() => false);

  final MethodChannel _channel;
  final bool Function() _streamingEnabled;

  Future<void> play({
    required List<Channel> channels,
    required int startIndex,
    int maxBitrate = 0,
  }) async {
    if (!_streamingEnabled() &&
        channels.any((channel) => !isLocalMedia(channel.streamUrl))) {
      throw const ServiceDisabled(OptionalService.streaming);
    }
    try {
      await _channel.invokeMethod<void>('play', {
        'urls': [for (final c in channels) c.streamUrl],
        'names': [for (final c in channels) c.name],
        'referers': [for (final c in channels) c.referrer ?? ''],
        'userAgents': [for (final c in channels) c.userAgent ?? ''],
        'startIndex': startIndex,
        'maxBitrate': maxBitrate,
      });
    } on PlatformException {
      // Launch failure is non-fatal — the browser stays put.
    } on MissingPluginException {
      // No native side (tests / unsupported host).
    }
  }

  Future<void> stop({bool networkOnly = false}) async {
    try {
      await _channel.invokeMethod<void>('stop', {'networkOnly': networkOnly});
    } on PlatformException {
      // An unsupported host must not break local UI.
    } on MissingPluginException {
      // Tests and unsupported host.
    }
  }
}
