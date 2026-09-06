import '../../_car_domain/command/command.dart';
import '../../_car_domain/command/registry.dart';
import 'command_phrases.dart';
import 'grammar_phrase.dart';
import 'voice_grammar.dart';
import 'voice_lang_data.dart';
import 'voice_model_catalog.dart';

/// **What the on-device model can do, OFFLINE — for the "?" help sheet next to
/// the mic, so a driver can discover the free, offline car commands.**
///
/// Single source of truth: it reads the SAME localized seed set the recognizer
/// grammar is built from ([commandSeedsByLang] for the active language) and
/// applies the SAME exclusions ([isOnDeviceExcluded], `voiceHidden`). So the
/// sheet can't advertise a phrase the fast-path won't dispatch, and a fully
/// localized language (e.g. Arabic) lists its own phrasing — not English. We
/// derive from the curated seeds rather than the built grammar on purpose: the
/// grammar's auto-label layer injects each command's ENGLISH label into every
/// language for coverage, which would leak English rows into a localized
/// sheet. Adding a command/phrase/language surfaces here automatically.

/// One offline-capable command for the help sheet: its human [label], the
/// [category] it groups under, and 1–2 representative spoken [examples].
class OfflineCommand {
  const OfflineCommand(this.label, this.category, this.examples);
  final String label;
  final CommandCategory category;
  final List<String> examples;
}

/// A category section (e.g. "Doors & trunk") with its offline commands,
/// alphabetised. Empty categories are omitted by [offlineVoiceCommands].
class OfflineCommandSection {
  const OfflineCommandSection(this.category, this.title, this.commands);
  final CommandCategory category;
  final String title;
  final List<OfflineCommand> commands;
}

/// Section titles per language: the built-in en/ar plus every [VoiceLangPack]
/// (`voiceLangPacks`) language, merged once. English is the default/fallback.
final Map<String, Map<CommandCategory, String>> _categoryTitlesByLang = {
  ..._builtinCategoryTitlesByLang,
  for (final e in voiceLangPacks.entries) e.key: e.value.titles,
};

/// Localized command labels per language: built-in Arabic plus every
/// [VoiceLangPack] language, merged once. A language/id absent here falls back
/// to the registry label, sentence-cased.
final Map<String, Map<String, String>> _commandLabelsByLang = {
  ..._builtinCommandLabelsByLang,
  for (final e in voiceLangPacks.entries) e.key: e.value.labels,
};

/// English (+ Arabic) titles defined inline; other languages come from their
/// pack. English is the default/fallback; a category absent within a language
/// falls back to the English title then the enum name.
const Map<String, Map<CommandCategory, String>> _builtinCategoryTitlesByLang = {
  'en-us': {
    CommandCategory.door: 'Doors & trunk',
    CommandCategory.window: 'Windows',
    CommandCategory.climate: 'Climate',
    CommandCategory.light: 'Lights',
    CommandCategory.comfort: 'Comfort',
    CommandCategory.apps: 'Apps',
    CommandCategory.status: 'Status',
    CommandCategory.radio: 'Radio',
    CommandCategory.raw: 'Other',
  },
  'ar': {
    CommandCategory.door: 'الأبواب والصندوق',
    CommandCategory.window: 'النوافذ',
    CommandCategory.climate: 'التكييف',
    CommandCategory.light: 'الأضواء',
    CommandCategory.comfort: 'الراحة',
    CommandCategory.apps: 'التطبيقات',
    CommandCategory.status: 'الحالة',
    CommandCategory.radio: 'الراديو',
    CommandCategory.raw: 'أخرى',
  },
};

/// Arabic command labels defined inline (the reference localized example);
/// other languages come from their pack. English derives from the registry.
const Map<String, Map<String, String>> _builtinCommandLabelsByLang = {
  'ar': {
    'door.lock': 'قفل الأبواب',
    'door.unlock': 'فتح الأبواب',
    'door.trunk.open': 'فتح الصندوق',
    'door.trunk.close': 'إغلاق الصندوق',
    'hood.open': 'فتح غطاء المحرك',
    'hood.close': 'إغلاق غطاء المحرك',
    'window.fl.open': 'فتح نافذة السائق',
    'window.fl.close': 'إغلاق نافذة السائق',
    'window.fl.down': 'تنزيل النافذة بالكامل',
    'window.fr.open': 'فتح نافذة الراكب',
    'window.fr.close': 'إغلاق نافذة الراكب',
    'window.rl.open': 'فتح النافذة الخلفية اليسرى',
    'window.rl.close': 'إغلاق النافذة الخلفية اليسرى',
    'window.rr.open': 'فتح النافذة الخلفية اليمنى',
    'window.rr.close': 'إغلاق النافذة الخلفية اليمنى',
    'climate.power': 'المكيف',
    'climate.defrost_f': 'مزيل الضباب الأمامي',
    'climate.defrost_r': 'مزيل الضباب الخلفي',
    'climate.max_hot': 'أقصى تدفئة',
    'climate.max_cool': 'أقصى تبريد',
    'climate.compressor': 'الكمبروسر',
    'climate.temp': 'درجة الحرارة',
    'climate.fan': 'سرعة المروحة',
    'comfort.frag.off': 'إطفاء المعطر',
  },
};

/// Sheet display order — most-used categories first.
const List<CommandCategory> _categoryOrder = [
  CommandCategory.door,
  CommandCategory.window,
  CommandCategory.climate,
  CommandCategory.light,
  CommandCategory.comfort,
  CommandCategory.apps,
  CommandCategory.status,
  CommandCategory.radio,
  CommandCategory.raw,
];

