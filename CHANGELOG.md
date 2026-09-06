# Changelog

This repository starts with the standalone codebase. Historical release notes are retained with the private archive of the previous repository. Future release entries are managed by release-please from Conventional Commits.

## [3.22.2-b](https://github.com/i99dev/ilink/releases/tag/v3.22.2-b) (2026-09-06)

First release published from the standalone iLINK repository.

### Features

- Run the dashboard, workflows, vehicle catalog and English speech recognition entirely on the device — no account, no subscription, no hosted API, no MQTT broker and no license check.
- Ship every outbound connection behind an optional-service switch that defaults to off, with no analytics SDK or telemetry.
- Browse and search the bundled radio directory (5,166 stations across 212 countries) with no network at all; only playing a live stream needs the internet, and only after it is enabled.
- Discover opted-in updates through GitHub Releases, verifying both the APK SHA-256 and the signing certificate before install.
- Enforce mini-app local permissions and WebView boundaries, and handle local voice capture errors and cancellation safely.
- Adopt the MIT License and add standalone development and contribution guidance.

### Bug Fixes

- Restore radio playback: `radioPlayerProvider` is no longer `autoDispose`, so the controller that takes it with `ref.read` can no longer be left holding a player whose `ref` was unmounted.
- Surface radio command failures in the UI instead of failing silently.
- Stop the station switch from hanging in a loading state when playback starts.
- Defer on-device speech engine refresh to a microtask, fixing an uninitialized-provider crash on startup.
- Derive the Android `versionCode` from the version name rather than commit history, so it always increases across releases.
- Tag releases `v<version>`; the device-side update source enforces this exactly and silently refuses anything else.
- Locate `keytool` without relying on `PATH`, and export the password variables before it reads them.
- Pin CI to Flutter 3.47.2, the version this code actually builds on.

### Dependencies

- Bump `com.android.application` from 8.11.1 to 8.13.2, and `com.google.protobuf:protobuf-java`.
- Bump `connectivity_plus` 7.1.1 → 7.3.1, `flutter_cache_manager` 3.4.1 → 3.4.2, `flutter_secure_storage` 10.3.0 → 10.3.1, `flutter_svg` 2.2.4 → 2.3.0 and `just_audio` 0.10.5 → 0.10.6.
- Hold Gradle below 9.6: 9.6.0 removed an internal API that every AGP 8.x relies on, and AGP stays at 8.x until AGP 9 is Flutter-ready.

### Known gaps

Physical head-unit acceptance (fresh install → speech → vehicle execution) has not been completed. See the [standalone cleanup record](docs/offline-first/standalone-cleanup.md) and [final verification](docs/offline-first/final-verification.md) for test evidence and the remaining device acceptance work.
