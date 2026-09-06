package com.i99dev.ilink.input

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Drift guard for the on-car a11y flags probe.
 *
 * `RemoteControlAccessibilityService.XML_DECLARED_FLAGS` hardcodes the flag set that
 * `res/xml/a11y_remote_control.xml` declares, so `onServiceConnected` can log which
 * declared flags the ROM did *not* hand back (`droppedByRom`). If someone edits the XML
 * and forgets the Kotlin constant, that log starts lying — it would report a flag as
 * "dropped by ROM" that we never asked for, or silently stop watching one we did. On a
 * probe whose entire purpose is to settle a hypothesis with one scarce car session, a
 * lying diagnostic is worse than no diagnostic.
 *
 * This test therefore pins the XML side. It deliberately re-states the expected flag
 * names rather than importing the constant (which is `private`, and lives on an Android
 * class that cannot be loaded on a host JVM) — so it catches XML edits, which is the
 * drift direction that actually happens.
 *
 * NOT covered here, and not coverable on a host JVM: whether the ROM preserves any of
 * these flags, whether the re-assert in `onServiceConnected` runs, or whether
 * `findAccessibilityNodeInfosByViewId` returns anything. There is no `AccessibilityService`
 * off-device. That remains pending on-car verification.
 */
class A11yDeclaredFlagsTest {
    /** Flag-name -> value, per `javap -constants android.accessibilityservice.AccessibilityServiceInfo`. */
    private val flagValues = mapOf(
        "flagRetrieveInteractiveWindows" to 0x40,
        "flagReportViewIds" to 0x10,
        "flagRequestFilterKeyEvents" to 0x20,
        "flagRequestMultiFingerGestures" to 0x1000,
    )

    private fun xmlFile(): File {
        // Unit tests may run with working dir = android/app or the repo root depending on
        // how Gradle is invoked; probe upward rather than assuming one of them.
        val rel = "src/main/res/xml/a11y_remote_control.xml"
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            for (candidate in listOf(File(dir, rel), File(dir, "android/app/$rel"))) {
                if (candidate.isFile) return candidate
            }
            dir = dir.parentFile
        }
        throw AssertionError("could not locate $rel from ${System.getProperty("user.dir")}")
    }

    private fun declaredFlagNames(): List<String> {
        val xml = xmlFile().readText()
        val attr = Regex("""android:accessibilityFlags\s*=\s*"([^"]*)"""")
            .find(xml)
            ?.groupValues
            ?.get(1)
            ?: throw AssertionError("a11y_remote_control.xml declares no accessibilityFlags attribute")
        return attr.split('|').map { it.trim() }.filter { it.isNotEmpty() }
    }

    @Test
    fun `xml declares exactly the flags the probe constant accounts for`() {
        assertEquals(
            "a11y_remote_control.xml accessibilityFlags changed — update XML_DECLARED_FLAGS in " +
                "RemoteControlAccessibilityService or the droppedByRom log will misreport",
            flagValues.keys.sorted(),
            declaredFlagNames().sorted(),
        )
    }

    @Test
    fun `declared flags sum to the expected correct-ROM word`() {
        // 0x40 | 0x10 | 0x20 | 0x1000 == 0x1070 == 4208. This is the number the on-car
        // instructions tell the user to compare the dumpsys flags word against, so if the
        // XML changes, the documented expectation has to change with it.
        val sum = declaredFlagNames().fold(0) { acc, name ->
            acc or (flagValues[name] ?: throw AssertionError("unknown a11y flag in XML: $name"))
        }
        assertEquals(0x1070, sum)
        assertEquals(4208, sum)
    }

    @Test
    fun `the two nav-critical flags are declared`() {
        // flagReportViewIds backs the entire scrape (findAccessibilityNodeInfosByViewId);
        // flagRetrieveInteractiveWindows backs the background window ladder. Losing either
        // from the XML produces a frozen cluster, and the two failures look identical.
        val declared = declaredFlagNames()
        assertTrue("flagReportViewIds must stay declared", "flagReportViewIds" in declared)
        assertTrue(
            "flagRetrieveInteractiveWindows must stay declared",
            "flagRetrieveInteractiveWindows" in declared,
        )
    }
}
