import 'grammar_phrase.dart';
import 'number_words.dart';
import 'voice_lang_data.dart';

export 'grammar_phrase.dart' show CommandPhraseSeed;

const List<CommandPhraseSeed> commandVoicePhrases = [
  // ── Doors ──────────────────────────────────────────────────────────
  CommandPhraseSeed('door.lock', [
    'lock the doors',
    'lock the car',
    'lock the door',
    'lock up',
  ]),
  CommandPhraseSeed('door.unlock', [
    'unlock the doors',
    'unlock the car',
    'unlock the door',
    'open the doors',
  ]),
  CommandPhraseSeed('door.trunk.open', [
    'open the trunk',
    'pop the trunk',
    'open the boot',
  ]),
  CommandPhraseSeed('door.trunk.close', [
    'close the trunk',
    'shut the trunk',
    'close the boot',
  ]),

  CommandPhraseSeed('hood.open', ['open the hood', 'open the frunk']),
  CommandPhraseSeed('hood.close', ['close the hood', 'close the frunk']),
  CommandPhraseSeed('hood.stop', ['stop the hood']),

  CommandPhraseSeed('window.fl.open', [
    'open the window',
    'open my window',
    'open the driver window',
    'open the drivers window',
    'roll down the window',
    'roll my window down',
    'lower the window',
  ]),
  CommandPhraseSeed('window.fl.close', [
    'close the window',
    'close my window',
    'close the driver window',
    'roll up the window',
    'roll my window up',
    'raise the window',
  ]),
  CommandPhraseSeed('window.fl.down', [
    'roll the window all the way down',
    'drop the window all the way down',
  ]),
  CommandPhraseSeed('window.fr.open', [
    'open the passenger window',
    'roll down the passenger window',
  ]),
  CommandPhraseSeed('window.fr.close', [
    'close the passenger window',
    'roll up the passenger window',
  ]),
  CommandPhraseSeed('window.rl.open', ['open the rear left window']),
  CommandPhraseSeed('window.rl.close', ['close the rear left window']),
  CommandPhraseSeed('window.rr.open', ['open the rear right window']),
  CommandPhraseSeed('window.rr.close', ['close the rear right window']),
  CommandPhraseSeed('window.fl.stop', [
    'stop the window',
    'stop the driver window',
  ]),
  CommandPhraseSeed('window.fr.stop', ['stop the passenger window']),
  CommandPhraseSeed('window.rl.stop', ['stop the rear left window']),
  CommandPhraseSeed('window.rr.stop', ['stop the rear right window']),

  CommandPhraseSeed(
    'climate.power',
    [
      'turn on the ac',
      'turn on the air conditioning',
      'turn on the climate',
      'turn on the air con',
    ],
    args: {'on': true},
  ),
  CommandPhraseSeed(
    'climate.power',
    [
      'turn off the ac',
      'turn off the air conditioning',
      'turn off the climate',
      'turn off the air con',
    ],
    args: {'on': false},
  ),
  CommandPhraseSeed(
    'climate.defrost_f',
    ['defrost the windshield', 'turn on the front defroster', 'front defrost'],
    args: {'on': true},
  ),
  CommandPhraseSeed(
    'climate.defrost_f',
    ['turn off the front defroster', 'stop defrosting the windshield'],
    args: {'on': false},
  ),
  CommandPhraseSeed(
    'climate.defrost_r',
    ['defrost the rear window', 'turn on the rear defroster', 'rear defrost'],
    args: {'on': true},
  ),
  CommandPhraseSeed(
    'climate.defrost_r',
    ['turn off the rear defroster'],
    args: {'on': false},
  ),
  CommandPhraseSeed(
    'climate.max_hot',
    ['max heat', 'maximum heat', 'full heat'],
    args: {'on': true},
  ),
  CommandPhraseSeed(
    'climate.max_cool',
    ['max cool', 'maximum cooling', 'max ac'],
    args: {'on': true},
  ),
  CommandPhraseSeed(
    'climate.compressor',
    ['turn on the compressor'],
    args: {'on': true},
  ),
  CommandPhraseSeed(
    'climate.compressor',
    ['turn off the compressor'],
    args: {'on': false},
  ),

  // ── Exterior lights (on/off toggles — baked {on} arg) ────────────────
  CommandPhraseSeed(
    'light.head',
    ['turn on the headlights', 'headlights on', 'turn on the lights'],
    args: {'on': true},
  ),
  CommandPhraseSeed(
    'light.head',
    ['turn off the headlights', 'headlights off', 'turn off the lights'],
    args: {'on': false},
  ),
  CommandPhraseSeed(
    'light.fog_f',
    ['turn on the front fog lights', 'front fog lights on'],
    args: {'on': true},
  ),
  CommandPhraseSeed(
    'light.fog_f',
    ['turn off the front fog lights', 'front fog lights off'],
    args: {'on': false},
  ),
  CommandPhraseSeed(
    'light.fog_r',
    ['turn on the rear fog lights', 'rear fog lights on'],
    args: {'on': true},
  ),
  CommandPhraseSeed(
    'light.fog_r',
    ['turn off the rear fog lights', 'rear fog lights off'],
    args: {'on': false},
  ),
  CommandPhraseSeed(
    'light.turn_left',
    ['left turn signal', 'signal left', 'indicate left', 'left blinker'],
    args: {'on': true},
  ),
  CommandPhraseSeed(
    'light.turn_right',
    ['right turn signal', 'signal right', 'indicate right', 'right blinker'],
    args: {'on': true},
  ),

  // ── Lights (arg-free momentary triggers) ─────────────────────────────
  CommandPhraseSeed('light.flash', [
    'flash the lights',
    'flash the headlights',
  ]),
  CommandPhraseSeed('light.find_car', [
    'find my car',
    'find the car',
    'locate my car',
    'where is my car',
  ]),

  CommandPhraseSeed('comfort.frag.off', [
    'turn off the fragrance',
    'stop the fragrance',
    'disable the fragrance',
    'no fragrance',
  ]),
];

