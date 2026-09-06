# `platform/` — thin OS adapters

`lib/platform/` wraps Android/Flutter platform surfaces so the rest
of the app can use them with a stable Dart shape. Each module owns
one OS concern.

May import `sdk/_internal/` only. Forbidden: `kernel/`, `features/`,
`app/` — enforced by `test/architecture/layer_test.dart`.

## Modules

| Module | What it wraps |
|---|---|
| `deep_link/` | App-link / intent reception. `deep_link_listener.dart` exposes a stream of incoming URIs that the `kernel/routing/` deep-link router consumes. |
| `device/` | Device fingerprint primitives — `device_fingerprint.dart`, `install_id_provider.dart`, `model_detector.dart`. (The provider that *composes* these with kernel config + i18n lives in `app/device/`.) |
| `launcher/` | Launcher bootstrap (`launcher_bootstrap_controller.dart`, `launcher_privilege_status.dart`) for shipping the dash as the device's home app. |
| `network/` | Connectivity + certificate handling. |
| `observability/` | Sentry init + structured logging sinks. (The Sentry context binding to vehicle identity lives in `app/observability/`.) |
| `location/` | Location service wrapper. |

## What does NOT belong here

- Anything that imports kernel/ — that's composition; it goes in
  `app/<concern>/` or in a feature.
- Anything that holds product state (workflows, media, settings) — that's
  kernel or feature.
- Anything Riverpod-orchestration-shaped (a provider that watches
  multiple kernel providers and produces a derived value) — that's
  `app/` composition.

The litmus test: if this file were lifted into a second Flutter app
that did NOT have any of our features, would it still make sense?
If yes — it's platform/. If no — it's higher up.

## Why this layer

Keeps OS surfaces narrow and testable. Mocking `kernel/api/` in a
unit test doesn't require mocking deep-link reception too. And when
Flutter ships a breaking change in one of these wrappers, the blast
radius is one file in `platform/<X>/`, not the rest of the app.
