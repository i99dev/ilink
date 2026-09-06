library;

enum VoiceToolUiHint {
  /// No UI — dispatch through the registered router immediately.
  /// Default for non-destructive car commands (lock_doors,
  /// climate.temp, light.flash) and for invisible backend tools.
  none,

  confirm,

  select,

  display,

  /// Free-text input (e.g. "where do you want to go?"). Returns
  /// ``{"text": "..."}`` or ``{"cancelled": true}``.
  input,
}

extension VoiceToolUiHintWire on VoiceToolUiHint {
  /// JSON wire value. Stable across builds — backend mirrors
  /// these strings when serialising ``voice_tool.ui_hint``.
  String get wireValue => switch (this) {
    VoiceToolUiHint.none => 'none',
    VoiceToolUiHint.confirm => 'confirm',
    VoiceToolUiHint.select => 'select',
    VoiceToolUiHint.display => 'display',
    VoiceToolUiHint.input => 'input',
  };

  static VoiceToolUiHint fromWire(Object? raw) => switch (raw) {
    'confirm' => VoiceToolUiHint.confirm,
    'select' => VoiceToolUiHint.select,
    'display' => VoiceToolUiHint.display,
    'input' => VoiceToolUiHint.input,
    _ => VoiceToolUiHint.none,
  };
}
