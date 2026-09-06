package com.i99dev.ilink.miniapps

import android.util.Log
import com.i99dev.ilink.car.profiles.CarProfileRegistry

/**
 * Single point of dispatch for the mini-apps native-capability runtime.
 *
 * Phase 0+1 lands the dispatcher infrastructure — the source-swap
 * machinery and the empty/encrypted source pair — but does NOT yet
 * route any family handler through it. Each existing
 * `*PlatformPlugin` (pkg, boot, surface, display, cursor) keeps its
 * hardcoded am-start / Intent / AIDL constants until that family's
 * Phase 2 migration PR.
 *
 * After Phase 2, family handlers become thin shells that call
 * [resolve] and dispatch off the returned [OpRoute]. After Phase 3,
 * the Dart side passes only [OpRoute.token] (the sha256-derived
 * 16-hex op token) and the dispatcher uses [resolveByToken].
 *
 * Mirrors [com.i99dev.ilink.car.UnitDispatcher] — same source-swap
 * pattern, same fail-closed empty default, same `setSource` /
 * `sourceVersion` API shape so MainActivity wiring is symmetric and
 * any future "is the X table loaded?" telemetry can answer both with
 * the same query.
 */
object MiniAppDispatcher {
    private const val TAG = "MiniAppDispatcher"

    @Volatile
    private var source: MiniAppTableSource = EmptySource

    /**
     * Active model id chain — finest-to-coarsest match candidates the
     * dispatcher tries against each route's `model_match`. Pushed in
     * once at boot from Dart (`ModelDetector.detect()`), read by
     * [resolveByToken].
     *
     * Concretely the list is `[variant, dilinkFamily]` with `null`s
     * filtered — e.g. `["l8", "di5.1"]` on a Leopard 8, or
     * `["di5.1"]` alone on a Di5.1 trim we haven't profiled. The
     * dispatcher's match rule is "any id in the chain hits any
     * entry in `model_match`." That keeps existing textproto entries
     * targeting `["di5.1"]` working even after the per-trim variant
     * resolves more precisely (e.g. real L8 ROMs whose
     * `ro.product.system.model` doesn't carry the `l8` substring,
     * which used to land on `di5.1` and now resolves to `l8` via
     * outswver — both still match here).
     *
     * Default `["unknown"]` means: any route with a non-empty
     * `model_match` is filtered out and the dispatcher returns null.
     * Routes with an empty `model_match` (= matches everything) still
     * resolve. So a head unit we haven't profiled yet still gets the
     * cross-model baseline ops without crashing.
     */
    @Volatile
    private var modelIds: List<String> = listOf("unknown")

    /** Single-slot callback fired when [setModelIds] resolves the
     *  model to a NEW chain (the cold-boot `unknown` → trim
     *  transition). `DisplayPlatformPlugin` registers here to
     *  re-push a corrected display snapshot to event subscribers
     *  that received the pre-detection Generic one (D2). Single
     *  nullable slot — one consumer today; mirrors the plugin's own
     *  single-`sink` pattern. Cleared from the plugin's
     *  `dispose()`. */
    @Volatile
    private var onModelResolved: (() -> Unit)? = null

    /** Register (or clear, with `null`) the [onModelResolved]
     *  callback. The consumer MUST clear it in its own dispose. */
    fun setModelResolvedListener(cb: (() -> Unit)?) {
        onModelResolved = cb
    }

    /** Set the active model id chain. Idempotent. Logs the
     *  transition for the same trail Sentry tags surface. Called
     *  from MainActivity after `ModelDetector` resolves on the
     *  Dart side and pushes the result back via the model_detector
     *  channel. */
    fun setModelIds(newIds: List<String>) {
        val sanitized = newIds
            .filter { it.isNotBlank() && it != "unknown" }
            .ifEmpty { listOf("unknown") }
        // Keep CarProfileRegistry.active in lockstep with the resolved
        // model chain. setActive() previously had ZERO production
        // callers, so forActiveCar() — consumed by the pkg.launch
        // role gate via DisplayRoles.roleFor() — was permanently
        // GENERIC_PROFILE while the picker used the correctly-resolved
        // forVariant() profile (two divergent sources for the same
        // display; audit D1). Idempotent (AtomicReference) and placed
        // before the no-change early-return so a redundant resolve
        // still re-asserts the active profile.
        //
        // Pass the FULL chain (not just the head): a known-but-
        // unprofiled nameplate head (e.g. "tang") only resolves to the
        // generation-correct DiShare/am-start transport when the
        // `dilinkFamily` token in the chain tail is available to
        // CarProfileRegistry.forChain.
        CarProfileRegistry.setActive(sanitized)
        if (sanitized == modelIds) return
        Log.i(TAG, "modelIds: $modelIds -> $sanitized")
        modelIds = sanitized
        // D2: the active profile just transitioned (unknown →
        // resolved trim). Notify listeners so DisplayPlatformPlugin
        // can re-push a corrected snapshot to subscribers that got
        // the pre-detection Generic one. Fired only here — after the
        // no-change early-return — so idempotent re-resolves don't
        // spam the event channel. Runs on the model_detector channel
        // thread; the listener hops to the main thread itself.
        onModelResolved?.invoke()
    }

