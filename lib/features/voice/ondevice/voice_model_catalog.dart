class VoiceModelEntry {
  const VoiceModelEntry({
    required this.langCode,
    required this.label,
    required this.nativeLabel,
    required this.file,
    required this.sizeMb,
    required this.version,
    this.engine = VoiceEngine.vosk,
    this.fallback,
  });

  /// Vosk language tag, e.g. `en-us`, `ar`, `ru`.
  final String langCode;

  /// English label for the picker ("English (US)").
  final String label;

  /// Endonym shown alongside ("العربية", "Русский").
  final String nativeLabel;

  /// Model zip basename on the CDN, e.g. `vosk-model-small-en-us-0.15.zip`.
  final String file;

  /// Approximate download size (MB) — surfaced in the picker.
  final int sizeMb;

  /// Catalog version for the model (drives idempotent re-provision).
  final String version;

  /// The PRIMARY on-device ASR engine. Always [VoiceEngine.vosk] today —
  /// streaming + grammar-constrained is unbeatable on the exact command set.
  final VoiceEngine engine;

  /// Optional SECOND-tier engine, run only when the primary returns
  /// `[unk]`/low-confidence. Non-null for Arabic ([ar]): a Moonshine bundle
  /// that rescues the dialectal / out-of-grammar speech Vosk's MSA model
  /// mishears. Null for languages whose Vosk model needs no rescue.
  final VoiceModelFallback? fallback;

  /// Full download URL — the CDN base + [file]. One source of truth for the
  /// host (change [kVoiceModelCdnBase] to move CDNs).
  String get url => '$kVoiceModelCdnBase/$file';
}

/// A second-tier model run only when the primary engine misses. Carries its
/// own CDN artifact + version so it provisions side-by-side with the primary
/// (both live under their own `version` dir on disk).
class VoiceModelFallback {
  const VoiceModelFallback({
    required this.engine,
    required this.file,
    required this.version,
    required this.sizeMb,
  });

  /// The fallback engine — [VoiceEngine.moonshine] today.
  final VoiceEngine engine;

  /// Fallback artifact basename on the CDN (a flat zip: model + VAD + tokens).
  final String file;

  /// Catalog version / on-disk dir id for the fallback model.
  final String version;

  /// Approximate download size (MB).
  final int sizeMb;

  /// Full download URL — CDN base + [file].
  String get url => '$kVoiceModelCdnBase/$file';
}

/// The on-device ASR engine backing a [VoiceModelEntry] (or its fallback).
enum VoiceEngine {
  /// Vosk / Kaldi — streaming, grammar-constrained decoding (`org.vosk`).
  /// Near-instant + accurate over the fixed command grammar with `[unk]`
  /// rejecting out-of-grammar speech. The default for every language whose
  /// small Vosk model is accurate enough.
  vosk,

  /// Moonshine via sherpa-onnx — a non-streaming ONNX encoder/decoder. There
  /// is no grammar: a VAD segments the utterance, Moonshine freely transcribes
  /// it, and the Dart intent matcher maps the transcript onto the command set.
  /// Used where Vosk is too weak — Arabic, where Moonshine-base matches
  /// Whisper-medium accuracy (incl. dialect) at a Vosk-sized footprint.
  moonshine,
}

/// Default language when none is selected.
const String kDefaultVoiceLang = 'en-us';

/// Upstream Vosk downloads. No publisher digest is pinned for optional downloads.
/// English also ships in the APK; URLs must match the native download policy.
const String kVoiceModelCdnBase = 'https://alphacephei.com/vosk/models';

/// Curated small Vosk models; listing is not cryptographic authentication.
const List<VoiceModelEntry> voiceModelCatalog = [
  VoiceModelEntry(
    langCode: 'en-us',
    label: 'English (US)',
    nativeLabel: 'English',
    file: 'vosk-model-small-en-us-0.15.zip',
    sizeMb: 40,
    version: 'en-0.15',
  ),
  // Existing locally provisioned Arabic fallback files remain compatible.
  VoiceModelEntry(
    langCode: 'ar',
    label: 'Arabic',
    nativeLabel: 'العربية',
    file: 'vosk-model-small-ar-0.3.zip',
    sizeMb: 100,
    version: 'ar-0.3',
    fallback: VoiceModelFallback(
      engine: VoiceEngine.moonshine,
      file: 'moonshine-base-ar-libs-2026-06-26.zip',
      version: 'ar-moonshine-libs-2026-06-26',
      sizeMb: 141,
    ),
  ),
  VoiceModelEntry(
    langCode: 'ru',
    label: 'Russian',
    nativeLabel: 'Русский',
    file: 'vosk-model-small-ru-0.22.zip',
    sizeMb: 44,
    version: 'ru-0.22',
  ),
  VoiceModelEntry(
    langCode: 'fr',
    label: 'French',
    nativeLabel: 'Français',
    file: 'vosk-model-small-fr-0.22.zip',
    sizeMb: 40,
    version: 'fr-0.22',
  ),
  VoiceModelEntry(
    langCode: 'es',
    label: 'Spanish',
    nativeLabel: 'Español',
    file: 'vosk-model-small-es-0.42.zip',
    sizeMb: 38,
    version: 'es-0.42',
  ),
  VoiceModelEntry(
    langCode: 'de',
    label: 'German',
    nativeLabel: 'Deutsch',
    file: 'vosk-model-small-de-0.15.zip',
    sizeMb: 45,
    version: 'de-0.15',
  ),
  VoiceModelEntry(
    langCode: 'cn',
    label: 'Chinese',
    nativeLabel: '中文',
    file: 'vosk-model-small-cn-0.22.zip',
    sizeMb: 42,
    version: 'cn-0.22',
  ),
  VoiceModelEntry(
    langCode: 'tr',
    label: 'Turkish',
    nativeLabel: 'Türkçe',
    file: 'vosk-model-small-tr-0.3.zip',
    sizeMb: 35,
    version: 'tr-0.3',
  ),
  VoiceModelEntry(
    langCode: 'fa',
    label: 'Persian',
    nativeLabel: 'فارسی',
    file: 'vosk-model-small-fa-0.42.zip',
    sizeMb: 51,
    version: 'fa-0.42',
  ),
  VoiceModelEntry(
    langCode: 'hi',
    label: 'Hindi',
    nativeLabel: 'हिन्दी',
    file: 'vosk-model-small-hi-0.22.zip',
    sizeMb: 42,
    version: 'hi-0.22',
  ),
  VoiceModelEntry(
    langCode: 'it',
    label: 'Italian',
    nativeLabel: 'Italiano',
    file: 'vosk-model-small-it-0.4.zip',
    sizeMb: 33,
    version: 'it-0.4',
  ),
  VoiceModelEntry(
    langCode: 'pt',
    label: 'Portuguese',
    nativeLabel: 'Português',
    file: 'vosk-model-small-pt-0.3.zip',
    sizeMb: 31,
    version: 'pt-0.3',
  ),
];

/// Lookup by language tag, or null if unsupported.
VoiceModelEntry? voiceModelFor(String langCode) {
  for (final e in voiceModelCatalog) {
    if (e.langCode == langCode) return e;
  }
  return null;
}