/// Renders an integer to its spoken word in some language; null when out of
/// that language's supported range.
typedef NumberWordFn = String? Function(int n);

/// One numeric setpoint command to enumerate: its routable [commandId], the
/// inclusive [min]..[max] value range (sourced from the BYD catalog so the
/// grammar can't drift past what the wire accepts), and the natural-language
/// [templates] a driver says — each with a single `{n}` placeholder for the
/// spoken number word.
class _NumberCommand {
  const _NumberCommand(this.commandId, this.min, this.max, this.templates);
  final String commandId;
  final int min;
  final int max;
  final List<String> templates;
}

/// English setpoint templates. Cabin temp 16-32 °C (ac_target_temp), fan 0-7
/// (ac_fan; 0 = off, 7 = max).
const List<_NumberCommand> _enNumberCommands = [
  _NumberCommand('climate.temp', 16, 32, [
    'set the temperature to {n}',
    'set temperature to {n}',
    'set the temp to {n}',
    'set the ac to {n}',
    'set the air conditioning to {n}',
    'set the climate to {n}',
    'change the temperature to {n}',
    'make it {n} degrees',
    'temperature {n}',
    '{n} degrees',
  ]),
  _NumberCommand('climate.fan', 0, 7, [
    'set the fan to {n}',
    'set the fan speed to {n}',
    'set fan speed to {n}',
    'fan speed {n}',
    'fan level {n}',
    'fan to {n}',
  ]),
];

/// Arabic setpoint templates (DRAFT — needs on-car Vosk tuning, same caveat as
/// [_localizedCore]). Same ranges as English.
const List<_NumberCommand> _arNumberCommands = [
  _NumberCommand('climate.temp', 16, 32, [
    'اضبط الحرارة على {n}',
    'خلي الحرارة {n}',
    'الحرارة {n}',
    'درجة الحرارة {n}',
    'حرارة {n}',
  ]),
  _NumberCommand('climate.fan', 0, 7, [
    'اضبط المروحة على {n}',
    'سرعة المروحة {n}',
    'مستوى المروحة {n}',
    'المروحة {n}',
  ]),
];

