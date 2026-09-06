import 'package:ilink/features/tv/data/tv_ivi_bridge.dart';
import 'package:ilink/features/tv/domain/channel.dart';

/// Records launches of the native IVI player so the controller's
/// launch-on-play behaviour can be asserted without a device.
class FakeTvIviBridge implements TvIviBridge {
  final List<Channel> launched = [];
  int lastStartIndex = -1;
  int lastMaxBitrate = -1;

  @override
  Future<void> stop({bool networkOnly = false}) async {}

  @override
  Future<void> play({
    required List<Channel> channels,
    required int startIndex,
    int maxBitrate = 0,
  }) async {
    launched
      ..clear()
      ..addAll(channels);
    lastStartIndex = startIndex;
    lastMaxBitrate = maxBitrate;
  }
}
