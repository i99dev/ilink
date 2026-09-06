package com.i99dev.ilink.voice

/**
 * The steering-wheel voice/assistant button **as the ROM declares it** —
 * resolved dynamically from `/system/usr/keylayout`, never hardcoded.
 *
 * On a BYD DiLink unit the wheel button is a CAN-bus event the MCU injects
 * through a virtual input device (`simulate-keys` on Leopard 8) and the ROM
 * names it `AUTO_MEDIA_VOICE` (scancode 290 on that trim). Other trims may
 * use a different scancode/device, or the AOSP `VOICE_ASSIST` / `ASSIST`
 * labels — so we discover whatever *this* car declares rather than baking a
 * number in. See [WheelVoiceKeyParser] for the parse and
 * [WheelVoiceKeyResolver] for the on-device read.
 *
 * @property label     the keylayout label, one of [WheelVoiceKeyParser.LABEL_PRIORITY].
 * @property scanCode  the raw input scancode (matched against `KeyEvent.scanCode`).
 * @property deviceNode `/dev/input/eventN` the key originates from, or null
 *                      when the keylayout's owning device couldn't be mapped
 *                      (e.g. a `Generic.kl` fallback with no named device).
 * @property keyLayout  the keylayout basename without `.kl` (e.g. `simulate-keys`).
 */
data class WheelVoiceKey(
    val label: String,
    val scanCode: Int,
    val deviceNode: String?,
    val keyLayout: String,
)

/**
 * Pure parser for the two on-device reads that resolve [WheelVoiceKey]:
 *   1. grepping the `.kl` files in `/system/usr/keylayout` — scancode + label.
 *   2. `getevent -lp` — maps a keylayout's owning device to its `/dev` node.
 *
 * No Android, no ADB — every input is a captured shell body, so the whole
 * resolution is unit-testable (see `WheelVoiceKeyParserTest`). The shelling
 * lives in [WheelVoiceKeyResolver]; this object only transforms strings.
 */
object WheelVoiceKeyParser {

    /**
     * Accepted keylayout labels, **most-specific first**. `AUTO_MEDIA_VOICE`
     * is the BYD DiLink wheel-voice label; `VOICE_ASSIST` / `ASSIST` are the
     * AOSP fallbacks a non-BYD trim might use. The long-press variant
     * (`AUTO_MEDIA_VOICE_LP`) is deliberately absent — it's a distinct
     * gesture we don't claim in v1, and excluding it from the set means
     * [parseCandidates] skips it for free.
     */
    val LABEL_PRIORITY: List<String> = listOf("AUTO_MEDIA_VOICE", "VOICE_ASSIST", "ASSIST")

    private val ACCEPTED: Set<String> = LABEL_PRIORITY.toSet()

    /** One `key <scancode> <LABEL>` declaration found in a keylayout. */
    data class Candidate(val label: String, val scanCode: Int, val keyLayout: String)

    /**
     * Parse the grep output over the `/system/usr/keylayout` `.kl` files into
     * the set of voice-key candidates. Lines look like:
     * ```
     * /system/usr/keylayout/simulate-keys.kl:key 290   AUTO_MEDIA_VOICE
     * /system/usr/keylayout/Vendor_18d1_Product_0200.kl:key 0x246 VOICE_ASSIST
     * /system/usr/keylayout/Vendor_0957_Product_0001.kl:key 217   ASSIST   WAKE
     * ```
     * Comment lines (`# …`), non-`key` directives, unparseable scancodes, and
     * labels outside [ACCEPTED] are skipped. Trailing flags (e.g. `WAKE`) are
     * ignored — the label is the token immediately after the scancode.
     */
    fun parseCandidates(grepOut: String): List<Candidate> {
        val out = ArrayList<Candidate>()
        for (raw in grepOut.lineSequence()) {
            val line = raw.trim()
            if (line.isEmpty()) continue
            // Split off the `grep -H` filename prefix at the FIRST colon; the
            // remainder is the keylayout directive (which has no colons).
            val colon = line.indexOf(':')
            if (colon <= 0) continue
            val path = line.substring(0, colon)
            val directive = line.substring(colon + 1).trim()
            if (directive.isEmpty() || directive.startsWith("#")) continue
            val tokens = directive.split(Regex("\\s+"))
            if (tokens.size < 3 || tokens[0] != "key") continue
            val scan = parseScanCode(tokens[1]) ?: continue
            val label = tokens[2]
            if (label !in ACCEPTED) continue
            out.add(Candidate(label, scan, keyLayoutBasename(path)))
        }
        return out
    }

    /**
     * Parse `getevent -lp` output into a `device-name -> /dev/input/eventN`
     * map. The shape is:
     * ```
     * add device 9: /dev/input/event0
     *   name:     "simulate-keys"
     * ```
     * A device's `name:` line follows its `add device` line, so we carry the
     * pending node forward until the name arrives.
     */
    fun parseDeviceNodes(geteventOut: String): Map<String, String> {
        val map = LinkedHashMap<String, String>()
        var pendingNode: String? = null
        for (raw in geteventOut.lineSequence()) {
            val line = raw.trim()
            val addIdx = line.indexOf("/dev/input/")
            if (line.startsWith("add device") && addIdx >= 0) {
                pendingNode = line.substring(addIdx).trim()
                continue
            }
            if (line.startsWith("name:")) {
                val name = line.substringAfter("name:").trim().trim('"')
                val node = pendingNode
                if (name.isNotEmpty() && node != null) map[name] = node
                pendingNode = null
            }
        }
        return map
    }

    /**
     * Resolve the wheel-voice key from the two captured shell bodies, or null
     * when no accepted label is declared on this car. Selection:
     *   1. take the highest-priority label that appears at all;
     *   2. among its candidates, prefer one whose keylayout maps to a present
     *      input device (so the resolved [WheelVoiceKey.deviceNode] is real),
     *      falling back to the first candidate when none map.
     */
    fun resolve(grepOut: String, geteventOut: String): WheelVoiceKey? {
        val candidates = parseCandidates(grepOut)
        if (candidates.isEmpty()) return null
        val nodes = parseDeviceNodes(geteventOut)
        for (label in LABEL_PRIORITY) {
            val matching = candidates.filter { it.label == label }
            if (matching.isEmpty()) continue
            val chosen = matching.firstOrNull { nodes[it.keyLayout] != null } ?: matching.first()
            return WheelVoiceKey(
                label = chosen.label,
                scanCode = chosen.scanCode,
                deviceNode = nodes[chosen.keyLayout],
                keyLayout = chosen.keyLayout,
            )
        }
        return null
    }

    /** `/system/usr/keylayout/simulate-keys.kl` -> `simulate-keys`. */
    private fun keyLayoutBasename(path: String): String =
        path.substringAfterLast('/').removeSuffix(".kl")

    /** Decimal or `0x`-hex scancode; null on anything else (avoids octal
     *  surprises from a leading zero — keylayout codes are decimal or hex). */
    private fun parseScanCode(token: String): Int? = when {
        token.startsWith("0x") || token.startsWith("0X") ->
            token.substring(2).toIntOrNull(16)
        else -> token.toIntOrNull()
    }
}
