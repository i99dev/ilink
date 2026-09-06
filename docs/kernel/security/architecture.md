# Security architecture

The app keeps release signing, local data encryption and mini-app authority separate.

- Android release signing identifies install-compatible updates. The existing private keystore is external; the APK may contain its public verification fingerprint.
- Public offline command tables provide fresh-install recipes. Local encrypted caches and their key stores preserve readable data across upgrades; compatibility code is not an active server integration.
- Each installation maintains its own ADB authorization keypair. Shared fleet private keys must not be embedded in assets.
- Mini-app local scopes are approved for an exact app ID and bundle SHA-256. Digest changes require renewed consent. Legacy signed administrator operations retain their certificate/capability gates.
- Vehicle writes use the shared integrity, rate and stationary checks. Unknown speed is an existing limitation, not a guarantee that a command is safe.
- Optional network access is explicit and disabled by default. Secondary native WebViews are local visual surfaces without a host bridge.

See [mini-app security](../../features/mini_apps/security.md) and [media boundaries](../../offline-first/media-webview-egress.md).
