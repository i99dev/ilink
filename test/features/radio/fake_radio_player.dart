import 'dart:async';

import 'package:ilink/features/radio/data/radio_player.dart';
import 'package:ilink/features/radio/domain/station.dart';

/// Hand-rolled fake [RadioPlayer] for controller tests — follows the same
/// "fake, not mock" pattern as `test/support/fake_car_bridge.dart`. Records
/// every call so assertions stay readable (`expect(player.played, [s])`).
class FakeRadioPlayer implements RadioPlayer {
  FakeRadioPlayer() {
    _controller = StreamController<RadioPlaybackState>.broadcast(
      onListen: () => _controller.add(_current),
    );
  }

  late final StreamController<RadioPlaybackState> _controller;
  RadioPlaybackState _current = const RadioPlaybackState(
    status: RadioPlaybackStatus.idle,
  );

  final List<Station> played = [];
  int pauseCalls = 0;
  int resumeCalls = 0;
  int stopCalls = 0;
  bool disposed = false;

  /// Call from tests to simulate the real player's status transitions.
  void emit(RadioPlaybackState s) {
    _current = s;
    _controller.add(s);
  }

  @override
  Stream<RadioPlaybackState> get state => _controller.stream;

  @override
  RadioPlaybackState get current => _current;

  @override
  Future<void> play(Station station) async {
    played.add(station);
    emit(
      RadioPlaybackState(status: RadioPlaybackStatus.playing, station: station),
    );
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    if (_current.station != null) {
      emit(
        RadioPlaybackState(
          status: RadioPlaybackStatus.paused,
          station: _current.station,
        ),
      );
    }
  }

  @override
  Future<void> resume() async {
    resumeCalls++;
    if (_current.station != null) {
      emit(
        RadioPlaybackState(
          status: RadioPlaybackStatus.playing,
          station: _current.station,
        ),
      );
    }
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    emit(const RadioPlaybackState(status: RadioPlaybackStatus.idle));
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _controller.close();
  }
}
