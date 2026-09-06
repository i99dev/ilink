package com.i99dev.ilink.security

import java.io.ByteArrayInputStream
import org.junit.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertFailsWith

class LocalTableLoaderTest {
    @Test fun readsLocalBytesWithoutContextOrNetwork() {
        val bytes = "version: \"local\"".toByteArray()
        assertContentEquals(bytes, LocalTableLoader.readBounded(ByteArrayInputStream(bytes)))
    }

    @Test fun rejectsOversizedAssetBeforeParsing() {
        assertFailsWith<IllegalArgumentException> {
            LocalTableLoader.readBounded(ByteArrayInputStream(ByteArray(2 * 1024 * 1024 + 1)))
        }
    }
}
