library;

const List<String> _ones = [
  'zero',
  'one',
  'two',
  'three',
  'four',
  'five',
  'six',
  'seven',
  'eight',
  'nine',
  'ten',
  'eleven',
  'twelve',
  'thirteen',
  'fourteen',
  'fifteen',
  'sixteen',
  'seventeen',
  'eighteen',
  'nineteen',
];

const List<String> _tens = [
  '', // 0
  '', // 10 (handled by _ones)
  'twenty',
  'thirty',
  'forty',
  'fifty',
  'sixty',
  'seventy',
  'eighty',
  'ninety',
];

/// Spoken English for [n] (0–99), space-joined; null when out of range.
String? englishNumberWord(int n) {
  if (n < 0 || n > 99) return null;
  if (n < 20) return _ones[n];
  final tens = _tens[n ~/ 10];
  final unit = n % 10;
  return unit == 0 ? tens : '$tens ${_ones[unit]}';
}

// ── Arabic ──────────────────────────────────────────────────────────────
//
// Best-effort spoken Arabic for the same enumeration (DRAFT — the Arabic Vosk
// model's exact token output for numbers needs on-car tuning, same caveat as
// the localized command phrases). Masculine forms, which is what's said for a
// bare value/level. Compounds use the spoken "<unit> و<tens>" order
// (e.g. 22 → "اثنان وعشرون"); the "و" stays attached to the tens word, matching
// how the model emits it. `normalizePhrase` keeps Arabic letters, so these key
// the grammar directly.

const List<String> _arOnes = [
  'صفر',
  'واحد',
  'اثنان',
  'ثلاثة',
  'أربعة',
  'خمسة',
  'ستة',
  'سبعة',
  'ثمانية',
  'تسعة',
];

const List<String> _arTeens = [
  'عشرة', // 10
  'أحد عشر',
  'اثنا عشر',
  'ثلاثة عشر',
  'أربعة عشر',
  'خمسة عشر',
  'ستة عشر',
  'سبعة عشر',
  'ثمانية عشر',
  'تسعة عشر',
];

const List<String> _arTens = [
  '', // 0
  '', // 10 (handled by _arTeens)
  'عشرون',
  'ثلاثون',
  'أربعون',
  'خمسون',
  'ستون',
  'سبعون',
  'ثمانون',
  'تسعون',
];

/// Spoken Arabic for [n] (0–99); null when out of range. See the note above.
String? arabicNumberWord(int n) {
  if (n < 0 || n > 99) return null;
  if (n < 10) return _arOnes[n];
  if (n < 20) return _arTeens[n - 10];
  final tens = _arTens[n ~/ 10];
  final unit = n % 10;
  return unit == 0 ? tens : '${_arOnes[unit]} و$tens';
}
