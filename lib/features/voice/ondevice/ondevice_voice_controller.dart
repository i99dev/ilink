import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../kernel/settings/app_settings.dart';
import '../../../kernel/services/optional_services.dart';
import '../../_car_domain/command/registry.dart';
import '../../workflow/engine/workflow_engine_provider.dart';
import '../state/tool_router.dart';
import '../state/voice_access_gate.dart';
import '../state/voice_controller.dart';
import 'local_intent_matcher.dart';
import 'moonshine_fallback_engine.dart';
import 'on_device_recognizer.dart';
import 'ondevice_voice_bridge.dart';
import 'ondevice_voice_router.dart';
import 'voice_grammar.dart';
import 'voice_model_catalog.dart';

/// Lifecycle phase of the always-on on-device detector.
enum OnDeviceVoiceStatus {
  /// Not armed.
  idle,

  noModel,

  /// Downloading + unpacking the language model (progress in
  /// [OnDeviceVoiceState.downloadProgress]).
  downloading,

  /// Always-on wake loop idle — listening for "Hey BYD". Ambient; the mic
  /// surface stays calm (no pulse) so an armed car isn't visually "busy".
  armed,

  listening,

  /// Provisioning failed (download/unpack error) — surfaced so the picker
  /// can show "failed, tap to retry".
  error,
}

/// Snapshot the UI watches: the phase, which language it's for, and live
/// download progress so the Settings picker can show a bar + "ready".
@immutable
class OnDeviceVoiceState {
  const OnDeviceVoiceState(
    this.status, {
    this.lang,
    this.downloadProgress,
    this.error,
  });

  final OnDeviceVoiceStatus status;

  /// Language tag this state is about (the active selection).
  final String? lang;

  /// 0..1 while [OnDeviceVoiceStatus.downloading]; null = indeterminate
  /// (server didn't report Content-Length) or not downloading.
  final double? downloadProgress;

  /// Failure reason when [status] is [OnDeviceVoiceStatus.error].
  final String? error;

  @override
  bool operator ==(Object other) =>
      other is OnDeviceVoiceState &&
      other.status == status &&
      other.lang == lang &&
      other.downloadProgress == downloadProgress &&
      other.error == error;

  @override
  int get hashCode => Object.hash(status, lang, downloadProgress, error);
}

class OnDeviceVoiceController extends Notifier<OnDeviceVoiceState> {
  PlatformOnDeviceRecognizer? _recognizer;
  OnDeviceVoiceRouter? _router;
  StreamSubscription<OnDeviceResult>? _sub;
  StreamSubscription<({int received, int total})>? _progressSub;

  bool _armed = false;

  /// Arabic second-tier engine, non-null only while an entry with a Moonshine
  /// [VoiceModelFallback] is armed. Vosk stays primary; this runs solely on a
  /// native `[unk]` miss (see [_onUtteranceMiss]).
  MoonshineFallbackEngine? _fallback;
  StreamSubscription<Uint8List>? _missSub;

  bool _manualTurn = false;
  Timer? _manualTimeout;

  @override
  OnDeviceVoiceState build() {
    ref.listen<bool>(serviceEnabledProvider(OptionalService.downloads), (
      _,
      enabled,
    ) {
      final recognizer = _recognizer ??= PlatformOnDeviceRecognizer();
      unawaited(
        recognizer.setModelDownloadsEnabled(enabled).catchError((Object _) {}),
      );
    }, fireImmediately: true);
    ref.onDispose(() {
      unawaited(
        _recognizer?.setModelDownloadsEnabled(false).catchError((Object _) {}),
      );
      _manualTimeout?.cancel();
      unawaited(_sub?.cancel());
      unawaited(_progressSub?.cancel());
      unawaited(_missSub?.cancel());

      _fallback?.dispose();
      unawaited(_recognizer?.dispose());
    });
    // Reactive grammar: when the set of automation voice phrases changes
    // (a "When I say…" workflow saved/removed/toggled), re-apply the Vosk
    // grammar so the new phrase is heard without a voice off/on toggle.
    // Only acts while actively armed; ignored no-op changes are filtered.
    ref.listen<Set<String>>(activeVoicePhrasesProvider, (prev, next) {
      if (prev != null && setEquals(prev, next)) return;
      unawaited(_reapplyGrammar());
    });
    return const OnDeviceVoiceState(OnDeviceVoiceStatus.idle);
  }

