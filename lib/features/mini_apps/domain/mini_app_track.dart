enum MiniAppTrack {
  production,
  beta;

  /// Parses the wire string into an enum value. Treats anything other
  /// than `"beta"` (including null and unknown strings) as
  /// [production] — this matches the backend's API contract: an absent
  /// `track` field means production. Future tracks added on the server
  /// without a frontend bump are forward-compatible (rendered as
  /// production until the client knows about them).
  static MiniAppTrack fromWire(String? wire) =>
      wire == 'beta' ? MiniAppTrack.beta : MiniAppTrack.production;

  /// Wire string this enum value serialises back to. Symmetric with
  /// [fromWire].
  String get wire => switch (this) {
    MiniAppTrack.production => 'production',
    MiniAppTrack.beta => 'beta',
  };
}
