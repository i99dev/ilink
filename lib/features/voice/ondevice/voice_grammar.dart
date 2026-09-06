import 'dart:convert';

import 'package:ilink/features/_car_domain/command/command.dart';

import 'command_phrases.dart';
import 'grammar_phrase.dart';
import 'voice_model_catalog.dart';

/// Normalize an utterance/phrase to the canonical matching form: lowercase,
/// non-alphanumeric collapsed to single spaces, trimmed, with Arabic folded
/// ([_foldArabicRune]). Used by BOTH the grammar builder and
/// [LocalIntentMatcher] so the index keys and the transcript lookup are
/// produced by the exact same function — there is no second normalization to
/// drift.
///
/// Arabic folding is what lets the Moonshine fallback's fully-voweled output
/// (e.g. `إفْتَحْ النَّافِذَةَ`) match the grammar's bare phrase
/// (`افتح النافذة`): diacritics/tatweel are dropped and alef/ya/hamza-seat
/// variants are unified. It also hardens the Vosk path against the same
/// alef-hamza inconsistencies — harmless for non-Arabic text (all folded
/// codepoints are in the Arabic blocks).
String normalizePhrase(String input) {
  final lowered = input.toLowerCase();
  final buf = StringBuffer();
  var lastWasSpace = true; // trims leading space
  for (final rune in lowered.runes) {
    final folded = _foldArabicRune(rune);
    if (folded == null) continue; // diacritic / tatweel — drop, no break
    final isAlnum =
        (folded >= 0x30 && folded <= 0x39) || // 0-9
        (folded >= 0x61 && folded <= 0x7a) || // a-z
        folded > 0x7f; // keep unicode letters (Arabic etc.)
    if (isAlnum) {
      buf.writeCharCode(folded);
      lastWasSpace = false;
    } else if (!lastWasSpace) {
      buf.write(' ');
      lastWasSpace = true;
    }
  }
  return buf.toString().trimRight();
}

/// Fold an Arabic rune to its canonical matching form, or return null for a
/// rune that should be DROPPED (combining diacritic / tatweel). Non-Arabic
/// runes pass through unchanged.
int? _foldArabicRune(int rune) {
  switch (rune) {
    // Alef variants (hamza/madda/wasla) → bare alef.
    case 0x0623: // أ
    case 0x0625: // إ
    case 0x0622: // آ
    case 0x0671: // ٱ
      return 0x0627; // ا
    // Alef maqsura → ya (Moonshine/Vosk disagree on word-final ى vs ي).
    case 0x0649: // ى
      return 0x064A; // ي
    // Hamza-seat waw/ya → plain waw/ya.
    case 0x0624: // ؤ
      return 0x0648; // و
    case 0x0626: // ئ
      return 0x064A; // ي
    case 0x0640: // ـ tatweel (kashida)
      return null;
  }
  // Combining marks: harakat (064B–0652), Quranic annotation (0653–065F),
  // superscript alef (0670), extended marks (06D6–06ED). Drop them.
  if ((rune >= 0x064B && rune <= 0x065F) ||
      rune == 0x0670 ||
      (rune >= 0x06D6 && rune <= 0x06ED)) {
    return null;
  }
  return rune;
}

bool isOnDeviceExcluded(String commandId, CommandCategory category) {
  if (commandId.endsWith('.stop')) return true;
  if (category == CommandCategory.light) return true;
  if (commandId.startsWith('hood.')) return true;
  if (commandId == 'door.trunk.close') return true;
  return false;
}

class VoiceGrammar {
  VoiceGrammar._(
    this.phrases,
    this._byText,
    this.vocabulary,
    this.wakePhrases,
    this.workflowPhrases,
  );

  final List<GrammarPhrase> phrases;
  final Map<String, GrammarPhrase> _byText;

  /// User-defined automation phrases ("When I say…" workflow triggers).
  /// In the Vosk grammar so the recognizer can HEAR them, but NOT in
  /// [_byText] — they don't map to a built-in command. The workflow engine
  /// matches + fires them (`WorkflowEngine.onVoicePhrase`), which is why
  /// the controller checks the engine FIRST. Normalized + deduped.
  final List<String> workflowPhrases;

  /// Unique normalized tokens across every phrase + wake word.
  final Set<String> vocabulary;

  /// Normalized "Hey BYD" wake phrases — route to the OFFLINE command path.
  /// Stripped from transcripts by [LocalIntentMatcher] before command matching.
  final List<String> wakePhrases;

