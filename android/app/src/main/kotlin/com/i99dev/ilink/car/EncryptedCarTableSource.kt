package com.i99dev.ilink.car

import android.content.Context
import android.util.Log
import com.i99dev.ilink.security.EncryptedTableLoader
import com.i99dev.ilink.security.LocalTableLoader
import com.google.protobuf.TextFormat
// Generated classes from proto/car_table.proto by the com.google.protobuf
// Gradle plugin — package matches the `package com.i99dev.ilink.car;`
// declaration in the proto.
// Import path: com.i99dev.ilink.car.CarTableProto.{CarTable, FastAction, …}

/**
 * Dispatch data adapter: a valid locally cached v2 table is preserved on upgrades;
 * fresh installs use public textproto bundled in the signed APK. No network or
 * server-issued key is required. The historic class name preserves call sites.
 */
class EncryptedCarTableSource private constructor(
    private val table: CarTableProto.CarTable,
    private val sourceKind: String,
) : CarTableSource {

    private val fastByAction: Map<String, CarTableProto.FastAction> =
        table.fastActionsList.associateBy { it.actionId }

    private val unitByAction: Map<String, CarTableProto.UnitAction> =
        table.unitActionsList.associateBy { it.actionId }

    private val specByName: Map<String, CarTableProto.UnitSpec> =
        table.unitsList.associateBy { it.name }

    /**
     * Telemetry-read catalog. Two entry shapes feed in:
     *
     *   * **Integer key** (legacy) — `key` is set explicitly in the
     *     textproto. Used for the original 26 entries whose feature
     *     IDs we know at build time.
     *   * **Feature name** — `feature_name` is set instead of (or
     *     alongside) `key`. The host resolves the name via
     *     [BydAutoFeatureIdsCatalog] at first access; entries whose
     *     name isn't on this device's BYD framework drop silently.
     *     Used for the ~150 fields whose integer values live only
     *     in the framework jar (the catalog is reflection-loaded at
     *     boot).
     *
     * `feature_name` wins when both are populated — that's the
     * forward-compatible path because BYD can rename a feature's
     * integer between ROMs while keeping the name stable.
     */
    private val statusKeysCached: List<StatusKey> =
        table.statusKeysList.mapNotNull { sk ->
            // feature_name is the only addressing path — the legacy
            // `key` proto field was removed 12 May 2026. Drop entries
            // whose name is missing or doesn't resolve in the framework
            // catalog (silently — this is expected on stripped ROMs).
            val resolvedKey = BydAutoFeatureIdsCatalog.resolve(sk.featureName)
                ?: return@mapNotNull null
            // Branch on the proto's value_kind discriminator. Default
            // (UNSPECIFIED) maps to IntKey for back-compat with rows
            // that pre-date Phase 2.
            when (sk.valueKind) {
                CarTableProto.ValueKind.VALUE_KIND_DOUBLE ->
                    StatusKey.DoubleKey(label = sk.label, dt = sk.deviceType, key = resolvedKey)
                CarTableProto.ValueKind.VALUE_KIND_BYTES ->
                    StatusKey.BytesKey(label = sk.label, dt = sk.deviceType, key = resolvedKey)
                CarTableProto.ValueKind.VALUE_KIND_INT_ARRAY ->
                    StatusKey.IntArrayKey(label = sk.label, dt = sk.deviceType, key = resolvedKey)
                // VALUE_KIND_UNSPECIFIED + UNRECOGNIZED + null (older
                // proto without the field) all collapse to IntKey.
                else ->
                    StatusKey.IntKey(label = sk.label, dt = sk.deviceType, key = resolvedKey)
            }
        }

    private val binderRouteById: Map<String, BinderRoute> =
        table.binderRoutesList.associate {
            it.routeId to BinderRoute(
                routeId = it.routeId,
                serviceToken = it.serviceToken,
                aidlDescriptor = it.aidlDescriptor,
                transactionCode = it.transactionCode,
            )
        }

    /// Phase-9 ContentProvider URIs and observer settings. The proto
    /// schema declares both as `repeated`; we materialise them into
    /// fast lookup maps keyed by `family`. Empty list = no
    /// ContentProvider integration in this build of the encrypted
    /// catalog (older v1 assets that pre-date Phase-9 just never had
    /// these fields populated).
    private val contentProviderUriByFamily: Map<String, ContentProviderUriEntry> =
        table.contentProviderUrisList.associate { p ->
            p.family to ContentProviderUriEntry(
                family = p.family,
                authority = p.authority,
                path = p.path,
                projection = p.projectionList.toList(),
                selection = p.selection,
                columnToField = p.columnToFieldMap.toMap(),
            )
        }

    private val observerChannelByFamily: Map<String, ObserverChannelEntry> =
        table.observerChannelsList.associate { p ->
            p.family to ObserverChannelEntry(
                family = p.family,
                notifyForDescendants = p.notifyForDescendants,
                throttleMs = p.throttleMs,
            )
        }

    override fun version(): String = "$sourceKind-${table.version.ifBlank { "unknown" }}"

    override fun fastAction(actionId: String): FastAction? {
        val proto = fastByAction[actionId] ?: return null
        // feature_name is the only addressing path — the legacy
        // `key` proto field was removed 12 May 2026. Drop entries
        // whose name doesn't resolve in the framework catalog so a
        // router miss surfaces as `unknown action` upstream rather
        // than firing a setInt with a junk key.
        val resolvedKey = BydAutoFeatureIdsCatalog.resolve(proto.featureName)
            ?: return null
        return FastAction(
            dt = proto.deviceType,
            key = resolvedKey,
            valueFn = proto.value.toValueFn(),
        )
    }

    override fun unitAction(actionId: String): UnitAction? {
        val proto = unitByAction[actionId] ?: return null
        val templates = proto.argTemplateList.toList()
        return UnitAction(
            unit = proto.unitName,
            args = { argsMap -> templates.map { renderTemplate(it, argsMap) } },
        )
    }

    override fun unit(unitName: String): UnitSpec? {
        val proto = specByName[unitName] ?: return null
        return UnitSpec(dex = proto.dexFilename, className = proto.className)
    }

    override fun knownActionIds(): List<String> =
        (fastByAction.keys + unitByAction.keys).sorted()

    override fun knownUnitNames(): List<String> = specByName.keys.sorted()

    override fun statusKeys(): List<StatusKey> = statusKeysCached

    override fun binderRoute(routeId: String): BinderRoute? = binderRouteById[routeId]

    override fun contentProviderUriFor(family: String): ContentProviderUriEntry? =
        contentProviderUriByFamily[family]

    override fun observerChannelFor(family: String): ObserverChannelEntry? =
        observerChannelByFamily[family]

    companion object {
        private const val TAG = "EncryptedCarTableSource"
        // v2 lives in filesDir, not assets — backend serves it after
        // pair, client persists. Same wire format (nonce || ct || tag),
        // different key derivation (HKDF over server_secret || signer_sha).
        private const val V2_FILE = "car_table.v2.pb.enc"
        private const val V2_INFO = "car_table.v2"

        /** Both providers read only on-device data. Invalid caches fall back to the APK. */
        fun loadOrNull(context: Context): EncryptedCarTableSource? {
            val legacy = EncryptedTableLoader.v2PlaintextOrNull(context, V2_FILE, V2_INFO, TAG)
            if (legacy != null) parse(legacy)?.let { return it }
            val text = LocalTableLoader.textOrNull(context, "car_table") ?: return null
            return try {
                val builder = CarTableProto.CarTable.newBuilder()
                TextFormat.getParser().merge(text, builder)
                parse(builder.build().toByteArray(), "bundled")
            } catch (e: Exception) {
                Log.w(TAG, "bundled table invalid: ${e.javaClass.simpleName}")
                null
            }
        }
        private fun parse(plaintext: ByteArray, sourceKind: String = "encrypted"): EncryptedCarTableSource? {
            return try {
                // Both decoded legacy caches and bundled TextFormat parsing
                // converge here as protobuf wire bytes.
                val table = CarTableProto.CarTable.parseFrom(plaintext)
                if (table.fastActionsCount == 0 && table.unitActionsCount == 0) {
                    Log.w(TAG, "decrypted table has no actions — treating as invalid")
                    return null
                }
                Log.i(
                    TAG,
                    "loaded $sourceKind table: version=${table.version} " +
                        "fast=${table.fastActionsCount} unit=${table.unitActionsCount} " +
                        "units=${table.unitsCount}",
                )
                EncryptedCarTableSource(table, sourceKind)
            } catch (t: Throwable) {
                // Most common causes: AEADBadTagException (wrong signer),
                // TextFormat.ParseException (corrupted text), OutOfMemory
                // (giant adversarial asset). All treated identically —
                // log and return null. UnitDispatcher stays on its empty
                // default; every dispatch fails closed.
                Log.w(TAG, "failed to load encrypted table: ${t.javaClass.simpleName}: ${t.message}")
                null
            }
        }
    }
}

