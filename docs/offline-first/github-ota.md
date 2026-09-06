# Update discovery and migration

## Existing released apps: automatic migration does not work

The latest inspected old release, tag `ilink-v3.21.0-b` at commit `cd370d46b961b3cee0fb5c6253bea231fd787670`, checks `https://api.ilink.app/api/v1/app/release/manifest?b=<rollout-bucket>&v=<installed-versionCode>`. The archived APK reports package `com.i99dev.ilink`, versionName `3.21.0-b` and versionCode **844**. Its compiled Dart library contains that backend host and route; the released source has no GitHub update fallback.

That DigitalOcean backend was deleted. An unauthenticated request during this audit failed DNS resolution (curl exit 6, no HTTP response). Publishing a new GitHub release cannot change an already-installed binary's endpoint. **Users on this released backend-based app will not automatically discover the standalone update.** Signer continuity makes an update install compatible; it does not provide update discovery. `apksigner` confirms the inspected 3.21.0-b APK and the standalone candidate share certificate SHA-256 `2a4700925fe0c230c9bac63ab194ff9500a58a4ac0825c2196ee9ac7f33fc264`.

The old `ReleaseApi` requires an HTTP 200 JSON manifest with `versionCode`, `versionName`, `apkUrl`, `sha256`, `sizeBytes`, `signerSha256` and `releasedAt` (and `forceUpdate` for older parsers). The GitHub release page, GitHub API response and new four-field `ilink-release.json` do not satisfy that contract. A redirect to a GitHub page is insufficient. A static file at a new hostname is also unreachable unless the old hostname and exact route are routed to it.

A compatibility service outside DO is technically possible if it owns HTTPS for `api.ilink.app`, implements the existing manifest route/query behavior and serves complete legacy JSON referring to a publicly accessible, signed APK. That is a maintained compatibility endpoint, not a generic redirect, and is not currently deployed. Released startup mounts OTA before the ordinary sign-in gate, but a legacy license block can return before OTA boot in builds enforcing licensing. A compatibility endpoint therefore would need testing across those startup states and cannot be promised to reach every installation.

The GitHub updater was introduced in later cleanup source, not the inspected published 3.21.0-b release. An unreleased development build may have a different update feed; it does not establish a fallback for existing production users.

## Chosen migration: one manual update announcement (option b)

Use an external announcement or direct owner-managed notice instructing existing users to install the first standalone APK over their existing installation. The retired backend cannot deliver a dependable in-app notice. This task prepared the notice below; no email, message or announcement was sent.

Release owner sequence:

