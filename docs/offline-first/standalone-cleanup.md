# Standalone cleanup and signing record

Started 2026-09-06, before code changes.

This records the initial standalone cleanup snapshot. See [final verification](final-verification.md) for the later OTA discovery audit, additional voice fixes/tests, rebuilt candidate APK and outstanding physical acceptance. The owner approved the [MIT License](../../LICENSE); that decision is closed.

## Release signing baseline

Application ID: `com.i99dev.ilink`. Existing release keystore: `.secrets/keystore/dash-release.jks`. SHA-256 of original file: `5ad3fc2ac7db99eaf08a1e9fa0756d095171d1ca420ba8e4b4394c3b8066d9d3`.

Gradle reads `DASH_KEYSTORE_PATH`, `DASH_KEYSTORE_PASSWORD`, `DASH_KEY_PASSWORD`, and optional `DASH_KEY_ALIAS` (default `dash`) from environment then the ignored `.env`. Release CI supplies the same existing keystore and GitHub secrets, with v1/v2/v3 signing enabled. No signing identity has been generated, rotated or changed. Baseline Gradle SHA-256: `c6e10a1df47285f61c3c0192c9310d3b40827dd752ae5cd55e2a7d49cbe66bbb`.

The exact keystore is backed up outside both repositories, in an owner-controlled directory outside Git (path intentionally not recorded here). The directory has inheritance disabled and permits only the current Windows user and SYSTEM. The backup is Windows DPAPI encrypted for the current user; decryption round-trip hash matches the original. This host-bound copy requires the same Windows identity/profile for restoration.

Existing CI signing passwords, alias and expected fingerprint were exported encrypted to an owner-only backup encryption key, then DPAPI encrypted alongside it in that same owner-controlled directory. No plaintext credentials were written to Git or logs. The temporary remote backup branch, workflow run and encrypted artifact were deleted after retrieval. The keystore password was verified against alias `dash`, a PrivateKeyEntry. Certificate SHA-256 is `2a4700925fe0c230c9bac63ab194ff9500a58a4ac0825c2196ee9ac7f33fc264`, exactly matching archived released APK asset `401595221--app-release.apk` verified with apksigner. Both the original keystore bytes and release signing identity remain unchanged.

## Publication boundary

A new repository is safer than force-pushing a one-commit branch into the old repository: old PR references and cached views are not removed by a branch reset. GitHub Support handles qualifying sensitive-data removal; clones/forks remain outside that guarantee. Existing repositories stay private while cleanup and final scans run.

Source: https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository

## Payment and account removal

Removed checkout, billing lifecycle, subscriptions, credits, trial/entitlement screens, QR payment presentation, payment/auth API clients, OTP/pairing, access/refresh tokens, backend configuration and account ownership transfer. Obsolete stored credentials are deleted on upgrade without deleting device settings or local keys. No payment provider remains in the app dependency graph. The retired backend's current branch contains only its retirement notice, and its private repository is archived with Actions disabled.

Provider components removed with the backend include the Stripe SDK, checkout/customer portal, Stripe webhooks and retry jobs, and the Telegram Payments/bot integration (`aiogram`). No replacement payment provider was introduced.

All ordinary dashboard features now use the local device profile and local feature policy. Optional profile PIN protection applies to private profile settings, never startup or vehicle access. OS permissions and vehicle safety checks remain necessary.

Flagged compatibility boundaries: cloud conversations, remote support and account ownership transfer were retired; new issuer-bound privileged extension installs cannot be recreated locally without their issuer authority. Cached tier-1 templates retain local checks; tier-2 operations retain issuer/capability validation and fail closed. These are explicit retired/unsupported flows, not retained login gates.

## DigitalOcean services deleted

The following app-owned resources were backed up as applicable and deletion verified:

- App Platform: `backend-ilink-prod` (API, scheduler, car-MQTT, car-persist, Celery, bot and migration job), `miniapp-ilink-prod`, `website-ilink-prod`, and `docs-ilink-prod`.
- Managed PostgreSQL `backend-ilink-pg` and Redis `backend-ilink-redis`.
- MQTT droplet `mqtt-broker-fra1` and its reserved IP.
- Space `ilink-miniapps`, its CDN endpoint and all 2,565 objects. The external backup contains 8,619,981,522 bytes with per-object SHA-256 records; size and ETag were checked against the live bucket before deletion.
- Obsolete DigitalOcean DNS zones `ilink.app` and `ilink.com`. The app domain's authoritative nameservers are Cloudflare; its authoritative zone and domain registration were not changed.

The BYD DigitalOcean project's resource inventory is empty. Unrelated applications, databases and domains were preserved. PostgreSQL has a custom-format dump and encrypted backup outside Git; original backend history is also preserved in a private external Git bundle.

