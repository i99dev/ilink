# OpenBYD 2.4.2.1 → ilink: the `launcher_map_cn` HUD-map wire (TASK-016, Phase 1)

Static analysis of the reference implementation's `LauncherMapCnStrategy` (decompiled
2.4.2.1, `com.sr.openbyd`). **No third-party source or assets are reproduced here** —
this is our own description of interface facts (topic ids, field numbers, formulas) and
our own reimplementation.

> **STATUS: PORTED, PENDING ON-CAR VERIFICATION.** Phase 1 only. The variant exists
> behind an **opt-in** flag (`someIpVariant = launcher_map_cn`); the default is
> unchanged (`ui7`) on every model. Phase 2 needs a physical car and is a human gate —
> not started.

**Context that sets the bar.** The reference implementation is tested and working on a
real vehicle, so "does this mechanism work at all" is **closed — it does**. What is open
is narrower and sharper: **do its six map-camera constants generalize to _our_ cars?**
"Works on a real car" is not "works on our cars."

Files: `nav/transport/someip/LauncherMapCnVariant.kt`,
`nav/transport/someip/LauncherMapPose.kt`, tests `NavSomeIpLauncherMapCnTest.kt`.

---

## 1. What this wire actually is

`Ui7Variant` (what we ship) sends **one** RoadInfo event on **one** topic and drives a
text-and-arrow HUD. This wire is a different thing: one nav frame fans out over **11
topics across 6 service ids**, and the payload it terminates in is a **map camera pose**,
not a text field. The name is the tell — it drives the **map widget embedded in the
Chinese launcher**, not the HUD strip.

That difference matters for expectations: success here does not look like "our HUD but
better", it looks like "a map appears on the cluster". And the failure mode is a map
drawn from the wrong viewpoint.

---

## 2. The 11 topics (enumerated)

Topic ids decompose cleanly as `0x0004 | service16 | instance16 | event16`:

| Our name | Topic (dec) | Topic (hex) | service16 | instance16 | event16 | → service id |
|---|---|---|---|---|---|---|
| `ROUTE_SESSION` | 1125929972105217 | 0x0004000700078001 | 0x0007 | 0x0007 | 0x8001 | 3096254809047040 |
| `MANEUVER` | 1268847189590027 | 0x000482028202800B | 0x8202 | 0x8202 | 0x800B | 3239172026531840 |
| `TRIP_PROGRESS` | 1125929972105219 | 0x0004000700078003 | 0x0007 | 0x0007 | 0x8003 | 3096254809047040 |
| `LANES` | 1268847189590028 | 0x000482028202800C | 0x8202 | 0x8202 | 0x800C | 3239172026531840 |
| `GUIDE_TICK` | 1125951447269377 | 0x0004000C000C8001 | 0x000C | 0x000C | 0x8001 | 3096276284211200 |
| `ROUTING_STATUS` | 1125951447269379 | 0x0004000C000C8003 | 0x000C | 0x000C | 0x8003 | 3096276284211200 |
| `MANEUVER_STATUS_1` | 1125955742302209 | 0x0004000D000D8001 | 0x000D | 0x000D | 0x8001 | 3096280579244032 |
| `MANEUVER_STATUS_2` | 1125955742302210 | 0x0004000D000D8002 | 0x000D | 0x000D | 0x8002 | 3096280579244032 |
| `NAV_ACTIVE` | 1125955742302213 | 0x0004000D000D8005 | 0x000D | 0x000D | 0x8005 | 3096280579244032 |
| `ROUTE_METADATA` | 1125960037335041 | 0x0004000E000E8001 | 0x000E | 0x000E | 0x8001 | 3096284874276864 |
| `MAP_CAMERA` | 1125998692630531 | 0x0004001700178003 | 0x0017 | 0x0017 | 0x8003 | 3096323529572352 |

**11 topics → 6 distinct service ids.** (An earlier count of 7 in working notes included
our own UI7 topic in the set; it is not part of this strategy.)

Note `service16 == instance16` on all 11. Our shipped UI7 topic breaks that pattern
(0x010A / 0x0001), which suggests these low ids are the platform's own internal nav
services and this strategy is impersonating the built-in producer — consistent with the
"launcher map" reading, and worth remembering as a risk (see §6).

---

## 3. Service-id formula — VERIFIED EXACT, not an approximation

The formula under test:

```
serviceId = (((topic >> 16) & 0xFFFFFFFF) << 16) | 3096224743817216
```

**It reproduces every one of the 11 topics exactly, with no residue.** Checked
arithmetically, not assumed. Restated so the structure is visible (this is the same
function, and how we spell it in our code):

```
serviceId = (topic & 0x0000FFFF_FFFF0000) | 0x000B0000_00000000
```

i.e. **keep the middle 32 bits, zero the event id, and rewrite the leading tag
`0x0004` → `0x000B`.** The `& 0xFFFFFFFF` mask is load-bearing, not cosmetic: it is
precisely what strips the `0x0004` tag before the `0x000B` base is OR'd in. A port that
"simplified" the mask away would produce wrong service ids for every topic.

**The check that makes this more than self-consistent:** apply the formula to our own
shipped, on-car-proven UI7 pair, which it was *not* derived from —

```
topic 1127042368241665 (0x0004010A00018001)  →  3097367205183488 (0x000B010A00010000)
```

— and it lands exactly on `Ui7Variant.SERVICE_ID`. A formula read off one strategy
correctly predicting a different strategy's constants that we have independently proven
on a real car is strong evidence it is the platform's real addressing rule.

Pinned by `NavSomeIpLauncherMapCnTest.serviceIdFormulaReproducesOurOwnOnCarProvenPair`.

**Verdict: exact.**

---

## 4. Frame → events

One frame becomes exactly 11 events, one per topic, in this order. All are protobuf
wrapped in outer field 1, identical framing to our RoadInfo envelope.

