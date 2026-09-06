# Application architecture

The standalone app starts from local settings and device permissions. It requires no account, subscription or hosted application service.

| Layer | Responsibility |
|---|---|
| app | Startup and composition across features |
| features | Dashboard, car commands, workflows, mini-apps, local voice and media |
| kernel | Local settings, permission policies, optional internet consent, theme, localization and logging |
| platform | Android and Flutter platform adapters |
| sdk | Vehicle abstraction, local transport, identity and feature streams |

Features may depend on lower layers. The SDK is self-contained; kernel code must not import app or feature implementations. Architecture tests enforce these boundaries.

## Local command flow

Manual controls and recognized speech use CarClient.dispatch, which main.dart binds to CarCommandRouter. The router applies integrity, vehicle-profile, rate and stationary checks before the native CarBridge and UnitDispatcher. Public bundled tables provide action recipes. Valid existing local encrypted caches remain readable for upgrades.

Vehicle state is read through the SDK cache and native event streams. These device-local subscriptions are unrelated to the removed MQTT service. Unknown speed currently does not reject a stationary-only action; see the current verification record for this remaining safety limitation.

Mini-app family operations require selected scopes bound to both installed app ID and archive SHA-256. Native secondary surfaces are local visual renderers without a host JS bridge. Legacy signed extensions retain their separate authority checks.

Workflows are saved, compiled and executed locally. English speech is bundled and recognized on-device; additional models require local import or enabled upstream downloads. Radio and TV can play saved local resources and user-selected streams. GitHub Releases is the optional application update source.

See [standalone architecture](offline-first/architecture.md), [car SDK](sdk/README.md), and [permissions](features/mini_apps/security.md).
