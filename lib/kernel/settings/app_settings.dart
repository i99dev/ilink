import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Re-export so existing imports of `app_settings.dart` keep
// resolving `VadNoisePreset` — the canonical enum lives with the
// VAD state machine.
export 'package:ilink/kernel/settings/vad_preset.dart' show VadNoisePreset;

import '../config/config_provider.dart';
import 'package:ilink/sdk/car/identity/car_device_id.dart';
import 'package:ilink/kernel/settings/vad_preset.dart' show VadNoisePreset;

enum VoiceVadMode { semantic, server, ptt, clientLevel }

/// Parses a persisted `.name` string back to [VoiceVadMode]. Unknown /
/// legacy values fall through to the default ([VoiceVadMode.semantic]).
VoiceVadMode parseVoiceVadMode(String? raw) {
  if (raw == null) return VoiceVadMode.semantic;
  for (final m in VoiceVadMode.values) {
    if (m.name == raw) return m;
  }
  return VoiceVadMode.semantic;
}

VadNoisePreset _parseVadNoisePreset(String? raw) {
  if (raw == null) return VadNoisePreset.normal;
  for (final p in VadNoisePreset.values) {
    if (p.name == raw) return p;
  }
  return VadNoisePreset.normal;
}

/// Which side the driver sits on. Drives the position of the floating
/// mic (and any future driver-anchored UI) so the primary control sits
/// within the driver's natural reach instead of forcing them to cross
/// arms over the wheel.
///
///  * [left] — LHD markets (USA, EU, China). Mic anchors bottom-left.
///  * [right] — RHD markets (UK, Australia, Japan, India, ...). Mic
///    anchors bottom-right.
enum DriverSide { left, right }

DriverSide _parseDriverSide(String? raw) {
  if (raw == null) return DriverSide.left;
  for (final s in DriverSide.values) {
    if (s.name == raw) return s;
  }
  return DriverSide.left;
}

/// How the voice AI decides which language the driver is speaking.
///  * [fixed] — recognize only the selected [AppSettings.voiceLanguages]
///    (or the tier default when none are picked).
///  * [auto] — STT auto-detects the spoken language (Chirp 3
///    `language_codes: ["auto"]`); the assistant replies in kind and the
///    car speaks it with the chosen personality's matching variant.
enum VoiceLanguageMode { fixed, auto }

VoiceLanguageMode parseVoiceLanguageMode(String? raw) {
  if (raw == null) return VoiceLanguageMode.fixed;
  for (final m in VoiceLanguageMode.values) {
    if (m.name == raw) return m;
  }
  return VoiceLanguageMode.fixed;
}

/// Parses the persisted `.name` of a [ThemeMode]. Unknown / legacy
/// values fall through to `system` — matches
/// [AppSettings.defaultThemeMode].
ThemeMode parseThemeMode(String? raw) {
  if (raw == null) return ThemeMode.system;
  for (final m in ThemeMode.values) {
    if (m.name == raw) return m;
  }
  return ThemeMode.system;
}

class AppSettings {
  const AppSettings({
    required this.deviceId,
    this.openAiVoice = defaultOpenAiVoice,
    this.voiceVadMode = defaultVoiceVadMode,
    this.voiceVadThreshold = defaultVoiceVadThreshold,
    this.voiceAllowInterrupt = false,
    this.voicePersonality = defaultVoicePersonality,
    this.voiceLanguages = const [],
    this.voiceLanguageMode = defaultVoiceLanguageMode,
    this.vadNoisePreset = VadNoisePreset.normal,
    this.vadSilenceHangMs = defaultVadSilenceHangMs,
    this.vadMinUtteranceMs = defaultVadMinUtteranceMs,
    this.vadMaxUtteranceMs = defaultVadMaxUtteranceMs,
    this.audioTelemetryConsent = false,
    this.devCarControlsEnabled = false,
    this.flightTestModeEnabled = false,
    this.voiceAssistantEnabled = defaultVoiceAssistantEnabled,
    this.wakeWordEnabled = false,
    this.voiceModelLang = 'en-us',
    this.customWakePhrases = const [],
    this.floatingAppShortcuts = const [],
    this.themeMode = defaultThemeMode,
    this.activeThemeId = defaultActiveThemeId,
    this.driverSide = defaultDriverSide,
    this.bubbleEnabled = defaultBubbleEnabled,
    this.onboardingCompletedAt,
    this.heyBydIntroSeenAt,
  });

