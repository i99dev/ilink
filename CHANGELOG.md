# Changelog

This repository starts with the standalone codebase. Historical release notes are retained with the private archive of the previous repository. Future release entries are managed by release-please from Conventional Commits.

## [3.22.1-b](https://github.com/i99dev/ilink/compare/ilink-v3.22.0-b...ilink-v3.22.1-b) (2026-09-06)


### Bug Fixes

* **ci:** export the password vars before keytool reads them ([4c8ca27](https://github.com/i99dev/ilink/commit/4c8ca27442fae6860f9dca166e1e7dd4a2cbfb72))
* **ci:** locate keytool without relying on PATH, and reject WSL ([ac25d78](https://github.com/i99dev/ilink/commit/ac25d78e176b9e9ae98a1c9b0f79472cdca0330e))
* **ci:** pin CI to Flutter 3.47.2, the version this code actually builds on ([7e37123](https://github.com/i99dev/ilink/commit/7e37123b9f65dfaab23330deb9c2b1094f984966))
* **ci:** restore the blank-line layout Flutter 3.41.7's formatter expects ([65769a7](https://github.com/i99dev/ilink/commit/65769a795b9e3bb0c50f52d2cb04fedd4df066e5))


### Dependencies

* bump com.android.application from 8.11.1 to 8.13.2 in /android ([ea07e2c](https://github.com/i99dev/ilink/commit/ea07e2c91724bf2c2ff6dc7c8de0577d491cd4c9))
* bump com.google.protobuf:protobuf-java in /android ([b648f45](https://github.com/i99dev/ilink/commit/b648f454cad9ed68832fdd2e29406035a8d5e88e))
* bump connectivity_plus from 7.1.1 to 7.3.1 ([865b791](https://github.com/i99dev/ilink/commit/865b791d4d692e7f07e49dc643ac9f579290b31d))
* bump flutter_cache_manager from 3.4.1 to 3.4.2 ([6a16532](https://github.com/i99dev/ilink/commit/6a16532508b19d7af7c8b792fd20586e626d5254))
* bump flutter_secure_storage from 10.3.0 to 10.3.1 ([760b30b](https://github.com/i99dev/ilink/commit/760b30b0ac907d810306b0b1a354f01ec49d78da))
* bump flutter_svg from 2.2.4 to 2.3.0 ([84c4bba](https://github.com/i99dev/ilink/commit/84c4bba829e7613a012cf5a4a4a97b51869480f7))
* bump just_audio from 0.10.5 to 0.10.6 ([4ea3720](https://github.com/i99dev/ilink/commit/4ea3720eb8765a5ace3b0bcba0afb26cf4052fba))

## [Unreleased]

- Run core dashboard, workflow, catalog and English voice features locally without a payment system, login or hosted backend.
- Preserve the original Android release signer and use an explicit versionCode independent of Git history.
- Discover opted-in future updates through GitHub Releases; existing backend-based installations need one manual migration update.
- Enforce mini-app local permissions and WebView boundaries, and handle local voice capture errors and cancellation safely.
- Adopt the owner-approved MIT License and add standalone development/contribution guidance.

See the [standalone cleanup record](docs/offline-first/standalone-cleanup.md) and [final verification](docs/offline-first/final-verification.md) for the transformation detail, test evidence and remaining physical-device/publication acceptance work. This entry does not announce a published release.