  /// Arm the detector for the user's selected language. Downloads that
  /// language's Vosk model from the catalog if missing (idempotent by
  /// version, so a language switch re-downloads) with live progress, then
  /// builds the grammar in that language.
  Future<void> arm() async {
    if (_armed) return;
    final recognizer = _recognizer ??= PlatformOnDeviceRecognizer();
    final lang =
        ref.read(settingsProvider).value?.voiceModelLang ?? kDefaultVoiceLang;
    final entry = voiceModelFor(lang);
    if (entry == null) {
      state = OnDeviceVoiceState(OnDeviceVoiceStatus.noModel, lang: lang);
      return;
    }
    // Ensure the active language's model is present (downloads + unpacks with
    // live progress; instant if already at this version). Bails on failure.
    if (!await _provisionActiveModel(lang, entry, recognizer)) return;
    final grammar = _buildCurrentGrammar(lang);
    _router = OnDeviceVoiceRouter(grammar, LocalIntentMatcher(grammar));
    try {
      await recognizer.applyGrammar(grammar, version: entry.version);
    } catch (e) {
      if (kDebugMode) debugPrint('ondevice voice: applyGrammar failed: $e');
      state = OnDeviceVoiceState(
        OnDeviceVoiceStatus.error,
        lang: lang,
        error: 'load_failed',
      );
      return;
    }
    await _sub?.cancel(); // a manual turn may have already attached one
    _sub = recognizer.results.listen(_onResult, onError: _onRecognitionError);
    // Two-tier (Arabic): provision + arm the Moonshine fallback BEFORE start()
    // so the native capture loop buffers PCM from the very first utterance.
    // Best-effort — a fallback failure must never block the Vosk primary.
    await _setupFallback(entry, recognizer);
    await recognizer.start();
    _armed = true;
    state = OnDeviceVoiceState(OnDeviceVoiceStatus.armed, lang: lang);
  }

  /// Provision + load the Moonshine fallback for [entry] when it declares one
  /// (Arabic). Tears down any previous fallback first. Silent on failure:
  /// disables native buffering and leaves the car Vosk-only.
  Future<void> _setupFallback(
    VoiceModelEntry entry,
    PlatformOnDeviceRecognizer recognizer,
  ) async {
    // Tear down a prior fallback (e.g. language switched away from Arabic).
    await _missSub?.cancel();
    _missSub = null;
    _fallback?.dispose();
    _fallback = null;

    final fb = entry.fallback;
    if (fb == null) {
      await recognizer.setFallbackEnabled(false);
      return;
    }
    try {
      // The custom fallback bundle has no public upstream equivalent.
      // Existing local models remain usable without a hosted download.
      final ready = await recognizer.fallbackModelPresent(version: fb.version);
      if (!ready) {
        await recognizer.setFallbackEnabled(false);
        return;
      }
      final dir = await recognizer.fallbackModelPath(version: fb.version);
      if (dir == null) {
        await recognizer.setFallbackEnabled(false);
        return;
      }
      final engine = MoonshineFallbackEngine.load(dir: dir);
      if (engine == null) {
        await recognizer.setFallbackEnabled(false);
        return;
      }
      _fallback = engine;
      _missSub = recognizer.utteranceMisses.listen(_onUtteranceMiss);
      await recognizer.setFallbackEnabled(true);
    } catch (e) {
      if (kDebugMode) debugPrint('ondevice voice: fallback setup failed: $e');
      await recognizer.setFallbackEnabled(false);
    }
  }

