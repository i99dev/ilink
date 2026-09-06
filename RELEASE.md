# Standalone releases

Use the existing Android release keystore and alias. See
[signing inputs](.github/SECRETS.md); no private submodule is required.

1. Set a new `versionName+versionCode` in `pubspec.yaml`. Standalone builds start
   at versionCode **10000**, above archived releases. Increment it for every
   release; never derive it from Git commit counts or reset it with Git history.
2. Run `flutter pub get`, `flutter analyze`, `flutter test`, signing preflight,
   and a signed release build. Validate the APK signer, package ID and versionCode,
   then scan the exact source snapshot and packaged APK for secrets.
   Complete and record the [head-unit acceptance test](docs/offline-first/final-verification.md)
   before the final standalone release; host tests cannot clear that requirement.
3. Tag the reviewed commit as `v<versionName>`. Run `Release Build` with that
   tag/version. It restores the existing keystore outside checkout and attaches
   `ilink.apk` plus `ilink-release.json` to the GitHub release.
4. Publish an ordinary release for the public updater. Draft/prerelease entries
   are ignored. Updates require newer versionCode, matching package and signer,
   plus the expected size/SHA-256. No embedded GitHub token exists.

No standalone release is published yet; publish only after the acceptance
checks below. The default
OTA source is `i99dev/ilink`; release CI injects its repository with
`GITHUB_RELEASE_REPOSITORY`. Until a release is published, in-app OTA finds
nothing to download.
Existing backend-based releases cannot automatically discover this standalone
build. Follow the [manual migration and announcement plan](docs/offline-first/github-ota.md)
after the APK is publicly downloadable. Install over the existing app, verify
local data retention, and then enable GitHub updates in Optional Services.

Microphone, vehicle-command, package-install and playback acceptance on the
supported BYD head unit is separate from host tests.