| # | Topic | Payload |
|---|---|---|
| 1 | `ROUTE_SESSION` | `4: 101` (varint constant) |
| 2 | `MANEUVER` | `1: maneuverCode`, `2: mainAction(code)`, `3: 0`, `4: distanceMeters` |
| 3 | `TRIP_PROGRESS` | `17: remainingDistanceM`, `18: remainingTimeS`, `11: lon`, `12: lat` |
| 4 | `LANES` | `1: codes[]`, `2: activeCode[]`, `4: 0xFF×n`, `5: 0x00×n`, `6: inactiveMask[]`, `9: double(millis)` |
| 5 | `GUIDE_TICK` | `1: 2641158014` (0x9D6CDF7E) |
| 6 | `ROUTING_STATUS` | `1: 1729875789` (0x671BCF4D) |
| 7 | `MANEUVER_STATUS_1` | `1: 3592003832` (0xD619A0F8), `5: 1`, `12: 5.0`, `13: 2.2` |
| 8 | `MANEUVER_STATUS_2` | `1: 3817498742` (0xE38A6876) |
| 9 | `NAV_ACTIVE` | `1: 4073768758` (0xF2D0C736), `3: 1` |
| 10 | `ROUTE_METADATA` | `1: routeId`, `3: 1`, `4: double(micros)` |
| 11 | `MAP_CAMERA` | `1: {1: routeId, 2: counter, 3: double(micros)}`, `3: {1..6 = the six doubles}`, `7: 7` |

Stop/clear sends 4 events: empty lanes, `MANEUVER_STATUS_1` with `5:0, 12:0.0, 13:0.0`,
`NAV_ACTIVE` with `3:0`, and `ROUTE_METADATA` with `3:0`.

### Things that are easy to get wrong

- **Field order is not ascending.** `TRIP_PROGRESS` writes 17, 18, 11, 12 in that order.
  Protobuf tolerates it; a strict receiver might not. Preserved verbatim.
- **Timestamp units are inconsistent** — `LANES` field 9 is **milliseconds**,
  `ROUTE_METADATA` field 4 and the map-camera correlation field 3 are **microseconds**
  (millis × 1000). Both carried as doubles. This is the reference's inconsistency and it
  is on-car proven, so we reproduce it rather than tidy it.
- **`routeId`** is a random 10-digit value generated once per route and reset on stop.
  The receiver correlates route-metadata and map-camera messages by it.
- **The decompiled source appears to send the 7-event tail twice** — once inside the
  lane branch and once after it, in byte-identical blocks. We read that as a decompiler
  artifact of an inlined `return` and collapse it to a single firing; a naive
  transcription would double-push every frame.

  **This is an assumption, not a proof** (corrected in TASK-019; it was previously
  written here as settled arithmetically). The argument was: "the strategy declares 11
  topics, single-fire emits exactly 11 events, 11 == 11". That does not follow. A
  class's declared topic count places **no constraint** on how many events one
  `updateNavigation` call fires — a topic may legitimately fire twice per frame — so
  the two 11s are different quantities and the argument assumes its conclusion. What
  actually supports the collapse is reading the decompile: lines 193–250 and 257+ read
  as an if/else whose `else` jadx flattened, and the duplicated blocks are
  byte-identical. That is decent evidence and probably right, but it is exactly the
  kind of reasoning the "arithmetic" framing claimed to have replaced.
  **What would settle it:** observing the reference's own SOME/IP stream on a car and
  counting events per frame. Until then this stays a hypothesis.

### How fields 17/18 were resolved (the Rosetta stone paying off)

`AlternativeUi7Strategy` is byte-identical to our shipped `SomeIpHudTransport`, so its
field conventions are known-good. It derives its ETA string from the same source field
that this strategy writes to field 18 ⇒ **field 18 is remaining time (seconds)**, and by
elimination **field 17 is remaining distance (metres)**. It also writes lon *before* lat
(its fields 19/20), which is the same ordering as fields 11/12 here — a consistency check
that the position pair is not transposed. Getting this backwards would have been
invisible in a compile and subtly wrong on a car.

---

## 5. The six doubles — **UNEXPLAINED**

`1161.2184496889508`, `971.1426529964466`, `-19.15885124372106`,
`0.0014609250661213498`, `-1.5712258405572703`, `0.0037437084083233626`

**Verdict: unexplained.** Not derived, not partially derived. Stating that plainly rather
than dressing up a guess.

### Where they land

Topic `MAP_CAMERA` (1125998692630531), **outer field 3**, as **inner fields 1–6**, each a
little-endian IEEE-754 double. That is the entire structural constraint available: the
submessage contains these six values and nothing else, and it sits beside a correlation
submessage of `{routeId, counter, timestamp}`.

### Are they computed anywhere and merely defaulted to these literals?

**No.** This was the best possible finding and it is not available. A search of the whole
decompile for each literal returns **exactly two hits each** — the two byte-identical
copies of the same payload builder inside this one class (the duplicated-tail artifact
above). They are never computed, never read back, never varied by model, trim, screen
geometry, route or position, and no other class references them. There is no derivation
to port. There is only a capture to copy — or to re-measure on our own cars.

### Numeric hypotheses tested, and their results

| Hypothesis | Result |
|---|---|
| `-1.5712258405572703` is exactly −π/2 | **No.** It is −90.0246°, off by 4.3e-4 rad (0.0246°). |
| Screen pixels (1920×720 / 1920×1080 / 2560×1440 / 1280×720 / 2224×1080) | **No fit.** 971.14 exceeds a 720 px height; no pair lands on a centre, corner or edge of any cluster geometry we ship. |
| Web-Mercator pixel or tile coordinates, zoom 0–24, tile size 1/256/512 | **No hit.** No zoom inverts (1161.22, 971.14) to a coordinate in China (or anywhere plausible). |
| EPSG:3857 metres at scale 1…1e7 | **No hit.** |
| Simple relationships among the six (ratios, products, reciprocals, `atan2`, `hypot`) | **Nothing meaningful.** `f6/f4 = 2.5626`, `f1/f2 = 1.1957`, `atan2(f6,f4) = 1.1987` — near each other but not equal; treating that as a relationship would be manufacturing a fit. |

