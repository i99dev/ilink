package com.i99dev.ilink.car.profiles.definitions


/**
 * Leopard 5 Ultra — Di5.1, **XDJA** container. Behaves like
 * Leopard 8 / Leopard 5 Lidar, NOT like the Di5.0 BYD-container L5
 * base. Resolved via outsw `34.1.23` (outsw alone pins this trim).
 *
 * ── CORRECTION (operator field-attested) ──────────────────────────
 * The prior profile set `passenger = DishareQuickShare` +
 * `cluster = {DishareQuickShare, Icons}` + empty owner map — the
 * Di5.0/BYD DiShare shape. That was an **unverified value inherited
 * verbatim** from pre-refactor `VehicleProfile.Leopard5Ultra` "for
 * byte-identical behavior", and it was internally inconsistent:
 * `dilinkFamily` here has ALWAYS been `Di51`, and *every other*
 * Di5.1 trim (L8, L5L) is XDJA + `Fission` + `am start --display`.
 * L5U was the lone Di5.1-but-DiShare profile — the smell that
 * exposed the inherited guess. The car owner confirms L5U is XDJA
 * and works like L8 (the DiShare/`com.byd.dishare` path does not
 * apply — that priv-app is BYD-container/Di5.0). L5U now mirrors
 * its true sibling L5L (Di5.1, XDJA, same `com.xdja
 * .containerservice` topology: 3 base + 4 `_0` + 5 `_1` driver,
 * 3/4 shadow). Still no live fingerprint — on-car confirmation is
 * the same open Track-B item as the other Di5.1 trims, but the
 * profile is now CONSISTENT with its platform family instead of
 * contradicting it.
 *
 * Archetype: [DI51_XDJA_CLUSTER] — identical to L5L (the
 * correction above is exactly "make L5U == the archetype"); no
 * behavioural delta, identity only.
 */
internal val LEOPARD5_ULTRA_PROFILE = DI51_XDJA_CLUSTER.copy(
    variantId = "l5u",
    familyName = "Leopard 5 Ultra",
)
