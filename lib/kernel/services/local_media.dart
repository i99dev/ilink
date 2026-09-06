/// Only resources entirely on the device avoid streaming consent. Network
/// streams, including arbitrary LAN addresses, remain explicitly opt-in.
bool isLocalMedia(String source) {
  final uri = Uri.tryParse(source);
  if (uri == null ||
      !const {'file', 'asset'}.contains(uri.scheme) ||
      uri.host.isNotEmpty) {
    return false;
  }
  // Local playlists can reference remote HLS/DASH segments; they still need
  // streaming consent. Only direct media files qualify for the offline path.
  final name = uri.path.toLowerCase();
  return const [
    '.wav',
    '.mp3',
    '.aac',
    '.ogg',
    '.flac',
    '.m4a',
    '.opus',
    '.mp4',
    '.mkv',
    '.webm',
  ].any(name.endsWith);
}
