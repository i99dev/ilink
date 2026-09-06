# Developer setup

Install the Flutter version used by .github/actions/setup-flutter/action.yml, the Android SDK and a supported JDK. Clone the standalone repository and run:

```sh
flutter pub get
flutter analyze
flutter test
bash scripts/build-prod-apk.sh
```

The build helper defaults to a debug APK using standalone production settings. The public command tables, vehicle catalog, unit DEX assets and English speech model are already in the repository. No private submodule, account, backend, model download or encryption-generation step is needed to build.

Fresh settings enable manual voice and select English; microphone permission is still required. Optional Downloads, Streaming and Updates are disabled until selected. Local vehicle operation requires compatible hardware and its device-local ADB authorization.

Release builds require the exact existing external release keystore. Do not generate or rotate that identity, and do not commit its files or credentials. Follow [RELEASE.md](../../RELEASE.md) before producing an update for installed users.

Use an identified safe test device for hardware work. Host tests and an APK build do not prove microphone capture or physical vehicle operation.
