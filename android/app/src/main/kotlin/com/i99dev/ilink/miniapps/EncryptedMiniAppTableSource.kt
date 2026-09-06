package com.i99dev.ilink.miniapps

import android.content.Context
import android.util.Log
import com.i99dev.ilink.security.EncryptedTableLoader
import com.i99dev.ilink.security.LocalTableLoader
import com.google.protobuf.TextFormat

/**
 * Dispatch data adapter: a valid locally cached v2 table is preserved on upgrades;
 * fresh installs use public textproto bundled in the signed APK. No network or
 * server-issued key is required. The historic class name preserves call sites.
 */
class EncryptedMiniAppTableSource private constructor(
    private val table: MiniAppTableProto.MiniAppTable,
    private val sourceKind: String,
) : MiniAppTableSource {

    // Index by (familyId, opId) — convenience for the legacy
    // [opRoute(family, op)] entry. When per-model variants exist for
    // the same op, this returns the first one declared; per-model
    // dispatch should go through [opRoutesByToken] instead.
    private val byPair: Map<String, MiniAppTableProto.OpRoute> =
        table.opsList.associate { "${it.familyId}.${it.opId}" to it }

    // Multi-valued index: a single token can map to N OpRoutes when
    // the textproto declares per-model variants (`model_match`). The
    // dispatcher picks the right one at call time.
    private val routesByToken: Map<String, List<MiniAppTableProto.OpRoute>> =
        table.opsList
            .filter { it.opToken.isNotEmpty() }
            .groupBy { it.opToken }

    private val familiesById: Map<String, MiniAppTableProto.FamilyRoute> =
        table.familiesList.associateBy { it.familyId }

    private val binderById: Map<String, BinderRoute> =
        table.binderRoutesList.associate {
            it.routeId to BinderRoute(
                routeId = it.routeId,
                serviceToken = it.serviceToken,
                aidlDescriptor = it.aidlDescriptor,
                transactionCode = it.transactionCode,
            )
        }

    private val intentByName: Map<String, IntentAction> =
        table.intentActionsList.associate {
            it.name to IntentAction(
                name = it.name,
                action = it.action,
                category = it.category,
                flags = it.flags,
            )
        }

    private val settingsByName: Map<String, SettingsKey> =
        table.settingsKeysList.associate {
            it.name to SettingsKey(
                name = it.name,
                namespace = it.namespace,
                key = it.key,
            )
        }

    private val cpByFamily: Map<String, ContentProviderUriEntry> =
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

    override fun version(): String = "$sourceKind-${table.version.ifBlank { "unknown" }}"

    override fun opRoute(familyId: String, opId: String): OpRoute? {
        val proto = byPair["$familyId.$opId"] ?: return null
        return proto.toRuntime()
    }

    override fun opRoutesByToken(token: String): List<OpRoute> {
        return routesByToken[token]?.map { it.toRuntime() } ?: emptyList()
    }

    override fun knownFamilies(): List<String> = familiesById.keys.sorted()

    override fun knownOps(familyId: String): List<String> =
        table.opsList.filter { it.familyId == familyId }.map { it.opId }.sorted()

    override fun binderRoute(routeId: String): BinderRoute? = binderById[routeId]

    override fun intentAction(name: String): IntentAction? = intentByName[name]

    override fun settingsKey(name: String): SettingsKey? = settingsByName[name]

    override fun contentProviderUriFor(family: String): ContentProviderUriEntry? =
        cpByFamily[family]

    private fun MiniAppTableProto.OpRoute.toRuntime(): OpRoute = OpRoute(
        familyId = familyId,
        opId = opId,
        token = opToken,
        kind = kind.toRuntimeKind(),
        argTemplate = argTemplateList.toList(),
        requiredScope = requiredScope,
        intentRef = intentRef,
        binderRef = binderRef,
        settingsRef = settingsRef,
        cpRef = cpRef,
        requiresStationary = requiresStationary,
        modelMatch = modelMatchList.toList(),
    )

    private fun MiniAppTableProto.NativeKind.toRuntimeKind(): NativeKind = when (this) {
        MiniAppTableProto.NativeKind.AM_START -> NativeKind.AM_START
        MiniAppTableProto.NativeKind.INTENT -> NativeKind.INTENT
        MiniAppTableProto.NativeKind.BINDER -> NativeKind.BINDER
        MiniAppTableProto.NativeKind.SERVICE_CALL -> NativeKind.SERVICE_CALL
        MiniAppTableProto.NativeKind.CP_QUERY -> NativeKind.CP_QUERY
        MiniAppTableProto.NativeKind.SETTINGS_PUT -> NativeKind.SETTINGS_PUT
        MiniAppTableProto.NativeKind.SETTINGS_GET -> NativeKind.SETTINGS_GET
        MiniAppTableProto.NativeKind.PM_LIST -> NativeKind.PM_LIST
        MiniAppTableProto.NativeKind.PM_FOREGROUND -> NativeKind.PM_FOREGROUND
        MiniAppTableProto.NativeKind.ACCESSIBILITY -> NativeKind.ACCESSIBILITY
        else -> NativeKind.UNSPECIFIED
    }

    companion object {
        private const val TAG = "EncMiniAppTableSrc"
        private const val V2_FILE = "mini_app_table.v2.pb.enc"
        private const val V2_INFO = "mini_app_table.v2"

        /** Both providers read only on-device data. Invalid caches fall back to the APK. */
        fun loadOrNull(context: Context): EncryptedMiniAppTableSource? {
            val legacy = EncryptedTableLoader.v2PlaintextOrNull(context, V2_FILE, V2_INFO, TAG)
            if (legacy != null) parse(legacy)?.let { return it }
            val text = LocalTableLoader.textOrNull(context, "mini_app_table") ?: return null
            return try {
                val builder = MiniAppTableProto.MiniAppTable.newBuilder()
                TextFormat.getParser().merge(text, builder)
                parse(builder.build().toByteArray(), "bundled")
            } catch (e: Exception) {
                Log.w(TAG, "bundled table invalid: ${e.javaClass.simpleName}")
                null
            }
        }
        private fun parse(plaintext: ByteArray, sourceKind: String = "encrypted"): EncryptedMiniAppTableSource? {
            return try {
                val table = MiniAppTableProto.MiniAppTable.parseFrom(plaintext)
                if (table.opsCount == 0 && table.familiesCount == 0) {
                    Log.w(TAG, "decrypted table has no ops or families — treating as invalid")
                    return null
                }
                Log.i(
                    TAG,
                    "loaded $sourceKind mini-apps table: version=${table.version} " +
                        "families=${table.familiesCount} ops=${table.opsCount} " +
                        "binders=${table.binderRoutesCount} intents=${table.intentActionsCount}",
                )
                EncryptedMiniAppTableSource(table, sourceKind)
            } catch (t: Throwable) {
                // AEADBadTagException (wrong signer), InvalidProtocolBufferException
                // (corrupted bytes), OutOfMemory (giant adversarial asset). All
                // treated identically — log and return null. MiniAppDispatcher
                // stays on its empty default; every dispatch fails closed.
                Log.w(TAG, "failed to load encrypted mini-apps table: ${t.javaClass.simpleName}: ${t.message}")
                null
            }
        }
    }
}
