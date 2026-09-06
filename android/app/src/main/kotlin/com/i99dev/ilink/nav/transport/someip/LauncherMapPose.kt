package com.i99dev.ilink.nav.transport.someip

/**
 * The six doubles the `launcher_map_cn` wire puts in the **map-camera** submessage
 * (topic [LauncherMapCnVariant.TOPIC_MAP_CAMERA], outer field 3, inner fields 1..6).
 *
 * ## Why this is a type and not six literals in a payload builder
 * TASK-016's central open question is whether these six values **generalize across
 * models**. They may be a camera pose captured from one specific vehicle, in which
 * case they are right for whatever car the reference implementation was calibrated
 * on and subtly wrong on L8 UI7 / L5 LR. We cannot answer that off a car.
 *
 * So the requirement is: **when the car tells us they are per-model, calibrating
 * them must be a one-line edit at a place that already has the model in hand** —
 * [forModel] — and not an archaeology dig through a byte builder. That is the only
 * reason this class exists.
 *
 * ## What we actually know (see docs/nav-hud/openbyd-2421-launchermap-spike.md)
 * Statically: **nothing beyond their position on the wire.** In the reference they
 * are hardcoded literals, written twice (both branches of one function), never
 * computed, never read back, never varied by model, trim, screen size or route.
 * A whole-decompile search for each literal finds only those two writes. There is
 * no derivation to port, only a capture to copy or to re-measure.
 *
 * ## The naming is a HYPOTHESIS, not a fact
 * The field NUMBERS (1..6) are the contract; the NAMES below are our reading of
 * them and may be wrong. The reading is structural rather than numeric: three
 * large-magnitude values followed by three angle-magnitude values, one of which
 * ([pitchRadians], −1.5712) sits 0.025° off −π/2. A right angle appearing in a
 * triple of small angles is what a captured 6-DOF pose looks like, and −90° of
 * pitch is a camera pointed straight down — i.e. a top-down map view, which is
 * what "launcher map" implies. Every numeric attempt to *derive* the values
 * failed (see the doc); we did not manufacture a fit.
 *
 * If the pose reading turns out to be wrong, rename freely — but keep the
 * positional order, because that is the part that is actually load-bearing.
 */
data class LauncherMapPose(
    /** Inner field 1. HYPOTHESIS: camera/scene X. Units unknown — not screen
     *  pixels for any cluster geometry we ship, and not a Web-Mercator or
     *  EPSG:3857 coordinate at any zoom (all checked, none land in China). */
    val x: Double,
    /** Inner field 2. HYPOTHESIS: camera/scene Y. Same unit as [x]. */
    val y: Double,
    /** Inner field 3. HYPOTHESIS: camera/scene Z — height or depth offset. The
     *  only negative of the three magnitudes, ~19 in [x]/[y]'s units. */
    val z: Double,
    /** Inner field 4. HYPOTHESIS: roll, radians (≈ 0.084°) — i.e. ~level. */
    val rollRadians: Double,
    /** Inner field 5. HYPOTHESIS: pitch, radians. **The strongest signal in the
     *  whole set**: −1.5712258405572703 = −90.0246°, which is −π/2 to within
     *  0.025°. Near-but-not-exactly a right angle is itself evidence — an
     *  intentional constant would be `-Math.PI / 2`; a *measured* value would be
     *  a hair off, which is what this is. Reads as "camera looking straight down". */
    val pitchRadians: Double,
    /** Inner field 6. HYPOTHESIS: yaw, radians (≈ 0.214°) — i.e. ~north-up. */
    val yawRadians: Double,
) {
    companion object {

        /**
         * The reference implementation's literals, verbatim. **On-car-proven, but
         * on *its* car** — that is exactly the distinction this whole task exists
         * to resolve. Treat as a starting guess for our fleet, never as truth.
         */
        val REFERENCE_CAPTURE: LauncherMapPose = LauncherMapPose(
            x = 1161.2184496889508,
            y = 971.1426529964466,
            z = -19.15885124372106,
            rollRadians = 0.0014609250661213498,
            pitchRadians = -1.5712258405572703,
            yawRadians = 0.0037437084083233626,
        )

        /**
         * **The one per-model override point.** Calibrating a car after an on-car
         * render comparison = adding one `when` row here. Nothing else changes:
         * the variant reads the pose, the payload builder reads the variant.
         *
         * Every model resolves to [REFERENCE_CAPTURE] today, and that is the
         * honest state rather than an oversight — we have no measurement of our
         * own for any car yet, so any other row would be invention. The `when` is
         * written out per family so the first real calibration is a one-line
         * change at a place that already has the model name.
         *
         * @param modelName the EXISTING detector's friendly name
         *   (`CarIdentity.modelName()`), same key [SomeIpVariants.defaultFor] uses.
         *   No parallel model enum is introduced.
         */
        fun forModel(modelName: String?): LauncherMapPose {
            val m = modelName?.trim().orEmpty()
            return when {
                m.startsWith("Leopard 8") -> REFERENCE_CAPTURE  // uncalibrated
                m.startsWith("Leopard 5") -> REFERENCE_CAPTURE  // uncalibrated
                m.startsWith("Leopard 7") -> REFERENCE_CAPTURE  // uncalibrated
                else -> REFERENCE_CAPTURE                       // uncalibrated
            }
        }
    }
}