  /// A Vosk `[unk]` utterance arrived as raw PCM. Run Moonshine over it and, if
  /// it yields text, feed it through the SAME result path a Vosk hit takes —
  /// so the router/matcher resolve a (dialectal) command with no other change.
  ///
  /// NOTE: [MoonshineFallbackEngine.transcribe] is a blocking native decode
  /// (~0.5–1s). It runs only on a miss, never on the hot path; moving it to a
  /// dedicated isolate is a follow-up if the brief jank shows on-car.
  void _onUtteranceMiss(Uint8List pcm) {
    final engine = _fallback;
    if (engine == null) return;
    final String text;
    try {
      text = engine.transcribe(pcm);
    } catch (e) {
      if (kDebugMode) debugPrint('ondevice voice: moonshine decode failed: $e');
      return;
    }
    if (text.isEmpty) return;
    _onResult(OnDeviceResult(text: text, isFinal: true));
  }

  /// Build the on-device grammar for [lang] from the ONE command registry +
  /// the driver's wake phrases + the active automation voice phrases
  /// ([activeVoicePhrasesProvider]). Centralized so arm(), the manual-turn
  /// path, and the reactive re-apply stay in lockstep.
  VoiceGrammar _buildCurrentGrammar(String lang) {
    final router = ref.read(voiceToolRouterProvider);
    return VoiceGrammar.build(
      registry: ref.read(commandRegistryProvider),
      handles: router.handles,
      langCode: lang,
      // Driver-added wake phrases (presets + free-text) — additive.
      extraWakePhrases:
          ref.read(settingsProvider).value?.customWakePhrases ?? const [],
      // Driver-added AI ("Hey AI") wake phrases — additive, same as above.
      // "When I say…" automation phrases so Vosk can hear them; the engine
      // matches + fires them (checked first in _onResult).
      extraCommandPhrases: ref.read(activeVoicePhrasesProvider).toList(),
    );
  }

  Future<void> _reapplyGrammar() async {
    if (state.status != OnDeviceVoiceStatus.armed) return;
    final recognizer = _recognizer;
    if (recognizer == null) return;
    final lang =
        ref.read(settingsProvider).value?.voiceModelLang ?? kDefaultVoiceLang;
    final entry = voiceModelFor(lang);
    if (entry == null) return;
    final grammar = _buildCurrentGrammar(lang);
    _router = OnDeviceVoiceRouter(grammar, LocalIntentMatcher(grammar));
    try {
      await recognizer.stop();
      await recognizer.applyGrammar(grammar, version: entry.version);
      await recognizer.start();
    } catch (e) {
      if (kDebugMode) debugPrint('ondevice voice: grammar re-apply failed: $e');
    }
  }

  /// Download + unpack the active language's model (live progress, `error` on
  /// failure). Returns true when ready. Version-idempotent: instant if already
  /// at [entry]'s version. Shared by [arm] (always-on) and [ensureModelReady]
  /// (on-device-only provisioning without arming).
  Future<bool> _provisionActiveModel(
    String lang,
    VoiceModelEntry entry,
    PlatformOnDeviceRecognizer recognizer,
  ) async {
    state = OnDeviceVoiceState(
      OnDeviceVoiceStatus.downloading,
      lang: lang,
      downloadProgress: 0,
    );
    await _progressSub?.cancel();
    _progressSub = recognizer.provisionProgress.listen((p) {
      // Only reflect progress while still in the downloading phase.
      if (state.status != OnDeviceVoiceStatus.downloading) return;
      state = OnDeviceVoiceState(
        OnDeviceVoiceStatus.downloading,
        lang: lang,
        downloadProgress: p.total > 0 ? (p.received / p.total) : null,
      );
    });
    final provisioned = await recognizer.provisionModel(
      url: entry.url,
      version: entry.version,
      allowNetwork: ref.read(serviceEnabledProvider(OptionalService.downloads)),
    );
    if (!ref.mounted) return false;
    await _progressSub?.cancel();
    _progressSub = null;
    if (!provisioned) {
      state = OnDeviceVoiceState(
        ref.read(serviceEnabledProvider(OptionalService.downloads))
            ? OnDeviceVoiceStatus.error
            : OnDeviceVoiceStatus.noModel,
        lang: lang,
        error: ref.read(serviceEnabledProvider(OptionalService.downloads))
            ? 'download_failed'
            : 'local_model_missing',
      );
      return false;
    }
    return true;
  }

