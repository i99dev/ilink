package com.i99dev.ilink.car.profiles.definitions


/**
 * Song PLUS — Di5.0 / BYD container. A **normal Di5.0 BYD trim**:
 * same container, same DiShare path, same display layout as
 * Leopard 5. Auto-resolves via `vehicleId=243`
 * (`model_detector.dart` `case 243 -> ('song_plus','Song PLUS')`);
 * BYD exposes no `model_variant.model` token for it.
 *
 * ── CORRECTION (operator field-attested 2026-05-17) ───────────────
 * The prior profile set `showCluster=false` + `cluster=emptySet()`
 * ("Song PLUS has no driver cluster"). The car owner confirms the
 * foreign-app driver launch (`pkg.launch` → cluster) works on
 * **every Di5.0 DiLink car, Song PLUS included** — i.e. Song PLUS
 * has the same DiShare-reachable cluster as L5. The no-cluster
 * value was an inherited conservative guess from a read-only scan
 * (a scan can't *launch*), the same class of error as the L5U
 * mis-tag. Song PLUS now mirrors L5 exactly.
 *
 * Archetype: [DI50_BYD_DISHARE] — Song PLUS IS a canonical member
 * (the "Song PLUS == L5" correction above is exactly "Song PLUS ==
 * the archetype"). NO behavioural delta — pure identity only.
 * `DeviceTagResolver` resolves `fse` / `cluster_c` / `cluster_tr`
 * for displays 2 / 3 / 4 uniformly with every other Di5.0 car.
 * Probe provenance: `vehicle40dCode = 243` (no modelVariant; BYD
 * exposes none) — documented discriminator, retired as a field.
 *
 * Sources:
 *   * Live collector probe v0.10
 *     (`byd-fingerprint-23.1.83-20260506-084258.json`):
 *     `vehicle40dCode=243`; `modelVariant="unknown"`; displays
 *     0(IVI)/2/3/4 with 2/3/4 = `(shared_)fission_bg_
 *     XDJAScreenProjection*`, VIRTUAL 1920x720, owner
 *     `com.byd.containerservice`, OWN_CONTENT_ONLY — byte-identical
 *     layout to L5. `body_control`/`ac_manager` absent (kept in
 *     STANDARD_UNIVERSAL_CAPS; daemon no-ops at runtime).
 *
 * On-car verification of the DiShare opcodes remains the shared
 * Track-B item for all Di5.0 trims (it is RE-derived); the
 * #127 launch-outcome decoder surfaces an honest failure if a
 * given ROM's DiShare service differs.
 */
internal val SONG_PLUS_PROFILE = DI50_BYD_DISHARE.copy(
    variantId = "song_plus",
    familyName = "Song PLUS",
)
