package com.i99dev.ilink.car

import android.content.ContentResolver
import android.content.Context
import android.database.ContentObserver
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.concurrent.ConcurrentHashMap

/**
 * Phase-9 reader for the BYD ContentProviders (`com.byd.carStatusProvider`,
 * `carsettings`, …). Pulls URI metadata from a [CarTableSource] entry —
 * normally the encrypted-asset path so authority / path / column names are
 * not visible in the APK strings dump — and exposes:
 *
 *   - [readFamily] — one-shot snapshot for a family ("vehicle.environment",
 *     "vehicle.diagnostics", "climate", …). Maps row columns to the SDK's
 *     wire-shape field names per the [ContentProviderUri.column_to_field]
 *     map. Returns `null` if the family isn't in the table or the row is
 *     empty.
 *
 *   - [observeFamily] — registers a [ContentObserver] on the family's URI;
 *     the observer pushes the freshly-mapped row through `notify` on every
 *     `ContentResolver.notifyChange()`. Burst coalescing per
 *     [ObserverChannel.throttle_ms] keeps a CAN flood from saturating the
 *     JS bridge.
 *
 * Multi-call safety: a single instance is allocated per [Context] in
 * [CarChannel] and shared across all mini-app viewers. `_observers` is
 * keyed by `family + ":" + observerId` so two viewers subscribed to the
 * same family don't trample each other's unregister calls; observer IDs
 * are minted by `CarChannel.nextObserverId()`.
 *
 * Thread model: Android's `ContentObserver.onChange` is called on the
 * caller-supplied Handler — we use the main looper Handler so the
 * `notify` lambda fires on the UI thread, which matches the way Flutter
 * platform channels deliver events back to Dart. Coalescing uses
 * `Handler.postDelayed` rather than a coroutine so the cancel/replace
 * semantics are obvious.
 */
