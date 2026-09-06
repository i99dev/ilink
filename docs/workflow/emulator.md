# Emulator smoke checks

Use Android Studio Device Manager to create an Android emulator compatible with the project's minimum SDK and your host CPU. A normal emulator is enough to exercise navigation, local settings, bundled catalogs and UI; it does not emulate BYD vehicle actuators.

Start the chosen AVD in Device Manager. From the repository root:

```sh
flutter devices
flutter run -d emulator-5554 --dart-define-from-file=config/dev.json --dart-define=MOCK_CAR=true
```

Replace emulator-5554 with the exact emulator serial from flutter devices. This command installs the debug build on that selected emulator. MOCK_CAR enables canned car transport replies; any displayed success is simulated and cannot verify physical operation. Do not use a physical device serial for an emulator smoke check.

There is no production backend, VIN impersonation, Telegram pairing or content entitlement setup. The old .deploy-car kit changed vendor identity properties and targeted retired servers; it was archived outside the repository and removed.

For genuine voice decoding, disable mocked car state only when needed for a specific test and distinguish Android microphone/model initialization from simulated vehicle dispatch. English is bundled; microphone permission and a usable emulator audio input are still required. Physical head-unit testing needs separate authorization and safety review.