/** Convert a parsed [CarTableProto.ValueSpec] into the runtime lambda
 *  [FastAction.valueFn] expects. Supports constant / argInt / argBool
 *  plus the percent / level / color24 variants from the extended proto schema.
 *  Atomic packed-array writes (ArgPackedArray) are NOT yet handled at
 *  runtime — the dispatcher would need a setIntArray path on the daemon
 *  side. Until then, ARG_PACKED_ARRAY entries fall through to 0 and
 *  log a warning — populating one without daemon support is a no-op. */
private fun CarTableProto.ValueSpec.toValueFn(): (Map<String, Any?>) -> Int {
    return when (kindCase) {
        CarTableProto.ValueSpec.KindCase.CONSTANT -> { _ -> constant }
        CarTableProto.ValueSpec.KindCase.ARG_INT -> {
            val spec = argInt
            val name = spec.argName
            val def = spec.defaultValue
            { args -> (args[name] as? Int) ?: def }
        }
        CarTableProto.ValueSpec.KindCase.ARG_BOOL -> {
            val spec = argBool
            val name = spec.argName
            val on = spec.onValue
            val off = spec.offValue
            { args -> if (args[name] == true) on else off }
        }
        CarTableProto.ValueSpec.KindCase.ARG_PERCENT -> {
            val spec = argPercent
            val name = spec.argName
            val min = spec.min
            val max = spec.max
            val def = spec.defaultValue
            { args ->
                val raw = (args[name] as? Int) ?: def
                raw.coerceIn(min, max)
            }
        }
        CarTableProto.ValueSpec.KindCase.ARG_LEVEL -> {
            val spec = argLevel
            val name = spec.argName
            val min = spec.min
            val max = spec.max
            val def = spec.defaultValue
            { args ->
                val raw = (args[name] as? Int) ?: def
                raw.coerceIn(min, max)
            }
        }
        CarTableProto.ValueSpec.KindCase.ARG_COLOR24 -> {
            val spec = argColor24
            val name = spec.argName
            val def = spec.defaultValue
            { args ->
                when (val raw = args[name]) {
                    is Int -> raw and 0xFFFFFF
                    is Map<*, *> -> {
                        val r = (raw["r"] as? Int ?: 0) and 0xFF
                        val g = (raw["g"] as? Int ?: 0) and 0xFF
                        val b = (raw["b"] as? Int ?: 0) and 0xFF
                        (r shl 16) or (g shl 8) or b
                    }
                    else -> def
                }
            }
        }
        else -> { _ -> 0 }
    }
}

/** Render a `{key:default}` template token against the dispatch args map.
 *  Matches the `{key:default}` syntax emitted by the Dart dumper so
 *  textproto round-trips the argv shape cleanly. Literals (no braces)
 *  pass through unchanged. */
private fun renderTemplate(token: String, args: Map<String, Any?>): String {
    if (!token.startsWith('{') || !token.endsWith('}')) return token
    val body = token.substring(1, token.length - 1)
    val colon = body.indexOf(':')
    val (key, default) = if (colon >= 0) {
        body.substring(0, colon) to body.substring(colon + 1)
    } else {
        body to ""
    }
    return when (val raw = args[key]) {
        null -> default
        is Int -> raw.toString()
        is Boolean -> if (raw) "1" else "0"
        else -> raw.toString()
    }
}
