# Car SDK

The SDK exposes vehicle identity, live feature values, event subscriptions and gated command dispatch. Device-local transport and cached signal streams do not require a hosted service.

| Guide | Purpose |
|---|---|
| [Overview](overview.md) | Read/write architecture |
| [Dart API](dart.md) | Feature reads and application integration |
| [Native engine](engine-kotlin.md) | Local discovery and signal delivery |
| [Bridge](bridge.md) | Method and event channel contracts |
| [Source of truth](source-of-truth.md) | Public command tables and safe recipe changes |
| [Adding a feature](add-a-feature.md) | Local SDK development |
| [Identity](identity.md) | Device and profile resolution |
| [Operations](operations.md) | Diagnose local state and daemon issues |
| [Derived values](derived-features.md) | Local computed features |
| [Troubleshooting](troubleshooting.md) | Common integration failures |

The SDK remains self-contained. main.dart installs the gated dispatcher used by CarClient.dispatch. Direct raw invocation is not a replacement for the application's safety route. Historical cloud-transport and private-encryption plans have been archived outside Git.
