package com.i99dev.ilink.nav.logic

/**
 * The Waze maneuver-arrow registry — the reference's `qm1`, decompiled verbatim:
 * 32 perceptual-hash signatures (225-bit `mi0`, MSB-first) → maneuver code.
 * Round-trip-verified against the original bit-strings.
 *
 * The per-entry code is `qm1.a(name)` precomputed (longest-substring match), so
 * there's no runtime ambiguity. Classify a captured Waze arrow with [classify]:
 * nearest entry within Hamming 18, else null (caller defaults to straight=11).
 */
object WazeArrowRegistry {

    /** Bias the reference passes to `ym0.b` for Waze arrows. */
    const val BIAS = 0.8f
    const val INVERT = true

    data class Entry(val hash: Mi0, val code: Int, val name: String)

    /** ARGB arrow pixels → maneuver code (TURN_ICON_*), or null if no match. */
    fun classify(argb: IntArray, w: Int, h: Int): Int? {
        val sig = PerceptualHash.buildHash(argb, w, h, BIAS, INVERT) ?: return null
        var best: Entry? = null
        var bestD = Int.MAX_VALUE
        for (e in ENTRIES) {
            val d = PerceptualHash.hamming(sig, e.hash)
            if (d == 0) return e.code
            if (d <= PerceptualHash.HAMMING_ACCEPT && d < bestD) { best = e; bestD = d }
        }
        return best?.code
    }

    private fun e(code: Int, name: String, vararg w: Long) = Entry(Mi0.fromWords(w), code, name)

    private val ENTRIES: List<Entry> = listOf(
        e(25, "directions_roundabout", 4096L, -4611686018427385856L, 1157495679139971072L, 0L),
        e(15, "directions_roundabout_l", 0L, 4035462808286793776L, 6917951265876475920L, 0L),
        e(35, "directions_roundabout_lhs", 1024L, 432345564228091920L, 4573974814392320L, 0L),
        e(17, "directions_roundabout_l_lhs", 0L, 4035462773956943372L, 1732760008170930192L, 0L),
        e(18, "directions_roundabout_r", 0L, 100670976L, 7494412018179899408L, 0L),
        e(16, "directions_roundabout_r_lhs", 0L, 51543539756L, 3377751260659728L, 0L),
        e(20, "directions_roundabout_s", 2199258143744L, 1729408645591994368L, 6917951265876475920L, 0L),
        e(19, "directions_roundabout_s_lhs", 2199258143744L, 3458975632938237964L, 3377751260659728L, 0L),
        e(22, "directions_roundabout_u", 0L, 4035462773923385352L, 6922173502210441664L, 72057594037927936L),
        e(21, "directions_roundabout_u_lhs", 0L, 4035462773923385356L, 2308165179919269895L, 1125899906842624L),
        e(48, "direction_end", 17043042657154L, -4141584271161687028L, 6933538189675987000L, 9007199254740992L),
        e(3, "direction_exit_left", 402681856L, -2305807824304709632L, 4611826760210841600L, 0L),
        e(5, "direction_exit_right", 58722048L, 1008863494357057540L, 2251868535259136L, 0L),
        e(5, "direction_exit_right2", 896L, 1080896896924434433L, 562967133814800L, 0L),
        e(11, "direction_forward", 67116032L, 4035260451569827841L, 562967133814800L, 0L),
        e(1, "direction_left", 536920065L, -576152888913424384L, 3458870070158131200L, 0L),
        e(2, "direction_right", 8389504L, 4539843937258700824L, 13511211211554816L, 0L),
        e(45, "direction_stop", 14843952267394L, 4072653784161182723L, -9214329440623001544L, 9007199254740992L),
        e(9, "direction_u_turn", 234890752L, -8790740590879567864L, 2310417460781711360L, 0L),
        e(10, "direction_u_turn_lhs", 234893824L, -4467284948603891704L, 2310417122544812032L, 0L),
        e(25, "car_directions_roundabout", 14336L, -4611686018427385856L, 1157495679139971072L, 0L),
        e(35, "car_directions_roundabout_lhs", 3584L, 432345564228091920L, 4573974814392320L, 0L),
        e(17, "car_directions_roundabout_r_uk", 0L, 4035462774024052236L, 1732760008170930192L, 0L),
        e(21, "car_directions_roundabout_u_lhs", 0L, 4035462773923516428L, 2308165179919532039L, 1125899906842624L),
        e(48, "car_direction_end", 6598026131202L, -7131949135403737042L, -5162021940122238973L, 0L),
        e(45, "car_direction_stop", 503333121L, 73183528339905568L, 594475426768814136L, 0L),
        e(25, "car_dark_directions_roundabout", 6144L, -4611686018427385856L, 1157495685582422016L, 0L),
        e(35, "car_dark_directions_roundabout_uk", 3072L, 432345564228091920L, 4609296625434624L, 0L),
        e(21, "car_dark_directions_roundabout_u_uk", 0L, 4035462773923385356L, 2308165179919532047L, 3377699720527872L),
        e(48, "car_dark_direction_end", 234909953L, -216146341253342146L, 7917028111548472L, 0L),
        e(45, "car_dark_direction_stop", 234897665L, 72057628433194016L, 576461028259332152L, 0L),
        e(10, "car_dark_direction_u_turn_uk", 503342592L, -8790740590879567864L, 2310557868623069184L, 0L),
    )

    /** Exposed for tests: the embedded entries. */
    val entries: List<Entry> get() = ENTRIES
}
