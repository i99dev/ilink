# Changelog

This repository starts with the standalone codebase. Historical release notes are retained with the private archive of the previous repository. Future release entries are managed by release-please from Conventional Commits.

## [Unreleased]

- Run core dashboard, workflow, catalog and English voice features locally without a payment system, login or hosted backend.
- Preserve the original Android release signer and use an explicit versionCode independent of Git history.
- Discover opted-in future updates through GitHub Releases; existing backend-based installations need one manual migration update.
- Enforce mini-app local permissions and WebView boundaries, and handle local voice capture errors and cancellation safely.
- Adopt the owner-approved MIT License and add standalone development/contribution guidance.

See the [standalone cleanup record](docs/offline-first/standalone-cleanup.md) and [final verification](docs/offline-first/final-verification.md) for the transformation detail, test evidence and remaining physical-device/publication acceptance work. This entry does not announce a published release.
