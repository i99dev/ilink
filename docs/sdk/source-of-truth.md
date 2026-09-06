# Vehicle command source of truth

Framework-readable numeric feature values are discovered through Kotlin and exposed by the SDK cache and event streams. Write semantics and binder recipes live in the checked-in public textproto assets:

- android/app/src/main/assets/offline/car_table.textproto
- android/app/src/main/assets/offline/mini_app_table.textproto

Their schemas are proto/car_table.proto and proto/mini_app_table.proto. Both schemas remain active in native parsing and resource tests. Unit recipes reference public DEX assets with an integrity manifest under assets/offline/units.

CarCommand registry IDs must resolve to genuine native action IDs. Preserve value mappings, model constraints, permission scopes, rate classifications and stationary requirements when adding a command. Update the appropriate domain fragment and verify registry/table parity; a plausible command name is not evidence of hardware support.

Fresh builds package the textproto directly. No private submodule, encryption generator or remote table fetch is required. Legacy local encrypted cache readers remain to preserve upgrade compatibility. scripts/ci/prepare-offline-release.sh validates assets and the existing signer pin; it does not generate tables.

Run native OfflineTableAssetsTest, DispatchTableContractTest and LocalTableLoaderTest after changing resources. These establish schema/reference integrity, not vehicle behavior. Verify physical writes only on an explicitly identified safe device.
