# Configuration

AppConfig contains compile-time build settings: environment, local car mocking, loopback daemon/ADB ports, logging and powertrain. config/dev.json and config/prod.json provide checked-in defaults; config/local.json.example documents an optional ignored local override.

There is no backend URL or runtime backend override. No account or payment credential belongs in app configuration. Legacy mini-app issuer public verification keys remain compatibility data, not signing secrets or a service to deploy.

Local settings store UI preferences, voice language, first-run state and selected optional services. Downloads, Streaming and Updates default off; device-local resources do not depend on these switches.

Android release signing uses the existing keystore outside the repository, supplied through the environment or ignored local configuration. Keep the certificate identity unchanged for update compatibility. CI secret names are documented in [.github/SECRETS.md](../../.github/SECRETS.md); follow [RELEASE.md](../../RELEASE.md).
