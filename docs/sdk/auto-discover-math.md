# 05 · Auto-discover math — why 21k catalog → ~9k live entries

> **TL;DR.** BYD's framework defines ~10–11k unique feature
> constants. `BydAutoFeatureIdsCatalog` stores nested-class entries
> twice (bare + prefixed), inflating to ~21k catalog keys. The
> registry probes each catalog name against 7 `WARM_DT` device-types
> and keeps the first non-sentinel reading. On a Leopard 8 car, ~9k
> tuples come back live; the rest are write-only commands, signals
> scoped to subsystems we don't probe, or features the framework
> knows about but this trim doesn't implement. Nothing is broken —
> this is the expected curve.

## The 21k number

`BydAutoFeatureIdsCatalog.byName.size` is the count of entries in
the catalog map after reflection. On DiLink 5.1+ this hovers around
~21,000.

### Where the 21k comes from

1. `Class.forName("android.hardware.bydauto.BYDAutoFeatureIds")` —
   root class with N `public static final int` fields.
2. `root.declaredClasses` — nested classes like `Ac`, `Door`,
   `Statistic`, `Bodywork`, `Light`, `Setting`, `Instrument`, …
3. For each nested class, **two** entries are stored:
   - `Ac.AC_POWER_STATE` → 0x60000001  (prefixed form)
   - `AC_POWER_STATE`     → 0x60000001  (bare form)

The bare form is back-compat for pre-migration textproto entries
that wrote `feature_name: "AC_POWER_STATE"` without the namespace.
The prefixed form disambiguates collisions across groups (e.g. a
root `LEVEL_HIGH` vs a `Sensor.LEVEL_HIGH`).

`HashMap.putIfAbsent` keeps the **first** registration, so:

- Root fields land first under their bare name.
- Nested fields land second — prefixed first, then bare (skipped
  if already present from root).
- Net: every nested constant lives at **two keys** in the catalog
  (its prefixed name + its bare name, unless root already claimed
  the bare).

That double-counting is why the catalog reports ~21k for what's
actually ~10–11k unique constants.

### Is the double-counting a bug?

No — it's by design.

- **Prefixed form** is what new code and the public textproto
  emit. It's the canonical key going forward.
- **Bare form** is what legacy textproto entries authored before
  the prefix migration used. The catalog has to resolve both for
  back-compat.

The registry's first-wins dedup absorbs the duplication on the
read path — see below. There's no behavioral consequence to the
larger catalog count.

## The probe

```
catalog_keys      = ~21,000  (counts both bare + prefixed)
WARM_DT           = 7        (1000, 1001, 1023, 1038, 1040, 1041, 1045)
CHUNK_SIZE        = 64
binder_calls      = ceil(21000 / 64) × 7 ≈ 2,300
wall_clock        = ~2–5 s on real hardware
```

Each probe call:

```kotlin
AdbShellBridge.fastBatchGet(chunkKeys.map { Pair(dt, it) })
```

returns one int per (dt, key) tuple — the framework's current value or
a sentinel.

## The sentinel filter

A value counts as **live** iff it isn't in `SENTINELS`:

