# Local diagnostics

Inspect the active vehicle model, device-local daemon connection and app build information before changing configuration. A missing vehicle signal can mean unsupported firmware, unavailable permissions or a disconnected local daemon; signing in cannot repair it.

For local diagnostics, use adb devices -l and read-only logcat filters for CarBridge, UnitDispatcher, VoskRecognizer and Flutter. Do not issue writes, clear app data or install over an existing vehicle application without an identified safe target and authorization.

For voice, grant microphone permission, confirm the selected local model, and try a supported phrase. Default English is bundled; other models require compatible imported files or Downloads consent. Native capture failure must show an error and stop the turn. Recognition and successful dispatch are distinct from observed actuator movement.

For updates, follow the [GitHub OTA contract](../offline-first/github-ota.md). Preserve the installed package identity, monotonically increasing versionCode and exact release signing certificate.

There are no hosted service health endpoints or account recovery steps for this app. Current unresolved hardware checks are recorded in [final verification](../offline-first/final-verification.md).