  // VAD timing defaults — see `features/voice/domain/voice_activity_detector.dart`
  // for rationale. Production-tunable via env (rare); not in the Settings UI.
  //
  // silenceHangMs: 600 ms lets the driver pause mid-question to
  // think without the mic closing on them. Sub-300 ms is the 2026
  // snappy target per LiveKit / Picovoice, but in practice natural
  // speech has 300–500 ms gaps between clauses ("turn on the AC …
  // and play some music"), and closing the turn inside that gap
  // makes the assistant feel like it's interrupting. 600 ms at
  // 16 kHz / 80 ms PCM frames is ~8 chunks — still well under a
  // second, so short commands ("lock doors") still feel instant.
  // LevelVad's adaptive logic bumps this to 700 ms for genuinely
  // long dictation (>5 s of active speech).
  static const defaultVadSilenceHangMs = 600;
  static const defaultVadMinUtteranceMs = 200;
  static const defaultVadMaxUtteranceMs = 10000;

  static const defaultOpenAiVoice = 'alloy';

  /// Default is [ThemeMode.system] — the app follows the OS
  /// light/dark preference unless the user explicitly picks a mode
  /// from Settings. On head units without an OS-level setting, Flutter
  /// falls back to light (Material default); the user can force dark
  /// from the picker.
  static const defaultThemeMode = ThemeMode.system;

  /// Default active theme — empty string = the built-in default look
  /// (Midnight dark / Daylight light, picked by [themeMode]). A
  /// non-empty value is a catalog / built-in theme id resolved by
  /// `activeThemeProvider`. Empty by default so the theming feature
  /// ships **inert** — zero visual change until the user picks a theme
  /// (THEMES_CONTRACT.md §7).
  static const defaultActiveThemeId = '';

  /// Floating bubble ("chat head") default — ON (shown when the app is
  /// minimized/backgrounded). The driver opts OUT from Settings → Appearance.
  /// Mirrored to the native `BubbleOverlayService` (which actually decides
  /// whether to spawn the overlay on background) via `bubble_overlay.dart`.
  static const defaultBubbleEnabled = true;

  /// Default driver side — left (USA, EU, China; covers most markets).
  /// Users in RHD markets flip this to [DriverSide.right] from Settings
  /// → Display → Driver side, which moves the floating mic to the
  /// bottom-right corner.
  static const defaultDriverSide = DriverSide.left;

  /// Voice assistant default — ON. The user opts OUT, not in (the
  /// feature is discoverable in the default state). Off → every mic
  /// surface hides + the access gate refuses to start. Independent of
  /// [voiceVadMode]: VAD mode picks the trigger style WHEN voice is
  /// on, this picks whether voice is on at all. See `voice_access_gate.dart`
  /// for the canonical visibility check.
  static const defaultVoiceAssistantEnabled = true;

  static const defaultVoiceVadMode = VoiceVadMode.semantic;

  /// Driver-selected TTS voice. Empty ([defaultVoicePersonality]) =
  /// operator/pipeline default voice (feature ships inert). A non-empty
  /// value is a Chirp 3 HD personality name (e.g. "Charon"); the car
  /// resolves the per-turn `{lang}-Chirp3-HD-{personality}` variant.
  static const defaultVoicePersonality = '';

  /// Default language mode — [VoiceLanguageMode.fixed] so a fresh
  /// install keeps the single-language path until the driver opts into
  /// multi-language or auto-detect from the AI-config panel.
  static const defaultVoiceLanguageMode = VoiceLanguageMode.fixed;

  /// Only used when `voiceVadMode == VoiceVadMode.server`. Higher = less
  /// sensitive. OpenAI default is 0.5; we default higher because the car
  /// cabin is noisy.
  static const defaultVoiceVadThreshold = 0.7;

  /// Voices supported by the OpenAI Realtime API. Presented in the
  /// settings page as a dropdown.
  static const availableVoices = <String>[
    'alloy',
    'ash',
    'ballad',
    'coral',
    'echo',
    'sage',
    'shimmer',
    'verse',
  ];

  /// Namespace for data created locally on this device.
  String get userId => 'local-device';

