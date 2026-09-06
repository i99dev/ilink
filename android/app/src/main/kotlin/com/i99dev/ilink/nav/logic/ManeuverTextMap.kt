package com.i99dev.ilink.nav.logic

import java.util.Locale

/**
 * Maps a maneuver *text* (Yandex maneuver-balloon / notification string) to a
 * TURN_ICON code 1..49. Faithful to the reference's
 * `YandexManager.getTurnIconFromManeuverText`: lowercase+trim → EQUALS extras →
 * a first-substring-wins ladder → default `1`; blank → `11`.
 *
 * Production fix (deviation from the reference, intentional): the numeric-exit groups
 * are checked **10→1** so `"exit 10"` no longer matches the `"exit 1"` substring
 * (the reference's 1→10 order mis-classified exits 10..19 as exit 1). Everything else
 * is verbatim. Pure + host-testable.
 */
object ManeuverTextMap {

    private const val BLANK = 11

    // Unknown maneuver → STRAIGHT, never a confident wrong turn. (the reference used 1 =
    // LEFT here, which made every text we couldn't classify render as a left
    // arrow — the "always left" bug. Real "left" is matched explicitly in the
    // ladder below; only genuinely-unrecognised text falls through to straight.)
    private const val DEFAULT = 11

    /** EQUALS-only extras the contains-ladder doesn't cover (Cyrillic / translit /
     *  notification_*_sdl). Checked before the ladder (exact match). */
    private val EQUALS: Map<String, Int> = buildMap {
        listOf("направо", "поверните направо", "поверните направо 2-й поворот", "pravo", "pravyj", "notification_right_sdl").forEach { put(it, 2) }
        listOf("левее", "поверните левее", "сверните налево", "polu_levo", "polulevo", "vetvlenie_levo", "notification_exit_left_sdl", "notification_fork_left_sdl", "notification_slight_left_sdl").forEach { put(it, 3) }
        listOf("правее", "поверните правее", "сверните направо", "polu_pravo", "polupravo", "vetvlenie_pravo", "notification_exit_right_sdl", "notification_fork_right_sdl", "notification_slight_right_sdl").forEach { put(it, 5) }
        listOf("круто налево", "круто поверните налево", "kruto_levo", "kruto_levyj", "notification_hard_left_sdl").forEach { put(it, 7) }
        listOf("круто направо", "круто поверните направо", "kruto_pravo", "kruto_pravyj", "notification_hard_right_sdl").forEach { put(it, 8) }
        listOf("u-turn left", "uturn_left", "make a u-turn", "turn_back_left", "разворот", "разворот налево", "razvorot", "notification_uturn_left_sdl").forEach { put(it, 9) }
        listOf("u-turn right", "uturn_right", "разворот направо", "turn_back_right", "notification_uturn_right_sdl").forEach { put(it, 10) }
        listOf("выезд с кольца", "кольцевое движение", "кольцо", "круг", "kolco", "krug", "notification_enter_roundabout_sdl", "notification_leave_roundabout_sdl").forEach { put(it, 20) }
    }

    /** First group whose any pattern is a substring of the text wins. Order matters. */
    private val LADDER: List<Pair<List<String>, Int>> = buildList {
        add(listOf("finish", "done", "completed") to 48)
        // exits 10→1 (reversed vs the reference: longest numeric first, fixes prefix bug)
        add(listOf("10-й", "10th", "exit 10", "tenth exit", "съезд 10") to 34)
        add(listOf("9-й", "9th", "exit 9", "ninth exit", "съезд 9") to 33)
        add(listOf("8-й", "8th", "exit 8", "eighth exit", "съезд 8") to 32)
        add(listOf("7-й", "7th", "exit 7", "seventh exit", "съезд 7") to 31)
        add(listOf("6-й", "6th", "exit 6", "sixth exit", "съезд 6") to 30)
        add(listOf("5-й", "5th", "exit 5", "fifth exit", "съезд 5") to 29)
        add(listOf("4-й", "4th", "exit 4", "fourth exit", "съезд 4") to 28)
        add(listOf("3-й", "3rd", "exit 3", "third exit", "съезд 3") to 27)
        add(listOf("2-й", "2nd", "exit 2", "second exit", "съезд 2") to 26)
        add(listOf("1-й", "1st", "exit 1", "first exit", "съезд 1") to 25)
        add(listOf("roundabout", "circular") to 20)
        add(listOf("slight_left", "slight left", "veer left", "keep_left", "keep left", "fork_left", "exit_left", "take_left", "exit to the left", "exit to left", "exit left", "exit to the lef", "exit to lef") to 3)
        add(listOf("slight_right", "slight right", "veer right", "keep_right", "keep right", "fork_right", "exit_right", "take_right", "exit to the right", "exit to right", "exit right", "exit to the righ", "exit to righ") to 5)
        add(listOf("hard_left", "hard_turn_left", "sharp_left", "sharp left") to 7)
        add(listOf("hard_right", "hard_turn_right", "sharp_right", "sharp right") to 8)
        // directional u-turn FIRST (so "u-turn right" isn't swallowed by the generic
        // "u-turn" below). Right-biased → 10, everything else → 9.
        add(listOf("u-turn right", "uturn_right", "u_turn_right", "turn_back_right", "разворот направо") to 10)
        add(listOf("uturn", "u-turn", "u_turn", "u turn", "turn_back", "turn back") to 9)
        // explicit directional turns BEFORE the special-maneuver words below, so an
        // instruction like "turn right toward the toll" classifies as the TURN, not the
        // toll/destination. (Bare "maneuver_*_left/right" icon names have no contiguous
        // "turn left/right" substring, so they still reach the specials / generic below.)
        add(listOf("turn left", "turn_left") to 1)
        add(listOf("turn right", "turn_right") to 2)
        // special maneuvers — arrive as large-icon / custom-layout drawable NAMES, or as
        // keywords in the instruction. Kept AFTER the directional turns so they can't
        // hijack a real turn that merely mentions them.
        add(listOf("toll", "tollbooth", "tolbooth") to 47)
        add(listOf("tunnel") to 49)
        add(listOf("destination_left", "destination_right", "destination") to 45)
        add(listOf("depart") to 12)
        // generic turns — explicit now (so unrecognised text can default to
        // STRAIGHT instead of masquerading as a left turn).
        add(listOf("right", "направо", "вправо", "يمين", "اليمين") to 2)
        add(listOf("left", "налево", "влево", "يسار", "اليسار") to 1)
        // "straight"/"forward"/"continue"/"ferry"/"waypoint"/unknown → DEFAULT (11)
    }

    fun classify(text: String?): Int {
        val t = text?.trim()?.lowercase(Locale.ROOT) ?: return BLANK
        if (t.isEmpty()) return BLANK
        EQUALS[t]?.let { return it }
        for ((patterns, code) in LADDER) {
            if (patterns.any { t.contains(it) }) return code
        }
        return DEFAULT
    }
}
