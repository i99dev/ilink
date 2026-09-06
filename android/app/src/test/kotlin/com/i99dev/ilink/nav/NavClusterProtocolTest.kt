package com.i99dev.ilink.nav

import com.i99dev.ilink.nav.transport.ClusterProtocol
import com.i99dev.ilink.nav.transport.ClusterProtocol.Ui
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The cluster-HUD protocol partition: 7.0UI cars (Leopard 7) must classify as
 * UI_7_0 (→ HudNaviInfoTransport) and Di5.0/5.1 cars as UI_5_0 (→ the legacy
 * RoadInfo SomeIpHudTransport). A misclassification cross-wires a car onto the
 * wrong cluster protocol, so this is fenced.
 */
class NavClusterProtocolTest {

    @Test
    fun `L7 Ti7 DiLink100 7_0UI - and the DiLink150 variant - classify as 7_0UI`() {
        assertEquals(Ui.UI_7_0, ClusterProtocol.classify("DiLink100_7.0UI"))
        assertEquals(Ui.UI_7_0, ClusterProtocol.classify("DiLink150_7.0UI"))
    }

    @Test
    fun `Di5_1 L8 - L5 - and Di5_0 classify as 5_0UI`() {
        assertEquals(Ui.UI_5_0, ClusterProtocol.classify("Di5.1_5.0UI"))
        assertEquals(Ui.UI_5_0, ClusterProtocol.classify("Di5.0_5.0UI"))
        assertEquals(Ui.UI_5_0, ClusterProtocol.classify("DiLink150_5.0UI"))
    }

    @Test
    fun `blank or unprofiled trim is UNKNOWN - treated 5_0UI-compatible by transports`() {
        assertEquals(Ui.UNKNOWN, ClusterProtocol.classify(null))
        assertEquals(Ui.UNKNOWN, ClusterProtocol.classify(""))
        assertEquals(Ui.UNKNOWN, ClusterProtocol.classify("SomethingElse_9.0UI"))
    }

    @Test
    fun `classification is case-insensitive`() {
        assertEquals(Ui.UI_7_0, ClusterProtocol.classify("dilink100_7.0ui"))
        assertEquals(Ui.UI_5_0, ClusterProtocol.classify("di5.1_5.0ui"))
    }
}