  /// Prefixed canonical device id — `<brand>:<native_id>` per the
  /// rename contract. For BYD: `byd:BYD...` where the native suffix
  /// comes from `persist.sys.cloud.last_vin` (NOT the chassis VIN —
  /// see [DeviceFingerprint] for provenance).
  final String deviceId;

  final String openAiVoice;
  final VoiceVadMode voiceVadMode;
  final double voiceVadThreshold;

  /// If true, any loud noise (door, cabin chatter) cuts off the AI
  /// mid-answer. Default false = AI finishes speaking before listening again.
  final bool voiceAllowInterrupt;

  /// Driver-selected voice personality (Chirp 3 HD name, e.g. "Charon").
  /// Empty = operator/pipeline default. Sent on /voice/session as
  /// `voice_personality`.
  final String voicePersonality;

  /// Locales the driver enabled for the voice AI (e.g. `['en-US',
  /// 'ar-XA']`). Empty = the tier default. Sent on /voice/session as
  /// `languages`; drives STT `language_codes`.
  final List<String> voiceLanguages;

  /// Whether STT auto-detects the spoken language ([VoiceLanguageMode.auto])
  /// or is restricted to [voiceLanguages] ([VoiceLanguageMode.fixed]).
  final VoiceLanguageMode voiceLanguageMode;

  /// Noise-environment preset for [VoiceVadMode.clientLevel]. Three
  /// fixed presets (quiet/normal/noisy) bias the on/off thresholds
  /// above the auto-tracked ambient floor — production users pick one
  /// of three rather than tweaking dBFS dials.
  final VadNoisePreset vadNoisePreset;

  /// Silence-hang in ms before the level VAD fires SpeechEnded. Default
  /// 800. The VAD adapts in-flight to 1200 ms once the active speech
  /// run crosses 3 s — this field is just the steady-state floor.
  final int vadSilenceHangMs;

  /// Speech runs shorter than this (ms, excluding trailing silence) are
  /// dropped as noise bursts. Default 200.
  final int vadMinUtteranceMs;

  /// Hard cap (ms) on a single utterance. Default 10s — past this the
  /// VAD force-flushes with [SpeechEnded.maxLengthHit]=true so the
  /// controller surfaces a "shorter please" toast.
  final int vadMaxUtteranceMs;

  /// Opt-in: "Help us improve voice" toggle in Settings. When true,
  /// the audio telemetry sampler may upload a fraction of each
  /// turn's audio to the backend for offline review (P3). Off by
  /// default — every upload requires explicit consent.
  final bool audioTelemetryConsent;

  /// Opt-in flag. When `false` (production default), the app shows only
  /// the radio surface and hides every car-actuator UI / voice tool. When
  /// `true`, the home dashboard re-exposes windows + quick-actions, the
  /// climate screen appears in the pill dock, a diagnostic Compat screen
  /// appears, and the full car-command tool manifest is sent to the
  /// voice model. Car commands are only verified on the Leopard 8 —
  /// other BYD models may show errors until the compat matrix is built.
  final bool devCarControlsEnabled;

  /// Opt-in flag for "flight test mode" — surfaces a dedicated tab on
  /// the mini-apps screen listing only the beta builds the user is
  /// invited to test. Default `false`; testers turn it on from
  /// Settings → Developer once a developer has invited them. The
  /// toggle is purely additive (the existing My Apps / Store tabs
  /// keep their BETA badges); this just gives flight testers a
  /// focused surface.
  ///
  /// Per-device preference, persisted in SharedPreferences. Survives
  /// sign-out so a tester signing out and back in keeps the toggle
  /// state — same convention as `themeMode`.
  final bool flightTestModeEnabled;

  /// Master kill-switch for the voice assistant. When `false`, every
  /// mic surface hides (FloatingMic, home VoiceCard, hardware-key,
  /// voice intent) and the access gate refuses to start a session.
  /// Default `true` so the feature stays discoverable; users opt OUT
  /// from Settings → Appearance.
  ///
  /// Orthogonal to [voiceVadMode]: this answers "do I want voice at
  /// all on this car"; that answers "WHEN voice is on, how do I
  /// trigger it" (PTT vs always-listen).
  final bool voiceAssistantEnabled;

