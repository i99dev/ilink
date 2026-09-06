import 'voice_tool_ui_hint.dart';

/// Local tool schema and interaction requirements shared by tool surfaces.
class VoiceToolDef {
  const VoiceToolDef({
    required this.name,
    required this.description,
    required this.parameters,
    this.uiHint = VoiceToolUiHint.none,
  });

  final String name;
  final String description;
  final Map<String, dynamic> parameters;

  final VoiceToolUiHint uiHint;

  /// Back-compat getter — true when the tool wants the user to
  /// confirm before execution. Same predicate the original
  /// consent gate read. New code should switch on [uiHint]
  /// directly to discriminate confirm-vs-select-vs-display.
  bool get requiresConsent => uiHint == VoiceToolUiHint.confirm;

  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'parameters': parameters,
  };
}
