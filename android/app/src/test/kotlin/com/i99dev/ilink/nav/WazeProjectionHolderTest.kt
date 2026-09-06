package com.i99dev.ilink.nav

import com.i99dev.ilink.nav.ingest.WazeProjectionHolder
import org.junit.Assert.assertFalse
import org.junit.Test

/** Host coverage for the consent holder. setToken/acquire need Android Intent /
 *  Context / MediaProjection (on-car only); here we lock the no-consent invariant —
 *  no token ⇒ hasConsent false ⇒ the capture service self-stops, arrow → straight. */
class WazeProjectionHolderTest {

    @Test
    fun noConsentInitiallyAndAfterClear() {
        WazeProjectionHolder.clear()
        assertFalse(WazeProjectionHolder.hasConsent)
    }
}