  /// Always-on "Hey BYD" hands-free wake word (on-device Vosk fast-path).
  /// Default OFF — the feature is inert until a Kaldi model is provisioned
  /// AND this is enabled (user toggle / fleet config). Independent of
  /// [voiceAssistantEnabled] (which governs the manual-trigger assistant):
  /// a driver may keep manual voice but opt out of always-listening for
  /// privacy. Gated this way so shipping the code changes nothing on the
  /// fleet until deliberately turned on.
  final bool wakeWordEnabled;

  final String voiceModelLang;

  /// Extra wake phrases the driver added — presets they picked plus any
  /// free-text they typed — ADDITIVE to the built-in per-language defaults
  /// ([wakePhrasesByLang]), so "Hey BYD" never stops working. Each must be
  /// recognizable by the ACTIVE Vosk model: written in that model's script,
  /// using words in its lexicon (out-of-vocabulary phrases silently never
  /// fire). Plumbed into the on-device grammar via
  /// `VoiceGrammar.build(extraWakePhrases: …)`. Empty by default.
  final List<String> customWakePhrases;

  /// Package names the driver pinned as standalone floating launch buttons
  /// (independent draggable overlay icons that float over every app — tap to
  /// open that app directly, no app-list navigation). Empty = the floating
  /// launcher is off. Pushed to the native `AppShortcutOverlayService` via
  /// `app_shortcut_overlay.dart`.
  final List<String> floatingAppShortcuts;

  /// User-selected app theme: `system` (default), `light`, or `dark`.
  /// Wired into `MaterialApp.themeMode` in `main.dart`.
  final ThemeMode themeMode;

  /// Id of the active catalog / built-in theme. Empty
  /// ([defaultActiveThemeId]) = the built-in default look (Midnight /
  /// Daylight, selected by [themeMode]). Resolved to a concrete
  /// `ThemeSpec` → `ThemeData` by `activeThemeProvider`, which feeds
  /// `_AppShell` in `main.dart`. Orthogonal to [themeMode]: this picks
  /// *which palette*; that picks light-vs-dark-vs-system within it.
  /// Persisted across launches (SharedPreferences `active_theme_id`).
  final String activeThemeId;

  /// Which side the driver sits on — `left` (default) anchors the
  /// floating mic to the bottom-left of the shell; `right` mirrors it
  /// to the bottom-right for RHD markets. Persisted across launches
  /// so a UK / Australia / Japan / India tester sets it once.
  final DriverSide driverSide;

  /// Whether the floating bubble may appear when the app is backgrounded.
  /// Default true (shown); the user hides it from Settings → Appearance.
  /// The native `BubbleOverlayService` reads its own persisted copy (pushed
  /// via `bubble_overlay.dart`'s `setEnabled`); this field is the UI truth.
  final bool bubbleEnabled;

  /// Set the moment the user completes the first-launch onboarding
  /// screen (or skips through it). Null means onboarding hasn't run
  /// yet — the `_Gate` in main.dart routes to OnboardingScreen instead
  /// of DashShell when this is null. Resettable from Settings →
  /// Developer for QA + dev cycles.
  final DateTime? onboardingCompletedAt;

  /// When the one-time "Hands-free Hey BYD" intro sheet was shown (on the
  /// first mic tap while [wakeWordEnabled] is off). Null = never shown.
  /// Set the moment it appears — whether the driver activates or dismisses —
  /// so the upsell is shown exactly once, ever. Read by the mic-tap gate
  /// (`VoiceIntroGate`).
  final DateTime? heyBydIntroSeenAt;

