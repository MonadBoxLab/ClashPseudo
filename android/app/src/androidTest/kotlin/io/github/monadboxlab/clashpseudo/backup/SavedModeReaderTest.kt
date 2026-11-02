package io.github.monadboxlab.clashpseudo.backup

import java.io.IOException
import java.io.Reader
import java.io.StringReader
import org.junit.Assert.*
import org.junit.Test

/** Saved-mode observation uses the SDK reader, not a second business decoder. */
class SavedModeReaderTest {
    private val modes = setOf("rule", "global", "direct")

    @Test fun modesNullEscapesAndUnknownFieldsUseActualSdkValues() {
        for (mode in modes) assertEquals(mode, savedMode(StringReader("{\"mode\":\"$mode\"}"), modes))
        assertNull(savedMode(StringReader("{\"mode\":null,\"other\":[false,0,{},[]]}"), modes))
        assertEquals("rule", savedMode(StringReader("{\"\\u006dode\":\"r\\u0075le\"}"), modes))
        assertEquals("direct", savedMode(StringReader("{\"unknown\":\"\\uD800\",\"mode\":\"direct\"}"), modes))
        assertEquals("global", savedMode(StringReader("{\"unknown\":{\"mode\":42},\"mode\":\"global\"}"), modes))
    }

    @Test fun onlyTheRequestedModeFieldIsValidatedAndTheWholeDocumentIsRead() {
        val unknown = "x".repeat(1024 * 1024)
        assertEquals("direct", savedMode(StringReader("{\"$unknown\":\"$unknown\",\"mode\":\"direct\"}"), modes))
        assertEquals("global", savedMode(StringReader("{\"mode\":\"global\",\"unknown\":" + "[".repeat(40) + "0" + "]".repeat(40) + "}"), modes))
        for (source in listOf("{}", "{\"mode\":false}", "{\"mode\":0}", "{\"mode\":[]}",
            "{\"mode\":\"other\"}", "{\"mode\":\"rule\",\"\\u006dode\":null}",
            "{\"mode\":\"rule\"} []", "{\"mode\" \"rule\"}", "{\"mode\":\"rule\",}",
            "{\"other\":tru\"e\",\"mode\":\"rule\"}", "{\"mode\":\"rule\",\"x\":\"\\u12g4\"}")) {
            backupRejects<Exception> { savedMode(StringReader(source), modes) }
        }
    }

    @Test fun singleCharacterReadsAndActualSourceFailureBothCloseTheReader() {
        for (failure in listOf(false, true)) {
            val original = IOException("saved-mode source failure: 原始原因")
            var closed = false
            val text = "{\"mode\":\"r\\u0075le\",\"other\":[null,true,1e+2]}"
            val source = object : Reader() {
                var index = 0
                override fun read(target: CharArray, offset: Int, length: Int): Int {
                    if (failure && index == 8) throw original
                    if (length == 0) return 0
                    if (index == text.length) return -1
                    target[offset] = text[index++]
                    return 1
                }
                override fun close() { closed = true }
            }
            if (failure) {
                try { savedMode(source, modes); fail("Expected source failure") }
                catch (error: IOException) { assertSame(original, error) }
            } else assertEquals("rule", savedMode(source, modes))
            assertTrue(closed)
        }
    }
}
