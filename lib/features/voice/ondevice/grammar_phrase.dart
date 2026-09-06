/// One spoken phrase the on-device recognizer can match, bound to the
/// registry command it dispatches. Produced by [VoiceGrammar] and consumed
/// by [LocalIntentMatcher].
///
/// [text] is already normalized (lowercase, punctuation-stripped, single
/// spaced) so it can be used directly as a map key and compared against a
/// normalized transcript without re-processing.
class GrammarPhrase {
  const GrammarPhrase({
    required this.text,
    required this.commandId,
    this.args = const {},
  });

  /// Normalized spoken form, e.g. `lock the doors`.
  final String text;

  final String commandId;

  /// Args passed to dispatch. Empty for pure action commands (the v1 set);
  /// carries the discriminator for parameterized phrases (e.g. on/off).
  final Map<String, dynamic> args;

  @override
  String toString() => 'GrammarPhrase("$text" -> $commandId $args)';
}

/// Central, hand-curated natural phrasing for a command. Lives in one file
/// ([commandVoicePhrases]) so every spoken alias is maintained in a single
/// place rather than scattered across domain fragments. Auto-derived
/// label phrases cover the long tail; these add the natural forms a driver
/// actually says.
class CommandPhraseSeed {
  const CommandPhraseSeed(this.commandId, this.phrases, {this.args = const {}});

  final String commandId;
  final List<String> phrases;
  final Map<String, dynamic> args;
}
