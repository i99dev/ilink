import 'grammar_phrase.dart';
import 'voice_grammar.dart';

class CommandHit {
  const CommandHit({
    required this.commandId,
    required this.args,
    required this.matchedPhrase,
    required this.exact,
    required this.score,
  });

  final String commandId;
  final Map<String, dynamic> args;
  final String matchedPhrase;

  /// True when the normalized transcript equalled a grammar phrase exactly
  /// (highest confidence). False when resolved by token-subset fallback.
  final bool exact;

  /// Specificity of the match (number of content tokens in the matched
  /// phrase). Higher = more specific; used to pick the best of several
  /// candidate phrases.
  final double score;

  @override
  String toString() =>
      'CommandHit($commandId $args via "$matchedPhrase" '
      'exact=$exact score=$score)';
}

class LocalIntentMatcher {
  LocalIntentMatcher(this.grammar);

  final VoiceGrammar grammar;

  /// Content-free tokens dropped before token-subset matching. Kept small
  /// and conservative — only words that never disambiguate a command.
  static const Set<String> _fillers = {
    'please',
    'ok',
    'okay',
    'can',
    'could',
    'would',
    'will',
    'you',
    'i',
    'id',
    'we',
    'want',
    'wanna',
    'need',
    'like',
    'to',
    'for',
    'me',
    'the',
    'a',
    'an',
    'my',
    'now',
    'just',
    'go',
    'ahead',
    'and',
    'um',
    'uh',
  };

  /// Resolve [transcript] to a command, or null on no confident match.
  CommandHit? match(String transcript) {
    final normalized = normalizePhrase(transcript);
    if (normalized.isEmpty) return null;

    final stripped = _stripWake(normalized);
    if (stripped == null) return null; // bare wake word, nothing to do
    if (stripped.isEmpty) return null;

    // 1. Exact phrase — highest confidence, O(1).
    final direct = grammar.exact(stripped);
    if (direct != null) {
      return CommandHit(
        commandId: direct.commandId,
        args: direct.args,
        matchedPhrase: direct.text,
        exact: true,
        score: _contentTokens(direct.text).length.toDouble(),
      );
    }

    // 2. Token-subset fallback — every content token of a phrase is
    //    present in the transcript. Pick the MOST SPECIFIC such phrase
    //    (most content tokens) so "lock the doors" beats the bare "lock".
    final transcriptTokens = _contentTokens(stripped);
    if (transcriptTokens.isEmpty) return null;

    GrammarPhrase? best;
    var bestScore = 0;
    for (final phrase in grammar.phrases) {
      final phraseTokens = _contentTokens(phrase.text);
      if (phraseTokens.isEmpty) continue;
      if (phraseTokens.difference(transcriptTokens).isNotEmpty) continue;
      if (phraseTokens.length > bestScore) {
        bestScore = phraseTokens.length;
        best = phrase;
      }
    }
    if (best == null) return null;
    return CommandHit(
      commandId: best.commandId,
      args: best.args,
      matchedPhrase: best.text,
      exact: false,
      score: bestScore.toDouble(),
    );
  }

  /// Remove a leading wake phrase. Returns the remainder, or null if the
  /// transcript was *only* the wake word (caller should arm listening, not
  /// dispatch). When no wake prefix is present the transcript is returned
  /// unchanged (manual-trigger turns carry no wake word).
  String? _stripWake(String normalized) {
    for (final wake in grammar.wakePhrases) {
      if (normalized == wake) return null;
      if (normalized.startsWith('$wake ')) {
        return normalized.substring(wake.length + 1).trimLeft();
      }
    }
    return normalized;
  }

  Set<String> _contentTokens(String normalized) => {
    for (final tok in normalized.split(' '))
      if (tok.isNotEmpty && !_fillers.contains(tok)) tok,
  };
}