  AppSettings copyWith({
    String? deviceId,
    String? openAiVoice,
    VoiceVadMode? voiceVadMode,
    double? voiceVadThreshold,
    bool? voiceAllowInterrupt,
    String? voicePersonality,
    List<String>? voiceLanguages,
    VoiceLanguageMode? voiceLanguageMode,
    VadNoisePreset? vadNoisePreset,
    int? vadSilenceHangMs,
    int? vadMinUtteranceMs,
    int? vadMaxUtteranceMs,
    bool? audioTelemetryConsent,
    bool? devCarControlsEnabled,
    bool? flightTestModeEnabled,
    bool? voiceAssistantEnabled,
    bool? wakeWordEnabled,
    String? voiceModelLang,
    List<String>? customWakePhrases,
    List<String>? floatingAppShortcuts,
    ThemeMode? themeMode,
    String? activeThemeId,
    DriverSide? driverSide,
    bool? bubbleEnabled,
    DateTime? onboardingCompletedAt,
    DateTime? heyBydIntroSeenAt,
    // The conventional `?? this.x` pattern can't represent "set to
    // null" for a nullable field. Pass `clearOnboarding: true` from
    // the dev "Reset onboarding" row to wipe the flag.
    bool clearOnboarding = false,
  }) => AppSettings(
    deviceId: deviceId ?? this.deviceId,
    openAiVoice: openAiVoice ?? this.openAiVoice,
    voiceVadMode: voiceVadMode ?? this.voiceVadMode,
    voiceVadThreshold: voiceVadThreshold ?? this.voiceVadThreshold,
    voiceAllowInterrupt: voiceAllowInterrupt ?? this.voiceAllowInterrupt,
    voicePersonality: voicePersonality ?? this.voicePersonality,
    voiceLanguages: voiceLanguages ?? this.voiceLanguages,
    voiceLanguageMode: voiceLanguageMode ?? this.voiceLanguageMode,
    vadNoisePreset: vadNoisePreset ?? this.vadNoisePreset,
    vadSilenceHangMs: vadSilenceHangMs ?? this.vadSilenceHangMs,
    vadMinUtteranceMs: vadMinUtteranceMs ?? this.vadMinUtteranceMs,
    vadMaxUtteranceMs: vadMaxUtteranceMs ?? this.vadMaxUtteranceMs,
    audioTelemetryConsent: audioTelemetryConsent ?? this.audioTelemetryConsent,
    devCarControlsEnabled: devCarControlsEnabled ?? this.devCarControlsEnabled,
    flightTestModeEnabled: flightTestModeEnabled ?? this.flightTestModeEnabled,
    voiceAssistantEnabled: voiceAssistantEnabled ?? this.voiceAssistantEnabled,
    wakeWordEnabled: wakeWordEnabled ?? this.wakeWordEnabled,
    voiceModelLang: voiceModelLang ?? this.voiceModelLang,
    customWakePhrases: customWakePhrases ?? this.customWakePhrases,
    floatingAppShortcuts: floatingAppShortcuts ?? this.floatingAppShortcuts,
    themeMode: themeMode ?? this.themeMode,
    activeThemeId: activeThemeId ?? this.activeThemeId,
    driverSide: driverSide ?? this.driverSide,
    bubbleEnabled: bubbleEnabled ?? this.bubbleEnabled,
    onboardingCompletedAt: clearOnboarding
        ? null
        : (onboardingCompletedAt ?? this.onboardingCompletedAt),
    heyBydIntroSeenAt: heyBydIntroSeenAt ?? this.heyBydIntroSeenAt,
  );

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.deviceId == deviceId &&
      other.openAiVoice == openAiVoice &&
      other.voiceVadMode == voiceVadMode &&
      other.voiceVadThreshold == voiceVadThreshold &&
      other.voiceAllowInterrupt == voiceAllowInterrupt &&
      other.voicePersonality == voicePersonality &&
      listEquals(other.voiceLanguages, voiceLanguages) &&
      other.voiceLanguageMode == voiceLanguageMode &&
      other.vadNoisePreset == vadNoisePreset &&
      other.vadSilenceHangMs == vadSilenceHangMs &&
      other.vadMinUtteranceMs == vadMinUtteranceMs &&
      other.vadMaxUtteranceMs == vadMaxUtteranceMs &&
      other.audioTelemetryConsent == audioTelemetryConsent &&
      other.devCarControlsEnabled == devCarControlsEnabled &&
      other.flightTestModeEnabled == flightTestModeEnabled &&
      other.voiceAssistantEnabled == voiceAssistantEnabled &&
      other.wakeWordEnabled == wakeWordEnabled &&
      other.voiceModelLang == voiceModelLang &&
      listEquals(other.customWakePhrases, customWakePhrases) &&
      listEquals(other.floatingAppShortcuts, floatingAppShortcuts) &&
      other.themeMode == themeMode &&
      other.activeThemeId == activeThemeId &&
      other.driverSide == driverSide &&
      other.bubbleEnabled == bubbleEnabled &&
      other.onboardingCompletedAt == onboardingCompletedAt &&
      other.heyBydIntroSeenAt == heyBydIntroSeenAt;

