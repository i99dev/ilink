# On-device voice fast-path ("Hey BYD")

Hybrid voice architecture, modelled on the fastest in-market BYD assistant
(leopard-assistant.apk: on-device Vosk grammar recognition + cloud Gemini
tail) but built on **our single command registry** as the source of truth:

```
openWakeWord gate (cheap, always-on)        ── Phase 1b, native (Kotlin)
        │  wake → TriggerSource.wakeWord
        ▼
Vosk grammar recognizer (on-device)         ── Phase 1b, native (Kotlin)
        │  final transcript
        ▼
LocalIntentMatcher  ──hit──► ToolRouter.dispatch   ← sub-300ms, no cloud, no credit
        │ miss
        ▼
cloud LLM broker (existing /voice/chat SSE) ── the "smart tail", unchanged
```

## What's in this module (Phase 1a — shipped, pure Dart, unit-tested)

| File | Role |
|------|------|
| `voice_grammar.dart` | Derives the Vosk grammar **and** the local intent index from the **one** `commandRegistry`. Same routability filter as the LLM manifest (`ToolHandler`) → the two surfaces never diverge. |
| `command_phrases.dart` | The single place every curated spoken phrase lives. Auto layer (labels) guarantees coverage; this adds natural phrasing. |
| `local_intent_matcher.dart` | Transcript → `(commandId, args)` or null. Null ⇒ cloud fallback. Normalization + wake-strip + filler-tolerant token-subset match. |
| `grammar_phrase.dart` | `GrammarPhrase` / `CommandPhraseSeed` value types. |
| `trigger_source.dart` | The **one-way-in** contract: wheel / mic / wake / assist / localCommand all funnel through the same trigger, tagged. |
| `on_device_recognizer.dart` | Seams (`OnDeviceRecognizer`, `WakeWordDetector`) the native engines plug into. |

**Centralization guarantee:** adding a `CarCommand` makes it appear in the
LLM tools and (if arg-free + routable) the on-device grammar with zero extra
wiring. `voice_grammar_test.dart` asserts no seed drifts from the registry.

**Dispatch safety:** a local hit is handed to the **same**
`ToolRouter.dispatch` the LLM path uses — the stationary gate, rate limiter,
and audit log all apply. Nothing here bypasses the safety stack.

## v1 scope / deliberate exclusions

- **Arg-free hardware commands only.** Parameterized ("set temp to 22",
  "fan speed 3") stay cloud-routed until the number/enum grammar follow-up.
- **`radio.*` excluded** — it's `voiceHidden` and routed via the radio
  subagent; it must not enter the daemon-bound fast-path.

## Phase 1b (native, on-car) — gated on the Phase-0 spike

Implement `WakeWordDetector` (openWakeWord TFLite) and `OnDeviceRecognizer`
(Vosk) over Method/EventChannels, mirroring `voice_service_bridge.dart`.
Carry the must-fixes from the architecture pressure-test
(`memory/project_heybyd_wakeword_plan.md`):

- **M1** — wake config + kill-switch ride the `/account` entitlement
  snapshot + MQTT, **not** `/voice/session`.
- **M2** — detector free on-device; gate the **turn** at the mint
  (fail-open on uncertainty). Do not gate the mic on a client snapshot.
- **M3** — **one** AudioRecord owner + 1–2s pre-roll ring buffer; never
  re-acquire mid-turn (host the loop in the resident `ConnectivityService`).
- **M4** — system mic preemption (telephony / `com.byd.autovoice`) is a
  first-class disarm state; detect the `-120 dBFS` zero-fill.
- **M5** — half-duplex v1: gate the detector off during TTS + tail.
- **M6** — English on openWakeWord; **Arabic engine chosen from Phase-0
  in-cabin data** (Vosk ships Arabic models — likely the Arabic path).

Do not build the native arbiter / config plumbing / Arabic model until the
on-car spike (HAL coexistence, latency, false-accept bar) passes.
