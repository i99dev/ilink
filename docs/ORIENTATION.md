# Orientation for new contributors

Everything iLINK needs is in this repository. There is no private submodule, no secrets to
request, no backend to be granted access to, and no account to register. If `flutter pub get`
succeeds, you can build and run the whole app.

This page is the "where do I start" map. [CONTRIBUTING.md](../CONTRIBUTING.md) is the
process; this is the tour.

## 1. Get it running (about 20 minutes, most of it downloads)

You do **not** need a BYD head unit. An ordinary Android emulator runs everything except the
vehicle actuators.

```sh
flutter pub get
flutter run -d emulator-5554 --dart-define-from-file=config/dev.json --dart-define=MOCK_CAR=true
```

`MOCK_CAR=true` feeds canned vehicle replies. Anything that "succeeds" under it is simulated
— see [Claims you must not make](#5-claims-you-must-not-make).

Two things that will otherwise waste your afternoon:

- **The web target does not build.** The speech engine pulls in `dart:ffi`, which the web
  compiler rejects with a few hundred errors. Use an emulator or a device.
- **A fresh install starts with everything off.** Optional Services (catalogs, streaming,
  GitHub updates) all default to disabled, so radio playback fails until you turn streaming
  on. That is intentional, not a bug.

## 2. How the code is arranged

```
lib/
  features/     one folder per user-facing area (radio, tv, voice, mini_apps, workflows, settings)
  kernel/       cross-cutting: config, i18n, storage, optional-service consent, logging
  sdk/          the car SDK surface that features are written against
  platform/     device, observability, deep links
android/app/src/main/kotlin/com/i99dev/ilink/
                native bridges: vehicle, ADB, display, packages, voice
```

A feature folder follows the same shape throughout:

| Folder | Holds |
| --- | --- |
| `domain/` | Plain models and state types. No Flutter, no plugins. |
| `data/` | Stores, API clients and platform-channel wrappers. |
| `state/` | Riverpod controllers. |
| `presentation/` | Widgets and pages. |
| `providers.dart` | The feature's dependency injection in one file. |

Start by reading one feature end to end — `lib/features/radio/` is a good choice. It touches
persistence, a platform channel, optional-service consent and a real player, so it shows most
of the app's patterns in one place.

## 3. Two conventions worth knowing before you write code

**Optional services gate every outbound connection.** Anything that reaches the internet sits
behind `OptionalService.downloads`, `.streaming` or `.updates`, all off by default. If you add
a network call, put it behind the right one and make failure visible to the driver — do not
let it fail silently.

**Provider lifetimes are load-bearing.** Riverpod's `autoDispose` tears a provider down as
soon as it has no listeners, and `ref.read` does not create a listener. A long-lived owner
that grabs an `autoDispose` provider with `ref.read` ends up holding an object whose `ref` is
dead — which is exactly how radio playback silently broke once. If something owns another
object's lifetime, do not mark that other provider `autoDispose`.

## 4. Checks to run before opening a PR

These are precisely what CI runs, so a green local run means a green PR:

```sh
dart format --set-exit-if-changed .
flutter analyze
flutter test
dart run tool/audit_hex.dart          # vehicle feature IDs must stay in the dispatch table
dart run tool/validate_prod_config.dart
uv run --python 3.12 scripts/ci/check_release_version_test.py   # release gate (needs uv)
```

For native changes, also run the JVM tests from `android/`:

```sh
./gradlew :app:testDebugUnitTest      # .\gradlew.bat on Windows PowerShell
```

## 5. Claims you must not make

This app can move a car. The single most useful habit here is being precise about what you
actually verified.

- A passing emulator or widget test is **not** hardware verification. Say so.
- If you touched vehicle, cluster, audio-routing or firmware-compatibility paths, state the
  device, vehicle model and firmware build you tested on, and what you left untested.
- Test on a vehicle you are authorised to use, parked, in a safe place. Never while driving.
- Do not weaken a safety check, a permission scope or a CI gate to make something pass. If a
  gate is wrong, fix the gate in its own PR and explain why.
- Never put VINs, precise locations or other personal data in issues, logs, screenshots or
  test fixtures.

## 6. Good places to start

- **Docs and comments** — if something on this page was wrong or missing, that is a real PR.
- **Tests** — several paths are device-verified but not unit-tested. `JustAudioRadioPlayer`
  builds its `AudioPlayer` internally, so covering it needs an injectable player; that
  refactor plus tests would be a genuinely valuable contribution.
- **Localisation** — strings live in `lib/kernel/i18n/*.arb` (English, Arabic, Russian). Edit
  the ARB, run `flutter gen-l10n`, and commit the generated files.
- **Trim support** — [adding a trim variant](features/_car_domain/profiles/adding-a-trim-variant.md)
  is a self-contained runbook if you have access to a BYD head unit.

## 7. Getting help

Open an issue using one of the templates. Include app version, head-unit model and firmware,
reproduction steps, and sanitised logs. For anything security-related, do **not** open a
public issue — follow [SECURITY.md](../SECURITY.md).