  /// True iff the active on-device model is already downloaded. Cheap probe
  /// the manual mic uses to tell "model missing → provision" from "busy".
  Future<bool> isModelPresent() async {
    final lang =
        ref.read(settingsProvider).value?.voiceModelLang ?? kDefaultVoiceLang;
    final entry = voiceModelFor(lang);
    if (entry == null) return false;
    final recognizer = _recognizer ??= PlatformOnDeviceRecognizer();
    return recognizer.modelPresent(version: entry.version);
  }

  Future<bool> ensureModelReady() async {
    if (_armed) return true; // arm() already provisioned it
    if (state.status == OnDeviceVoiceStatus.downloading) return false;
    final lang =
        ref.read(settingsProvider).value?.voiceModelLang ?? kDefaultVoiceLang;
    final entry = voiceModelFor(lang);
    if (entry == null) {
      state = OnDeviceVoiceState(OnDeviceVoiceStatus.noModel, lang: lang);
      return false;
    }
    final recognizer = _recognizer ??= PlatformOnDeviceRecognizer();
    if (await recognizer.modelPresent(version: entry.version)) return true;
    final ok = await _provisionActiveModel(lang, entry, recognizer);
    // Settle back to idle (not armed) so the manual mic can take the next turn.
    if (ok) state = const OnDeviceVoiceState(OnDeviceVoiceStatus.idle);
    return ok;
  }

  /// Cancel an in-flight MANUAL (push-to-talk) capture — used when the driver
  /// taps the mic again to stop the turn they just started. Deliberately does
  /// NOT tear down the always-on "Hey BYD" wake loop: if it's armed the
  /// recognizer never stopped, so we just drop back to wake-gated listening;
  /// otherwise we release the mic and go idle. No-op when no manual turn is in
  /// flight (the caller can fire this unconditionally on a stop tap).
  Future<void> cancelManualTurn() async {
    if (!_manualTurn) return;
    _manualTimeout?.cancel();
    _manualTimeout = null;
    _manualTurn = false;
    if (_armed) {
      state = OnDeviceVoiceState(OnDeviceVoiceStatus.armed, lang: state.lang);
    } else {
      await _recognizer?.stop();
      state = const OnDeviceVoiceState(OnDeviceVoiceStatus.idle);
    }
  }

  /// Stop listening + release the mic.
  Future<void> disarm() async {
    _armed = false;
    _manualTurn = false;
    _manualTimeout?.cancel();
    _manualTimeout = null;
    await _sub?.cancel();
    _sub = null;
    await _progressSub?.cancel();
    _progressSub = null;

    await _recognizer?.stop();
    state = const OnDeviceVoiceState(OnDeviceVoiceStatus.idle);
  }

  void _onRecognitionError(Object error, StackTrace stack) {
    if (!ref.mounted) return;
    _manualTimeout?.cancel();
    _manualTimeout = null;
    _manualTurn = false;
    _armed = false;
    unawaited(_recognizer?.stop().catchError((Object _) {}));
    state = OnDeviceVoiceState(
      OnDeviceVoiceStatus.error,
      lang: state.lang,
      error: 'Microphone or local speech recognition failed. Try again.',
    );
  }

