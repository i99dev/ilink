/// User-selectable streaming quality for live TV.
///
/// HLS streams are adaptive (a master playlist of variant renditions). On a
/// weak connection the highest variant buffers/stalls, so the user can cap
/// the rendition. The cap is best-effort: it only bites on multi-variant
/// streams (single-bitrate feeds ignore it), and on the IVI it maps to
/// mpv's `hls-bitrate`, on the passenger to ExoPlayer's max-video-bitrate.
enum TvQuality {
  /// No cap — best variant the connection sustains.
  auto('Auto', 0),

  /// ~720p.
  hd720('720p', 2000000),

  /// ~480p.
  sd480('480p', 1000000),

  /// ~360p, for weak connections.
  sd360('360p', 600000);

  const TvQuality(this.label, this.maxBitrate);

  final String label;

  /// Max variant bandwidth in bits/sec; 0 = no cap (best available).
  final int maxBitrate;

  /// Value for mpv's `hls-bitrate` property (media_kit / IVI player):
  /// a numeric ceiling, or `max` for [auto].
  String get hlsBitrate => maxBitrate > 0 ? '$maxBitrate' : 'max';

  static TvQuality fromName(String? name) => TvQuality.values.firstWhere(
    (q) => q.name == name,
    orElse: () => TvQuality.auto,
  );
}
