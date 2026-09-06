# Security operations

Preserve the existing Android release keystore and credentials outside the repository. Validate its identity with scripts/prepare-signing.sh; prepare public offline assets and the existing signer pin with scripts/ci/prepare-offline-release.sh. Neither script generates or rotates a key.

Before publishing an update, run the documented tests and secret audit, verify the APK package/version/certificate and retain the external signing backup. Follow [RELEASE.md](../../../RELEASE.md).

For permission issues, review the installed mini-app's Local permissions. A replaced archive needs consent for its new digest. Do not manufacture certificates or bypass legacy signed-extension checks. For local ADB authorization, use the installation's own keypair and the head unit's authorization UI.

Historical key-issuance, account-secret rotation and remote telemetry procedures were archived outside Git. They are not supported recovery paths. Preserve existing local encrypted stores during diagnostics; deleting them can destroy compatibility data.
