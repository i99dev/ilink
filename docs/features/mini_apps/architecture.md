# Mini-app runtime

InstalledMiniAppStore owns validated local archive installation and installed-version metadata. LocalMiniAppRepository presents bundled catalog entries plus installed content. The primary viewer loads the local bundle, exposes the host bridge and supplies manifest/session context.

LocalMiniAppGrants checks app ID, exact archive SHA-256, current installed metadata and selected permission scope. FamilyExecutor and direct handlers apply these checks before dispatch. Vehicle operations converge on the shared CarClient safety route; workflow operations use local persistence and execution.

Secondary display surfaces are rendered by a shared native WebView factory and canonical same-bundle policy. They do not expose a host JS bridge. The originating primary session needs the supported surface permission to create a window.

Legacy signed administrator extensions use a separate validation path. That compatibility path has no new hosted issuer or privilege-minting service. See [permissions](security.md) and [legacy boundary](../../kernel/pubkey/README.md).