/// Expand a language's [_NumberCommand] table into per-value
/// [CommandPhraseSeed]s, baking the value into `{value: N}`. Values whose word
/// is out of [word]'s range (returns null) are skipped — defensive, since
/// every current range is 0–99.
List<CommandPhraseSeed> _numberSeeds(
  List<_NumberCommand> commands,
  NumberWordFn word,
) {
  final out = <CommandPhraseSeed>[];
  for (final cmd in commands) {
    for (var n = cmd.min; n <= cmd.max; n++) {
      final w = word(n);
      if (w == null) continue;
      out.add(
        CommandPhraseSeed(
          cmd.commandId,
          cmd.templates.map((t) => t.replaceAll('{n}', w)).toList(),
          args: {'value': n},
        ),
      );
    }
  }
  return out;
}

/// Adapts a [VoiceLangPack]'s `numberWords` map into a [NumberWordFn].
NumberWordFn _wordsFromMap(Map<int, String> words) =>
    (n) => words[n];

/// The two setpoint commands built from a pack's templates (same ranges as
/// English/Arabic: temp 16-32, fan 0-7).
List<_NumberCommand> _numCmdsFor(VoiceLangPack pack) => [
  _NumberCommand('climate.temp', 16, 32, pack.tempTemplates),
  _NumberCommand('climate.fan', 0, 7, pack.fanTemplates),
];

final Map<String, List<CommandPhraseSeed>> numberSeedsByLang = {
  'en-us': List.unmodifiable(
    _numberSeeds(_enNumberCommands, englishNumberWord),
  ),
  'ar': List.unmodifiable(_numberSeeds(_arNumberCommands, arabicNumberWord)),
  for (final e in voiceLangPacks.entries)
    if (e.value.numberWords.isNotEmpty && e.value.tempTemplates.isNotEmpty)
      e.key: List.unmodifiable(
        _numberSeeds(_numCmdsFor(e.value), _wordsFromMap(e.value.numberWords)),
      ),
};

/// English numeric-setpoint seeds — kept as a named alias (used by the English
/// entry of [commandSeedsByLang] and the grammar parity tests).
final List<CommandPhraseSeed> numberCommandSeeds = numberSeedsByLang['en-us']!;

/// Wake phrases per language. The model transcribes in its own
/// language/script, so the wake string must match what THAT Vosk model
/// outputs. English is solid; non-Latin entries are best-effort candidates
/// that need on-car tuning (G4/M6) — what the model actually emits for a
/// driver saying "Hey BYD" is empirical. Missing language → English wake.
const Map<String, List<String>> wakePhrasesByLang = {
  'en-us': ['hey byd', 'hey b y d'],
  'ar': [
    'يا بي دي',
    'هاي بي واي دي',
    'هيي بي دي',
    'مرحبا بايدي',
    'يا بايدي',
    'هاي بايدي',
  ],
  'ru': ['привет байди', 'эй байди', 'хэй би уай ди'],
  'fr': ['hey byd', 'eh byd'],
  'es': ['hey byd', 'oye byd'],
  'de': ['hey byd'],
  'cn': ['你好 比亚迪', 'hey byd'],
  'tr': ['hey byd'],
  'fa': ['های بی دی', 'هی بی وای دی'],
  'hi': ['हे बीवाईडी', 'hey byd'],
  'it': ['hey byd', 'ehi byd'],
  'pt': ['hey byd', 'ei byd'],
};