/// A `value` param expressed as an inclusive integer range, e.g. `16-32`.
final RegExp _rangePattern = RegExp(r'^\s*\d+\s*-\s*\d+\s*$');

/// Build the grouped offline-command help for [langCode] (defaults to
/// English). [registry] is injectable for tests. A language with no localized
/// commands still yields the English-derived sections via the grammar's
/// English fallback in the caller's chosen lang — callers pass the active
/// `voiceModelLang`.
List<OfflineCommandSection> offlineVoiceCommands({
  String langCode = kDefaultVoiceLang,
  Map<String, CarCommand>? registry,
}) {
  final reg = registry ?? commandRegistry;
  final seeds = commandSeedsByLang[langCode] ?? const <CommandPhraseSeed>[];

  // commandId → its localized phrases, each carrying the seed's baked args.
  // Apply the recognizer's exclusions here so the sheet stays in lockstep.
  final phrasesById = <String, List<GrammarPhrase>>{};
  for (final seed in seeds) {
    final cmd = reg[seed.commandId];
    if (cmd == null) continue;
    if (cmd.voiceHidden) continue;
    if (isOnDeviceExcluded(cmd.id, cmd.category)) continue;
    final list = phrasesById[seed.commandId] ??= [];
    for (final phrase in seed.phrases) {
      list.add(
        GrammarPhrase(text: phrase, commandId: seed.commandId, args: seed.args),
      );
    }
  }

  final labels = _commandLabelsByLang[langCode];
  final byCategory = <CommandCategory, List<OfflineCommand>>{};
  for (final entry in phrasesById.entries) {
    final cmd = reg[entry.key];
    if (cmd == null) continue; // grammar already drift-guards, belt-and-braces
    final examples = _examplesFor(cmd, entry.value);
    if (examples.isEmpty) continue;
    (byCategory[cmd.category] ??= []).add(
      OfflineCommand(
        labels?[cmd.id] ?? _sentenceCase(cmd.label),
        cmd.category,
        examples,
      ),
    );
  }

  final out = <OfflineCommandSection>[];
  for (final cat in _categoryOrder) {
    final cmds = byCategory.remove(cat);
    if (cmds == null || cmds.isEmpty) continue;
    cmds.sort((a, b) => a.label.compareTo(b.label));
    out.add(OfflineCommandSection(cat, _titleFor(langCode, cat), cmds));
  }
  // Any category not in the explicit order (future-proofing) trails, sorted.
  for (final cat
      in byCategory.keys.toList()..sort((a, b) => a.index - b.index)) {
    final cmds = byCategory[cat]!..sort((a, b) => a.label.compareTo(b.label));
    out.add(OfflineCommandSection(cat, _titleFor(langCode, cat), cmds));
  }
  return out;
}

/// Section title for [cat] in [langCode], falling back per-category to the
/// English title, then the enum name.
String _titleFor(String langCode, CommandCategory cat) {
  return _categoryTitlesByLang[langCode]?[cat] ??
      _categoryTitlesByLang[kDefaultVoiceLang]![cat] ??
      cat.name;
}

/// Pick 1–2 representative spoken phrases for [cmd] from its grammar phrases.
///   * Numeric setpoints (a `value` range like 16-32) collapse the whole range
///     to ONE example at the command's default value.
///   * On/off (or other discrete-arg) commands show one example per distinct
///     arg set, capped at 2 (so "turn on the ac" AND "turn off the ac").
///   * Arg-free commands show up to 2 natural phrasings.
List<String> _examplesFor(CarCommand cmd, List<GrammarPhrase> phrases) {
  if (phrases.isEmpty) return const [];

  final byArgs = <String, List<GrammarPhrase>>{};
  for (final p in phrases) {
    (byArgs[p.args.toString()] ??= []).add(p);
  }

  if (_isNumericRange(cmd)) {
    // One example, at the default value if that value was enumerated.
    final atDefault = byArgs[cmd.paramDefaults.toString()];
    return _topPhrases(atDefault ?? byArgs.values.first, 1);
  }

  final keys = byArgs.keys.toList()..sort();
  if (keys.length == 1) {
    return _topPhrases(byArgs[keys.first]!, 2); // arg-free → variety
  }
  // Discrete arg sets (on/off …) → one example each, capped.
  return [for (final k in keys.take(2)) ..._topPhrases(byArgs[k]!, 1)];
}

bool _isNumericRange(CarCommand cmd) =>
    cmd.params.values.any(_rangePattern.hasMatch);

/// The [max] most natural phrasings in [group]: longest (most complete) first,
/// alphabetical tie-break for determinism, deduped.
List<String> _topPhrases(List<GrammarPhrase> group, int max) {
  final sorted = [...group]
    ..sort((a, b) {
      final byWords = b.text.split(' ').length - a.text.split(' ').length;
      return byWords != 0 ? byWords : a.text.compareTo(b.text);
    });
  final out = <String>[];
  for (final p in sorted) {
    if (out.contains(p.text)) continue;
    out.add(p.text);
    if (out.length >= max) break;
  }
  return out;
}

/// "CLIMATE TEMP" → "Climate temp"; "LOCK" → "Lock".
String _sentenceCase(String shouty) {
  final lower = shouty.toLowerCase();
  if (lower.isEmpty) return lower;
  return lower[0].toUpperCase() + lower.substring(1);
}