class CarStatusProviderSource(
    private val context: Context,
    private val tableSource: CarTableSource,
) {
    private companion object {
        const val TAG = "CarStatusProviderSrc"
    }

    private val resolver: ContentResolver = context.contentResolver
    private val mainHandler = Handler(Looper.getMainLooper())

    /// Active observer registrations keyed by `family:observerId`. Holds
    /// the [ContentObserver] reference itself so [unobserveFamily] can
    /// pass it back to [ContentResolver.unregisterContentObserver].
    private val observers = ConcurrentHashMap<String, ContentObserver>()

    /// Pending throttled-emit jobs keyed by `family:observerId`. Each
    /// observer notification cancels its prior pending job and posts a
    /// fresh one — the burst-coalescing trick. Set in [observeFamily];
    /// drained in [unobserveFamily].
    private val pendingEmits = ConcurrentHashMap<String, Runnable>()

    /// Resolve the URI for a family from the [CarTableSource] entry.
    /// Returns `null` if the family isn't declared — caller decides
    /// whether that's a "no implementation" or a "config bug".
    private fun uriFor(family: String): UriEntry? {
        val entry = tableSource.contentProviderUriFor(family) ?: return null
        val authority = entry.authority
        val path = entry.path
        val uri = if (path.isEmpty()) {
            Uri.parse("content://$authority")
        } else {
            Uri.parse("content://$authority/$path")
        }
        return UriEntry(uri = uri, entry = entry)
    }

    /// One-shot snapshot read. Maps the first row's columns onto the
    /// SDK-wire field names declared in [ContentProviderUri.column_to_field].
    /// Returns the field map, or `null` if the URI is missing, the
    /// query fails, or the cursor is empty.
    fun readFamily(family: String): Map<String, Any?>? {
        val u = uriFor(family) ?: run {
            Log.d(TAG, "readFamily($family): no URI in table")
            return null
        }
        val projection = if (u.entry.projection.isEmpty()) null else u.entry.projection.toTypedArray()
        val selection = if (u.entry.selection.isEmpty()) null else u.entry.selection
        return try {
            resolver.query(u.uri, projection, selection, null, null)?.use { c ->
                if (!c.moveToFirst()) {
                    Log.d(TAG, "readFamily($family): cursor empty")
                    return null
                }
                buildSnapshotRow(c, u.entry.columnToField)
            }
        } catch (t: Throwable) {
            // Permission, authority-not-found, etc. Logged but not
            // re-thrown — the caller (CarChannel) returns null to the
            // mini-app, which surfaces as an empty/zero snapshot.
            Log.w(TAG, "readFamily($family) failed", t)
            null
        }
    }

    /// Register a [ContentObserver] for the family. `notify` is called
    /// on the main thread with the fresh snapshot map every time the
    /// underlying provider issues a `notifyChange`. Returns the
    /// observerId the caller passes back to [unobserveFamily]. Returns
    /// `null` (no-op) if the family isn't in the catalog.
    fun observeFamily(
        family: String,
        observerId: String,
        notifyForDescendants: Boolean,
        throttleMs: Int,
        notify: (Map<String, Any?>) -> Unit,
    ): String? {
        val u = uriFor(family) ?: return null
        val key = "$family:$observerId"
        val observer = object : ContentObserver(mainHandler) {
            override fun onChange(selfChange: Boolean, changedUri: Uri?) {
                // Drop any pending emit for this key, schedule a fresh
                // one. Net effect: a burst of N notifications inside
                // [throttleMs] collapses to one read+emit at the end.
                pendingEmits[key]?.let { mainHandler.removeCallbacks(it) }
                val r = Runnable {
                    pendingEmits.remove(key)
                    val snap = readFamily(family)
                    if (snap != null) notify(snap)
                }
                pendingEmits[key] = r
                mainHandler.postDelayed(r, throttleMs.toLong())
            }
        }
        observers[key] = observer
        try {
            resolver.registerContentObserver(u.uri, notifyForDescendants, observer)
        } catch (t: Throwable) {
            // Same swallow-and-null contract as readFamily: if we can't
            // observe (permission denied, etc.), surface that as a
            // failed-to-subscribe to the caller. Drop the half-registered
            // entry from the map so a later [unobserveFamily] is a no-op.
            Log.w(TAG, "observeFamily($family) failed to register", t)
            observers.remove(key)
            return null
        }
        // Emit one initial snapshot so the SDK's onChange listener has
        // a value to render even before the next CAN frame arrives.
        readFamily(family)?.let(notify)
        return observerId
    }

    /// Symmetric to [observeFamily]. Idempotent — calling with an
    /// unknown id is a no-op.
    fun unobserveFamily(family: String, observerId: String) {
        val key = "$family:$observerId"
        observers.remove(key)?.let(resolver::unregisterContentObserver)
        pendingEmits.remove(key)?.let(mainHandler::removeCallbacks)
    }

    /// Tear-down for [CarChannel.dispose]: clears every observer and
    /// pending emit. Safe to call when the source has never observed
    /// anything.
    fun shutdown() {
        observers.values.forEach(resolver::unregisterContentObserver)
        observers.clear()
        pendingEmits.values.forEach(mainHandler::removeCallbacks)
        pendingEmits.clear()
    }

    private fun buildSnapshotRow(
        cursor: android.database.Cursor,
        columnToField: Map<String, String>,
    ): Map<String, Any?> {
        // Three paths:
        //   (a) Explicit column→field map — preferred when the provider
        //       has true columns (e.g. a future schema-versioned table).
        //   (b) (id, key, value) row schema — what BYD's carstatus
        //       and carsettings actually use. Each "field" is a row
        //       whose `key` column names it and `value` column holds
        //       the value. Verified on Leopard 8 against
        //       `content://com.byd.carStatusProvider/car_status` and
        //       `content://carsettings/global` (29 Apr 2026 dump).
        //   (c) Fallback "all columns" passthrough — for genuinely
        //       columnar providers we don't know about yet.
        val keyIdx = cursor.getColumnIndex("key")
        val valueIdx = cursor.getColumnIndex("value")
        val keyValueShape = keyIdx >= 0 && valueIdx >= 0 &&
            // Also require there isn't a meaningful column-set beyond
            // (id, key, value) — otherwise we'd misinterpret a
            // legitimate columnar table that just happens to have a
            // `key` column.
            cursor.columnCount <= 4

        if (keyValueShape) return buildKeyValueSnapshot(cursor, keyIdx, valueIdx)

        val out = LinkedHashMap<String, Any?>(cursor.columnCount)
        if (columnToField.isNotEmpty()) {
            for ((column, field) in columnToField) {
                val idx = cursor.getColumnIndex(column)
                if (idx < 0) {
                    out[field] = null
                    continue
                }
                out[field] = readCell(cursor, idx)
            }
        } else {
            for (i in 0 until cursor.columnCount) {
                out[cursor.getColumnName(i)] = readCell(cursor, i)
            }
        }
        return out
    }

    /// Walk the entire result set, treating each row as one (key,
    /// value) pair. Coerces values to int/double when the cell looks
    /// numeric so the Dart side gets the right Zod-friendly type
    /// without re-parsing. Strings that contain a '#' separator (BYD
    /// uses these for the 200-element history arrays) are kept raw —
    /// callers that care can split in Dart.
    private fun buildKeyValueSnapshot(
        cursor: android.database.Cursor,
        keyIdx: Int,
        valueIdx: Int,
    ): Map<String, Any?> {
        cursor.moveToFirst()
        val out = LinkedHashMap<String, Any?>(cursor.count)
        do {
            val key = cursor.getString(keyIdx) ?: continue
            out[key] = readCellWithCoercion(cursor, valueIdx)
        } while (cursor.moveToNext())
        return out
    }

    private fun readCellWithCoercion(
        cursor: android.database.Cursor,
        idx: Int,
    ): Any? {
        // BYD stores everything as TEXT in these key/value rows even
        // when the value is numeric (`auto_time=1`,
        // `lighting_backlight_brightness=172`). Detect numeric-looking
        // strings up front so the Dart-side Zod schemas don't have to
        // string→int every read.
        if (cursor.getType(idx) == android.database.Cursor.FIELD_TYPE_STRING) {
            val s = cursor.getString(idx) ?: return null
            if (s.isEmpty()) return s
            // Skip '#'-separated history arrays — those are application
            // data, not scalars.
            if (s.contains('#')) return s
            s.toLongOrNull()?.let { return it }
            s.toDoubleOrNull()?.let { return it }
            return s
        }
        return readCell(cursor, idx)
    }

    private fun readCell(cursor: android.database.Cursor, idx: Int): Any? {
        // Pick the cell's actual SQLite type — we don't want to coerce
        // ints to strings before sending across the platform channel
        // because the SDK's Zod schemas check `z.number()`. Fallback to
        // string for blob-or-other.
        return when (cursor.getType(idx)) {
            android.database.Cursor.FIELD_TYPE_NULL -> null
            android.database.Cursor.FIELD_TYPE_INTEGER -> cursor.getLong(idx)
            android.database.Cursor.FIELD_TYPE_FLOAT -> cursor.getDouble(idx)
            android.database.Cursor.FIELD_TYPE_STRING -> cursor.getString(idx)
            else -> cursor.getString(idx)
        }
    }

    private data class UriEntry(
        val uri: Uri,
        val entry: ContentProviderUriEntry,
    )
}

/// Plain-data view of a `ContentProviderUri` proto entry. Lives here
/// (not in a generated proto file) so the [CarTableSource] interface
/// can return a stable Kotlin type regardless of which backing source
/// (literal vs. encrypted-proto) loads it.
data class ContentProviderUriEntry(
    val family: String,
    val authority: String,
    val path: String,
    val projection: List<String>,
    val selection: String,
    val columnToField: Map<String, String>,
)

/// Plain-data view of an `ObserverChannel` proto entry.
data class ObserverChannelEntry(
    val family: String,
    val notifyForDescendants: Boolean,
    val throttleMs: Int,
)