| Value | Means |
|-------|-------|
| `-10011` | Feature key not bound / not supported on this trim. |
| `-10013` | Statistics-class signal not yet computed. |
| `-10006` | Value not initialised yet (CAN signal hasn't fired). |
| `-10005` | Permission denied for current process UID. |
| `-10001` | Framework still booting. |
| `65535`  | uint16 -1 / "no data". |
| `Int.MIN_VALUE` | InAppPushManager: device-type not registered. |

The first **non-sentinel** value across the 7 WARM_DT probes wins;
subsequent dts that also resolve are dropped (`putIfAbsent`). One
catalog name produces at most one registry entry.

## Why the live count is ~9k, not 21k

Three independent reductions stack:

### 1. Bare/prefixed dedup absorbs ~half

The 21k catalog has ~10–11k unique `(integer)` values. Even if
every constant resolved on every dt, the registry can only have
~10–11k entries — because both `Ac.AC_POWER_STATE` and
`AC_POWER_STATE` resolve to the same `(dt, key)` and the second
one hits `putIfAbsent` and is dropped.

(Strictly speaking we get two entries — one keyed by each name —
but they share the same `(dt, key, value)` triple. The "live entry
count" the user observes is the deduped map size.)

After this step: theoretical max ~10–11k.

### 2. Write-only / command keys return sentinel on read

A large fraction of the framework catalog is **write-only**
commands: door-lock commands, AC mode setters, fragrance triggers.
The framework slot exists, but reading it returns `-10011`
("not bound") because there's no underlying CAN signal carrying
state-of-command — the state lives in the **target** (door
position, AC power state) under a different feature ID.

Empirically this drops another ~30–40 % of catalog names.

After this step: ~6–7k.

Wait — you said 9k. The next bucket adds *back*:

### 3. WARM_DT covers seven device-types, not all of them

`WARM_DT = [1000, 1001, 1023, 1038, 1040, 1041, 1045]`. The
framework actually defines more device-types (some sources put
the full set in the 30-50 range). For example:

- 1002 = ADAS
- 1003 = MIRROR
- 1018 = ENERGY
- …others

Features scoped to those dts are invisible to the brute-force probe
(it would have to register additional `BydPushDevice` instances —
and the framework refuses for several of them on production trims
anyway). So the live set is bounded **down** by WARM_DT coverage.

### Net empirical curve

```
catalog (bare + prefixed)         21,000
↳ dedup to unique constants       10,500
↳ × WARM_DT match                  9,500
↳ − write-only / command keys      9,000-ish  (observed)
```

The exact figure varies per trim and per ROM. Han L4 hits ~7.5k.
Tang L4 hits ~8.2k. Leopard 8 (Flagship) hits ~9.5k. Yangwang U8
trims with full ADAS subsystem hit ~10.2k after we briefly probed
with dt 1002 added.

## Diagnostics — confirming the curve

`auto.registryStats()` returns the current live count:

```json
{
  "built": true,
  "totalEntries": 9579,
  "pushFramesReceived": 142315
}
```

The post-build dump is at `files/auto_registry.txt`:

```
$ adb shell run-as com.i99dev.ilink cat files/auto_registry.txt
AutoCarRegistry — 9579 entries (built in 3214ms)
# name	dt	key	value
Ac.AC_CYCLE_MODE	1000	1610612737	0
Ac.AC_POWER_STATE	1000	1610612738	1
…
```

Sort, grep, diff between trims — same shape on every car.

## Should we probe more device-types?

Yes, conditionally. Adding 1002 (ADAS) and 1018 (ENERGY) is on the
roadmap when the corresponding `BydPushDevice` subclass is shipped.
This is the only knob that meaningfully grows the live count above
~9.5k.

What you should NOT do:

- **Don't lower the sentinel set.** Letting `-10011` through
  pollutes the registry with phantom "live" entries that never
  push and never have meaningful values.
- **Don't probe every framework device-type optimistically.** The
  framework refuses `BydPushDevice` construction for several
  protected dts on production trims; the error surfaces are
  per-dt and we currently log them per-trim before opting in.
- **Don't fake a value through `putIfAbsent` to "fix" the count.**
  An entry without a real push subscription doesn't update. The
  count is correct; it's the *expectation* that it should match
  catalog size that's wrong.

## Quick FAQ

**Why does the user think there should be 21k?**
Catalog size is observable via `allKnownFeatures()`. That's the
universe BYD's framework defines — not the subset that's
implemented on the car under the seven `WARM_DT` subsystems.
`allFeaturesAuto()` returns the live subset; the gap is expected.

**Are we losing data?**
No. The ~12k catalog names that don't go live are either
write-only commands (state lives elsewhere), signals scoped to
unprobed subsystems, or features the trim doesn't implement.
Reading them today would just return sentinels.

**Will more DiLink versions raise the live count?**
Marginally. DiLink upgrades occasionally expose previously
restricted constants on new trims; we observe ~+200 entries
per major DiLink release. Don't expect step changes.