  /// O(1) exact lookup. The argument is re-run through [normalizePhrase]
  /// (idempotent) so a caller passing a raw phrase — and the index keys,
  /// which are always normalized — fold to the SAME form. This matters for
  /// Arabic: `exact('اقفل الأبواب')` and the stored key must agree on
  /// alef-hamza/diacritic folding.
  GrammarPhrase? exact(String text) => _byText[normalizePhrase(text)];

  int get phraseCount => phrases.length;

  static VoiceGrammar build({
    required Map<String, CarCommand> registry,
    bool Function(String commandId)? handles,
    String langCode = kDefaultVoiceLang,
    List<CommandPhraseSeed>? seeds,
    List<String>? wakePhrases,
    List<String> extraWakePhrases = const [],
    List<String> extraCommandPhrases = const [],
  }) {
    final canRoute = handles ?? (_) => true;
    final resolvedSeeds =
        seeds ?? commandSeedsByLang[langCode] ?? const <CommandPhraseSeed>[];
    final resolvedWake = [
      ...(wakePhrases ?? wakePhrasesByLang[langCode] ?? const ['hey byd']),
      ...extraWakePhrases,
    ];
    final byText = <String, GrammarPhrase>{};
    final vocab = <String>{};

    void add(String rawPhrase, String commandId, Map<String, dynamic> args) {
      final text = normalizePhrase(rawPhrase);
      if (text.isEmpty) return;
      // First writer wins. Auto (label) phrases are added first, then
      // curated; a collision means two commands claim the same utterance
      // — keep the first and let the parity test surface the conflict.
      byText.putIfAbsent(
        text,
        () => GrammarPhrase(text: text, commandId: commandId, args: args),
      );
      vocab.addAll(text.split(' '));
    }

    // 1. Auto layer — coverage from labels.
    for (final cmd in registry.values) {
      if (cmd.voiceHidden) continue; // respect LLM-hidden (e.g. radio)
      if (cmd.params.isNotEmpty) continue; // Needs an explicit phrase mapping.
      if (isOnDeviceExcluded(cmd.id, cmd.category)) continue; // not on-car
      if (!canRoute(cmd.id)) continue;
      add(cmd.label, cmd.id, const {});
    }

    // 2. Curated layer — natural phrasing.
    for (final seed in resolvedSeeds) {
      final cmd = registry[seed.commandId];
      if (cmd == null) continue; // drift guard
      if (isOnDeviceExcluded(cmd.id, cmd.category)) continue; // not on-car
      if (!canRoute(seed.commandId)) continue;
      for (final phrase in seed.phrases) {
        add(phrase, seed.commandId, seed.args);
      }
    }

    // Dedup after normalization — a driver-picked preset can repeat a
    // built-in default; keep first occurrence, drop empties.
    final normalizedWake = <String>[];
    final seenWake = <String>{};
    for (final w in resolvedWake) {
      final n = normalizePhrase(w);
      if (n.isEmpty || !seenWake.add(n)) continue;
      normalizedWake.add(n);
    }
    for (final w in normalizedWake) {
      vocab.addAll(w.split(' '));
    }

    // AI wake — same dedupe, and ALSO drop any phrase that collides with a BYD
    // wake phrase (BYD wins) so a single utterance can't be both wake words.
    // Workflow ("When I say…") phrases — dedup, add to vocab so Vosk can
    // decode them, but DO NOT enter byText (they aren't built-in commands).
    final normalizedWorkflow = <String>[];
    final seenWorkflow = <String>{};
    for (final p in extraCommandPhrases) {
      final n = normalizePhrase(p);
      if (n.isEmpty || !seenWorkflow.add(n)) continue;
      normalizedWorkflow.add(n);
      vocab.addAll(n.split(' '));
    }

    return VoiceGrammar._(
      List.unmodifiable(byText.values),
      Map.unmodifiable(byText),
      Set.unmodifiable(vocab),
      List.unmodifiable(normalizedWake),
      List.unmodifiable(normalizedWorkflow),
    );
  }

  String toVoskGrammarJson() {
    final entries = <String>{
      ...phrases.map((p) => p.text),
      ...wakePhrases,
      ...workflowPhrases,
    }.toList(growable: false);
    entries.sort(); // deterministic output (stable across builds)
    return jsonEncode([...entries, '[unk]']);
  }
}
