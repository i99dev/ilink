package com.i99dev.ilink.car

/**
 * Data-only view of the dispatcher tables. UnitDispatcher consults a
 * [CarTableSource] instead of owning the maps itself, so dispatch logic
 * doesn't need to know how the table is hydrated.
 *
 * Production composes a preserved local v2 cache with public tables bundled
 * in the signed APK. UnitDispatcher.EmptySource remains the fail-closed
 * fallback if neither local source is valid. No network provisioning is
 * required; dispatch and safety logic remain independent of hydration.
 */
interface CarTableSource {
    /**
     * Short identifier of which source + what version is currently loaded.
     * Examples: `"literal-v1"`, `"encrypted-v3"`, `"mock-v1"`. Surfaces
     * through [UnitDispatcher.setSource] logging and the daemonStatus
     * channel so log files and backend telemetry can tell which source
     * produced a given dispatch outcome — useful for A/B-style rollouts
     * of a new encrypted table, or for debugging a field report that
     * only reproduces on one of the sources.
     */
    fun version(): String

    fun fastAction(actionId: String): FastAction?
    fun unitAction(actionId: String): UnitAction?
    fun unit(unitName: String): UnitSpec?
    fun knownActionIds(): List<String>
    fun knownUnitNames(): List<String>

    /**
     * Telemetry reads aggregated by [AutoFeatureService.readStatus]. Replaces
     * the hardcoded `plan` list that used to live there. Order is preserved
     * from the source — UI surfaces (CarState.mergeBridge) iterate this
     * list in order and the order matches what the user sees first.
     *
     * Implementations may return an empty list (e.g. [UnitDispatcher.EmptySource]
     * before the encrypted asset loads) and AutoFeatureService falls back
     * gracefully.
     */
    fun statusKeys(): List<StatusKey> = emptyList()

    /**
     * AIDL routing for [AcFeatureService]. Replaces the const block at the
     * top of AcFeatureService.kt (BYDAC, ACAC, FRAG, CLEAN, SETT, SEAT
     * descriptors + service tokens). Returns `null` if the route_id isn't
     * known — caller's responsibility to fail closed.
     *
     * Default empty implementation so legacy CarTableSources don't need
     * to know about binder routes.
     */
    fun binderRoute(routeId: String): BinderRoute? = null

    /**
     * Phase-9: BYD ContentProvider URI for a family snapshot
     * ("vehicle.environment", "vehicle.diagnostics", "climate", …).
     * Returns `null` when the family isn't backed by a ContentProvider
     * (e.g. live-state families that flow through BYDMgmt.getInt
     * instead). Consumed by [CarStatusProviderSource].
     */
    fun contentProviderUriFor(family: String): ContentProviderUriEntry? = null

    /**
     * Phase-9: observer settings for the same family. The host registers
     * a [android.database.ContentObserver] using these on every
     * `<family>.subscribe` request. Defaults are a sane fallback for
     * families that have a URI but no explicit observer entry.
     */
    fun observerChannelFor(family: String): ObserverChannelEntry? = null
}

/**
 * Telemetry read entry — populates car.status.
 *
 * Sealed by value-kind so [AutoFeatureService.readStatus] can dispatch
 * to the right daemon op (`getInt` / `getDouble` / `getBuffer` /
 * `getIntArray`) via exhaustive `when`. Mirrors the Phase 2 proto
 * `ValueKind` discriminator: rows with the default `UNSPECIFIED` value
 * kind become [IntKey] (back-compat with the original flat data class
 * shape); rows with explicit `DOUBLE` / `BYTES` / `INT_ARRAY` become
 * the matching subtype.
 *
 * Adding a new value kind is a 4-step change all in this file +
 * `EncryptedCarTableSource.statusKeysCached`:
 *   1. New ValueKind enum entry in `proto/car_table.proto`
 *   2. New subtype in this sealed hierarchy
 *   3. Branch in `EncryptedCarTableSource.statusKeysCached`
 *   4. Branch in `AutoFeatureService.readStatus`
 *
 * The exhaustive `when` then forces the compiler to surface every
 * remaining usage at build time.
 */
sealed interface StatusKey {
    /** Output map key — what UI code reads off `car.status[label]`. */
    val label: String

    /** BYD device type (1000=AC, 1001=BODY, …). Matches
     *  proto `StatusKey.device_type`. */
    val dt: Int

    /** Single integer feature ID. Lives on the sealed interface (and
     *  not just per-subtype) so iteration code that doesn't care about
     *  the value kind — e.g. push subscription, bulk grouping by
     *  (dt, key) — can read it without an exhaustive `when`. The
     *  per-op dispatch in [AutoFeatureService.readStatus] still
     *  branches on the subtype to pick the right daemon op. */
    val key: Int

    /** Single integer value — the `getInt(dt, key)` path. Default
     *  for `value_kind == UNSPECIFIED` rows (every pre-Phase-2 entry). */
    data class IntKey(
        override val label: String,
        override val dt: Int,
        override val key: Int,
    ) : StatusKey

    /** Double-precision value — temperatures, pressures, %. */
    data class DoubleKey(
        override val label: String,
        override val dt: Int,
        override val key: Int,
    ) : StatusKey

    /** Raw byte buffer — media metadata, DTC blobs. Surfaces as
     *  `Base64String` in the JSON wire payload. */
    data class BytesKey(
        override val label: String,
        override val dt: Int,
        override val key: Int,
    ) : StatusKey

    /** Multi-zone read backed by `getIntArray(dt, keys)`. The
     *  per-zone integers are packed into the value column under
     *  `<label>.<zoneIndex>` keys at projection time. */
    data class IntArrayKey(
        override val label: String,
        override val dt: Int,
        override val key: Int,
    ) : StatusKey
}

/** Binder destination for AIDL transact calls (replaces AcFeatureService consts). */
data class BinderRoute(
    val routeId: String,
    val serviceToken: String,
    val aidlDescriptor: String,
    val transactionCode: Int,
)

/** Direct daemon setInt: (dt, key, computed value). */
data class FastAction(
    val dt: Int,
    val key: Int,
    val valueFn: (Map<String, Any?>) -> Int,
)

/** Per-domain DEX + class to spawn via app_process64. */
data class UnitSpec(val dex: String, val className: String)

/**
 * UNIT-path dispatch recipe: name of a unit to spawn + a builder that
 * materialises the argv list from the caller's args map.
 */
data class UnitAction(
    val unit: String,
    val args: (Map<String, Any?>) -> List<String>,
)
