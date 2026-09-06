import 'local_intent_matcher.dart';
import 'voice_grammar.dart';

/// What to do with one on-device recognizer transcript. The orchestration
/// controller acts on this; keeping the decision in a pure function makes
/// the wake/command policy unit-testable without the engine or the car.
sealed class OnDeviceVoiceDecision {
  const OnDeviceVoiceDecision();
}

class OnDeviceLocalCommand extends OnDeviceVoiceDecision {
  const OnDeviceLocalCommand(this.hit);
  final CommandHit hit;
  @override
  String toString() => 'OnDeviceLocalCommand($hit)';
}

class OnDeviceWakeTurn extends OnDeviceVoiceDecision {
  const OnDeviceWakeTurn(this.spokenQuery);
  final String? spokenQuery;
  @override
  String toString() => 'OnDeviceWakeTurn(${spokenQuery ?? "<bare>"})';
}

/// Do nothing. The transcript carried no wake phrase — hands-free MUST be
/// wake-gated so the assistant never acts on overheard conversation.
class OnDeviceIgnore extends OnDeviceVoiceDecision {
  const OnDeviceIgnore();
  @override
  String toString() => 'OnDeviceIgnore()';
}

class OnDeviceVoiceRouter {
  OnDeviceVoiceRouter(this.grammar, this.matcher);

  final VoiceGrammar grammar;
  final LocalIntentMatcher matcher;

  OnDeviceVoiceDecision decide(String transcript) {
    final normalized = normalizePhrase(transcript);
    if (normalized.isEmpty) return const OnDeviceIgnore();

    final remainder = _afterAnyWake(normalized, grammar.wakePhrases);
    if (remainder == null) {
      return const OnDeviceIgnore(); // no wake → wake-gated
    }
    if (remainder.isEmpty) return const OnDeviceWakeTurn(null); // bare wake

    // "Hey BYD" + a command — the matcher strips the wake itself, so hand it
    // the full transcript.
    final hit = matcher.match(transcript);
    if (hit != null) return OnDeviceLocalCommand(hit);

    return OnDeviceWakeTurn(remainder);
  }

  OnDeviceVoiceDecision decideManual(String transcript) {
    final hit = matcher.match(transcript);
    if (hit != null) return OnDeviceLocalCommand(hit);
    final normalized = normalizePhrase(transcript);
    return OnDeviceWakeTurn(normalized.isEmpty ? null : normalized);
  }

  /// Text after a leading wake phrase from [wakeSet] (possibly empty), or null
  /// when none of them prefix [normalized]. Uses the same normalization the
  /// grammar/matcher use, so they never disagree on what "wake" is. Shared by
  /// the "Hey BYD" and "Hey AI" sets.
  String? _afterAnyWake(String normalized, List<String> wakeSet) {
    for (final wake in wakeSet) {
      if (normalized == wake) return '';
      if (normalized.startsWith('$wake ')) {
        return normalized.substring(wake.length + 1).trimLeft();
      }
    }
    return null;
  }
}