/// Curated wake phrases the driver can pick from in Settings, per language.
/// Distinct from [wakePhrasesByLang] (the always-on internal detection
/// defaults, which carry multiple phonetic spellings of ONE phrase): these
/// are clean, human-readable ALTERNATIVES a driver may opt into — e.g. an
/// Arabic speaker who'd rather say "مرحبا بايدي" than "Hey BYD". Picking one
/// appends it to [AppSettings.customWakePhrases] (additive — the defaults keep
/// working). Each is written in the language's own script so it matches what
/// that Vosk model emits. A language absent here shows only the free-text box.
///
/// Keep these in the model's native script + real words (Vosk constrained
/// decoding silently ignores out-of-vocabulary tokens). Same on-car-tuning
/// caveat as [wakePhrasesByLang].
const Map<String, List<String>> wakePresetsByLang = {
  'en-us': ['hey byd', 'ok byd', 'hello byd'],
  'ar': ['مرحبا بايدي', 'يا بايدي', 'هاي بايدي', 'يا بي واي دي'],
  'ru': ['привет байди', 'эй байди', 'окей байди'],
  'fr': ['hey byd', 'eh byd', 'bonjour byd'],
  'es': ['hey byd', 'oye byd', 'hola byd'],
  'de': ['hey byd', 'hallo byd'],
  'cn': ['你好 比亚迪', '嗨 比亚迪'],
  'tr': ['hey byd', 'merhaba byd'],
  'fa': ['های بی دی', 'سلام بی دی'],
  'hi': ['हे बीवाईडी', 'नमस्ते बीवाईडी'],
  'it': ['hey byd', 'ehi byd', 'ciao byd'],
  'pt': ['hey byd', 'ei byd', 'olá byd'],
};

/// A language-neutral command intent: what to dispatch, independent of how
/// it's said. Localized phrasings bind to one of these by key.
class CoreIntent {
  const CoreIntent(this.commandId, {this.args = const {}});
  final String commandId;
  final Map<String, dynamic> args;
}

const Map<String, CoreIntent> coreIntents = {
  // Doors + trunk + hood/frunk.
  'lock': CoreIntent('door.lock'),
  'unlock': CoreIntent('door.unlock'),
  'trunk_open': CoreIntent('door.trunk.open'),
  'trunk_close': CoreIntent('door.trunk.close'),
  'hood_open': CoreIntent('hood.open'),
  'hood_close': CoreIntent('hood.close'),
  // Windows — driver pane + the three other panes (per-pane parity w/ English).
  'window_open': CoreIntent('window.fl.open'),
  'window_close': CoreIntent('window.fl.close'),
  'window_down': CoreIntent('window.fl.down'),
  'window_stop': CoreIntent('window.fl.stop'), // excluded at build
  'window_fr_open': CoreIntent('window.fr.open'),
  'window_fr_close': CoreIntent('window.fr.close'),
  'window_rl_open': CoreIntent('window.rl.open'),
  'window_rl_close': CoreIntent('window.rl.close'),
  'window_rr_open': CoreIntent('window.rr.open'),
  'window_rr_close': CoreIntent('window.rr.close'),
  // Climate — toggles (numeric temp/fan handled by [numberSeedsByLang]).
  'ac_on': CoreIntent('climate.power', args: {'on': true}),
  'ac_off': CoreIntent('climate.power', args: {'on': false}),
  'defrost': CoreIntent('climate.defrost_f', args: {'on': true}),
  'defrost_off': CoreIntent('climate.defrost_f', args: {'on': false}),
  'defrost_rear': CoreIntent('climate.defrost_r', args: {'on': true}),
  'defrost_rear_off': CoreIntent('climate.defrost_r', args: {'on': false}),
  'max_hot': CoreIntent('climate.max_hot', args: {'on': true}),
  'max_cool': CoreIntent('climate.max_cool', args: {'on': true}),
  'compressor_on': CoreIntent('climate.compressor', args: {'on': true}),
  'compressor_off': CoreIntent('climate.compressor', args: {'on': false}),
  // Comfort.
  'fragrance_off': CoreIntent('comfort.frag.off'),
  // Lights — excluded at build, translations kept for legacy.
  'lights_on': CoreIntent('light.head', args: {'on': true}),
  'lights_off': CoreIntent('light.head', args: {'on': false}),
  'find_car': CoreIntent('light.find_car'),
};

