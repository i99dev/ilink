# Legacy mini-app signature verification

The standalone application has no hosted certificate issuer, session-capability mint or remote key-provisioning service. The former DigitalOcean key issuance and rotation guides were archived outside the repository. They are not deployment or recovery instructions for this app.

## Current compatibility boundary

- New installs of legacy issuer-bound privileged extensions are unsupported and must be reviewed. Do not invent a certificate, issue local administrator authority or bypass an issuer check to make an old extension install.
- Previously cached tier-1 command templates may still execute when their existing local template, parameter, device and safety checks pass. Retirement of the issuer does not mean every cached extension is disabled.
- Legacy tier-2 operations retain consent, revocation-freshness, certificate and bound capability checks. Missing, expired or stale authority is rejected. The standalone app does not fetch or renew that authority; per-action issuer-dependent operations fail closed.
- Locally installed family APIs enforce selected local permission scopes bound to the app ID and exact archive SHA-256, alongside vehicle safety rules. The owner can review or revoke scopes through **Local permissions**; unknown and administrator scopes are denied. This local path does not manufacture legacy issuer credentials.

The remaining certificate/capability data models and local stores support validation and compatibility. Their presence is not evidence of a running backend or a supported new issuance workflow. Public verification keys are not private signing keys.

## Source map

- [Admin dispatcher](../../../lib/features/admin_mini_apps/domain/admin_dispatcher.dart): cached template lookup, tier selection, parameter and execution checks.
- [Tier-2 gate](../../../lib/features/admin_mini_apps/domain/mini_app_gate.dart): consent, freshness and capability binding.
- [Cached capabilities](../../../lib/features/admin_mini_apps/data/db/session_cap_store.dart): retained local capability records used by the gate; no issuance or renewal client.
- [Revocation store](../../../lib/features/admin_mini_apps/data/db/revocation_list_store.dart): local revocation and freshness data.
- [Standalone cleanup record](../../offline-first/standalone-cleanup.md): current migration, verification and publication status.

## Android release signing

The Android app's release keystore is a separate identity from legacy mini-app issuer public keys. It must remain unchanged so installed versions can update. This guide introduces no key generation, rotation or release-signing configuration changes; see the existing release workflow and signing record.
