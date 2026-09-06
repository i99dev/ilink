# Standalone application

The final conversion removes the hosted account, payment and DigitalOcean client systems. Startup requires only local settings and first-run device permissions. Vehicle commands, workflow execution, installed content and on-device speech run locally.

## Current guides

- [Architecture](architecture.md): local execution, storage and migration.
- [Optional internet features](service-reconnection.md): Downloads, Streaming and GitHub updates.
- [Command tables and speech resources](local-command-tables.md): bundled native assets, legacy local caches and model import.
- [Media and WebView boundaries](media-webview-egress.md): direct local playback and optional network access.
- [GitHub OTA](github-ota.md): update artifact and certificate verification contract.
- [Cleanup and signing record](standalone-cleanup.md): current verification, infrastructure and publication status.

## What changed

Payment SDK/client flows, checkout, subscriptions, credit balances, trials, login/pairing/OTP, account transfer, MQTT telemetry, hosted remote help, cloud voice and backend catalog/synchronization clients were removed. They have no settings switch or reconnection path.

The remaining internet settings all default off. Downloads permits supported public model downloads and declared mini-app network resources; Streaming permits user-selected online radio/TV; Updates checks GitHub Releases. None needs an ilink account or owned backend. Local imports and already installed resources remain available with these settings off.

The APK bundles the default English speech model and native command resources. Other languages need an existing/imported compatible model or an enabled download from the model publisher. The former custom Arabic Moonshine fallback works only when its compatible files already exist locally; it is not offered as a new hosted download.

Mini-app scope consent is stored per app ID and exact archive SHA-256, and enforced at runtime. Only selected supported scopes are granted; unknown and administrator scopes are denied. **Local permissions** lets the owner review or revoke access. Existing installations require scope review; a missing verifiable digest requires reimport. Gesture dispatch also requires confirmation for each operation. Vehicle and Android safety checks remain active.

New installs of legacy issuer-bound privileged mini-app extensions are unsupported pending explicit review. Existing cached tier-1 templates may still work; legacy tier-2 operations retain issuer/capability checks and fail closed without valid authority. Local operation does not grant administrator roles.

## Historical records

Prior selective-history plans, checkpoint audits and obsolete deployment documents were backed up outside Git and removed. Use the current cleanup and verification records for release decisions.
