# Local security boundaries

The Android release certificate preserves update continuity. Keep the exact existing keystore and credentials outside Git. See [release procedure](../../../RELEASE.md) and [current signing record](../../offline-first/standalone-cleanup.md).

Car writes pass through the local safety router. Mini-app privileges use owner-selected scopes bound to the installed archive digest; browser and secondary-display surfaces restrict access separately. Legacy certificate/capability validators remain for existing signed extension data and do not create new authority.

Public command tables are bundled for fresh installations. Local encrypted table/cache readers, device-key handling and installation ADB keys remain for compatible upgrades. There is no remote table provisioning, account-secret delivery or telemetry upload process to configure.

See [architecture](architecture.md), [operations](operations.md), [threat boundaries](threat-model.md), [legacy verification](../pubkey/README.md), and [native assets](../../offline-first/local-command-tables.md).
