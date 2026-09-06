# Release signing secrets

The standalone app has no backend, payment, analytics or account credentials.
Never commit a keystore or password, including encrypted keystores in submodules.

Release Actions require these existing signing values:

| Secret | Purpose |
| --- | --- |
| `DASH_RELEASE_KEYSTORE_B64` | Base64 of the exact existing release keystore, restored only under `RUNNER_TEMP`. |
| `DASH_KEYSTORE_PASSWORD` | Existing keystore password. |
| `DASH_KEY_PASSWORD` | Existing private-key password. |
| `DASH_KEY_ALIAS` | Existing alias, `dash`. |

The release workflow uses the `prod` environment. Keep secrets out of untrusted
pull-request workflows. The signing preflight requires certificate SHA-256
`2a4700925fe0c230c9bac63ab194ff9500a58a4ac0825c2196ee9ac7f33fc264`.
It never generates a replacement key. Signing keeps v1, v2 and v3 enabled.

For local release builds, supply the same environment variables and an absolute
keystore path outside the repository. Run `scripts/prepare-signing.sh` before
building. Verified owner backups exist outside Git; see the standalone cleanup
record. Never rotate this app signing identity as part of secret cleanup.