  @override
  int get hashCode => Object.hash(
    Object.hash(
      deviceId,
      openAiVoice,
      voiceVadMode,
      voiceVadThreshold,
      voiceAllowInterrupt,
    ),
    vadNoisePreset,
    vadSilenceHangMs,
    vadMinUtteranceMs,
    vadMaxUtteranceMs,
    audioTelemetryConsent,
    devCarControlsEnabled,
    flightTestModeEnabled,
    voiceAssistantEnabled,
    wakeWordEnabled,
    voiceModelLang,
    themeMode,
    activeThemeId,
    // driverSide + bubbleEnabled folded into one slot (Object.hash 20-arg cap).
    Object.hash(driverSide, bubbleEnabled),
    // Two one-time DateTime flags folded into one slot (Object.hash 20-arg cap).
    Object.hash(onboardingCompletedAt, heyBydIntroSeenAt),
    voicePersonality,
    // Three list fields folded into one positional slot to stay within
    // Object.hash's 20-argument ceiling.
    Object.hash(
      Object.hashAll(voiceLanguages),
      Object.hashAll(customWakePhrases),
      Object.hashAll(floatingAppShortcuts),
    ),
    voiceLanguageMode,
  );

  static const empty = AppSettings(deviceId: '');
}

class SettingsController extends AsyncNotifier<AppSettings> {
  // ── Auth / identity ──
  // Pre-release hard cutover (see RENAME_BYD_DEVICE_ID_CONTRACT.md):
  // fresh installs only. No SharedPreferences migration shim — a
  // value persisted under the old `'vin'` key is orphaned by design.
  static const _kDeviceId = 'deviceId';
  // ── Voice / VAD ──
  static const _kOpenAiVoice = 'openai_voice';
  static const _kVoiceVadMode = 'voice_vad_mode';
  static const _kVoiceVadThreshold = 'voice_vad_threshold';
  static const _kVoiceAllowInterrupt = 'voice_allow_interrupt';
  static const _kVoicePersonality = 'voice_personality';
  static const _kVoiceLanguages = 'voice_languages';
  static const _kVoiceLanguageMode = 'voice_language_mode';
  static const _kVadNoisePreset = 'vad_noise_preset';
  static const _kVadSilenceHangMs = 'vad_silence_hang_ms';
  static const _kVadMinUtteranceMs = 'vad_min_utterance_ms';
  static const _kVadMaxUtteranceMs = 'vad_max_utterance_ms';
  static const _kAudioTelemetryConsent = 'audio_telemetry_consent';
  static const _kVoiceAssistantEnabled = 'voice_assistant_enabled';
  static const _kWakeWordEnabled = 'wake_word_enabled';
  static const _kVoiceModelLang = 'voice_model_lang';
  static const _kCustomWakePhrases = 'custom_wake_phrases';
  static const _kFloatingAppShortcuts = 'floating_app_shortcuts';
  // ── Dev / feature flags ──
  static const _kDevCarControlsEnabled = 'dev_car_controls_enabled';
  static const _kFlightTestModeEnabled = 'flight_test_mode_enabled';
  // ── UI ──
  static const _kThemeMode = 'theme_mode';
  static const _kActiveThemeId = 'active_theme_id';
  static const _kDriverSide = 'driver_side';
  static const _kBubbleEnabled = 'bubble_enabled';
  // ── Onboarding / config ──
  static const _kOnboardingCompletedAt = 'onboarding_completed_at';
  static const _kHeyBydIntroSeenAt = 'heybyd_intro_seen_at';

  /// Legacy mock device id a pre-fix build persisted. Kept ONLY so the
  /// self-heal + migration in [_resolveDeviceId] recognises and replaces
  /// it. The live mock id is [CarDeviceId.mockDeviceId] — the single
  /// source of truth the bridge, pairing and MQTT creds all use.
  static const _kLegacyDevMockDeviceId = 'byd:DEV0DASH00000DEV1';

