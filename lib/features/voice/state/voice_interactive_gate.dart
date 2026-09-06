library;

import 'dart:convert';

import '../domain/voice_tool_def.dart';
import '../domain/voice_tool_ui_hint.dart';

typedef ToolDispatcher =
    Future<String> Function(String name, Map<String, dynamic> args);

abstract class InteractivePrompter {
  /// Yes / No on a destructive action. ``true`` = allow, ``false``
  /// = deny. Default implementation returns ``false`` so an
  /// unconfigured prompter fails closed.
  Future<bool> confirm(VoiceToolDef tool, Map<String, dynamic> args);

  /// Pick one option from the list embedded in [args]. Returns
  /// the chosen entry's identifier + label, or ``null`` if the
  /// user dismissed.
  Future<SelectResult?> select(VoiceToolDef tool, Map<String, dynamic> args);

  Future<void> display(VoiceToolDef tool, Map<String, dynamic> args);

  /// Free-text input from the user. Returns the typed string, or
  /// ``null`` if dismissed.
  Future<String?> input(VoiceToolDef tool, Map<String, dynamic> args);
}

class SelectResult {
  const SelectResult({required this.id, required this.label});
  final String id;
  final String label;
}

/// JSON-encoded synthetic results the gate emits on the deny /
/// cancel paths. Stable wire format so prompt copy that handles
/// these can rely on the shape across tool types.
String _encodeDenied() =>
    jsonEncode({'status': 'denied', 'reason': 'user_declined'});
String _encodeCancelled() =>
    jsonEncode({'status': 'cancelled', 'reason': 'user_dismissed'});
String _encodeShown() => jsonEncode({'status': 'shown'});
String _encodeSelected(SelectResult r) =>
    jsonEncode({'selected_id': r.id, 'selected_label': r.label});
String _encodeText(String text) => jsonEncode({'text': text});

/// Production-grade interactive gate. See module docstring for the
/// dispatch matrix.
class VoiceInteractiveGate {
  VoiceInteractiveGate({
    required Iterable<VoiceToolDef> tools,
    required this.prompter,
    required this.inner,
  }) : _byName = {for (final t in tools) t.name: t};

  final Map<String, VoiceToolDef> _byName;
  final InteractivePrompter prompter;
  final ToolDispatcher inner;

  /// Names the user has already approved this session for the
  /// confirm strategy. Cleared on gate teardown.
  final Set<String> _approvedConfirms = <String>{};

  Future<String> dispatch(String name, Map<String, dynamic> args) async {
    final tool = _byName[name];
    if (tool == null) return inner(name, args);

    switch (tool.uiHint) {
      case VoiceToolUiHint.none:
        return inner(name, args);

      case VoiceToolUiHint.confirm:
        if (_approvedConfirms.contains(name)) return inner(name, args);
        final ok = await prompter.confirm(tool, args);
        if (!ok) return _encodeDenied();
        _approvedConfirms.add(name);
        return inner(name, args);

      case VoiceToolUiHint.select:
        final picked = await prompter.select(tool, args);
        if (picked == null) return _encodeCancelled();
        return _encodeSelected(picked);

      case VoiceToolUiHint.display:
        await prompter.display(tool, args);
        return _encodeShown();

      case VoiceToolUiHint.input:
        final text = await prompter.input(tool, args);
        if (text == null) return _encodeCancelled();
        return _encodeText(text);
    }
  }

  /// Test hook — pre-seed the confirm cache.
  void preApproveConfirm(String name) => _approvedConfirms.add(name);

  void clear() => _approvedConfirms.clear();
}

/// Convenience: pretty-print a tool's args for any sheet that
/// wants to surface "the assistant wants to: …". Falls back to
/// ``{}`` on encode error so the sheet still renders.
String formatInteractiveArgs(Map<String, dynamic> args) {
  if (args.isEmpty) return '';
  try {
    return const JsonEncoder.withIndent('  ').convert(args);
  } catch (_) {
    return '$args';
  }
}