Every numeric route was a dead end. We did not force one.

### The one thing the near-miss on −π/2 does tell us

Being 0.025° off a right angle is itself informative. **An intentional constant would be
written `-Math.PI / 2`; a value that is a hair off is a _measurement_.** That is the
single strongest piece of evidence in the set, and it points at "captured from a running
system" rather than "chosen" — which is exactly the scenario in which the values would be
**per-car**.

### Best structural reading (hypothesis, recorded as such)

Three large magnitudes followed by three angle-magnitudes, one of which is a right angle,
is the shape of a **6-DOF pose**: position `(x, y, z)` then orientation
`(roll≈0.084°, pitch≈−90.02°, yaw≈0.214°)`. A pitch of −90° is a camera pointed straight
down — a top-down, north-up map view, which is what a "launcher map" widget would want.
Roll and yaw being within a quarter-degree of zero is consistent.

This is a reading, not a fact, and it is marked as a hypothesis in `LauncherMapPose`'s
KDoc. The **field numbers are the contract; the names are our interpretation.** Confidence
that they are a camera pose of some kind: **moderate**. Confidence in the specific
assignment of which double is which axis: **low**. Confidence that they generalize
unchanged to L8 UI7 and L5 LR: **low** — that is the open question, and static analysis
cannot close it.

### What we did about it

Made the answer cheap to change once a car tells us. The six live in
`LauncherMapPose`, a named six-field type, with `LauncherMapPose.forModel(modelName)` as
**the single per-model override point**. Calibrating a car after an on-car render
comparison is adding one `when` row. A test
(`poseIsInjectableAndOnlyAffectsTheMapCameraEvent`) proves swapping the pose changes the
map-camera event and **nothing else on the wire**, so a calibration cannot have side
effects — and it fails if anyone re-inlines the constants into the payload builder.

---

## 6. Minimal on-car probe (Phase 2 step 1) — observe-only

Goal: answer "does this car's launcher subscribe to these services?" **without emitting a
single nav payload.**

The key enabling fact: on this interface, **`transact(4)` (start) is an _offer_, not a
publish.** It advertises a service on the SOME/IP bus and carries no guidance data.
Guidance only moves on `transact(6)` (fireEvent). So the whole probe can stay on
`transact(4)` and the inbound callback, and never fire an event.

### Procedure

1. Set `someIpVariant = launcher_map_cn` and arm the HUD **with no navigation running**,
   so nothing produces a frame and `transact(6)` is never reached.
2. The transport binds and calls `transact(1)` (registerCallback), then `transact(4)`
   once per service id — 6 transactions.
3. Observe two signals.

### Signal A — the `transact(4)` return code (definite, free)

`serviceCtl` already reads a reply. Log the returned int per service id.

- **Positive:** all 6 offers accepted → this car's SOME/IP configuration knows these
  services.
- **Negative:** rejections/errors on some or all → the services do not exist on this
  trim, and the wire is a dead end here. **Stop; do not proceed to emitting.**

This is a *configuration-presence* check, not yet a subscription check. It is the cheap
gate, and it is worth doing first because a failure here ends the investigation for that
car in about 10 seconds.

### Signal B — inbound callback traffic (probable, needs one line of instrumentation)

Our callback binder currently handles and **silently discards** `CB_ON_SOMEIP_EVENT` (1),
`CB_ON_HAL_STATUS` (2) and `CB_ON_REQUEST` (3)
(`nav/transport/SomeIpHudTransport.kt:246-249`). Under SOME/IP semantics an offer that a
consumer subscribes to should produce inbound traffic. Logging `code` plus the parcel size
in those branches makes it observable.

- **Positive:** callbacks arrive on our binder shortly after the offers → something on
  this car is subscribing.
- **Negative:** silence for ~30 s with the launcher map visible → nothing is listening.

Honest caveat: we have **not** confirmed from the decompile that the platform delivers a
subscribe notification through this callback — the reference never inspects one. Signal B
is a reasonable expectation, not a documented guarantee. Signal A is the reliable one.

### Cost and duration

Under a minute per car once the build is installed. No route, no driving, park the car.

### Residual risk — the reason this is "observe-only" and not "risk-free"

The service ids here are **low** (0x0007, 0x000C, 0x000D, 0x000E, 0x0017) and their
`service16 == instance16`, unlike our UI7 service (0x010A/0x0001). That pattern suggests
they are the platform's **own internal nav services**. If the built-in nav app already
offers one of them, our `transact(4)` is a **duplicate offer**, which could disturb the
real nav stack even though we publish nothing.

Mitigations: probe with no route active; if practical, offer one service id at a time;
car parked. Flag `launcher_map_cn` back to `ui7` to revert instantly — no rebuild.

**Only after both signals are positive should Phase 2 move to emitting frames** and
comparing the rendered map against the reference implementation's on the same car.

---

## 7. Go / no-go and confidence

**GO for Phase 2, starting with the observe-only probe.** Conditional and staged, not a
blanket go.

Rationale:
- The mechanism is proven on real hardware; we are not gambling on whether it works.
- The service-id formula is verified exact, including against a pair we already trust
  on-car — so we are addressing the right services.
- The port is opt-in, reverts by flipping one option with no rebuild, and touches no
  default path.
- The safety profile is good: a wrong camera pose produces a **mis-positioned map view**.
  It does not corrupt guidance, and our real HUD path is unaffected because this variant
  shares no topic or service with UI7 (asserted by test).
- The probe answers the cheap question first and stops early if the answer is no.

**Confidence levels, stated honestly:**

