package com.i99dev.ilink.voice

import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Unit tests for [WheelVoiceKeyParser] — the pure half of the dynamic
 * wheel-voice discovery. No Android, no ADB: every input is a captured shell
 * body, so the whole "find the button from the system" resolution is locked
 * in here.
 *
 * The primary fixtures are the **verbatim** output captured from the L8 test
 * car (192.168.4.72, Di5.1) during the discovery session:
 *   - [L8_KEYLAYOUTS]: `grep -HE 'AUTO_MEDIA_VOICE|VOICE_ASSIST|ASSIST'` over
 *     the `.kl` files in `/system/usr/keylayout`
 *   - [L8_GETEVENT]: `getevent -lp`
 *
 * What this LOCKS IN: the wheel-voice key resolves to `AUTO_MEDIA_VOICE`
 * scancode 290 on `/dev/input/event0` for THIS ROM, and the AOSP
 * `VOICE_ASSIST` / `ASSIST` fallbacks lose to it on priority — exactly the
 * dynamic, non-hardcoded behaviour the feature promises across trims.
 */
class WheelVoiceKeyParserTest {

    private val L8_KEYLAYOUTS = """
        /system/usr/keylayout/Generic.kl:key 582   VOICE_ASSIST
        /system/usr/keylayout/Generic.kl:# Linux KEY_ASSISTANT
        /system/usr/keylayout/Generic.kl:key 583   ASSIST
        /system/usr/keylayout/Vendor_046d_Product_b501.kl:key 582 ASSIST
        /system/usr/keylayout/Vendor_0957_Product_0001.kl:key 217   ASSIST        WAKE
        /system/usr/keylayout/Vendor_18d1_Product_0200.kl:# assistant buttons
        /system/usr/keylayout/Vendor_18d1_Product_0200.kl:key 0x246 VOICE_ASSIST
        /system/usr/keylayout/Vendor_18d1_Product_0200.kl:key 0x247 ASSIST
        /system/usr/keylayout/Vendor_1949_Product_0401.kl:key 217 ASSIST
        /system/usr/keylayout/simulate-keys.kl:key 290   AUTO_MEDIA_VOICE
        /system/usr/keylayout/simulate-keys.kl:key 312   AUTO_MEDIA_VOICE_LP
    """.trimIndent()

    private val L8_GETEVENT = """
        add device 1: /dev/input/event6
          name:     "KTMICRO BYD-mic+div5"
        add device 2: /dev/input/event10
          name:     "dp_touchpad"
        add device 8: /dev/input/event2
          name:     "gpio-keys"
        add device 9: /dev/input/event0
          name:     "simulate-keys"
        add device 10: /dev/input/event3
          name:     "mtk-pmic-keys"
    """.trimIndent()

    // ── parseCandidates ────────────────────────────────────────────────────

    @Test
    fun `parses decimal and hex scancodes, skips comments, _LP and trailing flags`() {
        val c = WheelVoiceKeyParser.parseCandidates(L8_KEYLAYOUTS)
        // AUTO_MEDIA_VOICE_LP (312) and both comment lines are excluded; the
        // remaining 8 `key` lines whose label is in the accepted set survive.
        assertEquals(8, c.size, "candidate count")
        // Decimal scancode + basename.
        assertTrue(
            c.any { it.label == "AUTO_MEDIA_VOICE" && it.scanCode == 290 && it.keyLayout == "simulate-keys" },
            "AUTO_MEDIA_VOICE 290 on simulate-keys",
        )
        // Hex scancode (0x246 == 582).
        assertTrue(
            c.any { it.label == "VOICE_ASSIST" && it.scanCode == 582 && it.keyLayout == "Vendor_18d1_Product_0200" },
            "hex 0x246 -> 582",
        )
        // Trailing flag (WAKE) is ignored — label is the token after scancode.
        assertTrue(
            c.any { it.label == "ASSIST" && it.scanCode == 217 && it.keyLayout == "Vendor_0957_Product_0001" },
            "trailing WAKE flag ignored",
        )
        // The long-press variant is never a candidate.
        assertTrue(c.none { it.scanCode == 312 }, "AUTO_MEDIA_VOICE_LP excluded")
    }

