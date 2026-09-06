package com.i99dev.ilink.pkg

import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Unit tests for [ClusterLaunchPolicy] — the PURE core only
 * ([ClusterLaunchPolicy.ruleHit] / [ClusterLaunchPolicy.decide] /
 * [ClusterLaunchPolicy.freshLaunchSubset]). No Android, no
 * SharedPreferences (the persisted `userAdded` set defaults to empty
 * in a unit JVM because [ClusterLaunchPolicy.ensureLoaded] is never
 * called — so `freshLaunchOnly`/`freshLaunchSubset` reduce to the
 * rule, which is exactly what we assert here).
 *
 * What this LOCKS IN:
 *   * The default rule = ReVanced / ReVanced-patched prefixes ONLY
 *     (`app.revanced.`, `com.revanced.`) and is dot-anchored so a
 *     lookalike like `app.revancedx…` does NOT match.
 *   * [decide] is `pkg ∈ userAdded ∨ rule(pkg)` — a user entry forces
 *     fresh-launch even when no rule matches; a rule match forces it
 *     even when the user set is empty.
 *   * Behaviour-identity with the pre-policy hardcoded heuristic
 *     (`commit de05022`): rule(pkg) == old isRevancedPackage(pkg).
 */
class ClusterLaunchPolicyTest {

    @Test
    fun rule_matches_revanced_prefixes_only() {
        assertTrue(ClusterLaunchPolicy.ruleHit("app.revanced.android.youtube"))
        assertTrue(ClusterLaunchPolicy.ruleHit("app.revanced.android.apps.maps"))
        assertTrue(ClusterLaunchPolicy.ruleHit("com.revanced.net.revancedmanager"))
    }

    @Test
    fun rule_rejects_non_revanced_and_lookalikes() {
        assertFalse(ClusterLaunchPolicy.ruleHit("com.google.android.youtube"))
        assertFalse(ClusterLaunchPolicy.ruleHit("org.telegram.messenger"))
        assertFalse(ClusterLaunchPolicy.ruleHit("com.example.navigator"))
        assertFalse(ClusterLaunchPolicy.ruleHit("ru.yandex.yandexmaps"))
        // dot-anchored: no bare prefix / no substring match.
        assertFalse(ClusterLaunchPolicy.ruleHit("app.revanced"))
        assertFalse(ClusterLaunchPolicy.ruleHit("app.revancedx.fake"))
        assertFalse(ClusterLaunchPolicy.ruleHit("net.app.revanced.spoof"))
    }

    @Test
    fun decide_userAdded_forces_fresh_launch_even_without_rule() {
        assertTrue(
            ClusterLaunchPolicy.decide(
                "org.telegram.messenger",
                setOf("org.telegram.messenger"),
            ),
        )
        assertFalse(
            ClusterLaunchPolicy.decide("org.telegram.messenger", emptySet()),
        )
    }

    @Test
    fun decide_rule_forces_fresh_launch_even_with_empty_user_set() {
        assertTrue(
            ClusterLaunchPolicy.decide(
                "app.revanced.android.youtube",
                emptySet(),
            ),
        )
    }

    @Test
    fun decide_false_when_neither_user_nor_rule() {
        assertFalse(
            ClusterLaunchPolicy.decide(
                "com.spotify.music",
                setOf("com.other.app"),
            ),
        )
    }

    @Test
    fun freshLaunchSubset_filters_to_rule_when_user_set_empty() {
        val input = listOf(
            "app.revanced.android.youtube",
            "com.spotify.music",
            "com.revanced.net.revancedmanager",
            "org.telegram.messenger",
        )
        assertEquals(
            listOf(
                "app.revanced.android.youtube",
                "com.revanced.net.revancedmanager",
            ),
            ClusterLaunchPolicy.freshLaunchSubset(input),
        )
    }
}
