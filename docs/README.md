# ilink documentation

The app runs locally. Start with [standalone architecture](offline-first/architecture.md), [development](workflow/development.md), or [current verification](offline-first/final-verification.md).

| Area | Guide |
|---|---|
| Build and signing | [Release procedure](../RELEASE.md), [configuration](workflow/configuration.md) |
| Car SDK | [SDK overview](sdk/README.md), [command source](sdk/source-of-truth.md), [diagnostics](sdk/operations.md) |
| Head-unit integration | [DiLink display guides](50/README.md), [vehicle profiles](features/_car_domain/profiles/README.md) |
| Mini-apps | [Local installation](features/mini_apps/catalog.md), [permissions](features/mini_apps/security.md) |
| Voice | [Local speech](features/voice/README.md) |
| Native resources | [Command tables and models](offline-first/local-command-tables.md) |
| Security | [Security boundaries](kernel/security/README.md), [legacy verification](kernel/pubkey/README.md) |
| Optional internet | [User-controlled services](offline-first/service-reconnection.md), [GitHub updates](offline-first/github-ota.md) |

Layer boundaries are checked by test/architecture/layer_test.dart. Historical deployment, account, payment, MQTT, cloud speech and superseded planning documents have been archived outside Git; they are not setup requirements.