| Claim | Confidence |
|---|---|
| Topic list is complete and correct | **High** — enumerated directly from the constructor. |
| Service-id formula is exact | **High** — exact on all 11, and independently predicts our own on-car-proven UI7 pair. |
| Message field maps are correct | **Moderate-to-high** — cross-checked against the Rosetta-stone strategy; 17/18 and the lon/lat ordering are derived, not guessed. |
| Single-fire (not double-fire) tail | **Moderate** — downgraded in TASK-019. The "11 topics == 11 events" argument was circular (see §4); what remains is a decompile reading (byte-identical blocks, flattened if/else). Settled only by on-car observation. |
| The six doubles are a camera pose | **Moderate** — structural argument only. |
| Which double is which axis | **Low.** |
| The six doubles generalize to our cars | **Low** — genuinely unknown, and the whole point of Phase 2. |
| Either car's launcher subscribes at all | **Unknown** — no static evidence either way. |

If the constants stay unexplained *and* prove uncalibratable on-car, this remains a spike
and we ship real-GPS only. That is an acceptable, honest outcome, not a failure.

---

## 8. What was built (Phase 1, step 5b)

- `nav/transport/someip/LauncherMapCnVariant.kt` — the variant. Pure (no Android
  imports), reuses the existing protobuf primitives rather than adding a second encoder,
  injects wall-clock and route-id as seams so the wire is deterministic under test.
- `nav/transport/someip/LauncherMapPose.kt` — the six constants as a named type plus the
  per-model override point.
- Wired into the existing `SomeIpVariant` seam only: `SomeIpVariants.ids` gains
  `launcher_map_cn`, `create()` gains one row. **`defaultFor()` is unchanged — every
  model still resolves to `ui7`**, and a test asserts no model and no absent/auto
  preference can ever resolve to the new variant.
- `NavSomeIpLauncherMapCnTest` — 19 tests. The golden bytes were produced by a
  **separately written encoder** driven from the field map in §4, not dumped from the
  implementation, so a match is agreement between two independent encoders.
- 292 host tests pass (counted from JUnit XML). The pre-existing UI7 goldens are
  untouched and still green — the proven wire did not move.

### Deliberate deviations from the reference

1. **No lane-change dedupe.** The reference caches last lane codes to skip redundant lane
   events. We coalesce upstream already (`NavGuidanceCoalescer` is the sole push gate), so
   a second cache here would be a parallel gate. We emit the lane event every frame, empty
   when there are no lanes. Idempotent.
2. **Lane inactive-mask recomputed, not transcribed.** The reference marks a lane inactive
   by testing its active array for the sentinels 255/−1. Our `NavLane` carries booleans and
   encodes inactive as 0 — transcribing that sentinel test would have marked **every lane
   active**, silently. Field 6 is derived from the boolean directly and pinned by test.
3. **Single-fire tail**, per §4 — an assumption, not a proof.
4. ~~**No fix → 0.0/0.0** for fields 11/12, matching the reference.~~ **WITHDRAWN
   (TASK-019 / ISSUE-003) — the justification was factually wrong and this was never a
   deviation, it was a bug.** The claim that the reference's location helper "returns 0
   when it has nothing" is false: `LocationHelper` is a single static singleton
   pre-seeded to `DEFAULT_LAT = 39.9042` / `DEFAULT_LON = 116.4074`, only ever
   overwritten by a real fix or `setMockLocation`, and **no code path in it returns 0**.
   `LauncherMapCnStrategy:141-143` reads the same getters as
   `AlternativeUi7Strategy:38-40`, so there is no "on THIS wire" distinction either.
   With no fix the reference emits the stub; we were emitting null island. Fields 11/12
   now fall back to the same stub the UI7 path uses, and the oracle derives that value
   instead of being handed ours.

   Note this deviation also had a **testing** cost, not just a wire cost: with 0.0/0.0
   on both sides, swapping lon/lat was a **no-op in 11 of the 20** lmc vectors, so the
   reported lon/lat swap mutation was much weaker than its name suggested. Post-fix the
   swap is detectable in **20/20**.

**Note on the emit-count invariant.** "One frame → 11 events" is **our** model, not a
measured property of the reference. The reference gates its lane event on
`!Arrays.equals(iArr, lastLaneCodes)` (`:151`) and its empty-lane event on
`lastLaneCodes.length != 0` (`:253`), so **from fresh state it emits 10**. Emitting all
11 every frame follows from deviation 1 (we coalesce upstream instead) and is a
deliberate choice. The test and generator that assert "11" are pinning our choice; they
were previously worded as if they measured the reference's invariant.

---

## 9. On-car test cases (Phase 2 — DO NOT START, human gate)

1. **Subscription probe** (§6) on L8 UI7 and L5 LR, no route active. Record Signal A per
   service id and any Signal B traffic. Stop here if negative.
2. Active route, `someIpVariant = launcher_map_cn`: does a map appear on the cluster?
3. If it appears — is it positioned correctly, or skewed/offset/rotated? Compare against
   the reference implementation running on the **same car**.
4. Repeat 2–3 on the other car. **Correct on both ⇒ constants generalize. Correct on one,
   skewed on the other ⇒ constants are per-car** — which is the finding this sprint was
   for, and `LauncherMapPose.forModel` is where the fix lands.
5. Revert check: flip back to `ui7`, confirm the normal HUD is byte-for-byte unaffected.
6. Confirm the real nav stack and launcher are undisturbed throughout (see §6 risk).

---

# 10. TASK-017 — Differential oracle results

**Date:** 2026-07-20 · **Branch:** `feat/openbyd-differential-oracle`

No car was available, so the on-car gate in `workspace/status/NEEDS-REVIEW.md` could not be
run. This section records the substitute: a proof that our emitted wire bytes are identical
to what the reference implementation — which *is* on-car proven — would emit for the same
input frame.

## 10.1 Method

