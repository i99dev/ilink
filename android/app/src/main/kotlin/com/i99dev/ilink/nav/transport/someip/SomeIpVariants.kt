package com.i99dev.ilink.nav.transport.someip

import com.i99dev.ilink.nav.transport.HudRenderer
import com.i99dev.ilink.nav.transport.NoopHudRenderer

/**
 * Which [SomeIpVariant] this car should speak — the *selection* half of the
 * TASK-001/002 seam.
 *
 * ## Why this exists: the revert path
 * Nothing in this sprint's HUD work can be proven by a host test; only a car can
 * say whether the cluster still renders. So every change must be reversible on
 * the car **without a rebuild**. This object is that switch: forcing [UI7] pins
 * the wire to the exact bytes we ship and have proven on-car today, whatever a
 * later build decides the per-model default should be.
 *
 * ## Values
 *  - [AUTO] — derive from the detected model ([defaultFor]). The stored default.
 *  - [UI7]  — force the on-car-proven 5.0UI RoadInfo wire ([Ui7Variant]).
 *  - [LAUNCHER_MAP_CN] — the 11-topic launcher map-widget wire
 *    ([LauncherMapCnVariant]). **Opt-in only**; [defaultFor] never returns it.
 *
 * The *stored* default is [AUTO] and the *resolved* default is [UI7] on every
 * path, including undetected/unknown cars — deliberately NOT the reference
 * implementation's `LAUNCHER_MAP_CN` default. Defaulting the fleet onto a wire
 * no car of ours has ever rendered would be shipping an unproven nav change to
 * everyone at once.
 *
 * ## Purity
 * Same contract as [SomeIpVariant]: zero Android imports, so the whole
 * resolution matrix is host-testable (`NavSomeIpVariantSelectionTest`) instead
 * of only observable on a car. The model string is passed IN; nothing here
 * probes the device.
 */
object SomeIpVariants {

    /** Derive the variant from the detected model. The stored default. */
    const val AUTO = "auto"

    /** Force [Ui7Variant] — today's shipped, on-car-proven wire. The revert value. */
    const val UI7 = "ui7"

    /**
     * Force [LauncherMapCnVariant] — the 11-topic launcher map-widget wire
     * (TASK-016). **Accepted as an explicit choice, never produced by
     * [defaultFor].** The mechanism is known-good on the reference author's car;
     * whether its map-camera constants ([LauncherMapPose]) generalize to ours is
     * exactly what is unproven, so it stays a deliberate opt-in.
     */
    const val LAUNCHER_MAP_CN = "launcher_map_cn"

    /** Every id the option accepts. A new variant adds its id here + a [create] row. */
    val ids: List<String> = listOf(AUTO, UI7, LAUNCHER_MAP_CN)

    fun isKnown(id: String?): Boolean = id != null && id in ids

    /**
     * Model → default variant. Reads the EXISTING detector's friendly model name
     * (`CarIdentity.modelName()` / `byd_model_detector.dart`); this deliberately
     * does not introduce a parallel model enum.
     *
     * Every row resolves to [UI7] today, and that is the point rather than an
     * oversight. [LauncherMapCnVariant] now exists, but no car of OURS has been
     * seen to render it, so defaulting any model onto it would be shipping an
     * unproven nav change to a whole model family at once. It is reachable only
     * by setting the option by hand. The `when` is written out per family so that
     * promoting a variant later is a one-line edit at a place that already has
     * the model in hand, and so the matrix is pinned by a test today.
     *
     *  - Leopard 8 (UI7 / Huawei-HMI) — reads SOME/IP RoadInfo → [UI7].
     *  - Leopard 5 Long Range — renders via the CAN-FID / instrument-HAL path and
     *    ignores RoadInfo, so this option does not affect it. It still resolves to
     *    [UI7] because "drive all available transports" means the SOME/IP push
     *    happens anyway and must stay on the proven wire.
     *  - null / unrecognised — [UI7], the conservative answer.
     */
    fun defaultFor(modelName: String?): String {
        val m = modelName?.trim().orEmpty()
        return when {
            m.isEmpty() -> UI7                      // undetected car → proven wire
            m.startsWith("Leopard 8") -> UI7        // UI7 cluster, reads RoadInfo
            m.startsWith("Leopard 5") -> UI7        // incl. Long Range: CAN-FID path
            m.startsWith("Leopard 7") -> UI7
            m.startsWith("BYD HAN L") -> UI7
            m.startsWith("Song PLUS") -> UI7
            else -> UI7                             // unknown model → proven wire
        }
    }

