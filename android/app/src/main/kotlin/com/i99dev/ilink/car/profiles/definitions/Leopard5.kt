package com.i99dev.ilink.car.profiles.definitions


/**
 * Leopard 5 (base) — covers Flagship + Navigator sub-trims.
 * Di5.0, Qualcomm `lahaina`, Android 12.
 *
 * Sources:
 *   * Live collector probe: byd-fingerprint-23.1.4-20260506-072643.json
 *     (build `2510219.1` / 2026-01-06).
 *   * `vehicle40dCode` = "153" (BYD internal code for L5 base).
 *   * `modelVariant` = "fcbsf" (last letter discriminates trim;
 *     L5 = `f`, L8 = `q`).
 *   * Lidar (l5l) and Ultra (l5u) are SEPARATE families on Di5.1 —
 *     do not change their profiles based on findings here.
 *
 * Archetype: [DI50_BYD_DISHARE]. NO behavioural delta — pure
 * identity (variantId / familyName) only, same as Song PLUS. The
 * BYD-container display topology (2 = FSE co-pilot, 3 = small
 * panel / `cluster_c`, 4 = driver dashboard / `cluster_tr`) and
 * the DiShare passenger+cluster transport are the archetype.
 * Probe provenance: `vehicle40dCode = 153`, `modelVariant = fcbsf`
 * (retired as fields — documented trim discriminator only).
 *
 * Display topology (4 surfaces — different from L8). Corrected
 * 2026-05-16 from a read-only scan of a Navigator unit (40d=153,
 * ROM 23.1.4.2510219.1, car-profiles-out/l5-20260516-1326):
 *   0  Built-in Screen                          2560×1440 d=320  (Main IVI; owner=null)
 *   2  fission_bg_XDJAScreenProjection          1920× 720 d=320  (BYD-container-owned; FSE co-pilot)
 *   3  shared_fission_bg_XDJAScreenProjection_0 1920× 720 d=320  (BYD-container-owned; small panel)
 *   4  shared_fission_bg_XDJAScreenProjection_1 1920× 720 d=320  (BYD-container-owned; driver dash)
 *
 * NOTE on owners: the display NAMES contain "XDJAScreenProjection"
 * but `ownerPackageName` is `com.byd.containerservice` — BYD's own
 * container, NOT XDJA's. Don't rely on name-substring matching.
 * (Confirmed by the 2026-05-16 scan: com.xdja.containerservice
 * ABSENT, xdja.license.state empty.)
 *
 * ── PROVENANCE / VERIFICATION STATUS (read before trusting the
 *    DiShare claims) ─────────────────────────────────────────────
 * The DiShare passenger/cluster path IS fully implemented and
 * unit-tested in-repo ([com.i99dev.ilink.pkg.DishareTransport
 * .fastCast], [com.i99dev.ilink.pkg.DeviceTagResolver],
 * [com.i99dev.ilink.display.DisplayLaunchPlanner]), and the
 * planner routes L5 to it automatically. BUT the binder opcodes
 * (op=1/8/9/11) and interface tokens are **reverse-engineered**,
 * the cited provenance docs are **not committed to this repo**
 * (external secrets/research store), and the path has **not been
 * verified on a live current-ROM L5** — the 2026-05-16 scans were
 * read-only and could not launch. Treat the "verified" wording as
 * RE-derived, not runtime-confirmed; on-car confirmation on ROM
 * 23.1.4.2510219.1 is the open Track-B verification item.
 *
 * Measured preconditions (read-only scan 2026-05-16, GREEN — FACTS,
 * not RE): `com.byd.dishare` is versionName `1.5.1.1.e027a7e` /
 * versionCode `10501001` (system app), and `.api.DiShareApiService`
 * is exposed with NO manifest permission guard — so `fastCast`'s
 * `bindService` resolves and is not blocked at the manifest layer.
 * The residual unknown a read-only scan cannot settle is a runtime
 * caller check inside `onBind()`, plus op=1/8/9/11 correctness
 * against THIS DiShare APK version — exactly what the Track-B §6.2
 * on-car `fastCast` cast resolves.
 */
internal val LEOPARD5_PROFILE = DI50_BYD_DISHARE.copy(
    variantId = "l5",
    familyName = "Leopard 5",
)
