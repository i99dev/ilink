# Final OTA and account-free voice verification

Audit date: 2026-09-06. This record separates source/host checks from real-device acceptance. No final standalone release has been published.

The earlier verification totals below are retained as historical evidence. Re-run the checks in [Contributing](../../CONTRIBUTING.md#checks-before-opening-a-pr) to confirm the current candidate.

## Status

| Requirement | Result | Evidence / limitation |
| --- | --- | --- |
| Old production apps discover the new GitHub release automatically | **FAIL - migration needed** | Released updater calls the deleted `api.ilink.app` endpoint; live request fails DNS. No released GitHub fallback. |
| Chosen migration solution | **DOCUMENTED - option b** | One external manual-update notice; [instructions and announcement draft](github-ota.md). No notice has been sent and no compatibility endpoint is deployed. |
| Android update identity/version continuity | **PASS - artifact checks** | All 73 archived APKs inspected; maximum versionCode 844. Candidate uses 10000 and the same certificate as released 3.21.0-b. Actual Android upgrade/data retention still needs a device. |
| Local voice has no sign-in requirement | **PASS - source and host integration** | Fresh local settings, no account/session/token, voice enabled by default, developer controls off, Downloads/Streaming/Updates off. |
| Fresh default English model needs an account/download | **NO** | Original English Vosk ZIP bundled; native provisioner tries local resources before network. Actual bundled-model loading and PCM decoding passed on Windows; Android extraction, microphone and vehicle execution remain unverified. |
| Fresh install to spoken command to physical vehicle operation | **NOT PASSED - NOT RUN** | `adb devices -l` reports no connected devices. Host tests simulate native recognition and the actuator; they are not a vehicle E2E result. |
| Project license | **CLOSED — OWNER APPROVED** | [MIT License](../../LICENSE), copyright `2026 ilink contributors`, finalized after explicit owner approval. |

## What account-free voice verification establishes

`voice_access_gate.dart` checks only the local user preference; `startVoiceWithGate` requests Android microphone permission. `VoiceController` provisions the selected local model before manual capture. The default is `voiceModelLang=en-us` with `voiceAssistantEnabled=true`; a developer setting is not required to expose the voice command toolset.

The default asset is `android/app/src/main/assets/offline/voice/en-0.15.zip`, 41,205,931 bytes, SHA-256 `30f26242c4eb449f948e42cb302dd7a686cb29a3423a8367f99ff41780942498`. `VoskModelProvisioner` uses an already installed model, a local import archive or the bundled archive. That default English provisioning path has no account/license/session dependency and does not need a network download. Bundled file presence and digest were checked. The actual ZIP was extracted outside Git, loaded with desktop Vosk, and decoded a locally synthesized Microsoft Zira WAV (2.08 seconds, 16 kHz, mono, 16-bit). Both unconstrained decoding and constrained grammar returned exactly `open the driver window`. This proves the bundled model can load and decode PCM locally without an account; it does not prove Android/ARM loading, microphone routing or recognition accuracy in a noisy vehicle.

**The original sign-in blocker is removed. Model availability is language-specific:** only English is bundled. Other supported languages need a compatible local import or an optional direct publisher download. Custom Arabic Moonshine resources require a local model; there is no restored DigitalOcean model service. Android microphone permission, supported firmware, local vehicle/daemon setup and actual actuator availability remain necessary.

The host integration test uses the real settings controller, voice controller, native recognition bridge interface, intent matcher, composite voice router, BYD SDK, car command router and local audit path. Only native/platform/storage boundaries are simulated. It verifies a recognized parked command reaches the simulated actuator, moving/integrity-denied cases do not, and an unknown utterance produces no action. Simulated transcript delivery does not test microphones, PCM recognition accuracy, model extraction, vendor services or physical motion.

The follow-up native capture-error and post-cancellation transcript regressions are included in the final automated results below. No signing configuration was changed.

## Open release risk and completion timeline

**Release acceptance is open.** No calendar date can be confirmed without access to an authorized supported head unit and a person who can observe the vehicle. Reserve the next available **90-minute parked-vehicle session**, starting when that access is provided. The release owner/device operator performs physical observations; the maintainer records logs and results. Do not publish the final standalone release until the required positive case and update-install check pass.

| Time from device availability | Procedure | Pass evidence |
| --- | --- | --- |
| 0-10 min | Use a dedicated clean test device/profile with no existing app data or installed voice model. Verify APK checksum/certificate, device/firmware and local BYD connection. Keep internet and all optional services off. Do not erase a user's existing installation to create this test. | Device/firmware, APK hash/version, clean-model state, no account and no internet recorded. |
| 10-20 min | Fresh-install and open the app without signing in. Keep default English selected, grant microphone permission and start a voice turn. Confirm the bundled model provisions locally. | Model-ready signal with network disabled; microphone starts; no sign-in or model download prompt. |
| 20-35 min | With vehicle physically parked, known speed zero and operator agreement, speak a supported harmless command chosen for that vehicle (for example a climate adjustment or a window movement with the area clear). | Recognized text, matched command/arguments, real dispatch result **and observed vehicle response** agree. A success log alone is insufficient. |
| 35-45 min | Stop a voice turn, verify no delayed command executes, deny microphone permission and retry, then restart offline and repeat the positive case. Do not drive to test the moving gate; host tests cover that condition. | Cancellation/permission failures cause no action; positive offline behavior survives restart. |
| 45-60 min | On a separately preserved old installation, install the same-signer standalone APK as an update without uninstalling. Verify existing local settings and imported content. Once a public release exists, test its URL anonymously and enable/check GitHub updates. | Android accepts upgrade, local data retained; public download and opted-in update discovery verified when publication prerequisites are met. |
| 60-75 min | On the standalone build, enable GitHub updates and use an eligible newer signed release to exercise the in-app offer, download, unknown-app permission and Android install confirmation. If public delivery is not yet available, record it as pending rather than inventing a live pass. | The release is detected, verified and installed with the original signer; local data survives. |
| 75-90 min | Restart offline, repeat the chosen voice command, review logs and record every acceptance result or blocker. | Operator signs the observed results and any remaining issues have an owner. |

If any prerequisite fails, record the blocker and keep acceptance open; the schedule is a session plan, not a guaranteed completion time. Local vehicle control also has an existing limitation: the stationary gate permits unavailable/null speed in its current policy. Therefore this physical acceptance run must establish an actual parked vehicle and known zero-speed signal; this audit did not broaden or rewrite that safety policy.

Record: operator/date, vehicle/head-unit/firmware, APK hash/version, clean-install vs upgrade case, selected model, connection/permission state, spoken command, recognized text, dispatched operation, observed physical response and pass/fail. Keep VINs, precise locations and credentials out of public logs.

## Automated results

- OTA suite: **42 tests passed** (`flutter test test/kernel/update`). This verifies the new updater's behavior, not discovery by old binaries.
- Voice checks: **105 tests passed**, including six new integration scenarios (parked, moving, integrity denied, unknown utterance, native capture error and late transcript after cancellation), local startup/access checks and the on-device voice suite. Changed Dart files pass analyzer and formatting checks.
- Actual model smoke test: **PASS** — bundled model loaded and recognized synthesized English PCM using desktop Vosk, with and without grammar constraints. Ephemeral test dependencies stayed outside the repository.
- Full Flutter regression suite after the lifecycle fixes: **1,602 passed, one skipped**. The existing skip is the BYD label/catalog sync check for four names absent from the TSV; it requires a device catalog refresh and was not newly skipped or weakened by this task.
- Physical vehicle E2E: **not run**; zero connected ADB devices.

## Rebuilt verification candidate

The voice lifecycle fixes were rebuilt into a signed release APK: `com.i99dev.ilink`, `3.22.0-b+10000`, **81,669,740 bytes**. SHA-256: `c4e2c9c206a6bc207d0aedd5d4386064629d97f162e7066f80c1fa0286e1bd59`.

`apksigner verify` passed and the certificate matches released 3.21.0-b exactly. The original release keystore and `android/app/build.gradle.kts` remain unchanged. This candidate replaces the earlier unannounced APK in the local build output; no release has been published. APK inspection read 847 entries with zero known-sensitive-material findings and zero skipped entries. Re-run artifact verification if the APK is rebuilt again.

## Documentation and licensing

The README links the migration plan, this acceptance record, [CONTRIBUTING.md](../../CONTRIBUTING.md), the [Code of Conduct](../../CODE_OF_CONDUCT.md) and the PR template. The contribution guide specifies fork/clone, pinned toolchain, local builds, branch/commit conventions and required CI checks.

The owner approved MIT License with copyright `2026 ilink contributors`. The full text is finalized in [LICENSE](../../LICENSE), and the licensing decision is closed. Existing third-party component/model/asset licenses remain unchanged.