Both temporary Spaces access keys used for inventory, backup and deletion were revoked after completion.

The owner subsequently authorized deletion of two additional storage buckets in a separate hosting project. Both were removed after verified external backups, confirmed absent afterwards, and the temporary cleanup key was revoked. Unrelated project resources were preserved.

## Core functionality migrated into the app

| Former hosted dependency | Standalone replacement |
| --- | --- |
| Feature/subscription policy and user bootstrap | Local device profile; account-free local features |
| Workflow CRUD, publish/sync and boot fetch | Device storage, local import/export and execution |
| Cloud voice, STT/TTS, token minting and command dispatch | On-device recognition, bundled English model, local command router and existing safety dispatcher |
| Command tables, execution units and vehicle metadata | Checked-in local tables, DEX units and BYD catalog |
| Mini-app catalog and bundle hosting | Four verified bundled mini-apps plus validated local archive imports |
| Mini-app authority for local capabilities | Explicit per-scope owner consent bound to installed bundle SHA-256; revocation checked on calls/events |
| Native application catalog/downloads | Installed-package discovery and file-based APK import with package/version/hash/signer checks |
| Theme catalog | Built-in themes and local installed-theme metadata/cache |
| Radio/media directory | 5,166 bundled stations in 212 countries, saved stations and local playlists/imports |
| Diagnostics and tamper upload | Local persistence/copy, with existing local safety checks |
| Backend app update endpoint | Optional direct GitHub releases with hash/package/version/certificate verification |

Bundled mini-apps: Battery Analyzer 0.5.11, Islam Prayer 0.7.4, Quran Player 0.5.1 and Workflow Canvas 0.1.31. Internet radio/TV streams still need connectivity. Optional model downloads go directly to the model publisher; custom models can be imported from files. Downloads, Streaming and GitHub updates default off. Retired DigitalOcean and app backend hosts are rejected by HTTP and mini-app network policy.

## Fresh repository and release continuity

The replacement repository is `i99dev/ilink`, private during verification. Only the current sanitized source is copied; old Git objects, branches, tags, pull-request references, private submodules and build outputs are excluded. Existing repositories remain private. Creating this repository does not purge copies or cached references associated with the old repositories, and no GitHub Support purge is claimed.

Release CI restores the exact original keystore into runner temporary storage from protected GitHub secrets, verifies its certificate, and removes the temporary file afterward. The Gradle signing configuration is unchanged. Android versionCode is explicitly 10000, above every one of the 73 archived APKs subsequently inspected with aapt (maximum 844); CI requires subsequent versions to exceed every published OTA metadata version. Resetting Git history therefore cannot reset Android's update ordering.

## Final verification (2026-09-06)

- Clean snapshot Flutter suite: **1,596 passed, one skipped**. Follow-up tests for the final privilege badge/consent wording passed (12); final analyzer reports no issues and formatting checks pass.
- Native secondary-surface policy: **four tests passed**; production Kotlin compiled. These surfaces have no host JS bridge and now restrict access to their own canonical bundle paths, denying network and browser geolocation/microphone/camera access.
- CI configuration, local command-table hex audit, production configuration validation and explicit release version guard pass.
- Release APK built successfully: `com.i99dev.ilink`, versionName `3.22.0-b`, versionCode `10000`, **81,669,749 bytes**. SHA-256: `b0d940a64c6b89c4ebd1acb8ce80a72b9e0fb50cd262209ccc3f9bd4b6b15183`.
- `apksigner verify` passed with v2/v3 signatures and exactly the original certificate SHA-256 recorded above. Original keystore bytes and `android/app/build.gradle.kts` still match their baseline hashes. Gradle compatibility flags added automatically by the local Flutter SDK do not alter that signing file or identity.
- Full source audit: **1,323 files**, 60 known-sensitive-material variants, zero matches. Gitleaks found two deterministic public operation IDs in `mini_app_table.textproto`: `32d1fb949b60ac5c` and `b425c9821693e0e7`. They equal the first 16 hex characters of SHA-256 of `mini_app_op:pkg.stack_list` and `mini_app_op:gesture.input_swipe`; they are not credentials. No blanket scanner allowlist was added.
- APK content audit: **847 entries read, zero findings, zero skipped**. Gitleaks scan of 278 extracted string-content groups also reports zero findings.

The replacement repository starts with one initial commit containing only this sanitized snapshot. The same secrets audit is repeated over its entire new Git history before pushing; old histories are not imported. Private evidence logs, signing credentials, service backups and APK outputs remain outside the committed source. At the time of that snapshot the repository was still private and no public release was claimed.

Hardware microphone, Android update-install, multi-display WebView and vehicle actuator checks still require a supported head unit. The two `fq-ilink-*` buckets were subsequently deleted with explicit owner authorization; that infrastructure decision is closed.
