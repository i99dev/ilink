# Mini-app permission enforcement

Permission grants are stored locally for an app ID and exact archive SHA-256. Runtime authorization also requires the current installed record to contain the same digest. Missing grants, changed bundles and unknown or administrator scopes are denied. Review and revoke grants through Local permissions.

Family handlers and direct car, workflow and location calls enforce their scopes. Event subscriptions recheck authorization as data flows; browser geolocation uses the scoped host path rather than unrestricted native permission. Gesture execution requires operation-specific confirmation. Car writes still pass through the shared safety router.

The primary viewer constrains navigation, local files and optional network resources. Native secondary surfaces have no host JS bridge; canonical path checks restrict requests to their own installed bundle, with network/content loads and browser location/media permissions denied.

Owner scope consent does not grant administrator roles or replace legacy issuer signatures. Existing cached legacy templates retain their own parameter, device, certificate/capability and safety rules; new issuer-bound installs are unsupported. See [legacy verification](../../kernel/pubkey/README.md).
