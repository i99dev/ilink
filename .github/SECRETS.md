# Release signing secrets

iLINK has no backend, payment, analytics or account credentials. The only
secrets it needs are for signing the release APK. Never commit a keystore or a
password.

## Creating the signing key (once)

iLINK ships under its own applicationId, `com.i99dev.ilink`, so it has its own
signing identity. Generate the keystore once, outside this repository:

```sh
keytool -genkeypair -v -keystore ilink-release.jks -alias dash \
  -keyalg RSA -keysize 4096 -validity 10000
```

**Back it up before you use it.** Android will not accept an update signed by a
different key, so losing this keystore means no future build can ever update an
installed iLINK — the only remedy is a new applicationId and every user
reinstalling from scratch. Keep at least one encrypted copy off the build
machine.

Read the certificate fingerprint you will pin against:

```sh
keytool -list -v -keystore ilink-release.jks -alias dash | grep 'SHA256:'
```

## Repository secrets

Release Actions read these from the `prod` environment:

| Secret | Purpose |
| --- | --- |
| `DASH_RELEASE_KEYSTORE_B64` | Base64 of the release keystore, restored only under `RUNNER_TEMP` and deleted at the end of the job. |
| `DASH_KEYSTORE_PASSWORD` | Keystore password. |
| `DASH_KEY_PASSWORD` | Private-key password. |
| `DASH_KEY_ALIAS` | Key alias (`dash` by default). |
| `DASH_EXPECTED_SIGNER_SHA` | Certificate SHA-256 the preflight pins against. |

Base64 the keystore with `base64 -w0 ilink-release.jks` (macOS: `base64 -i`).

Secrets live in the `prod` environment, so they are never exposed to pull-request
workflows — including PRs from forks. Do not move them to repository-wide
secrets.

## How the preflight uses them

`scripts/prepare-signing.sh` reads the keystore's certificate and refuses to
build unless it matches `DASH_EXPECTED_SIGNER_SHA`. That catches a wrong or
swapped keystore before it produces artifacts no installed app can accept. The
fingerprint is configuration rather than a literal in the repository, so
rotating the key before the first public release is a secret change, not a code
change. The script never generates a keystore. Signing keeps v1, v2 and v3
enabled.

For local release builds, set the same variables (or use the gitignored `.env`,
see [`.env.example`](../.env.example)) and run `scripts/prepare-signing.sh`
before building.

Once iLINK has a public release, treat the signing identity as permanent and do
not rotate it as part of any secret cleanup.