1. Complete the head-unit acceptance run in [final verification](final-verification.md), including an actual update install over the old release. Retain the original signing identity and use a versionCode greater than 844; the verified standalone candidate uses **10000**.
2. Complete licensing/publication review and publish the signed APK to a download location accessible without a GitHub account. The intended location is [iLINK Releases](https://github.com/i99dev/ilink/releases). On 2026-09-06 this repository is **private and has zero releases**, so it is not yet a working public download link. Do not announce availability until it is tested anonymously.
3. Publish the owner-approved notice through the existing user communication channel. Link the actual release, include the APK checksum, and explain that the old in-app update check no longer works.
4. Users download the APK, verify it comes from the official release and accept Android's update prompt. **Do not uninstall first or clear app data.** Verify retained local settings on hardware; data retention is not established by certificate matching alone.
5. After installing the standalone version, users can enable **Settings > Optional Services > GitHub updates**. Updates default off; the app then checks the new feed. Android installer consent is still required, and updates are not silently installed.

Announcement draft, to send only after the download is available:

> ilink is moving to a standalone version with no account or payment requirement. Older versions cannot find this update through their in-app update check because the old update service has closed. Download the official standalone APK from https://github.com/i99dev/ilink/releases and install it as an update over your current app; do not uninstall or clear your data first. After updating, enable Settings > Optional Services > GitHub updates if you want future update checks. The official APK retains the existing signing identity. Follow the checksum and installation instructions on the release page.

## Future standalone updates: automatic discovery, manual installation

After the one-time manual migration, future supported releases can be downloaded and installed from inside ilink; users do not need to visit a browser for each update. This requires a publicly accessible GitHub release and **Settings > Optional Services > GitHub updates** enabled. The switch defaults off. With it off, boot, resume and the manual check make no update HTTP requests.

The automatic triggers are:

- At app boot, once the saved Updates permission resolves enabled; there is no artificial five-second delay.
- Immediately after the owner enables GitHub updates.
- On returning to the foreground, when **more than one hour** has elapsed since the orchestrator's last attempted check. Exactly one hour does not trigger another fetch. There is no periodic timer, background polling or check merely because an hour passes while the app stays open.

An automatic offer appears only while the app is foreground, no mini-app viewer is open, no dialog is visible and voice is idle (or in an error state). Otherwise it waits for a later foreground/resume event to reconsider those conditions. Ordinary automatic prompts have a 24-hour cooldown. These timestamps are held in memory and reset with the app process. Checking and prompting only fetch release information; they never start the APK download or installation. An active check, download, verified ready-to-install file or installer handoff is preserved when another check trigger arrives.

**Settings > About > Check for updates** is a separate explicit check. It bypasses the automatic prompt cooldown and idle conditions, still requires GitHub updates enabled, and is disabled while a download or installation is active. No offer is not proof that the app is current: an unavailable/private feed, invalid data or a network failure also produces no offer.

The current English prompt uses **Install now** for both manual stages:

1. The first tap downloads the APK inside the app and validates its length, SHA-256 and actual Android package, version and signing certificate. It stops at the ready-to-install state.
2. The next **Install now** tap rechecks the installed version, cached bytes and archive identity, then asks Android to install. If Android's permission to install unknown apps is missing, ilink opens that app-specific settings screen and keeps the verified file. Grant the permission, return, and tap **Install now** again; returning from settings alone does not install anything.
3. Android may show its own package-install confirmation. The owner accepts that system prompt. The app hands off to PackageInstaller; successful replacement, cancellation and retained data must be checked on an actual device.

**Later** dismisses an ordinary offer. Revoking the Updates switch clears pending work and prevents late responses or a ready file from triggering installation. Re-enabling can check again immediately; a stale earlier response cannot replace a newer offer.

The integration test [github_update_continuity_test.dart](../../test/app/update/github_update_continuity_test.dart) simulates installed standalone versionCode **10000** discovering a future public **10001** release through the real GitHub source, Dio consent interceptor, controller, APK downloader/hash checks, signer wrapper, prompt widget and installer wrapper. Only HTTP responses, platform calls and the clock are simulated; files are actually written and hashed. It exercises the explicit download/install taps and unknown-app settings return, default-off behavior, the foreground/hour cooldown, delayed and background responses, revoke/re-enable races, preservation of active downloads, corrupt bytes and signer rejection. This is an integration test through the simulated Android boundary, not a physical APK installation or live GitHub availability check.

## Standalone GitHub update contract

`GitHubReleaseSource.repository` defaults to `i99dev/ilink`; release CI supplies `GITHUB_RELEASE_REPOSITORY`. The app uses the unauthenticated endpoint `GET https://api.github.com/repos/i99dev/ilink/releases/latest`. It never embeds a GitHub token. Private/missing repositories, network errors and invalid release data produce no update and do not block local operation.

Publish a non-draft, non-prerelease release with tag `v<versionName>`. Attach exactly one universal signed `ilink.apk` and one `ilink-release.json`:

```json
{
  "versionName": "3.22.0-b",
  "versionCode": 10000,
  "sha256": "a6b86d28b79da9f8185280fb182a13e2b8e6712eb09df6d297efa817ef9c78b2",
  "sizeBytes": 81538870
}
```

These values describe the audited candidate APK, not a currently published release. Regenerate metadata for any rebuilt APK. Although the candidate versionName contains `-b`, GitHub's `prerelease` flag must be false for this updater to offer it. Subsequent releases require strictly increasing versionCode; Git history length is irrelevant.

The app validates exact repository/asset URLs, tag/version agreement, file size and SHA-256. Before Android installation it verifies the actual package/version and certificate against the installed app. Metadata cannot nominate a new trusted signer. Native child-app backend release/license clients were removed; native APK file import is separate from dashboard OTA.

The [GitHub Releases API documentation](https://docs.github.com/en/rest/releases/releases#get-the-latest-release) describes the public latest-release endpoint. Automated tests cover manifest selection, malformed data, private/offline responses, consent and archive checks; they do not prove successful old-version discovery or an actual Android upgrade. See [the release checklist](../../RELEASE.md) and [final verification](final-verification.md).
