import 'channel.dart';

/// Sealed state exposed to the UI by `TvController`. Subtypes map 1:1 to the
/// player's top-level status so widgets can switch on `runtimeType` without
/// digging into nested fields. Mirrors `RadioState`.
sealed class TvState {
  const TvState();
}

class TvIdle extends TvState {
  const TvIdle();
}

/// Transient — buffering the first frames. Distinct from [TvPlaying] so the
/// UI can show a spinner over the (still blank) video surface.
class TvLoading extends TvState {
  const TvLoading(this.channel);
  final Channel channel;
}

class TvPlaying extends TvState {
  const TvPlaying(this.channel);
  final Channel channel;
}

class TvPaused extends TvState {
  const TvPaused(this.channel);
  final Channel channel;
}

class TvError extends TvState {
  const TvError(this.message, {this.channel});
  final String message;

  /// Present when the error relates to a specific channel (stream refused,
  /// codec mismatch). Null for catalogue/search failures.
  final Channel? channel;
}
