package com.i99dev.ilink.miniapps

/**
 * Data-only view of the mini-apps dispatcher tables. MiniAppDispatcher
 * consults a [MiniAppTableSource] instead of owning the routes itself,
 * so dispatch logic doesn't need to know how the table is hydrated.
 *
 * Two implementations:
 *   - `EncryptedMiniAppTableSource` — production. Reads
 *     `assets/mini_app_table.pb.enc`, decrypts via
 *     [com.i99dev.ilink.security.EncryptedAssetLoader], hydrates
 *     OpRoute / BinderRouteSpec / IntentActionSpec / SettingsKeySpec /
 *     ContentProviderUriSpec records.
 *   - `MiniAppDispatcher.EmptySource` — fail-closed default until the
 *     encrypted loader runs at MainActivity.onCreate. No plaintext op
 *     names live in classes.dex; if the encrypted asset can't decrypt
 *     (signer mismatch, missing asset, source not yet populated), every
 *     dispatch returns "unknown route" and the family handler surfaces
 *     a structured error.
 *
 * Mirrors [com.i99dev.ilink.car.CarTableSource] exactly. Two reasons
 * for the duplication rather than a shared interface:
 *   1. The car + mini-apps tables have different field shapes (the car
 *      has FastAction / UnitAction; mini-apps have OpRoute keyed by the
 *      sha256-derived op_token). Shared types would force a lowest-
 *      common-denominator schema and lose specificity.
 *   2. A corrupted mini-apps source must not be able to take down the
 *      car table dispatcher, and vice versa. Independent storage paths,
 *      independent code paths.
 */
interface MiniAppTableSource {
    /**
     * Short identifier of which source + what version is currently
     * loaded. Examples: `"empty-v1"`, `"encrypted-v3"`. Surfaces through
     * [MiniAppDispatcher.sourceVersion] logging so dispatch outcomes can
     * be traced to the source that produced them.
     */
    fun version(): String

    /**
     * Resolve an op route by (familyId, opId). Returns `null` when the
     * pair isn't in the table — caller's responsibility to fail closed.
     */
    fun opRoute(familyId: String, opId: String): OpRoute?

    /**
     * Resolve an op route by token (sha256-derived 16-hex). Used by the
     * Phase 3 Dart-side path where the SDK passes only the token.
     * Returns `null` when the token isn't in the table.
     *
     * Convenience — calls [opRoutesByToken] and returns the first match.
     * For multi-model dispatch the dispatcher uses [opRoutesByToken]
     * directly so it can pick the best variant per [model_match].
     */
    fun opRouteByToken(token: String): OpRoute? = opRoutesByToken(token).firstOrNull()

    /**
     * All op routes matching this token. Multiple entries per token
     * exist when the textproto declares per-model variants
     * (`model_match`). Returns an empty list when the token isn't
     * known. Order is the textproto's declaration order — the
     * dispatcher's selector resolves by specificity, not by order.
     */
    fun opRoutesByToken(token: String): List<OpRoute> = emptyList()

    /**
     * Family list for diagnostic introspection only — never used to make
     * routing decisions. Empty list when the table isn't loaded.
     */
    fun knownFamilies(): List<String> = emptyList()

    /**
     * Op id list for one family — diagnostic only. Empty when the
     * family isn't in the table.
     */
    fun knownOps(familyId: String): List<String> = emptyList()

    /**
     * Binder routing for surface / display / cursor families. Returns
     * `null` if the route isn't known — caller's responsibility to fail
     * closed.
     */
    fun binderRoute(routeId: String): BinderRoute? = null

    /**
     * Intent action constant lookup. Used by AM_START / INTENT op kinds
     * to dereference [OpRoute.intentRef] into the actual action string.
     */
    fun intentAction(name: String): IntentAction? = null

    /**
     * settings.global / settings.secure / settings.system key lookup.
     * Used by SETTINGS_PUT / SETTINGS_GET op kinds.
     */
    fun settingsKey(name: String): SettingsKey? = null

    /**
     * ContentProvider URI lookup for mini-app-specific snapshots. Same
     * shape as [com.i99dev.ilink.car.CarTableSource.contentProviderUriFor].
     */
    fun contentProviderUriFor(family: String): ContentProviderUriEntry? = null
}

// ── Data classes returned by MiniAppTableSource ───────────────────────
//
// These are the runtime shapes the dispatcher consumes. Distinct from
// the proto-generated message classes so the dispatcher doesn't depend
// on the protobuf-java runtime — keeps the dispatch hot-path lean and
// the proto runtime confined to the loader.

/**
 * One op route. Returned by [MiniAppTableSource.opRoute] /
 * [MiniAppTableSource.opRouteByToken]. `kind` drives the dispatcher's
 * native-call selection; the `*Ref` fields name auxiliary entries the
 * dispatcher dereferences via the matching `intentAction` /
 * `binderRoute` / `settingsKey` / `contentProviderUriFor` lookup.
 */
data class OpRoute(
    val familyId: String,
    val opId: String,
    val token: String,
    val kind: NativeKind,
    val argTemplate: List<String>,
    val requiredScope: String,
    val intentRef: String,
    val binderRef: String,
    val settingsRef: String,
    val cpRef: String,
    val requiresStationary: Boolean,
    /** Set of model ids this route applies to. Empty = matches every
     *  model (the default). See [MiniAppDispatcher.resolveByToken]
     *  for the selection rule. */
    val modelMatch: List<String> = emptyList(),
)

/**
 * AIDL/binder route. Same shape as [com.i99dev.ilink.car.BinderRoute]
 * but kept in this package so the mini-apps dispatcher doesn't depend
 * on the car package's data classes.
 */
data class BinderRoute(
    val routeId: String,
    val serviceToken: String,
    val aidlDescriptor: String,
    val transactionCode: Int,
)

/** Intent action / category / flags constant. */
data class IntentAction(
    val name: String,
    val action: String,
    val category: String,
    val flags: Int,
)

/** settings.<namespace>.<key> entry. */
data class SettingsKey(
    val name: String,
    val namespace: String,
    val key: String,
)

/** ContentProvider URI entry. Mirrors car-side CPUE field-for-field. */
data class ContentProviderUriEntry(
    val family: String,
    val authority: String,
    val path: String,
    val projection: List<String>,
    val selection: String,
    val columnToField: Map<String, String>,
)

/**
 * Native call shape — drives dispatcher selection. Field numbers match
 * the proto `NativeKind` enum exactly so the loader can map straight
 * across.
 */
enum class NativeKind {
    UNSPECIFIED,
    AM_START,
    INTENT,
    BINDER,
    SERVICE_CALL,
    CP_QUERY,
    SETTINGS_PUT,
    SETTINGS_GET,
    PM_LIST,
    PM_FOREGROUND,
    ACCESSIBILITY,
}
