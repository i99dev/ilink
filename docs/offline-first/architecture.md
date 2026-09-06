# Standalone architecture

This describes the final local execution model. See [standalone-cleanup.md](standalone-cleanup.md) for current verification and release status.

~~~text
Flutter UI and Riverpod state
  +-- Settings / workflow JSON / installed apps / local theme and media data
  +-- Local workflow compiler and engine
  +-- Local speech model -> intent classifier -> command router
  +-- Command router -> existing safety dispatcher -> Android / BYD APIs
  |     +-- valid existing encrypted local table cache, or bundled APK tables
  +-- Explicit optional network policy
        +-- Downloads: model publisher and declared mini-app resources
        +-- Streaming: radio / TV sources selected by the driver
        +-- Updates: GitHub Releases -> verified APK -> Android installer
~~~

## Startup and storage

Startup loads local settings, resumes local workflow execution, registers local bridge families and initializes native resources. First-run onboarding requests the relevant OS permissions. There is no authentication, subscription, activation, backend reachability or cloud account gate.

Settings and favorites remain in local preferences. Workflows use the existing atomic JSON store, compiler and execution engine; CRUD, imports, enable/disable and execution stay local. Existing installed mini-app IDs and saved/active theme data are retained where compatible, including older cache locations. A local device namespace replaces remote account identity; it is not an administrator role or server credential.

One-time upgrade cleanup deletes retired account tokens, MQTT credentials, cached license/account data and backend URL preferences. It preserves vehicle identity, onboarding, user settings and unrelated local cryptographic keys. No remote session is restored from old preferences.

## Commands and speech

Core dispatch uses the original argument, model, permission and vehicle-state checks. Valid existing encrypted command caches can be read locally; otherwise the signed APK supplies public command tables and native unit resources. No table provisioning request or server secret is needed. See the native resource guide for artifact provenance.

The voice entry point starts the on-device pipeline. A bundled English Vosk model supports clean offline installation. Compatible imported/installed models remain usable; public Vosk downloads require Downloads consent. Cloud token minting, paid broker, remote LLM/STT/TTS adapters and voice telemetry were removed.

## Content and trust

The radio directory is bundled; TV uses retained local catalogs and user imports. Actual internet playback requires Streaming consent. Local theme specifications and installed mini-app bundles are read from device storage.

Local mini-app import validates archive limits, paths, manifest structure and content hashes, then presents scope checkboxes. Hashes do not establish publisher identity. Only selected scopes are saved, bound to the app ID and exact archive SHA-256. Requested supported scopes start selected; other supported scopes require explicit owner selection. Unknown and administrator scopes are denied. Runtime checks enforce grants on vehicle, location, workflow, voice and native family APIs; revoked access or a different bundle cannot use the old grant. Gesture dispatch also requires confirmation for each operation.

The **Local permissions** action reviews or revokes these grants. Existing installations require scope review before launch; a missing verifiable archive digest requires reimport. New installs of legacy issuer-bound privileged extensions are rejected for review. Existing cached tier-1 templates may still work; tier-2 operations retain issuer/capability validation and fail closed without valid authority. Android APK imports are inspected and staged locally; Android's installer enforces package signature compatibility and installation consent.

## Network boundary

Only Downloads, Streaming and Updates remain in the persisted optional-service enum. Grants become effective after durable storage; revocation cancels registered HTTP work and stops native network playback. Unknown/retired backend routes are denied. Mini-app WebViews use the local bundle and apply the declared-origin/network policy when Downloads is enabled.

GitHub updates retain local package, version, digest and signer checks before offering Android installation. No app token, account service, payment provider, MQTT service or DigitalOcean deployment belongs in this architecture.
