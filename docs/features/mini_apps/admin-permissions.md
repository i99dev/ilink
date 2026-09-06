# Legacy administrator extensions

New installs that require the retired certificate issuer or bound capability service are unsupported pending explicit review. The standalone app does not replace those checks with local administrator authority.

Existing cached tier-1 templates may execute only when their existing template, device, parameter and vehicle checks pass. Tier-2 operations retain local consent, revocation freshness, certificate and bound capability validation; unavailable authority remains a denial.

Local mini-app family APIs use a separate owner-selected scope system bound to the installed archive SHA-256. Those scopes do not manufacture legacy issuer credentials. See [legacy verification](../../kernel/pubkey/README.md) for the source map and [local scopes](security.md).
