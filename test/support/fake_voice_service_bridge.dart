import 'dart:async';

import 'package:ilink/features/voice/data/voice_service_bridge.dart';

/// Test double for [VoiceServiceBridge]. Records every call to start/stop
/// and lets the test inject platform events.
class FakeVoiceServiceBridge implements VoiceServiceBridge {
  final _eventsCtrl = StreamController<VoiceEventType>.broadcast();
  final List<String> calls = [];

  void fire(VoiceEventType e) => _eventsCtrl.add(e);
  Future<void> dispose() => _eventsCtrl.close();

  @override
  Stream<VoiceEventType> get events => _eventsCtrl.stream;

  @override
  Future<void> startService() async {
    calls.add('startService');
  }

  @override
  Future<void> stopService() async {
    calls.add('stopService');
  }

  @override
  Future<void> setNotificationText(String text) async {
    calls.add('setNotificationText:$text');
  }

  @override
  Future<void> setVoicePhase(String phase, String? tool) async {
    calls.add('setVoicePhase:$phase:${tool ?? ''}');
  }
}
