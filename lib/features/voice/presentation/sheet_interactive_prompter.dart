library;

import 'package:flutter/widgets.dart';

import '../../../app/app_navigator.dart';
import 'package:ilink/features/voice/domain/voice_tool_def.dart';
import 'package:ilink/features/voice/state/voice_interactive_gate.dart';
import 'widgets/voice_tool_consent_sheet.dart';
import 'widgets/voice_tool_display_sheet.dart';
import 'widgets/voice_tool_input_sheet.dart';
import 'widgets/voice_tool_select_sheet.dart';

class SheetInteractivePrompter implements InteractivePrompter {
  SheetInteractivePrompter({GlobalKey<NavigatorState>? navigatorKey})
    : _navigatorKey = navigatorKey ?? appNavigatorKey;

  final GlobalKey<NavigatorState> _navigatorKey;

  /// Tool-name → custom display builder. Add to this when a tool
  /// deserves a rich custom card (weather forecast widget, route
  /// map preview, restaurant detail with photos). The builder
  /// returns when the user dismisses; the prompter resolves
  /// after that future completes.
  static final Map<
    String,
    Future<void> Function(BuildContext, VoiceToolDef, Map<String, dynamic>)
  >
  _displayOverrides = {};

  /// Tool-name → custom select builder. Same convention as
  /// [_displayOverrides] but returns the user's pick. Useful for
  /// tools where a generic vertical list isn't expressive enough
  /// (e.g. a horizontal carousel of station logos for
  /// ``pick_radio_station``).
  static final Map<
    String,
    Future<SelectResult?> Function(
      BuildContext,
      VoiceToolDef,
      Map<String, dynamic>,
    )
  >
  _selectOverrides = {};

  /// Register a custom display sheet for [toolName]. Call from
  /// the per-feature setup code (e.g. weather feature's
  /// ``setupVoiceIntegration``). Idempotent: re-registering
  /// overwrites the previous builder.
  static void registerDisplay(
    String toolName,
    Future<void> Function(BuildContext, VoiceToolDef, Map<String, dynamic>)
    builder,
  ) {
    _displayOverrides[toolName] = builder;
  }

  /// Register a custom select sheet for [toolName].
  static void registerSelect(
    String toolName,
    Future<SelectResult?> Function(
      BuildContext,
      VoiceToolDef,
      Map<String, dynamic>,
    )
    builder,
  ) {
    _selectOverrides[toolName] = builder;
  }

  BuildContext? get _ctx => _navigatorKey.currentContext;

  @override
  Future<bool> confirm(VoiceToolDef tool, Map<String, dynamic> args) async {
    final ctx = _ctx;
    if (ctx == null) return false;
    return showVoiceToolConsentSheet(ctx, tool: tool, args: args);
  }

  @override
  Future<SelectResult?> select(
    VoiceToolDef tool,
    Map<String, dynamic> args,
  ) async {
    final ctx = _ctx;
    if (ctx == null) return null;
    final override = _selectOverrides[tool.name];
    if (override != null) return override(ctx, tool, args);
    return showVoiceToolSelectSheet(ctx, tool: tool, args: args);
  }

  @override
  Future<void> display(VoiceToolDef tool, Map<String, dynamic> args) async {
    final ctx = _ctx;
    if (ctx == null) return;
    final override = _displayOverrides[tool.name];
    if (override != null) {
      await override(ctx, tool, args);
      return;
    }
    await showVoiceToolDisplaySheet(ctx, tool: tool, args: args);
  }

  @override
  Future<String?> input(VoiceToolDef tool, Map<String, dynamic> args) async {
    final ctx = _ctx;
    if (ctx == null) return null;
    return showVoiceToolInputSheet(ctx, tool: tool, args: args);
  }
}