  @override
  Future<AppSettings> build() async {
    final prefs = await SharedPreferences.getInstance();
    // Reads the compile-time base, never the derived `appConfigProvider`.
    // The derived provider depends on `settingsProvider.select(...)` for
    // the URL override; reading it from inside this build would close a
    // cycle (`settingsProvider → appConfigProvider → settingsProvider`).
    // `mockCar` is a compile-time `--dart-define` and unaffected by the
    // runtime override, so the base value is what we want here.
    final mockCar = ref.read(appConfigBaseProvider).mockCar;
    final deviceId = await _resolveDeviceId(prefs, mockCar);
    return AppSettings(
      deviceId: deviceId,
      openAiVoice:
          prefs.getString(_kOpenAiVoice) ?? AppSettings.defaultOpenAiVoice,
      voiceVadMode: parseVoiceVadMode(prefs.getString(_kVoiceVadMode)),
      voiceVadThreshold:
          prefs.getDouble(_kVoiceVadThreshold) ??
          AppSettings.defaultVoiceVadThreshold,
      voiceAllowInterrupt: prefs.getBool(_kVoiceAllowInterrupt) ?? false,
      voicePersonality:
          prefs.getString(_kVoicePersonality) ??
          AppSettings.defaultVoicePersonality,
      voiceLanguages: prefs.getStringList(_kVoiceLanguages) ?? const [],
      voiceLanguageMode: parseVoiceLanguageMode(
        prefs.getString(_kVoiceLanguageMode),
      ),
      vadNoisePreset: _parseVadNoisePreset(prefs.getString(_kVadNoisePreset)),
      vadSilenceHangMs:
          prefs.getInt(_kVadSilenceHangMs) ??
          AppSettings.defaultVadSilenceHangMs,
      vadMinUtteranceMs:
          prefs.getInt(_kVadMinUtteranceMs) ??
          AppSettings.defaultVadMinUtteranceMs,
      vadMaxUtteranceMs:
          prefs.getInt(_kVadMaxUtteranceMs) ??
          AppSettings.defaultVadMaxUtteranceMs,
      audioTelemetryConsent: prefs.getBool(_kAudioTelemetryConsent) ?? false,
      devCarControlsEnabled: prefs.getBool(_kDevCarControlsEnabled) ?? false,
      flightTestModeEnabled: prefs.getBool(_kFlightTestModeEnabled) ?? false,
      voiceAssistantEnabled:
          prefs.getBool(_kVoiceAssistantEnabled) ??
          AppSettings.defaultVoiceAssistantEnabled,
      wakeWordEnabled: prefs.getBool(_kWakeWordEnabled) ?? false,
      voiceModelLang: prefs.getString(_kVoiceModelLang) ?? 'en-us',
      customWakePhrases: prefs.getStringList(_kCustomWakePhrases) ?? const [],
      floatingAppShortcuts:
          prefs.getStringList(_kFloatingAppShortcuts) ?? const [],
      themeMode: parseThemeMode(prefs.getString(_kThemeMode)),
      activeThemeId:
          prefs.getString(_kActiveThemeId) ?? AppSettings.defaultActiveThemeId,
      driverSide: _parseDriverSide(prefs.getString(_kDriverSide)),
      bubbleEnabled:
          prefs.getBool(_kBubbleEnabled) ?? AppSettings.defaultBubbleEnabled,
      onboardingCompletedAt: _parseDt(prefs.getString(_kOnboardingCompletedAt)),
      heyBydIntroSeenAt: _parseDt(prefs.getString(_kHeyBydIntroSeenAt)),
    );
  }

  /// Resolve the persisted device id with the mock-mode self-heal:
  /// a mock id left by a prior `mockCar` run is cleared when now running
  /// against a real head unit (so the real BYD id can flow through
  /// pairing); and on debug + `mockCar` the canonical mock id
  /// ([CarDeviceId.mockDeviceId]) is seeded + persisted so it survives
  /// restarts and — critically — MATCHES the id the bridge / pairing /
  /// MQTT creds use. When this diverged (settings carried the legacy
  /// placeholder while creds were minted for the bridge id) the MQTT
  /// client refused to connect (`creds_mismatch`) and no downlinks
  /// reached the car.
  Future<String> _resolveDeviceId(SharedPreferences prefs, bool mockCar) async {
    var deviceId = prefs.getString(_kDeviceId) ?? '';
    // Recognise both the live canonical mock id and the legacy
    // placeholder a pre-fix build may have persisted.
    final isStaleMockId =
        deviceId == CarDeviceId.mockDeviceId ||
        deviceId == _kLegacyDevMockDeviceId;
    if (isStaleMockId && !mockCar) {
      deviceId = '';
      await prefs.remove(_kDeviceId);
    }
    // Seed (empty prefs) OR migrate (legacy placeholder only) to the
    // canonical mock id. Scoped to those two cases so a deliberately
    // persisted id — a real pairing kept while toggling mockCar, or a
    // hand-set Settings VIN — is left untouched; only the desynced
    // legacy placeholder is repaired so an upgraded install self-heals.
    if (kDebugMode &&
        mockCar &&
        (deviceId.isEmpty || deviceId == _kLegacyDevMockDeviceId)) {
      deviceId = CarDeviceId.mockDeviceId;
      await prefs.setString(_kDeviceId, deviceId);
    }
    return deviceId;
  }

