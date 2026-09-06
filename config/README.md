# Build configuration

`dev.json` supplies local development defaults; `prod.json` supplies the same standalone production settings to local builds and GitHub release CI. `local.json.example` is a template for optional ignored machine overrides.

There is no backend URL, account credential or payment configuration. Daemon/ADB host settings refer to device-local services. Production public verification keys preserve compatibility with previously issued privileged extensions; they are not private keys and do not enable new issuer-bound installs.

Use `flutter run --dart-define-from-file=config/dev.json` for development, or `scripts/build-prod-apk.sh --release` with the original external signing key and environment described in [RELEASE.md](../RELEASE.md). Never put passwords or private keys in Dart defines; compiled app configuration is public.

When adding a local setting, update `lib/core/config/app_config.dart`, the appropriate JSON defaults and `tool/validate_prod_config.dart`. Release CI reads `config/prod.json`; there is no separate `.github/environments` configuration tree.
