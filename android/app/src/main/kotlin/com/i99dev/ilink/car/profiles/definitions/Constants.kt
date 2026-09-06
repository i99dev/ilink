package com.i99dev.ilink.car.profiles.definitions

/**
 * Always-on capability strings every trim grants unconditionally.
 *
 * Mirrors the legacy `VariantCapabilityProfile.UNIVERSAL_CAPS` so
 * the cap-bit output is byte-identical to the pre-refactor seed.
 *
 * Promote a cap to a per-trim field on [com.i99dev.ilink.car.profiles
 * .CapabilityProfile] if any trim ever needs to lack it. Today
 * `door.set` / `window.set` / `ac.get` / `ac.set` live here even
 * though some trims (e.g. L8) probe absent for body control —
 * a follow-up PR splits these into per-trim values once the
 * consumer logic is also updated to drop them when absent.
 */
internal val STANDARD_UNIVERSAL_CAPS: List<String> = listOf(
    "display.read",
    "pkg.read",
    "pkg.launch.ivi",
    "surface.write.ivi",
    "cursor.write",
    "gesture.dispatch",
    "ac.get",
    "ac.set",
    "door.set",
    "window.set",
)
