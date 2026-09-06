package com.i99dev.ilink.car

/**
 * BYDAutoManager device-type constants. Single source of truth — previously
 * duplicated across UnitDispatcher, AutoFeatureService, and DashDaemon.
 *
 * When the encrypted CarTable proto lands (plan Phase 2), these move into
 * the `CarTable.device_types` map and this file collapses to a thin getter.
 * Until then, keep the literals here so the three consumers can't drift.
 */
object DeviceTypes {
    const val AC = 1000
    const val BODY = 1001
    const val SETTING = 1023

    /**
     * DTs the daemon should `enableDevice` once at bootstrap so later
     * setInt / getInt calls on them avoid the first-touch latency. Order
     * matters only insofar as earlier entries get warmed first.
     *
     * @JvmField exposes the array as a plain static field so DashDaemon.java
     * can read `DeviceTypes.WARM` without the Kotlin-object getter hop.
     */
    @JvmField
    val WARM: IntArray = intArrayOf(
        AC, BODY, SETTING,
        // 1038, 1040, 1041, 1045 — extra DTs the daemon warms empirically;
        // unnamed here because no action is wired to them yet. If you add
        // one, give the constant a name and drop the magic number.
        1038, 1040, 1041, 1045,
    )
}
