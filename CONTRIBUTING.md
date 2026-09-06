# Contributing

iLINK is a standalone Flutter application for Android head units. Contributions should preserve local operation, explicit permissions and vehicle safety checks. Please follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Set up a fork

Fork `i99dev/ilink` on GitHub, then replace `YOUR-USERNAME` below with your account name:

```sh
git clone https://github.com/YOUR-USERNAME/ilink.git
cd ilink
git remote add upstream https://github.com/i99dev/ilink.git
git fetch upstream
git switch -c fix/short-description upstream/main
```

Use a focused branch such as `fix/local-model-loading`, `feat/radio-search` or `docs/setup`. These prefixes are a convention; CI validates PR titles, not branch names. Target `main` when opening the PR. This checkout needs no secrets submodule.

## Flutter and Android setup

- Install [uv](https://docs.astral.sh/uv/) for the one Python gate: `uv run --python 3.12 scripts/ci/check_release_version_test.py`. uv fetches the interpreter itself, so no separate Python install is needed.
- Install **Flutter 3.47.2 stable**, which includes Dart. Use the version pinned in the [setup action](.github/actions/setup-flutter/action.yml).
- Install Android Studio or the Android command-line tools, an Android SDK and platform tools, and a **JDK 17** environment for Gradle.
- Install Android SDK Platform **36**, **NDK 28.2.13676358** and **CMake 3.22.1** through the SDK Manager. Compile SDK follows the pinned Flutter SDK; NDK/CMake and Java versions are set in [Android build configuration](android/app/build.gradle.kts).
- Run `flutter doctor -v` and resolve Android toolchain issues. Accept SDK licenses with `flutter doctor --android-licenses`.

From the repository root:

```sh
flutter pub get
flutter gen-l10n
flutter devices
flutter build apk --debug --dart-define-from-file=config/prod.json
```

The debug APK is written to `build/app/outputs/flutter-apk/app-debug.apk`. To run on a selected emulator or development device:

```sh
flutter run -d DEVICE-ID --debug --dart-define-from-file=config/prod.json
```

Replace `DEVICE-ID` with a value from `flutter devices`. Dependencies resolve through Pub and Gradle using the checked-in configuration and lockfile; the first build needs network access to download build dependencies. Preserve bundled offline assets. Local app operation requires no account or hosted backend.

Debug builds use a development signing identity and need no release keystore, credentials or `.env`. Use an emulator or a dedicated development device: a debug-signed APK cannot update an installed official release with the same package ID. Do not uninstall an existing installation without preserving its local data. Maintainers handle official signing and publication through the [release process](RELEASE.md); never regenerate or replace the existing release key, or commit keys, passwords or personal configuration.

For an isolated UI smoke test, follow the [local emulator guide](docs/workflow/emulator.md). It uses mock car data and does not require backend pairing or changing the emulator's vehicle identity.

## Checks before opening a PR

Run the same checks as [PR CI](.github/workflows/ci.yml) from the repository root:

```sh
flutter pub get
dart format --set-exit-if-changed .
flutter analyze
flutter test
dart run tool/audit_hex.dart
dart run tool/validate_prod_config.dart
uv run --python 3.12 scripts/ci/check_release_version_test.py
```

The format command can update files and reports failure when changes were necessary; review those changes and run it again. The hex audit checks that vehicle feature IDs remain in their approved table locations. The configuration validator checks the production definitions without connecting to a backend. Do not weaken either check to hide a failure.

Run focused tests while developing, then the full checks above. Add regression coverage for behavior changes where a test can demonstrate the failure. If you change translations, edit the ARB files under `lib/kernel/i18n`, run `flutter gen-l10n`, and include generated changes. Include lockfile updates when changing dependencies.

For Android native changes, also build the debug APK and run applicable host JVM tests from `android`:

```sh
./gradlew :app:testDebugUnitTest
```

On Windows PowerShell use `.\gradlew.bat :app:testDebugUnitTest`. Native tests are an additional local check; the PR CI workflow currently runs the Dart/Flutter checks listed above.

## Head-unit verification

Emulator, widget and host JVM tests cannot establish BYD firmware compatibility, real vehicle signals, audio routing or instrument-cluster behavior. For changes touching those paths, state exactly which device, vehicle model and firmware you tested, the steps and results, and what remains untested. Do not describe a passing mock test as hardware verification.

Perform physical checks only on an authorized development vehicle, parked in a safe place. Preserve stationary checks, action consent, permission scopes and failure handling; do not bypass them to make a test pass. Test denied permissions and unavailable hardware as well as successful operations. Keep driving separate from development and testing.

## Commits and pull requests

Use Conventional Commit titles, for example `fix: preserve local voice settings` or `feat(radio): add station search`. The [PR-title check](.github/workflows/commitlint.yml) accepts `feat`, `fix`, `perf`, `refactor`, `docs`, `test`, `build`, `ci`, `chore` and `deps`. Scope is optional; the subject must start with a lowercase letter and must not end with a period. Mark breaking changes with `!` or a `BREAKING CHANGE:` footer and explain the migration.

Keep each PR focused. Explain the problem, resulting behavior, relevant issue, checks performed and any limits. Include screenshots for visible UI changes and hardware evidence where applicable. Call out changes to stored data, permissions, network access, bundled assets or compatibility. Do not include credentials, VINs, precise locations or other personal data in screenshots, logs or fixtures.

Push your branch to your fork and open a PR against `main`. Maintainers review and merge changes; contributors should not publish release artifacts or change release versions as an incidental part of an unrelated fix.

## Issues and private reports

Use the repository's bug or feature issue template. Include the app version, model and head-unit firmware, reproduction steps, expected and actual behavior, and sanitized logs.

Do not post exploitable security details or private conduct reports in public issues. For security vulnerabilities, use GitHub's private vulnerability reporting option in the repository's Security tab if available. Otherwise, contact a maintainer privately through a contact method they have made available. Conduct concerns follow the private-contact approach in the [Code of Conduct](CODE_OF_CONDUCT.md).