const Map<String, Map<String, List<String>>> _localizedCore = {
  // ARABIC — MSA + Gulf/Egyptian/Levantine dialect variants. The dialect
  // forms (سكّر/شبابيك/جام/كنديشن/طفّي/بطّل/شنطة/وين/فين…) mostly fall outside
  // Vosk's MSA lexicon, so they rarely help the Vosk fast-path — but they are
  // exactly what the Moonshine FALLBACK transcribes for a dialectal speaker,
  // and the intent matcher can only resolve a transcript it has a phrase for.
  // So every variant here directly lifts the two-tier dialect hit-rate.
  'ar': {
    // Doors + trunk + hood. (بلّع/كبّس Gulf-Levantine ; عربية Egyptian)
    'lock': [
      'اقفل الأبواب',
      'قفل السيارة',
      'اقفل السيارة',
      'قفل الأبواب',
      'سكر الأبواب',
      'قفل البيبان',
      'قفل الباب',
      'بلع الأبواب',
      'كبس القفل',
      'قفل العربية',
    ],
    'unlock': [
      'افتح الأبواب',
      'فتح الأقفال',
      'الغ قفل الأبواب',
      'فك قفل الأبواب',
      'شيل القفل',
      'افتح البيبان',
      'افتح الباب',
      'فك الأبواب',
      'شيل قفل الأبواب',
      'افتح اقفال السيارة',
    ],
    'trunk_open': [
      'افتح الصندوق',
      'افتح صندوق السيارة',
      'افتح الشنطة',
      'افتح البوت',
      'افتح الشنطة الخلفية',
      'افتح العفشة',
      'افتح الدكة',
      'افتح الصندوق الخلفي',
    ],
    'trunk_close': [
      'اغلق الصندوق',
      'سكر الصندوق',
      'قفل الصندوق',
      'سكر الشنطة',
      'قفل الشنطة',
      'بلع الشنطة',
      'سكر البوت',
      'قفل البوت',
    ],
    // (hood_open / hood_close removed — the hood.* family is excluded from the
    // on-device fast-path anyway: verified not actuating on-car.)
    // Windows — driver pane + per-pane. (شباك/شبابيك/جام/دريشة dialect)
    'window_open': [
      'افتح النافذة',
      'نزل الزجاج',
      'نزل النافذة',
      'نزل الشباك',
      'افتح الشباك',
      'نزل الجام',
      'نزل الشبابيك',
      'نزل الدريشة',
      'افتح الدريشة',
      'فتح الشباك',
      'نزل شباك',
    ],
    'window_close': [
      'اغلق النافذة',
      'ارفع الزجاج',
      'سكر النافذة',
      'سكر الشباك',
      'طلع الزجاج',
      'قفل الشباك',
      'ارفع الشباك',
      'سكر الشبابيك',
      'بلع الشباك',
      'طلع الشباك',
      'سكر الدريشة',
      'ارفع الدريشة',
    ],
    'window_down': [
      'نزل النافذة كامل',
      'نزل الزجاج كله',
      'نزل الشباك كله',
      'نزل الجام كامل',
      'نزل الدريشة كلها',
      'نزل الشباك للاخر',
    ],
    'window_stop': ['وقف النافذة', 'وقف الشباك', 'بطل النافذة', 'وقف الدريشة'],
    'window_fr_open': [
      'افتح نافذة الراكب',
      'نزل زجاج الراكب',
      'نزل شباك الراكب',
      'نزل دريشة الراكب',
    ],
    'window_fr_close': [
      'اغلق نافذة الراكب',
      'ارفع زجاج الراكب',
      'سكر شباك الراكب',
      'سكر دريشة الراكب',
    ],
    'window_rl_open': [
      'افتح النافذة الخلفية اليسرى',
      'نزل الشباك الخلفي الايسر',
    ],
    'window_rl_close': [
      'اغلق النافذة الخلفية اليسرى',
      'سكر الشباك الخلفي الايسر',
    ],
    'window_rr_open': [
      'افتح النافذة الخلفية اليمنى',
      'نزل الشباك الخلفي الايمن',
    ],
    'window_rr_close': [
      'اغلق النافذة الخلفية اليمنى',
      'سكر الشباك الخلفي الايمن',
    ],
    // Climate toggles. (مكيف/تكييف/كنديشن ; شغّل/شبّك/ولّع ; طفّي/بطّل/وقّف)
    'ac_on': [
      'شغل المكيف',
      'افتح التكييف',
      'شغل التكييف',
      'شغل الكنديشن',
      'شبك المكيف',
      'افتح المكيف',
      'شغل الايركنديشن',
      'فتح المكيف',
      'ولع المكيف',
      'شبك التكييف',
      'شغل الايركوندشن',
    ],
    'ac_off': [
      'اطفئ المكيف',
      'اغلق التكييف',
      'سكر المكيف',
      'طفي المكيف',
      'بطل المكيف',
      'سكر الكنديشن',
      'طفي التكييف',
      'وقف المكيف',
      'بطل التكييف',
      'سكر التكييف',
      'طفي الكنديشن',
    ],
    'defrost': [
      'ازل الضباب عن الزجاج',
      'شغل مزيل الضباب الأمامي',
      'شيل التعتيم',
      'نشف الزجاج الامامي',
      'شيل الرطوبة عن الزجاج',
      'ازل التكثيف',
    ],
    'defrost_off': [
      'اطفئ مزيل الضباب الأمامي',
      'اوقف ازالة الضباب',
      'طفي مزيل الضباب',
    ],
    'defrost_rear': [
      'ازل الضباب عن الزجاج الخلفي',
      'شغل مزيل الضباب الخلفي',
      'نشف الزجاج الخلفي',
    ],
    'defrost_rear_off': ['اطفئ مزيل الضباب الخلفي', 'طفي مزيل الضباب الخلفي'],
    'max_hot': [
      'اقصى تدفئة',
      'سخن بالكامل',
      'دفي السيارة',
      'سخن على الاخر',
      'سخن عالفل',
      'دفي عالاخر',
      'سخن لاقصى درجة',
      'تدفئة عالاخر',
    ],
    'max_cool': [
      'اقصى تبريد',
      'برد بالكامل',
      'برد السيارة',
      'برد على الاخر',
      'برد عالفل',
      'برد لاقصى درجة',
      'تبريد عالاخر',
      'برد بأقصى درجة',
    ],
    'compressor_on': ['شغل الكمبروسر', 'شغل الكمبريسر'],
    'compressor_off': ['اطفئ الكمبروسر', 'طفي الكمبريسر'],
    // Comfort.
    'fragrance_off': [
      'اطفئ المعطر',
      'اوقف العطر',
      'طفي المعطر',
      'بطل العطر',
      'سكر المعطر',
    ],
    // Lights — excluded at build, kept for legacy.
    'lights_on': ['شغل الأضواء', 'افتح الأنوار', 'ولع الانوار', 'فتح الاضواء'],
    'lights_off': [
      'اطفئ الأضواء',
      'اغلق الأنوار',
      'طفي الانوار',
      'طفي الاضواء',
      'بطل الانوار',
    ],
    // (find_car removed — the light.* category is excluded from the on-device
    // fast-path: not actuating on-car.)
  },
  'ru': {
    'lock': ['заблокируй двери', 'запри машину'],
    'unlock': ['разблокируй двери', 'открой двери'],
    'trunk_open': ['открой багажник'],
    'trunk_close': ['закрой багажник'],
    'window_open': ['открой окно', 'опусти стекло'],
    'window_close': ['закрой окно', 'подними стекло'],
    'window_stop': ['останови окно'],
    'ac_on': ['включи кондиционер'],
    'ac_off': ['выключи кондиционер'],
    'defrost': ['обогрев лобового стекла'],
    'lights_on': ['включи фары'],
    'lights_off': ['выключи фары'],
    'find_car': ['где моя машина', 'найди машину'],
  },
  'fr': {
    'lock': ['verrouille les portes'],
    'unlock': ['déverrouille les portes'],
    'trunk_open': ['ouvre le coffre'],
    'trunk_close': ['ferme le coffre'],
    'window_open': ['ouvre la fenêtre', 'baisse la vitre'],
    'window_close': ['ferme la fenêtre', 'remonte la vitre'],
    'window_stop': ['arrête la vitre'],
    'ac_on': ['allume la clim'],
    'ac_off': ['éteins la clim'],
    'defrost': ['dégivre le pare-brise'],
    'lights_on': ['allume les phares'],
    'lights_off': ['éteins les phares'],
    'find_car': ['où est ma voiture', 'trouve ma voiture'],
  },
  'es': {
    'lock': ['bloquea las puertas'],
    'unlock': ['desbloquea las puertas'],
    'trunk_open': ['abre el maletero'],
    'trunk_close': ['cierra el maletero'],
    'window_open': ['abre la ventana', 'baja la ventanilla'],
    'window_close': ['cierra la ventana', 'sube la ventanilla'],
    'window_stop': ['detén la ventanilla'],
    'ac_on': ['enciende el aire'],
    'ac_off': ['apaga el aire'],
    'defrost': ['desempaña el parabrisas'],
    'lights_on': ['enciende las luces'],
    'lights_off': ['apaga las luces'],
    'find_car': ['dónde está mi coche', 'encuentra mi coche'],
  },
  'de': {
    'lock': ['verriegle die türen', 'schließ das auto ab'],
    'unlock': ['entriegle die türen'],
    'trunk_open': ['öffne den kofferraum'],
    'trunk_close': ['schließe den kofferraum'],
    'window_open': ['öffne das fenster', 'fenster runter'],
    'window_close': ['schließe das fenster', 'fenster hoch'],
    'window_stop': ['stopp das fenster'],
    'ac_on': ['klimaanlage an'],
    'ac_off': ['klimaanlage aus'],
    'defrost': ['frontscheibe enteisen'],
    'lights_on': ['scheinwerfer an', 'licht an'],
    'lights_off': ['scheinwerfer aus', 'licht aus'],
    'find_car': ['wo ist mein auto', 'finde mein auto'],
  },
  'cn': {
    'lock': ['锁车', '锁门'],
    'unlock': ['解锁', '开锁'],
    'trunk_open': ['打开后备箱'],
    'trunk_close': ['关闭后备箱'],
    'window_open': ['开窗', '打开车窗'],
    'window_close': ['关窗', '关闭车窗'],
    'window_stop': ['停止车窗'],
    'ac_on': ['打开空调', '开空调'],
    'ac_off': ['关闭空调', '关空调'],
    'defrost': ['除霜', '前挡除雾'],
    'lights_on': ['开灯', '打开大灯'],
    'lights_off': ['关灯', '关闭大灯'],
    'find_car': ['我的车在哪', '寻找车辆'],
  },
  'tr': {
    'lock': ['kapıları kilitle'],
    'unlock': ['kapıların kilidini aç'],
    'trunk_open': ['bagajı aç'],
    'trunk_close': ['bagajı kapat'],
    'window_open': ['camı aç', 'camı indir'],
    'window_close': ['camı kapat', 'camı kaldır'],
    'window_stop': ['camı durdur'],
    'ac_on': ['klimayı aç'],
    'ac_off': ['klimayı kapat'],
    'defrost': ['ön cam buğu gider'],
    'lights_on': ['farları aç'],
    'lights_off': ['farları kapat'],
    'find_car': ['arabam nerede', 'aracı bul'],
  },
  'fa': {
    'lock': ['درها را قفل کن'],
    'unlock': ['قفل درها را باز کن'],
    'trunk_open': ['صندوق عقب را باز کن'],
    'trunk_close': ['صندوق عقب را ببند'],
    'window_open': ['پنجره را باز کن', 'شیشه را پایین بده'],
    'window_close': ['پنجره را ببند', 'شیشه را بالا بده'],
    'window_stop': ['پنجره را متوقف کن'],
    'ac_on': ['کولر را روشن کن'],
    'ac_off': ['کولر را خاموش کن'],
    'defrost': ['بخارزدایی شیشه جلو'],
    'lights_on': ['چراغ‌ها را روشن کن'],
    'lights_off': ['چراغ‌ها را خاموش کن'],
    'find_car': ['ماشینم کجاست', 'ماشین را پیدا کن'],
  },
  'hi': {
    'lock': ['दरवाज़े लॉक करो', 'गाड़ी लॉक करो'],
    'unlock': ['दरवाज़े अनलॉक करो'],
    'trunk_open': ['डिक्की खोलो'],
    'trunk_close': ['डिक्की बंद करो'],
    'window_open': ['खिड़की खोलो', 'शीशा नीचे करो'],
    'window_close': ['खिड़की बंद करो', 'शीशा ऊपर करो'],
    'window_stop': ['खिड़की रोको'],
    'ac_on': ['एसी चालू करो'],
    'ac_off': ['एसी बंद करो'],
    'defrost': ['विंडशील्ड डीफ़्रॉस्ट करो'],
    'lights_on': ['हेडलाइट जलाओ', 'लाइट चालू करो'],
    'lights_off': ['लाइट बंद करो'],
    'find_car': ['मेरी गाड़ी कहाँ है', 'गाड़ी ढूंढो'],
  },
  'it': {
    'lock': ['blocca le porte', 'chiudi l\'auto'],
    'unlock': ['sblocca le porte'],
    'trunk_open': ['apri il bagagliaio'],
    'trunk_close': ['chiudi il bagagliaio'],
    'window_open': ['apri il finestrino', 'abbassa il finestrino'],
    'window_close': ['chiudi il finestrino', 'alza il finestrino'],
    'window_stop': ['ferma il finestrino'],
    'ac_on': ['accendi il clima', 'accendi l\'aria'],
    'ac_off': ['spegni il clima', 'spegni l\'aria'],
    'defrost': ['sbrina il parabrezza'],
    'lights_on': ['accendi i fari'],
    'lights_off': ['spegni i fari'],
    'find_car': ['dov\'è la mia auto', 'trova la mia auto'],
  },
  'pt': {
    'lock': ['tranca as portas', 'trava o carro'],
    'unlock': ['destranca as portas'],
    'trunk_open': ['abre o porta-malas'],
    'trunk_close': ['fecha o porta-malas'],
    'window_open': ['abre a janela', 'abaixa o vidro'],
    'window_close': ['fecha a janela', 'sobe o vidro'],
    'window_stop': ['para a janela'],
    'ac_on': ['liga o ar condicionado'],
    'ac_off': ['desliga o ar condicionado'],
    'defrost': ['desembaça o para-brisa'],
    'lights_on': ['liga os faróis'],
    'lights_off': ['desliga os faróis'],
    'find_car': ['onde está meu carro', 'encontra meu carro'],
  },
};