An **independent encoder** was written in Python in the scratchpad, transcribed by reading
the decompiled reference and deliberately **not** by reading our Kotlin. (A golden captured
from the code under test proves only that the code equals itself.) The oracle script is
scratchpad-only and is never committed; only the hex vectors it generated are, as
`android/app/src/test/resources/nav/someip/openbyd-differential-vectors.tsv`.

**The oracle was validated before it was trusted.** It was first run against `Ui7Variant`,
whose wire is on-car proven (shipped 3.15.0-b) and whose goldens in `NavSomeIpVariantTest`
were captured pre-refactor — a genuine held-out pair. It reproduced **5 of 5 byte-for-byte
on the first run**, which is what makes its `launcher_map_cn` verdicts meaningful. Had it
disagreed, the *oracle* would have been the thing to fix: UI7 is the side with hardware
evidence behind it.

Matrix: **43 UI7 vectors** (every turn family, roundabout, unknown/`>49`, `0`; lanes
present/absent/all-active/all-inactive/short-active-array; distance `null`/`0`/negative/
large; counter `0`/`127`/`128`/`255`; position `null`/null-island/equator/negative lat *and*
lon/high latitude/near-pole/half-fix; ETA present/absent/zero/negative; empty and UTF-8
multibyte road names) and **20 launcher_map_cn vectors × 11 topics = 220 events**, plus both
clear/stop sequences. Test class: `NavSomeIpDifferentialTest` (13 tests).

## 10.2 What this CLOSES and what it does NOT

**CLOSES — protocol transcription fidelity.** Topic set, emit order, payload byte layout,
field numbers, wire types, varint encoding (including negative distance as an unsigned
64-bit varint), sentinel handling, envelope framing, event counts. All confirmed against an
independent encoder across the whole matrix.

**SCOPE OF THAT CLAIM (TASK-019 / ISSUE-004).** The shorthand "263 events byte-equal"
appears below and elsewhere. It is literally true and reproducible, but it must not be
read as "every byte of every field was independently predicted". The oracle owns
*layout* (transcribed from the reference); a number of field **values** are passed into
it as parameters and therefore **agree by construction rather than by prediction**.
State it in these words:

> **The protocol-transcription claim stands; the field-value claim holds only where the
> oracle derives the value itself.**

| Field(s) | Status as evidence |
|---|---|
| Framing, varints, LE doubles, field numbers, wire types, emit order (incl. the non-ascending 17/18/11/12 run), topic ids, `serviceIdFor`, map-camera pose bytes, lane fields 1/4/5/6, maneuver fields, conditional-field logic | **Independent.** This is the bulk of the 263 and the point of the exercise. |
| lmc lane field **2** | **Independent** — and genuinely so only since TASK-018 removed the `field2_mode="zeroed"` override. That correction is the differential's real win. |
| lmc trip-progress **11/12** | **Independent since TASK-019.** Was contaminated by a `0.0/0.0` generator override in 11 of 20 vectors (ISSUE-003). |
| ui7 **f28** | **Not independent** — `f28_value` is passed in, and it encodes 2.3.2 semantics while the oracle header claims to transcribe 2.4.2.1 (**D1**). |
| ui7 **f31** | **Not independent** in the 9 real-fix vectors — our `%.6f` formatting is passed in; the reference uses `Double.toString` (**D3**). The no-fix literal coincides exactly, so the shipped wire is unaffected. |
| ui7 **f26 / f30 content** | **Untested, not merely divergent** — the same stub is fed to *both* sides (**D4 / D2**), so the test cannot see the content at all. The real guideline projection maths is outside the differential entirely. |
| **f8 content** | **Excluded by design** (**D0**), and the exclusion is itself tested two ways. |
| `plausible()` branch selector, `distance ?: 0` coercion | **Our rules, applied to both sides.** If our validity rule wrongly rejects a fix, the oracle takes the same wrong branch and the test stays green. Low risk; recorded for honesty. |

