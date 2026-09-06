/// Barrel for the car write-side. Reads + real-time live in
/// `lib/sdk/car/`. This barrel only re-exports the surfaces a feature
/// widget needs to dispatch a registered command (CarCommand metadata
/// + the command router).
library;

export '../../sdk/car/_transport/car_bridge.dart';
export 'command/action_ids.dart';
export 'command/command.dart';
export 'command/command_outcome.dart';
export 'command/registry.dart';
export 'router/command_router.dart';
