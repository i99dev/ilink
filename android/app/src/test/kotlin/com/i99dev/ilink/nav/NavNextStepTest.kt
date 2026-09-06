package com.i99dev.ilink.nav

import com.i99dev.ilink.nav.logic.NavTextParse
import org.junit.Assert.assertEquals
import org.junit.Test

/** Host-JVM coverage for the Google Maps next-step → secondary-road cleaner (P5). */
class NavNextStepTest {

    @Test
    fun stripsLeadingManeuverPhrase() {
        assertEquals("Elm St", NavTextParse.cleanNextStep("then turn right onto Elm St"))
        assertEquals("King Fahd Rd", NavTextParse.cleanNextStep("Then merge onto King Fahd Rd"))
        assertEquals("Ring Road", NavTextParse.cleanNextStep("take the exit onto Ring Road"))
        assertEquals("A1", NavTextParse.cleanNextStep("then keep left onto A1"))
    }

    @Test
    fun ontoVariantBeatsBareVariant() {
        // "then turn right onto" must win over "then turn right" (order matters).
        assertEquals("Main St", NavTextParse.cleanNextStep("then turn right onto Main St"))
        // bare form (no road) → empty
        assertEquals("", NavTextParse.cleanNextStep("then turn right"))
    }

    @Test
    fun noPrefixReturnsTrimmedInput() {
        assertEquals("Damascus Rd", NavTextParse.cleanNextStep("  Damascus Rd  "))
        assertEquals("", NavTextParse.cleanNextStep(null))
        assertEquals("", NavTextParse.cleanNextStep("   "))
    }
}