  void _onResult(OnDeviceResult r) {
    // Native callbacks already queued when stop/error released the microphone
    // must not dispatch a command or trigger an automation afterwards.
    if (!r.isFinal || (!_armed && !_manualTurn)) return;

    // ── Automation voice triggers ("When I say…") take precedence ──
    // Check the workflow engine FIRST: if the utterance matches an armed
    // voice automation, fire it and stop — don't also run a built-in
    // command for the same words. Same ToolRouter/gates apply inside the
    // engine's action dispatch. Returns the automation's name on a match.
    final firedWorkflow = ref
        .read(workflowEngineProvider)
        .onVoicePhrase(r.text);
    if (firedWorkflow != null) {
      _feedbackChip('▶ $firedWorkflow');
      if (_manualTurn) {
        _manualTimeout?.cancel();
        _manualTimeout = null;
        _manualTurn = false;
      }
      if (_armed) {
        state = OnDeviceVoiceState(OnDeviceVoiceStatus.armed, lang: state.lang);
      } else {
        unawaited(_recognizer?.stop());
        state = const OnDeviceVoiceState(OnDeviceVoiceStatus.idle);
      }
      return;
    }

    // ── Manual push-to-talk (mic / steering-wheel, no wake word) ──
    if (_manualTurn) {
      _manualTimeout?.cancel();
      _manualTimeout = null;
      _manualTurn = false;
      // Consume the capture mode (a "Hey BYD" window is offline-only; a tap is
      // not). Reset so the next turn starts clean.
      final decision = _router?.decideManual(r.text);
      switch (decision) {
        case OnDeviceLocalCommand(:final hit):
          unawaited(_dispatchLocalCommand(hit));
          if (_armed) {
            // Tap preempted the wake loop — the recognizer never stopped;
            // resume wake-gated listening for the next "Hey BYD".
            state = OnDeviceVoiceState(
              OnDeviceVoiceStatus.armed,
              lang: state.lang,
            );
          } else {
            unawaited(_recognizer?.stop());
            state = const OnDeviceVoiceState(OnDeviceVoiceStatus.idle);
          }
        case OnDeviceWakeTurn():
        case OnDeviceIgnore():
        case null:
          _feedbackChip("Didn't catch a command — try again");
          if (_armed) {
            // Wake loop is live — return to wake-gated listening.
            state = OnDeviceVoiceState(
              OnDeviceVoiceStatus.armed,
              lang: state.lang,
            );
          } else {
            unawaited(_recognizer?.stop());
            state = const OnDeviceVoiceState(OnDeviceVoiceStatus.idle);
          }
      }
      return;
    }

    // ── Always-on Hey BYD loop (wake-gated) ──
    if (!_armed) return;
    final decision = _router?.decide(r.text);
    switch (decision) {
      case OnDeviceLocalCommand(:final hit):
        unawaited(_dispatchLocalCommand(hit));
      case OnDeviceWakeTurn():
        _beginArmedManualCapture(offlineOnly: true);
      case OnDeviceIgnore():
      case null:
        break;
    }
  }

  /// Surface a short, glanceable voice chip (no spoken reply) — e.g. "didn't
  /// catch a command" or "AI is off". Reuses the same transient chip the
  /// dispatch path uses, with a distinct haptic. Does NOT touch the recognizer
  /// or state — the caller decides whether to stay armed or settle to idle.
  void _feedbackChip(String reason, {String commandId = 'voice.no_match'}) {
    ref
        .read(recentToolDispatchProvider.notifier)
        .failLocalCommand(commandId: commandId, reason: reason);
    unawaited(HapticFeedback.heavyImpact());
  }

  void _beginArmedManualCapture({bool offlineOnly = false}) {
    _manualTurn = true;
    _armManualTimeout();
    state = OnDeviceVoiceState(OnDeviceVoiceStatus.listening, lang: state.lang);
  }

  /// Dispatch an on-device car command and confirm it NON-VERBALLY. One place
  /// both turn paths (manual press + always-on "Hey BYD") funnel through.
  ///
  /// We AWAIT the dispatch and act on the REAL result — recognizing a command
  /// is not the same as the car actuating it. A gate rejection (e.g.
  /// `UNSAFE_WHILE_MOVING`), an unsupported action, or a daemon error must NOT
  /// show a success chip (that was the "voice works but the window doesn't
  /// open" bug). On success: glanceable chip + light tick + earcon. On
  /// failure: a warning chip stating the reason, distinct haptic, no earcon.
  Future<void> _dispatchLocalCommand(CommandHit hit) async {
    // Friendly label from the ONE registry — same text as the command tile.
    final label = ref.read(commandRegistryProvider)[hit.commandId]?.label;
    final notifier = ref.read(recentToolDispatchProvider.notifier);
    // The whole dispatch is wrapped: a router that THROWS (car/daemon not
    // reachable, transport error) must NOT fail silently. This call runs
    // `unawaited`, so an uncaught throw would be swallowed — the mic closes
    // with no chip and no action, which reads exactly like a crash ("nothing
    // happened, no chip"). Always surface a chip: success, gate/daemon error
    // map, OR a thrown exception.
    try {
      final result = await ref
          .read(voiceToolRouterProvider)
          .dispatch(hit.commandId, hit.args);
      if (result['error'] != null) {
        notifier.failLocalCommand(
          commandId: hit.commandId,
          label: label,
          reason: _friendlyDispatchError(result),
        );
        unawaited(HapticFeedback.heavyImpact()); // distinct "didn't happen" cue
        return;
      }
      notifier.confirmLocalCommand(
        commandId: hit.commandId,
        arguments: hit.args,
        label: label,
      );
      // Eyes-free confirmation: a light tick + the system click earcon. No
      // spoken sentence — the chip + sound say "done" without the chatter.
      unawaited(HapticFeedback.lightImpact());
      unawaited(SystemSound.play(SystemSoundType.click));
    } catch (e) {
      if (kDebugMode) debugPrint('ondevice dispatch threw: $e');
      notifier.failLocalCommand(
        commandId: hit.commandId,
        label: label,
        reason: "Couldn't reach the car — try again",
      );
      unawaited(HapticFeedback.heavyImpact());
    }
  }

