# Bundled catalog and archive import

LocalMiniAppRepository reads assets/offline/mini_apps/catalog.json and overlays installed catalog records. InstalledMiniAppStore validates archives, verifies their SHA-256 and manifest, safely extracts them under the application's mini_apps directory, and records the installed version.

The install flow shows declared capabilities. Only selected supported scopes are granted, bound to the exact app ID and archive digest. A new archive needs its own approval; an unverifiable existing install must be reimported. Bundled examples are offered for explicit installation and are not silently installed.

Local permissions supports review and revocation. Uninstall removes the local installed record and resources; no account API is involved. Previously cached uninstalled private catalog entries are not promoted into the local catalog.

New installs of legacy issuer-bound privileged extensions are unsupported pending review. See [security](security.md) and [legacy authority](../../../docs/kernel/pubkey/README.md).
