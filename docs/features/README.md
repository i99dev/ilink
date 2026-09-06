# Product features

Features contain product controllers, local persistence and presentation. Shared settings and cross-cutting infrastructure live in kernel; device adapters live in platform and sdk; app owns startup composition.

Current feature areas include the dashboard, vehicle controls, local workflows, on-device voice, mini-apps, radio, TV, native installed apps and settings. Account/login, payment, MQTT, remote assistance and cloud speech modules were removed.

Use existing scoped mini-app and vehicle dispatcher boundaries when adding functionality. Add only optional internet operations that fit the owner's Downloads, Streaming or Updates consent. See [architecture](../architecture.md).