  /// Map a dispatch error map to a short driver-facing reason for the chip.
  String _friendlyDispatchError(Map<String, dynamic> result) {
    final code = (result['code'] ?? '').toString();
    switch (code) {
      case 'UNSAFE_WHILE_MOVING':
        return 'Not safe while moving';
      case 'ACTION_UNSUPPORTED':
        return 'Not available on this car';
      case 'RATE_LIMITED':
        return 'Too many requests — try again';
      case 'INTEGRITY_UNHEALTHY':
        return 'Blocked — security check';
      default:
        final msg = (result['error'] ?? '').toString();
        return msg.isEmpty ? "Couldn't run that" : "Couldn't run that — $msg";
    }
  }

  Future<bool> startManualTurn({bool offlineOnly = true}) async {
    if (_manualTurn) return false;
    if (state.status == OnDeviceVoiceStatus.downloading) {
      return false;
    }
    if (_armed) {
      _beginArmedManualCapture(offlineOnly: offlineOnly);
      return true;
    }
    try {
      final lang =
          ref.read(settingsProvider).value?.voiceModelLang ?? kDefaultVoiceLang;
      final entry = voiceModelFor(lang);
      if (entry == null) return false;
      final recognizer = _recognizer ??= PlatformOnDeviceRecognizer();
      if (!await recognizer.modelPresent(version: entry.version)) return false;
      // Build the grammar once if Hey BYD never armed it (no download).
      if (_router == null) {
        final grammar = _buildCurrentGrammar(lang);
        _router = OnDeviceVoiceRouter(grammar, LocalIntentMatcher(grammar));
        await recognizer.applyGrammar(grammar, version: entry.version);
      }
      await _sub?.cancel();
      _sub = recognizer.results.listen(_onResult, onError: _onRecognitionError);
      _manualTurn = true;
      state = OnDeviceVoiceState(OnDeviceVoiceStatus.listening, lang: lang);
      await recognizer.start();
      _armManualTimeout();
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('ondevice manual turn failed: $e');
      _manualTurn = false;
      _manualTimeout?.cancel();
      return false;
    }
  }

  void _armManualTimeout() {
    _manualTimeout?.cancel();
    _manualTimeout = Timer(const Duration(seconds: 6), () {
      if (!_manualTurn) return;
      _manualTurn = false;
      if (_armed) {
        // Wake loop is live (silent "Hey BYD" or armed tap) → just resume
        // wake-gated listening; no chip on a silent timeout.
        state = OnDeviceVoiceState(OnDeviceVoiceStatus.armed, lang: state.lang);
      } else {
        _feedbackChip("Didn't catch a command — try again");
        unawaited(_recognizer?.stop());
        state = const OnDeviceVoiceState(OnDeviceVoiceStatus.idle);
      }
    });
  }
}

final onDeviceVoiceControllerProvider =
    NotifierProvider<OnDeviceVoiceController, OnDeviceVoiceState>(
      OnDeviceVoiceController.new,
    );

Future<void> startVoiceCommandOnly(BuildContext context, WidgetRef ref) async {
  if (resolveVoiceAccess(ref) is! VoiceAccessUnlocked) return;
  if (!await ensureMicPermission(context, ref) || !context.mounted) return;
  await ref.read(voiceControllerProvider.notifier).start();
}
