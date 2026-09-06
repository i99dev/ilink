# Credentials and external-service review

Review date: 2026-09-06. This follow-up treats the source and network boundaries as potentially unsafe inputs and distinguishes observed checks from guarantees. It is a source/host review, not a physical-device packet capture or an independent penetration-test certification.

## Result

**No unresolved embedded credentials were found in the reviewed source, fresh Git history or audited release APK. The app is not free of third-party links or optional internet features.** GitHub OTA, publisher model downloads, radio/TV and some bundled mini-app functions intentionally use external services. The owner has been asked whether those functional optional features should remain; they have not been silently removed.

The scan checks known private signing/service material separately from public identifiers. A public certificate, SHA-256 digest, operation token or domain-separation salt is not an API credential. Device-local ADB/patch keys and the external original APK release keystore serve different purposes and must not be deleted together.

## Obsolete integrations removed in this follow-up

- Telegram mini-app feedback button, bot URL builder and its profile-ID/app-ID/bundle-digest payload.
- About-screen outbound sponsor/community links. Static attribution remains.
- Android automatic verification of the retired hosted mini-app link domain. New pinned shortcuts use `car-ilink://mini-app/<id>` and target this Android package. Existing pinned shortcuts retain local parsing/intent compatibility without domain verification or a generated browser URL.
- Unused issuer public-key settings and the obsolete build-script requirement for them. These were public keys, not leaked private credentials; no production verifier consumed them after the legacy verifier cleanup.
- Misleading cryptography comments claiming that public certificate-derived encryption required possession of the release private key, or that wrapping a derived key prevented reconstruction from its public/device inputs. The retained compatibility algorithms and signing identity are unchanged.

## Model archive and download hardening

The review found missing extraction limits and implicit redirect behavior in the native model provisioner. The updated provisioner applies limits to actual bytes read, including local imports and bundled archives: **512 MiB compressed, 1 GiB expanded, 512 MiB per file and 4,096 entries**, while preserving a 16 MiB free-space reserve. Paths are limited to 1,024 characters and 32 components. It rejects traversal, duplicate/conflicting paths and directory entries containing file data. Failures clean staging/invalid partial data without replacing an already usable model.

Native downloads accept only the 12 curated Vosk HTTPS model URLs. Credentials, query parameters, custom ports, other destinations and redirects are rejected. Resume responses must match the requested offset and bounded total size. This reduces destination and resource-exhaustion risk; it does **not** authenticate publisher content with a pinned digest. Existing local models and the bundled English model remain supported; custom fallback archives can still be imported locally within the limits.

## Remaining external connections

| Surface | Connection / boundary |
| --- | --- |
| GitHub OTA | GitHub Releases API and release asset downloads; Updates consent is off by default. Explicit download and Android install approval remain required. |
| Extra speech models | Direct Vosk publisher downloads, only with Downloads consent. English is bundled and works without download. |
| Radio / TV | 5,166 station URLs across 2,548 hosts: 2,468 HTTP and 2,698 HTTPS, plus user-selected playlist/stream URLs. Streaming consent required. HTTP streams provide no transport confidentiality/integrity; a bundled URL is not proof that its operator or content is trusted. |
| Bundled mini-app features | `api.aladhan.com` receives prayer-location coordinates; `everyayah.com` serves Quran audio; `tile.openstreetmap.org` serves map tiles. Downloads consent also controls declared mini-app network origins; local bundles remain available offline. |
| External navigation/media apps | User-triggered handoff to maps/media applications can cause those separate applications to connect. App network consent is not a device-wide firewall. |
| Imported content | User-imported playlists and mini-app archives can introduce new destinations; static scans cannot enumerate future imports. Archive/origin/permission validation remains necessary. |
| Build/development resources | Flutter/Gradle/package registries and CI actions are development dependencies. Documentation, licenses and source attribution contain external links that are not app service calls. |

Retired DO/backend host strings remain in explicit deny rules, historical migration explanations and some original bundle metadata. Removing a deny-rule string would weaken the block; a metadata/comment reference must be distinguished from an executable request.

## Evidence and limits

- Final source known-material scan: 1,229 files and 60 known secret variants, zero matches.
- Rebuilt APK scan: 780 entries, zero known-secret matches or skipped entries; extracted-string Gitleaks scan found zero issues.
- Source/history Gitleaks findings are the two public mini-app operation IDs and a keystore file checksum; no blanket suppression was added.
- All 11 focused optional-service and mini-app offline-egress tests passed in this follow-up. These cover default-off behavior, opted-in requests, revocation and local-resource/remote-origin restrictions.
- The updated Flutter suite passes **1,448 tests with one pre-existing skip**; native tests pass **342 with zero failures or skips**. The ten new native policy tests include real English model extraction: 41,205,931 compressed bytes to 70,898,967 expanded bytes, without model downloads or network traffic. Analyzer and formatting checks pass.
- Android WebView, streaming cancellation, DNS, redirects and external-app behavior still require on-device traffic observation. Passing host tests is not proof of zero network packets on every device.
- Legacy device-cache keys derived from a device ID and public signer/salt are reproducible if those inputs are known. They are retained for compatibility and must not be represented as a general credential vault. Bundled command tables are public resources.
- Publisher models do not have pinned expected digests in the catalog. HTTPS delivery does not make a downloaded or locally imported model independently authenticated. Only use trusted model archives; the bundled English model's SHA-256 is recorded in the existing acceptance report.

For a strict offline-only build, removing all active network features would also remove GitHub OTA and the listed online functionality. That is a separate product decision from removing credentials and obsolete integrations.

## DigitalOcean closure

The remaining hosted storage buckets were deleted after explicit owner authorization and complete verified external backups. Each bucket was confirmed removed, the temporary cleanup key was revoked, and unrelated resources were preserved.