**On the held-out UI7 anchor.** It is real (5/5 reproduced, `NavSomeIpVariantTest`
untouched, goldens predate the oracle) and it is the reason the oracle's *encoding
primitives* — varint, LE doubles, strings, length prefixes, envelope, conditional
fields, the field-29 sentinel rule — are trustworthy. Those primitives are shared with
the lmc encoder, so **the anchor transfers to lmc at the primitive layer**. It does
**not** cover lmc-specific layout: it contains zero `launcher_map_cn` bytes, it excludes
f28 by construction (`f28_value=4` is handed to it), and it cannot cover lane field 2,
whose UI7 analogue uses the *opposite* convention — confusing those two is precisely
what produced D5. Earlier wording here ("its launcher_map_cn verdicts become
trustworthy") was broader than the anchor supports.

Also worth keeping explicit: the goldens came from the shipped 3.15.0-b builder, which
is on-car proven **as a whole byte stream that rendered correctly**. That is weaker than
"each field is correct" — a field the cluster ignores could be wrong indefinitely with a
green car. D1 concedes exactly this. "On-car proven" must not be read field-wise.

**DOES NOT CLOSE — whether the constants are right for our cars.** A byte match reproduces
the reference's constants *exactly*, **including any per-car calibration baked into them**.
The six `LauncherMapPose` map-camera doubles are asserted to land in the right fields, bit
for bit; nothing here says they produce a correct view on an L8 or an L5 LR. **That risk
survives this work completely untouched.**

**Nothing here promotes any commit to "verified".** Everything that was pending on-car
before is pending on-car after. §9 is unchanged and still the gate.

## 10.3 Confirmed correct

| Claim | Evidence |
|---|---|
| Envelope framing (outer field 1, wire-type 2, length-prefixed) | all 263 events |
| UI7 field order 2, 8, 9, 10, 16, 19, 20, 26, 28, 30, 31, 5, 29 | asserted as a sequence |
| Icon field 8 omitted (not sent empty) when there is no icon | oracle + explicit test |
| ETA field 26 conditional on non-empty | `eta_absent`/`eta_negative` vectors |
| Negative distance to a 10-byte unsigned varint | `dist_negative` vector |
| Counter rollover across the 127/128 varint boundary | `counter_127`/`counter_128` |
| Lane sentinel re-derivation (`,0` not the code) | pinned; naive port fails it |
| **11 events, once each, in declared order** — *our* emit model (see below) | every vector |
| Non-ascending field runs (17, 18, 11, 12) preserved | asserted as a sequence |
| `serviceIdFor` on all 11 topics **and** on the on-car-proven UI7 pair | 6 service ids |
| Map-camera pose in fields 1..6, bit for bit | `doubleToLongBits` compare |

**Two corrections to how this section used to read (TASK-019):**

*The duplicated tail was NOT settled arithmetically.* The old wording — "read literally
the tail fires 3 + 1 + 7 + 7 = 18 events and repeats 7 topics; the single-fire reading
emits exactly 11, one per declared topic; 11 == 11" — assumes its conclusion. A declared
topic count constrains nothing about events-per-call, so those two 11s are different
quantities. The collapse is **assumed, consistent with the declared topic set, and
pending on-car**; the actual support for it is a decompile reading (§4).

*The 11-events-per-frame figure is OUR model, not the reference's.* The reference gates
lanes on `!Arrays.equals(iArr, lastLaneCodes)` (`:151`) and empty-lanes on
`lastLaneCodes.length != 0` (`:253`), so **from fresh state it emits 10**. We emit 11
every frame because we coalesce upstream instead (deviation 1). The test
`launcherMapCnEmitsElevenTopicsOncePerFrameInDeclaredOrder` and the generator's
`assert len(topics) == 11` pin **our deliberate choice**; they previously read as if they
measured the reference's invariant. The no-topic-repeated half of that check remains a
genuine duplicated-tail regression guard.

## 10.4 Divergences found — every one classified, none silently patched

### D0 — Field 8 icon content: **DELIBERATE, excluded by design**

Field 8 is a runtime-rendered maneuver icon PNG. We draw our own glyphs; the reference
loads BYD's assets. **These bytes differ by design and on legal grounds, and we do not
import their assets.** Field 8 is therefore compared by *presence and length-prefix framing
only, never by content*. Two tests prove the exclusion is real rather than a loophole:
different pixels of the same length compare equal, while a different length **and** a
disappearing field both still fail. Excluding it does not weaken the framing check.

### D1 — UI7 field 28: **reference version drift; we are on 2.3.2, deliberately**

We write the **raw** maneuver code (1..49). Reference **2.3.2** did the same — that is what
we ported, and it is what our on-car-proven wire has always sent. Reference **2.4.2.1**
changed it to a mapping that collapses the maneuver to the 4-value vocabulary
`{1, 2, 3, 9}`. **20 of 23 sampled codes differ.**

*Not adopted.* Our raw-code wire is the one with hardware evidence; this is a semantic
change to an in-service field on a bus with no error channel. Pinned by
`documentedDivergence_ui7Field28CarriesTheRawManeuverCode` so the choice stays visible.
**Open question for the on-car session:** does the L8 cluster actually read field 28, and
does it prefer the collapsed vocabulary? Cheap to test once a car exists.

### D2 — UI7 field 30 guideLine geometry: **deliberate (TASK-005), two sub-cases**

- **No-fix branch:** ours emits 2.3.2's raw-degree Beijing stub verbatim (frozen
  no-regression capture); 2.4.2.1 emits a metric projection from the *same* Beijing anchor
  (their location helper's defaults are 39.9042 / 116.4074, identical to our stub).
  Measured divergence: **0 m at point 0 rising to 28.4 m at point 9** over a ~200 m line.
- **With-fix branch:** same formula family. Ours uses one clamped scaling latitude, theirs
  recomputes `cos(lat)` per point. Measured worst-point divergence: **0.000 cm at the
  equator, 0.005 cm in Dubai, 0.104 cm in Oslo** — numerically irrelevant — and **50.2 m at
  latitude 89.9°**, entirely from our deliberate ±85° clamp that stops a polar fix dividing
  by ~0. Ours additionally prints `%.6f` where theirs prints `Double.toString`.

TASK-005 converged independently on essentially 2.4.2.1's maths. Keep as-is.

### D3 — UI7 field 31 position string: **deliberate formatting difference**

Ours is `%.6f,%.6f,0` (`Locale.US`-pinned); theirs is Java `Double.toString` concatenation:
`55.270800,25.204800,0` vs `55.2708,25.2048,0`. **The no-fix path falls back to the frozen
literal `116.4074,39.9042,0` on both sides**, so the shipped, on-car-proven wire is
unaffected. The 6-dp precision (~0.11 m) is deliberate and the locale pin is load-bearing.

### D4 — UI7 field 26 ETA semantics: **UNKNOWN, worth an on-car look**

Ours emits a **duration** (`"12 min"`, via `NavFormat.time`). Theirs emits an **arrival
clock time** (`HH:mm` of now + remaining, default locale). Same field, same wire type,
different meaning. Ours is on-car proven as *rendering*, but nobody has checked whether the
cluster labels the string as an ETA clock. Renderer-level, one-line fix if the car says so.

### D5 — launcher_map_cn lane field 2 inactive byte: **OUR-BUG, FIXED (TASK-018)**

Field 2 is the per-lane recommended-arrow array. **The reference writes it RAW, sentinels
intact**, so an inactive lane reads `0xFF`. **Our port wrote `0x00`**, having applied UI7
field 29's sentinel→0 convention to a different message that does not have it. Field 6
(`ff00ff`) flags inactivity identically on both sides, so a receiver reading field 6 was
unaffected; a receiver reading field 2 alone was not.

```
lane codes [2,3,4], active [false,true,false]
  field 1 (codes)      both  020304
  field 2 reference          ff03ff   <- sentinels preserved
  field 2 ours (was)         000300   <- inactive zeroed   [TASK-017]
  field 2 ours (now)         ff03ff   <- MATCHES reference [TASK-018]
  field 6 (inactive)   both  ff00ff
```

**TASK-017 classified this "candidate our-bug, deliberately not patched"**, reasoning that
only a car can say which reading the launcher wants. **That was overruled in TASK-018 and
the field now matches the reference.** The reasoning, recorded so the decision is auditable:

1. **Leaving it confounds the on-car experiment.** The Phase-2 session exists to isolate one
   variable — *do the six camera constants generalize to our cars?* Arriving with a known,
   unexplained wire deviation gives a bad render two candidate causes that cannot be told
   apart, spending the scarcest resource in this project (car access) on an ambiguous result.
2. **The symmetry argument did not hold.** The reference's encoding has hardware evidence
   behind it; our `0x00` had none — it was a transcription slip we could name precisely.
   "We don't know which the launcher wants" is not a real tie when one side is proven and
   the other is an identified mistake.

**UI7 field 29 was NOT harmonised and is correct as-is.** The two messages genuinely differ:
field 29 maps the sentinel to 0, lane field 2 keeps it raw. That difference *is* the finding,
and collapsing it would recreate the bug in the other direction.

Now pinned by `launcherMapLaneField2PreservesTheReferencesInactiveSentinel` — the old
`documentedDivergence_launcherMapLaneField2InactiveByte`, inverted rather than deleted and
**renamed with the behaviour**, since a test still named `documentedDivergence_…` would
convince the next reader the divergence is current.

> **Fixture correction, recorded because it is the sharpest finding here.** The TASK-017
> oracle vectors did **not** actually carry the reference's field-2 bytes: `gen_vectors.py`
> passed an explicit `field2_mode="zeroed"` override that encoded *our port's* reading, so
> the fixture agreed with our bug by construction and `launcherMapCnMatchesTheOracleByteForByte`
> was green across the divergence. The differential harness therefore never saw D5 — it was
> caught only by the separately written `measure_divergence.py`. The override is removed and
> the fixture regenerated from the encoder's faithful default. Regeneration was verified to be
> a pure correction, not a fit-to-our-code: an unmodified re-run first reproduced the committed
> fixture byte-for-byte, and the override removal then moved **field 2 of the lanes topic in 3
> lane-bearing `lmc` vectors and nothing else** — 0 UI7 vectors, 0 other fields, 0 topic or
> event-count changes. `lmc_lane_all_active` is correctly unchanged (no inactive lane → no
> sentinel).

**Still pending on-car verification.** Matching the reference more faithfully raises confidence
in the *transcription*; it says nothing about whether the six constants are right for an L8 or
an L5 LR. Keep on the §9 on-car checklist.

### D6 — Doc error: `LauncherMapCnVariant` KDoc says "7 service ids"; it is **6** — **FIXED**

11 topics map to 6 distinct service ids. Cosmetic, in a comment, no wire impact. Corrected to
"6 service ids" in TASK-018; the count is independently asserted by `serviceIdsMatchTheOracle`.

### D7 — launcher_map_cn trip-progress 11/12 no-fix position: **OUR-BUG, FIXED (TASK-019)**

**The same failure mode as D5, one message over, found the same way** (ISSUE-003). Before a
GPS fix we wrote `0.0/0.0` to fields 11/12 — null island, in the Gulf of Guinea — and told
the launcher's map widget the car was there. The reference writes **116.4074 / 39.9042**.

The justification in the KDoc was a false claim about the reference: that its "location
helper returns 0 when it has nothing". It has no such state. `LocationHelper` is one static
singleton, *pre-seeded* to `DEFAULT_LAT = 39.9042` / `DEFAULT_LON = 116.4074`, only ever
overwritten by a real fix or `setMockLocation`; grepping the whole decompile for its usages
returns three strategies, all reading the same two getters, and **no path that yields 0**.
`LauncherMapCnStrategy:141-143` and `AlternativeUi7Strategy:38-40` are the same source, so
the "on THIS wire" distinction was invented. Our UI7 path was already correct — the two
variants were inconsistent with each other and the lmc one was the deviant.

Fixed by falling back to `SomeIpRoadInfoCodec.STUB_LON/STUB_LAT`, the constants the UI7 path
already uses, behind the *existing* single plausibility decision (`NavFix.of`, taken once per
frame). No second "is this fix usable?" predicate was added: one factory, one call site.

> **Second fixture contamination, same class as D5's.** `gen_vectors.py` chose the no-fix
> position itself (`if plausible(...): lo, la = lon, lat else: 0.0, 0.0`), so the oracle was
> told to expect *our* reading and `launcherMapCnMatchesTheOracleByteForByte` was green
> straight across the deviation — exactly as it had been across D5. The override is removed;
> the generator now derives 11/12 through the same `pos_fields()` helper as UI7's 19/20.
> Regeneration was verified as a pure correction using TASK-018's procedure: an unmodified
> re-run first reproduced the committed fixture **byte-for-byte**, and removing the override
> then moved **fields 11 and 12 of the trip-progress topic in 11 of the 20 `lmc` vectors and
> nothing else** — 0 UI7 vectors, 0 other fields, 0 topic-order or event-count changes,
> verified by parsing both fixtures per vector/topic/field rather than by eyeballing hex.

**This also repairs a weakened mutation.** With `0.0/0.0` on both sides, swapping lon/lat was
a **no-op in 11 of 20** lmc vectors — TASK-017's "swapping trip-progress lon/lat fails 2
tests" was true but weaker than it sounded, since only the 9 real-fix vectors could detect
it. Post-fix the swap is detectable in **20/20** and fails **3** tests.

**Provenance:** pre-existing, introduced with the original port (`7b12ad2f`, TASK-016) and
untouched by the D5 fix — not a TASK-017/018 regression.

**Still pending on-car verification**, exactly as D5: this raises confidence in the
*transcription* only and says nothing about the six pose constants on an L8 or L5 LR.

## 10.5 Verification

- `:app:testDebugUnitTest --rerun-tasks`, with `build/app/test-results/` deleted first:
  **305 tests, 0 failures, 0 errors, 0 skipped**, counted from the JUnit XML (34 files, all
  freshly written) — not from the console. 292 pre-existing + 13 new.
- `flutter analyze` — no issues found.
- **Mutation-checked**, both reverted with `git checkout -- <path>`:
  - swapping lon/lat in the trip-progress message: `launcherMapCnMatchesTheOracleByteForByte`
    and the pre-existing `frozenGoldenFullFrame` both fail (2 failures).
  - switching UI7 field 28 to the 2.4.2.1 collapse: 8 failures across 4 classes, including
    `oracleIsValidatedAgainstTheOnCarProvenUi7Wire` and the pre-existing frozen goldens.
- **Pre-existing goldens unchanged and not regenerated.** `NavSomeIpVariantTest` and
  `NavSomeIpLauncherMapCnTest` were not edited; no golden moved. Two independently derived
  encoders now agree on the same bytes.

### 10.5.1 TASK-018 re-verification (after the D5 fix)

- `:app:testDebugUnitTest --rerun-tasks`, results dir wiped first: **305 tests, 0 failures,
  0 errors, 0 skipped**, from the JUnit XML (34 files, 0 stale). Count is unchanged because
  no test was added or removed — one was inverted and renamed.
- `flutter analyze` — no issues found.
- **Mutation-checked:** reverting lane field 2 to `0x00` fails **4 tests** in 2 classes —
  `launcherMapCnMatchesTheOracleByteForByte` and
  `launcherMapLaneField2PreservesTheReferencesInactiveSentinel` (`NavSomeIpDifferentialTest`),
  `frozenGoldenFullFrame` and `laneActiveFlagsAreDerivedFromOurBooleansNotTheReferenceSentinel`
  (`NavSomeIpLauncherMapCnTest`). Restored; green again. Note the differential test only bites
  *after* the fixture correction described in D5 — before it, the mutation was the fixture's
  own expectation.
- **UI7 path untouched:** `NavSomeIpVariantTest.kt` has an empty diff; 0 UI7 vectors moved.
- `NavSomeIpLauncherMapCnTest`'s `frozenGoldenFullFrame` lane payload **did** move, by design
  — it is a launcher_map_cn golden and this was an intentional launcher_map_cn wire fix. The
  replacement bytes were taken from the independent oracle, not re-captured from our output.

### 10.5.2 TASK-019 re-verification (after the D7 fix)

- `:app:testDebugUnitTest --rerun-tasks`, with **`build/app/test-results/` wiped first**:
  **305 tests, 0 failures, 0 errors, 0 skipped**, counted from the JUnit XML (34 files,
  **0 stale**). Count unchanged — no test added or removed, one golden updated.
  *Note the path:* it is `build/app/test-results`, **not** `android/app/build/test-results`;
  the latter does not exist in this project, so wiping it is a no-op that would leave a
  stale-run hole in the evidence.
- `flutter analyze` — no issues found.
- **Fixture regeneration audited before it was accepted.** Unmodified re-run reproduced the
  committed fixture byte-for-byte (`cmp` clean) *first*, establishing determinism so any
  later diff is attributable solely to the override removal. Post-change diff computed
  **structurally** — both fixtures parsed per vector, per topic, per protobuf field — not by
  reading hex: **11 vectors moved, all `lmc`, all at trip-progress fields 11/12 only**
  (`lmc_sparse`, `lmc_man_1/2/9/11/12`, `lmc_man_unknown_50`, `lmc_dist_negative`,
  `lmc_dist_large`, `lmc_counter_255`, `lmc_pos_null_island` — exactly the 11 ISSUE-003
  predicted). Distinct moved `(kind, field)` pairs: `[('lmc', 11), ('lmc', 12)]`. Everything
  else — event counts, topic order, field sets, input columns, the `#CONST` header, all 43
  UI7 vectors — **0 changes**.
- **Mutation-checked** (both restored from a scratchpad copy, see the note below):
  - forcing fields 11/12 back to `0.0/0.0` fails **2** tests:
    `launcherMapCnMatchesTheOracleByteForByte` (`NavSomeIpDifferentialTest`) and
    `frozenGoldenSparseFrame` (`NavSomeIpLauncherMapCnTest`). The differential now bites,
    where before this fix it was the fixture's own expectation.
  - swapping lon/lat now fails **3** tests (`launcherMapCnMatchesTheOracleByteForByte`,
    `frozenGoldenSparseFrame`, `frozenGoldenFullFrame`) — up from 2. Confirmed at vector
    level that the mutation is detectable in **20/20** lmc vectors, versus **9/20** under the
    old `0.0/0.0` fallback, which was blind in exactly the 11 vectors listed above.
- **UI7 path untouched:** `NavSomeIpVariantTest.kt` empty diff; `Ui7Variant.kt` and
  `SomeIpRoadInfoCodec.kt` empty diffs; 0 UI7 fixture lines changed.
- `frozenGoldenSparseFrame`'s trip-progress payload moved by design (it is the no-fix lmc
  golden and this was an intentional no-fix wire fix). Replacement bytes taken from the
  independent oracle's `lmc_sparse` vector and verified to decode to 116.4074 / 39.9042 —
  not re-dumped from our own encoder.

> **Process note, recorded because it nearly cost work.** Reverting a mutation with
> `git checkout -- <path>` also discards *uncommitted* edits to that same file — which is
> what happened here, wiping the not-yet-committed D7 fix and forcing a redo. For mutation
> testing on an uncommitted file, snapshot to the scratchpad and restore with `cp`, or commit
> the fix before mutating. `git checkout` is a revert-to-HEAD, not an undo.