    /** Convenience for the legacy single-id call site (preserved so
     *  internal Dart fallbacks that still pass a single string keep
     *  working). Wraps into a one-element chain. */
    fun setModelId(newId: String) = setModelIds(listOf(newId))

    /** Diagnostic — surfaces the finest id the dispatcher is
     *  currently selecting against (i.e. the head of the chain).
     *  Stable across calls until [setModelIds] runs. */
    fun activeModelId(): String = modelIds.first()

    /** Diagnostic — full match chain. */
    fun activeModelIds(): List<String> = modelIds

    /** Swap the dispatcher's data source. Called once at boot from
     *  MainActivity after [EncryptedMiniAppTableSource.loadOrNull]
     *  succeeds. Logs the version transition. */
    fun setSource(newSource: MiniAppTableSource) {
        val previous = source.version()
        source = newSource
        Log.i(TAG, "source swapped: $previous -> ${newSource.version()}")
    }

    /** Diagnostic — surfaces which source produced a given dispatch
     *  outcome. Stable across calls until [setSource] runs. */
    fun sourceVersion(): String = source.version()

    /** Reset to fail-closed empty default. Test-only. */
    fun resetForTesting() {
        source = EmptySource
    }

    /**
     * Resolve an op route by (familyId, opId). Returns `null` when the
     * pair isn't in the active source — caller's responsibility to
     * fail closed.
     */
    fun resolve(familyId: String, opId: String): OpRoute? =
        source.opRoute(familyId, opId)

    /**
     * Resolve an op route by token. Phase 3 entrypoint — the Dart side
     * passes only the sha256-derived token, never the plaintext
     * "family.op" name.
     *
     * Multi-model selection rule: when the table holds multiple routes
     * for the same token (because the textproto declared per-model
     * variants via `model_match`), pick the most-specific match for
     * the active [modelIds] chain. "Most specific" = longest non-empty
     * `model_match` that intersects the chain. An entry with empty
     * `model_match` matches everything but ranks last, so a per-trim
     * override always wins over a generic fallback.
     *
     * Returns null when no route matches — caller surfaces
     * "unsupported on this model" via the existing structured error
     * path, no crash.
     */
    fun resolveByToken(token: String): OpRoute? {
        val candidates = source.opRoutesByToken(token)
        if (candidates.isEmpty()) return null
        return selectByModel(candidates, modelIds)
    }

    private fun selectByModel(routes: List<OpRoute>, chain: List<String>): OpRoute? {
        var best: OpRoute? = null
        var bestSpecificity = -1
        for (r in routes) {
            val match = r.modelMatch
            val specificity = when {
                match.isEmpty() -> 0  // matches everything; lowest priority
                chain.any { match.contains(it) } -> match.size  // any chain id matches
                else -> -1  // doesn't match this model; skip
            }
            if (specificity > bestSpecificity) {
                best = r
                bestSpecificity = specificity
            }
        }
        return best
    }

    /** Pass-through to the active source. */
    fun binderRoute(routeId: String) = source.binderRoute(routeId)
    fun intentAction(name: String) = source.intentAction(name)
    fun settingsKey(name: String) = source.settingsKey(name)
    fun contentProviderUriFor(family: String) = source.contentProviderUriFor(family)
    fun knownFamilies(): List<String> = source.knownFamilies()
    fun knownOps(familyId: String): List<String> = source.knownOps(familyId)

    /**
     * Fail-closed default. Every lookup returns null; the version is
     * `"empty-v1"` so log lines distinguish "no source yet" from
     * "encrypted source loaded but no entry."
     */
    object EmptySource : MiniAppTableSource {
        override fun version(): String = "empty-v1"
        override fun opRoute(familyId: String, opId: String): OpRoute? = null
    }
}
