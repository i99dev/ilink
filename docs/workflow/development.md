# Development workflow

Use the Flutter version pinned in .github/actions/setup-flutter/action.yml. Run flutter pub get, flutter analyze and tests relevant to the change. The full suite runs with flutter test. Architecture checks live in test/architecture.

scripts/run-dev.sh and scripts/run-prod.sh select checked-in local build settings. scripts/build-prod-apk.sh creates a debug APK by default; an explicit --release uses the configured signing identity. The obsolete build-local-test.sh helper was removed because its private-table and unsigned-build claims no longer matched the build.

## Native assets and tests

The checked-in Android offline assets are the source for command tables, unit recipes and English speech. Edit tables against proto/car_table.proto and proto/mini_app_table.proto, preserving verified IDs and safety metadata. Existing encrypted cache readers support upgrades and must not be removed merely because fresh installs use public assets.

Run native resource tests from android:

```sh
bash gradlew :app:testDebugUnitTest --tests com.i99dev.ilink.security.OfflineTableAssetsTest --tests com.i99dev.ilink.security.DispatchTableContractTest --tests com.i99dev.ilink.security.LocalTableLoaderTest
```

The release preparation helper is scripts/ci/prepare-offline-release.sh. It validates public assets and, when configured, derives the existing certificate pin. It does not encrypt command tables or generate keys. See [release instructions](../../RELEASE.md).
