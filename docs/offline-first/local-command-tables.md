# Local command tables and unit resources

Implemented 2026-09-06 under the user's approval to ship command data publicly without backend-provisioned encryption. The dispatcher and its vehicle safety, argument, permission, model and stationary gates remain in place.

## Runtime and data migration

`CarTableSource` and `MiniAppTableSource` remain the interfaces used by core dispatch. The historically named `EncryptedCarTableSource` and `EncryptedMiniAppTableSource` now compose two local readers:

1. Preserve a valid existing `filesDir/<kind>.v2.pb.enc` cache using the existing on-device stored secret and v2 cryptography. This is a filesystem read, never a request or pairing operation.
2. On a new install, absent key, unreadable/corrupt cache or invalid protobuf, parse `assets/offline/<kind>.textproto` from the APK. No encryption key, sign-in, backend or database is required for this source.
3. If neither source is valid, keep the existing empty source and structured unknown-action/route error. Do not synthesize commands or bypass safety gates.

An invalid v2 authentication tag clears only the ETag, preserving the ciphertext for recovery. There is no backend table sync. Local table loading does not export secrets; the separate standalone upgrade migration removes retired account credentials. Bundled table reads and legacy cache sizes are bounded at 2 MiB.

The bundled tables are public command data, not credentials. Encryption is unnecessary for command safety: hiding dispatch recipes does not enforce user consent or vehicle conditions. Android APK signing authenticates the installed package; existing runtime safety/integrity checks still apply. No APK-derived key is presented as a confidentiality boundary.

## Shipped resources and provenance

The two textproto files and ten DEX files were copied from the already populated local `.secrets` submodule at commit `72979e96c5efa1f56c0089de792c8103a82ec432`. No action, integer value, argument template, permission or model constraint was invented. Only obsolete leading source comments were replaced in the textproto files. No signing keystore, ADB fleet key, cloud API key or other credential was copied.

| Resource | Public location | Contents |
| --- | --- | --- |
| Car dispatch | `android/app/src/main/assets/offline/car_table.textproto` | 36 fast actions, 13 unit actions, 10 unit specifications, 20 status entries |
| Native mini-app routing | `android/app/src/main/assets/offline/mini_app_table.textproto` | 12 operations in 4 families |
| Unit binaries | `android/app/src/main/assets/offline/units/*.dex` | All 10 binaries referenced by the car table |
| Unit manifest | `android/app/src/main/assets/offline/units/manifest.json` | SHA-256 of each binary |

These files are ordinary checked-in Android assets. A public clone does not need the private submodule to obtain them and does not need `prepare-offline-release.sh` to produce a command table. Android packages them in debug and release builds automatically. The separate optional release-signing pipeline must use the maintainer's signing key; no private key belongs in the repository or APK.

`UnitDexStager` prefers the public offline manifest, verifies each binary against its hash, stages through the existing device-local ADB transport, and verifies the staged bytes again. It retains the older encrypted asset reader when no local manifest is supplied. Unit basenames and hash syntax are validated before constructing any shell command. Local public units do not derive any encryption key. Existing ADB authorization/permissions are still required.

`AdbCrypto` no longer reads a shared fleet private key from the APK. It reuses the installation's existing `files/.adb_keys` keypair, or generates a fresh RSA keypair on-device. The release hardening script no longer reads the company fleet key, and Android `preBuild` rejects a stale `assets/adb_key.enc` to prevent accidental credential distribution by an incremental build. Existing per-install authorizations survive; an upgraded device which previously used only the fleet identity must authorize its new local identity once. The application's local data is preserved.

## Updating native resources

Edit the public textproto files against proto/car_table.proto and proto/mini_app_table.proto. Retain verified vehicle recipes, permission scopes, model constraints and safety metadata. Rebuild the APK to distribute changes. A unit DEX replacement also requires its matching manifest SHA-256; the original build sources for those binaries are not supplied, so reproducible unit rebuilding remains a limitation.

No hosted table refresh or secret issuance is available. Legacy v2 cryptography and readable existing cache files are retained; the unused provisioning channel writers were removed. SecureLogger and local integrity checks remain, while the retired upload outbox has been removed.

## Speech resources

The APK ships android/app/src/main/assets/offline/voice/en-0.15.zip, the original vosk-model-small-en-us-0.15.zip from the Vosk publisher. Its accompanying attribution and license remain with the asset. The archive is 41,205,931 bytes with observed SHA-256 30f26242c4eb449f948e42cb302dd7a686cb29a3423a8367f99ff41780942498.

VoskModelProvisioner retains an existing version, then checks filesDir/voice-import/<version>.zip and the APK's offline/voice/<version>.zip. Imports use the existing bounded version name and ZIP traversal checks. Other languages require compatible local import or explicitly enabled upstream downloads. Only English is bundled; the custom Arabic Moonshine fallback supports compatible existing local files and has no hosted mirror workflow.

Downloads default off. Native download consent is mirrored from settings, and revocation disconnects active requests. A model present on disk is usable without network access.

## Keys and local authorization

The Android release signing certificate must remain unchanged. Store its keystore and passwords externally. Per-install ADB RSA keys reside in the application's private filesystem and require the head unit's authorization; they are not the release keystore. PatchSigner uses its separate Android Keystore key for local cluster patch signing. Android Keystore wrapping is device-local, with hardware backing dependent on the provider; it does not make a separately reproducible public-input key secret.

## Validation

OfflineTableAssetsTest parses the real resources and checks model/unit integrity. DispatchTableContractTest checks recipe references, and LocalTableLoaderTest covers bounded reads and valid/corrupt cache fallback. Golden crypto tests retain legacy byte compatibility. Run the current native suite from android with gradlew :app:testDebugUnitTest.

Resource tests, a successful build and desktop Vosk decoding do not prove Android microphone capture or vehicle actuation. See the [current verification record](final-verification.md) for test counts, artifacts and pending hardware checks; historical build hashes and checkpoint counts are not release approval.
