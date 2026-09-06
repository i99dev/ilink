import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:ilink/features/_car_domain/command/command.dart';
import 'package:ilink/features/_car_domain/command/registry.dart';
import 'package:ilink/features/_car_domain/consumer/car_consumer.dart';
import 'package:ilink/sdk/car/client.dart';
import 'package:ilink/kernel/settings/app_settings.dart';
import 'package:ilink/features/radio/providers.dart';
import 'package:ilink/features/radio/radio_voice_dispatch.dart';
import 'package:ilink/features/apps/app_voice_dispatch.dart';
import 'package:ilink/kernel/shell/shell_tool_bridge_provider.dart';

/// Pluggable dispatch surface for a domain of voice-callable commands.
///
/// Today there is one implementation ([CarToolRouter]) that wraps the
/// existing [CarCommandRouter]. A new domain = a new [ToolRouter] impl +
/// one line in [voiceToolRouterProvider] — no changes to the voice
/// controller or realtime client.
abstract class ToolRouter {
  /// Namespace claim, used only for logging / debugging. Routing is
  /// delegated by [handles] so a single router may own multiple dotted
  /// prefixes (e.g. CarToolRouter owns `door.*`, `light.*`, `climate.*`).
  String get namespace;

  /// Return true if this router owns [commandId]. CompositeToolRouter
  /// asks each registered router and forwards to the first match.
  bool handles(String commandId);

  /// Describe the commands this router exposes. Used by the
  /// `car_list_commands` fallback so the model can discover what's available
  /// at runtime. Entry shape: `{id, label, category, params}`.
  List<Map<String, dynamic>> describe();

  /// Router-owned entries to add to the voice manifest, on top of whatever
  /// ToolHandler derives from the registry. Routers that only dispatch
  /// registry-backed commands (e.g. [CarToolRouter]) return an empty list;
  /// delegate routers whose tool doesn't exist in the registry (e.g.
  /// `radio_assistant`) return their OpenAI-shaped function tool here.
  /// Default is empty so existing impls stay backwards-compatible.
  List<Map<String, dynamic>> manifestEntries() => const [];

  /// Dispatch one tool call. [commandId] is the original dotted id, not the
  /// mangled tool name. Must never throw — return `{error: ...}` instead.
  Future<Map<String, dynamic>> dispatch(
    String commandId,
    Map<String, dynamic> args,
  );
}

/// Routes car commands through the [CarWriteGate]. Voice + tunnel +
/// quick-action tiles all converge on the same gate so the safety
/// stack (integrity → rate-limit → stationary → audit) and the
/// caller-attribution log are uniform.
///
/// [categoryAllowList] narrows which registry commands this router claims
/// to handle. Empty (default) = all registry commands. The voice provider
/// wires it empty so the assistant can reach every actuator; the
/// dispatch-time stationary gate in `command_router` is what keeps that
/// safe. A non-empty set is still honoured if a future caller wants to
/// scope a router to specific categories.
class CarToolRouter implements ToolRouter {
  CarToolRouter(
    this._client,
    this._registry, {
    required bool devModeEnabled,
    Set<CommandCategory> categoryAllowList = const {},
  }) : _allow = categoryAllowList,
       _devModeEnabled = devModeEnabled;
  final CarClient _client;
  final Map<String, CarCommand> _registry;
  final Set<CommandCategory> _allow;
  final bool _devModeEnabled;

  bool _allowed(CarCommand cmd) =>
      _allow.isEmpty || _allow.contains(cmd.category);

  @override
  String get namespace => 'car';

  @override
  bool handles(String commandId) {
    final cmd = _registry[commandId];
    return cmd != null && _allowed(cmd);
  }

  @override
  List<Map<String, dynamic>> describe() => [
    for (final cmd in _registry.values)
      if (_allowed(cmd))
        {
          'id': cmd.id,
          'label': cmd.label,
          'category': cmd.category.name,
          'params': cmd.params,
        },
  ];

  /// CarToolRouter contributes nothing directly to the manifest — every
  /// tool it handles is already sourced from the registry by ToolHandler.
  @override
  List<Map<String, dynamic>> manifestEntries() => const [];