    @Test
    fun `ignores non-key directives and blank input`() {
        assertTrue(WheelVoiceKeyParser.parseCandidates("").isEmpty())
        val noise = """
            /system/usr/keylayout/Generic.kl:# just a comment
            /system/usr/keylayout/Generic.kl:flags FUNCTION
            /system/usr/keylayout/Generic.kl:key 999 SOME_OTHER_KEY
        """.trimIndent()
        assertTrue(WheelVoiceKeyParser.parseCandidates(noise).isEmpty())
    }

    // ── parseDeviceNodes ─────────────────────────────────────────────────────

    @Test
    fun `maps device names to dev nodes`() {
        val nodes = WheelVoiceKeyParser.parseDeviceNodes(L8_GETEVENT)
        assertEquals("/dev/input/event0", nodes["simulate-keys"])
        assertEquals("/dev/input/event2", nodes["gpio-keys"])
        assertEquals("/dev/input/event6", nodes["KTMICRO BYD-mic+div5"])
    }

    // ── resolve (end-to-end on the verbatim L8 capture) ─────────────────────

    @Test
    fun `resolves the BYD wheel-voice key with its dev node on L8`() {
        val key = WheelVoiceKeyParser.resolve(L8_KEYLAYOUTS, L8_GETEVENT)
        assertNotNull(key)
        assertEquals("AUTO_MEDIA_VOICE", key.label)
        assertEquals(290, key.scanCode)
        assertEquals("/dev/input/event0", key.deviceNode)
        assertEquals("simulate-keys", key.keyLayout)
    }

    @Test
    fun `AUTO_MEDIA_VOICE wins over AOSP VOICE_ASSIST and ASSIST`() {
        // Same layouts minus the BYD label: must fall back to VOICE_ASSIST,
        // not ASSIST — priority order is honoured.
        val noByd = L8_KEYLAYOUTS.lineSequence()
            .filterNot { it.contains("AUTO_MEDIA_VOICE") }
            .joinToString("\n")
        val key = WheelVoiceKeyParser.resolve(noByd, L8_GETEVENT)
        assertNotNull(key)
        assertEquals("VOICE_ASSIST", key.label)
    }

    @Test
    fun `prefers a candidate whose keylayout maps to a present input device`() {
        // Two ASSIST candidates; only one keylayout maps to a real device in
        // the getevent capture, so that one must be chosen (its node is real).
        val onlyAssist = """
            /system/usr/keylayout/Vendor_046d_Product_b501.kl:key 582 ASSIST
            /system/usr/keylayout/gpio-keys.kl:key 217 ASSIST
        """.trimIndent()
        val getevent = """
            add device 8: /dev/input/event2
              name:     "gpio-keys"
        """.trimIndent()
        val key = WheelVoiceKeyParser.resolve(onlyAssist, getevent)
        assertNotNull(key)
        assertEquals("gpio-keys", key.keyLayout)
        assertEquals("/dev/input/event2", key.deviceNode)
        assertEquals(217, key.scanCode)
    }

    @Test
    fun `returns null when no accepted label is declared`() {
        assertNull(WheelVoiceKeyParser.resolve("", L8_GETEVENT))
        assertNull(
            WheelVoiceKeyParser.resolve(
                "/system/usr/keylayout/Generic.kl:key 999 SOME_OTHER_KEY",
                L8_GETEVENT,
            ),
        )
    }

    @Test
    fun `resolves label even when its device node is unmapped`() {
        // Generic.kl has no device named "Generic" in getevent, so the node
        // is null — but the key still resolves (a11y path doesn't need a node).
        val onlyGeneric = "/system/usr/keylayout/Generic.kl:key 582 VOICE_ASSIST"
        val key = WheelVoiceKeyParser.resolve(onlyGeneric, L8_GETEVENT)
        assertNotNull(key)
        assertEquals("VOICE_ASSIST", key.label)
        assertEquals(582, key.scanCode)
        assertNull(key.deviceNode)
    }
}