/// Build the localized [CommandPhraseSeed]s for [lang] by joining the
/// language-neutral [coreIntents] (id + baked args) with that language's
/// surface phrasings. Phrasings come from the inline base [_localizedCore]
/// MERGED with the language's [VoiceLangPack] (`voiceLangPacks`) extras, so a
/// language reaches full coverage from one pack entry. Empty for an
/// unlocalized language.
List<CommandPhraseSeed> _seedsForLang(String lang) {
  final base = _localizedCore[lang];
  final extra = voiceLangPacks[lang]?.commands;
  if (base == null && extra == null) return const [];
  final phrases = <String, List<String>>{...?base, ...?extra};
  final out = <CommandPhraseSeed>[];
  coreIntents.forEach((key, intent) {
    final list = phrases[key];
    if (list != null && list.isNotEmpty) {
      out.add(CommandPhraseSeed(intent.commandId, list, args: intent.args));
    }
  });
  return List.unmodifiable(out);
}

/// Localized command-phrase seeds per language. English uses the full
/// reference set ([commandVoicePhrases]); every other catalog language gets the
/// localized set derived from [coreIntents] + [_localizedCore]. Numeric
/// setpoints ([numberSeedsByLang]) are appended for any language that has them
/// (English + Arabic today). All built once at load.
final Map<String, List<CommandPhraseSeed>> commandSeedsByLang = {
  'en-us': [...commandVoicePhrases, ...?numberSeedsByLang['en-us']],
  for (final lang in _localizedCore.keys)
    lang: [..._seedsForLang(lang), ...?numberSeedsByLang[lang]],
};

bool isCommandLocalized(String langCode) =>
    (commandSeedsByLang[langCode] ?? const []).isNotEmpty;
