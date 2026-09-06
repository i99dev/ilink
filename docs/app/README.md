# Application composition

lib/app connects startup, local settings, feature policy, navigation and platform lifecycle. lib/main.dart binds the SDK's gated dispatcher to CarCommandRouter so user controls, workflows and voice share the same safety checks.

Feature implementations live under lib/features; platform integrations and the SDK remain independent of application composition. Account, payment and MQTT composition modules have been removed. Startup does not wait for a server or identity token.

See [architecture](../architecture.md) and [standalone startup](../offline-first/architecture.md).