  static DateTime? _parseDt(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  /// Persist [next] then mirror it into state. Each concern writes its own
  /// keys via a helper — same keys, same values as a single flat write,
  /// just grouped so the auth/voice/ui/flag/config surfaces are legible
  /// and independently auditable.
  Future<void> save(AppSettings next) async {
    state = AsyncData(next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDeviceId, next.deviceId);
    await _saveVoice(prefs, next);
    await _saveUi(prefs, next);
    await _saveFlags(prefs, next);
    await _saveConfig(prefs, next);
  }

  Future<void> _saveVoice(SharedPreferences prefs, AppSettings s) async {
    await prefs.setString(_kOpenAiVoice, s.openAiVoice);
    await prefs.setString(_kVoiceVadMode, s.voiceVadMode.name);
    await prefs.setDouble(_kVoiceVadThreshold, s.voiceVadThreshold);
    await prefs.setBool(_kVoiceAllowInterrupt, s.voiceAllowInterrupt);
    await prefs.setString(_kVoicePersonality, s.voicePersonality);
    await prefs.setStringList(_kVoiceLanguages, s.voiceLanguages);
    await prefs.setString(_kVoiceLanguageMode, s.voiceLanguageMode.name);
    await prefs.setString(_kVadNoisePreset, s.vadNoisePreset.name);
    await prefs.setInt(_kVadSilenceHangMs, s.vadSilenceHangMs);
    await prefs.setInt(_kVadMinUtteranceMs, s.vadMinUtteranceMs);
    await prefs.setInt(_kVadMaxUtteranceMs, s.vadMaxUtteranceMs);
    await prefs.setBool(_kAudioTelemetryConsent, s.audioTelemetryConsent);
    await prefs.setBool(_kVoiceAssistantEnabled, s.voiceAssistantEnabled);
    await prefs.setBool(_kWakeWordEnabled, s.wakeWordEnabled);
    await prefs.setString(_kVoiceModelLang, s.voiceModelLang);
    await prefs.setStringList(_kCustomWakePhrases, s.customWakePhrases);
    await prefs.setStringList(_kFloatingAppShortcuts, s.floatingAppShortcuts);
  }

  Future<void> _saveUi(SharedPreferences prefs, AppSettings s) async {
    await prefs.setString(_kThemeMode, s.themeMode.name);
    await prefs.setString(_kActiveThemeId, s.activeThemeId);
    await prefs.setString(_kDriverSide, s.driverSide.name);
    await prefs.setBool(_kBubbleEnabled, s.bubbleEnabled);
  }

  Future<void> _saveFlags(SharedPreferences prefs, AppSettings s) async {
    await prefs.setBool(_kDevCarControlsEnabled, s.devCarControlsEnabled);
    await prefs.setBool(_kFlightTestModeEnabled, s.flightTestModeEnabled);
  }

  Future<void> _saveConfig(SharedPreferences prefs, AppSettings s) async {
    final ts = s.onboardingCompletedAt;
    if (ts != null) {
      await prefs.setString(_kOnboardingCompletedAt, ts.toIso8601String());
    } else {
      await prefs.remove(_kOnboardingCompletedAt);
    }
    final introTs = s.heyBydIntroSeenAt;
    if (introTs != null) {
      await prefs.setString(_kHeyBydIntroSeenAt, introTs.toIso8601String());
    } else {
      await prefs.remove(_kHeyBydIntroSeenAt);
    }
  }
}

final settingsProvider = AsyncNotifierProvider<SettingsController, AppSettings>(
  SettingsController.new,
);
