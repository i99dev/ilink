import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/kernel/services/local_media.dart';

void main() {
  test('only direct on-device audio bypasses streaming consent', () {
    expect(isLocalMedia('file:///music/song.mp3'), isTrue);
    expect(isLocalMedia('asset:///audio/chime.wav'), isTrue);
    expect(isLocalMedia('https://example.com/song.mp3'), isFalse);
    expect(isLocalMedia('file://remote-server/song.mp3'), isFalse);
    expect(isLocalMedia('file:///music/remote-segments.m3u8'), isFalse);
    expect(isLocalMedia('content://external/something'), isFalse);
  });
}
