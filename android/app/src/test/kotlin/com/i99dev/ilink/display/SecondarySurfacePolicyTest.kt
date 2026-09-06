package com.i99dev.ilink.display

import java.io.File
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.assertFailsWith

class SecondarySurfacePolicyTest {
    private val files = File(System.getProperty("java.io.tmpdir"), "surface-policy-files").canonicalFile
    private val root = File(files, "mini_apps/clock/1.0")
    private val entry = File(root, "index.html").toURI().toASCIIString()
    private val policy = SecondarySurfacePolicy(entry)

    @Test fun sameBundleScriptsAndRoutesWork() {
        policy.requireOwner(files, "clock")
        assertTrue(policy.allows(File(root, "scripts/app.js").toURI().toASCIIString()))
        assertTrue(policy.allows(policy.resolve("/cluster.html?preset=night", entry)))
        assertEquals(entry, policy.resolve("/", entry))
    }

    @Test fun unconsentedNetworkAndOtherDeviceFilesAreDenied() {
        for (url in listOf("https://miniapps.ilink.app/index.html",
            "https://example.com/data", "http://127.0.0.1/private", "content://settings/system",
            "javascript:alert(1)", "file://remote/index.html", "data:text/html,hello")) {
            assertFalse(policy.allows(url), url)
        }
        assertFalse(policy.allows(File(files, "shared_prefs/FlutterSharedPreferences.xml").toURI().toASCIIString()))
        assertFalse(policy.allows(File(files, "mini_apps/other/1.0/index.html").toURI().toASCIIString()))
        assertFalse(policy.allows(File(files, "mini_apps/clock/1.01/index.html").toURI().toASCIIString()))
    }

    @Test fun traversalCannotEscapeBundle() {
        for (route in listOf("/../private.txt", "/%2e%2e/private.txt", "/..%2fprivate.txt",
            "/scripts/../../private.txt")) {
            assertFailsWith<IllegalArgumentException>(route) { policy.resolve(route, entry) }
        }
    }

    @Test fun exportedActivityCannotClaimAnotherAppOrUninstalledLocation() {
        assertFailsWith<IllegalArgumentException> { policy.requireOwner(files, "other") }
        assertFailsWith<IllegalArgumentException> { policy.requireOwner(files, "../clock") }
        assertFailsWith<IllegalArgumentException> {
            SecondarySurfacePolicy(File(files, "private/index.html").toURI().toASCIIString())
                .requireOwner(files, "clock")
        }
    }
}
