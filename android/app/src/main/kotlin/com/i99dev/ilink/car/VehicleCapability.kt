package com.i99dev.ilink.car

/**
 * Vehicle / hardware capabilities — host-side mirror of the SDK's
 * canonical taxonomy in `ilink-sdk/src/types/vehicle-capabilities.ts`.
 *
 * **Bit positions are derived from list order — never reorder.** The
 * SDK's drift check parses [ALL] looking for `val ALL: List<String> =
 * listOf(...)`; coordinate any rename with the check script.
 *
 * The host wires the bitmask as a [Long] (64-bit) so we have headroom
 * past the SDK's 31-bit signed-int wire shape; on the wire the value
 * is sent as a [Long] in the [DisplayPlatformPlugin] snapshot.
 */
object VehicleCapability {

    /** Canonical list. Bit position = index. **Append only.** */
    val ALL: List<String> = listOf(
        "display.read",
        "pkg.read",
        "pkg.launch.ivi",
        "pkg.launch.passenger",
        "pkg.launch.cluster.pixel",
        "pkg.launch.cluster.icons",
        "pkg.launch.dishare",
        "surface.write.ivi",
        "surface.write.passenger",
        "surface.write.cluster",
        "cursor.write",
        "gesture.dispatch",
        "ac.get",
        "ac.set",
        "door.set",
        "window.set",
    )

    /** Reverse map for fast lookup. Built once at class init. */
    private val INDEX: Map<String, Int> = ALL.withIndex().associate { (i, c) -> c to i }

    /**
     * Pack a list of capability strings into a [Long] bitmask. Unknown
     * strings are silently skipped (defensive — a future SDK declaring
     * caps an older host doesn't recognise must not crash the snapshot).
     */
    fun bitsOf(caps: Iterable<String>): Long {
        var bits = 0L
        for (cap in caps) {
            val idx = INDEX[cap] ?: continue
            bits = bits or (1L shl idx)
        }
        return bits
    }

    /**
     * Inverse — bitmask to canonical list, in taxonomy order. Used
     * when the host needs to log human-readable names (probe report,
     * Sentry breadcrumbs).
     */
    fun fromBits(bits: Long): List<String> {
        val out = ArrayList<String>()
        for (i in ALL.indices) {
            if ((bits and (1L shl i)) != 0L) out.add(ALL[i])
        }
        return out
    }

    /** `app.required ⊆ vehicle.has`. Single AND. Catalog hot path. */
    fun hasAll(vehicleBits: Long, requiredBits: Long): Boolean =
        (vehicleBits and requiredBits) == requiredBits
}
