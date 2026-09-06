# Releasing iLINK

Releases are automated. You do not edit versions, write a changelog, or build an
APK by hand — merging one pull request does all of it.

## The flow

```
 PR opened ──► ci.yml            format · analyze · test · hex audit · config
           └─► commitlint.yml    PR title must be a Conventional Commit
      │
      ▼ merge to main
 release-please ──► opens/updates the "Release PR"
                    (version bump + CHANGELOG entry from the commits)
      │
      ▼ merge THE RELEASE PR   ← the only thing that ships a build
 tag + GitHub Release created
      │
      ▼ repository_dispatch: release
 release-build ──► build-flutter-app
                   derive versionCode · restore keystore · verify signer
                   · build signed APK · attach ilink.apk + ilink-release.json
```

Ordinary merges to `main` never produce a release build. They only update the
pending Release PR. A build happens when, and only when, that Release PR is
merged.

## What you actually do

1. **Merge PRs to `main` as normal.** Each PR title must be a Conventional
   Commit — `feat:`, `fix:`, `perf:`, `refactor:`, `deps:` and so on. That title
   is what lands in the changelog, so write it for a reader of the release notes.
   `feat!:` or a `BREAKING CHANGE:` footer drives a major bump.

2. **Watch the Release PR.** release-please keeps one open, retitled and
   rewritten as commits land. Its body is the release notes; read it and fix any
   commit-message wording *before* merging, because that text is what ships.

3. **Merge the Release PR when you want to ship.** That tags the commit, creates
   the GitHub Release, and triggers the signed build. The APK and its OTA
   metadata attach to the Release when the build finishes.

4. **Before announcing**, confirm the attached `ilink.apk` installs on a real
   head unit and that
   [head-unit acceptance](docs/offline-first/final-verification.md) is recorded.
   CI proves the artifact is built and signed correctly; it proves nothing about
   the vehicle.

Nothing else is required. Do not hand-edit `version:` in `pubspec.yaml` or
`CHANGELOG.md` — release-please owns both, and manual edits fight it.

## Versioning

`versionName` comes from release-please, following SemVer from the commit types.

`versionCode` is derived in CI from the versionName by
[`tool/set_version_code.dart`](tool/set_version_code.dart):

```
major * 1000000 + minor * 1000 + patch      3.22.0 -> 3022000
```

It rises with every SemVer bump, is reproducible from the tag alone, and needs
no stored state. `scripts/ci/check-release-version.py` then independently
verifies the result exceeds every published release, because Android refuses an
update whose versionCode did not increase.

Keep minor and patch under 1000 — the derivation rejects anything that would
reorder releases.

## Signing

iLINK ships under its own applicationId with its own key. Set the key up once
following [`.github/SECRETS.md`](.github/SECRETS.md), including the
`DASH_EXPECTED_SIGNER_SHA` pin that makes the preflight fail on a wrong or
swapped keystore.

**Back the keystore up.** Android will not accept an update signed by a
different key, so losing it means no future build can update an installed iLINK.

Secrets live in the `prod` environment and are never exposed to pull-request
workflows, including PRs from forks.

## Out-of-band builds

`Release Build` also accepts a manual `workflow_dispatch` with a tag and
version, for a hotfix that cannot go through release-please. Use it sparingly —
the release PR is the canonical path, and a manual run still has to satisfy the
same versionCode and signing checks.

## In-app updates

Enabling **Settings → Optional Services → GitHub updates** lets the app discover
published releases, verify package, version, hash and signer, and offer an
install. Draft and pre-release entries are ignored. Downloading and installing
stay explicit user actions, and there is no embedded GitHub token.