    /**
     * The one resolution rule: a user-set preference WINS over the model-derived
     * default; [AUTO], null, or an unrecognised id fall through to [defaultFor].
     *
     * Tolerating an unrecognised [pref] matters for downgrades — a car that was
     * on a build with an extra variant keeps that id in SharedPreferences, and a
     * rollback must land on the proven default rather than on nothing.
     *
     * [modelDefault] is injectable for one reason: with a single ported variant
     * every branch of this function returns `ui7`, so "the preference overrides
     * the model default" is *unobservable* through the return value and a test
     * asserting it would pass even if the override were deleted (verified — the
     * mutation goes undetected without this seam). Passing a divergent default in
     * a test makes the rule real today instead of the day a second variant lands.
     * App code always uses the default argument.
     */
    fun resolve(
        pref: String?,
        modelName: String?,
        modelDefault: (String?) -> String = ::defaultFor,
    ): String {
        val p = pref?.trim()?.lowercase()
        if (p != null && p != AUTO && isKnown(p)) return p
        return modelDefault(modelName)
    }

    /**
     * Id → variant. Unknown ids fall back to [Ui7Variant] rather than throwing:
     * a bad pref must degrade to today's behaviour, never to a dead HUD.
     *
     * [modelName] is only consulted by [LAUNCHER_MAP_CN], to pick its map-camera
     * pose ([LauncherMapPose.forModel]) — the single place a per-car calibration
     * would land. It is passed in rather than probed, so this stays pure.
     */
    fun create(
        id: String?,
        renderer: HudRenderer = NoopHudRenderer,
        modelName: String? = null,
    ): SomeIpVariant =
        when (id?.trim()?.lowercase()) {
            UI7 -> Ui7Variant(renderer)
            LAUNCHER_MAP_CN -> LauncherMapCnVariant(pose = LauncherMapPose.forModel(modelName))
            else -> Ui7Variant(renderer)
        }
}

/**
 * A [SomeIpVariant] that resolves itself from the live option on every access, so
 * flipping the setting takes effect **without a rebuild and without a reinstall**.
 *
 * [SomeIpHudTransport][com.i99dev.ilink.nav.transport.SomeIpHudTransport] is
 * constructed once at plugin build, long before the user opens the settings
 * panel, so a variant captured at construction time could never be changed. This
 * delegate is the fix — and it keeps the transport untouched, which is what the
 * structural guard in `NavSomeIpVariantTest` requires.
 *
 * [idProvider] is a lambda, not a `NavHudOptions` reference, purely to keep this
 * class Android-free (and therefore host-testable). The plugin passes
 * `{ NavHudOptions.resolvedSomeIpVariant }`.
 *
 * The resolved variant is memoised per id, so the hot [buildEvents] path costs
 * one string compare, not an allocation.
 *
 * **Caveat, deliberate:** [serviceIds] is read at `start()`/`stop()`. Flipping the
 * option while the HUD is armed would let `stop()` see different ids than
 * `start()` did. Harmless today (one variant, one id) but the Dart controller
 * re-arms on change anyway — same pattern as `clusterProtocol` — so the two
 * always pair up.
 */
class SelectedSomeIpVariant(
    private val renderer: HudRenderer = NoopHudRenderer,
    private val modelNameProvider: () -> String? = { null },
    private val idProvider: () -> String,
) : SomeIpVariant {

    @Volatile private var cachedId: String? = null
    @Volatile private var cached: SomeIpVariant = Ui7Variant(renderer)

    private fun current(): SomeIpVariant {
        // A throwing provider must not take the HUD down: fall back to the
        // proven variant, exactly as an unknown id does.
        val id = runCatching { idProvider() }.getOrDefault(SomeIpVariants.UI7)
        if (id != cachedId) {
            // Model is read only on a variant SWITCH, not on the hot path, and a
            // failure to detect it degrades to the uncalibrated default pose.
            val model = runCatching { modelNameProvider() }.getOrNull()
            cached = SomeIpVariants.create(id, renderer, model)
            cachedId = id
        }
        return cached
    }

    /** Reports the variant actually in force, so diagnostics can't lie about it. */
    override val name: String get() = current().name

    override val serviceIds: List<Long> get() = current().serviceIds

    override fun buildEvents(
        frame: com.i99dev.ilink.nav.domain.NavGuidance,
        counter: Int,
    ): List<Pair<Long, ByteArray>> = current().buildEvents(frame, counter)

    override fun buildClearEvents(): List<Pair<Long, ByteArray>> = current().buildClearEvents()
}