  @override
  Future<Map<String, dynamic>> dispatch(
    String commandId,
    Map<String, dynamic> args,
  ) {
    // Through the SDK so caller=voice ends up in the audit log.
    // CarClient.dispatch routes through the same CarCommandRouter the
    // tunnel + manual-press use, so unknown-id / platform-exception /
    // CommandOutcome translation are unchanged.
    return _client
        .dispatch(
          commandId,
          args: args,
          caller: VoiceConsumer(devModeEnabled: _devModeEnabled),
        )
        .then((m) => m.cast<String, dynamic>());
  }
}

/// Composes multiple [ToolRouter]s. Dispatch asks each router whether it
/// [handles] the id and forwards to the first match. Unknown commands
/// return a uniform `{error: ...}` shape.
class CompositeToolRouter implements ToolRouter {
  CompositeToolRouter(Iterable<ToolRouter> routers)
    : _routers = List.unmodifiable(routers);

  final List<ToolRouter> _routers;

  @override
  String get namespace => '*';

  @override
  bool handles(String commandId) => _routers.any((r) => r.handles(commandId));

  @override
  List<Map<String, dynamic>> describe() => [
    for (final r in _routers) ...r.describe(),
  ];

  @override
  List<Map<String, dynamic>> manifestEntries() => [
    for (final r in _routers) ...r.manifestEntries(),
  ];

  @override
  Future<Map<String, dynamic>> dispatch(
    String commandId,
    Map<String, dynamic> args,
  ) async {
    for (final r in _routers) {
      if (r.handles(commandId)) return r.dispatch(commandId, args);
    }
    return {'error': 'unknown command: $commandId'};
  }
}

/// Single voice-assistant router wired to every domain we expose. Adding a
/// new domain = new ToolRouter impl + one line here.
///
/// Voice gets the FULL car toolset (windows, climate, doors, …) in every
/// mode — driving the car by voice is a shipping feature, not a dev-only
/// one. Safety is enforced at DISPATCH time, not by hiding tools:
/// `command_router` blocks any `requiresStationary` command while the car
/// is moving (`UNSAFE_WHILE_MOVING`) regardless of caller. The
/// `devCarControlsEnabled` flag no longer gates the toolset — it only
/// tags the audit log (dev vs prod run) through [VoiceConsumer].
class LocalDomainToolRouter extends ToolRouter {
  LocalDomainToolRouter(this.namespace, this.commands, this.execute);
  @override
  final String namespace;
  final Map<String, CarCommand> commands;
  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)
  execute;
  @override
  bool handles(String id) => commands.containsKey(id);
  @override
  List<Map<String, dynamic>> describe() => [
    for (final c in commands.values)
      {
        'id': c.id,
        'label': c.label,
        'category': c.category.name,
        'params': c.params,
      },
  ];
  @override
  Future<Map<String, dynamic>> dispatch(String id, Map<String, dynamic> args) =>
      execute(id, args);
}

final voiceToolRouterProvider = Provider<ToolRouter>((ref) {
  final client = ref.watch(carClientProvider);
  final registry = ref.watch(commandRegistryProvider);
  final devOn = ref.watch(
    settingsProvider.select((s) => s.value?.devCarControlsEnabled ?? false),
  );
  return CompositeToolRouter([
    LocalDomainToolRouter(
      'radio',
      {
        for (final c in registry.values)
          if (c.category == CommandCategory.radio) c.id: c,
      },
      (id, args) => dispatchRadioCommand(
        ref.read(radioControllerProvider.notifier),
        id,
        args,
        curated: ref.read(curatedPlaylistsControllerProvider.notifier),
      ),
    ),
    LocalDomainToolRouter(
      'apps',
      {
        for (final c in registry.values)
          if (c.category == CommandCategory.apps) c.id: c,
      },
      (id, args) =>
          dispatchAppCommand(ref.read(shellOpsCoordinatorProvider), id, args),
    ),
    CarToolRouter(client, registry, devModeEnabled: devOn),
  ]);
});
