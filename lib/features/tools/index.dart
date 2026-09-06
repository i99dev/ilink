/// Public surface of the Tools feature.
///
/// Consumers should import this file rather than reaching into the
/// feature's internal layers — keeps the contract narrow and makes
/// the registry the only entry point.
library;

export 'domain/tool.dart' show Tool, ToolKind, ToolStatusRing;
export 'domain/connectivity_state.dart' show ConnectivityState, NetState;
export 'presentation/tools_panel.dart' show ToolsPanel;
export 'registry/tools_registry.dart' show kToolsRegistry, resolveToolLabel;
export 'state/connectivity_controller.dart'
    show
        ConnectivityController,
        ToolCapability,
        ToggleOutcome,
        connectivityControllerProvider;
export 'state/connectivity_state_provider.dart' show connectivityStateProvider;
