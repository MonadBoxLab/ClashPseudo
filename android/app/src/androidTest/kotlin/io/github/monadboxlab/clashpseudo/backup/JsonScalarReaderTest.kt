package io.github.monadboxlab.clashpseudo.backup

import android.util.JsonReader
import android.util.JsonToken
import java.io.IOException
import java.io.Reader
import java.io.StringReader
import java.util.concurrent.CancellationException
import org.junit.Assert.*
import org.junit.Test

/**
 * Tests SDK token and inspection behavior. Separate low-heap tests use fixed AOSP
 * API24 classes.
 */
class JsonScalarReaderTest {
    internal class Repeated(val prefix: String, val pattern: String, val repeats: Long, val suffix: String,
        private val chunk: Int = Int.MAX_VALUE) : Reader() {
        var delivered = 0L
        var closed = false
        private val middle = pattern.length * repeats
        private val total = prefix.length + middle + suffix.length
        override fun read(target: CharArray, offset: Int, length: Int): Int {
            if (length == 0) return 0
            if (delivered == total) return -1
            val count = minOf(length.toLong(), chunk.toLong(), total - delivered).toInt()
            repeat(count) { index ->
                val position = delivered + index
                target[offset + index] = when {
                    position < prefix.length -> prefix[position.toInt()]
                    position < prefix.length + middle -> pattern[((position - prefix.length) % pattern.length).toInt()]
                    else -> suffix[(position - prefix.length - middle).toInt()]
                }
            }
            delivered += count
            return count
        }
        override fun close() { closed = true }
    }
    private fun readString(json: String): String = JsonReader(ScalarReader(StringReader("[$json]"))).use {
        it.beginArray()
        val value = it.nextString()
        it.endArray()
        assertEquals(JsonToken.END_DOCUMENT, it.peek())
        value
    }
    private fun keys(json: String): List<String> = JsonReader(ScalarReader(StringReader(json))).use { reader ->
        val result = mutableListOf<String>()
        reader.beginObject()
        while (reader.hasNext()) { result += reader.nextName(); reader.skipValue() }
        reader.endObject()
        assertEquals(JsonToken.END_DOCUMENT, reader.peek())
        result
    }
    private val modes = setOf("rule", "global", "direct")

    @Test fun stringsCarryOriginalUtf8SizeIncludingBomAndValidSurrogatePairsWithoutTheirContent() {
        assertEquals(0L, ScalarReader.utf8Bytes(readString("\"\"")))
        assertEquals(3L, ScalarReader.utf8Bytes(readString("\"\\uFEFF\"")))
        assertEquals(7L, ScalarReader.utf8Bytes(readString("\"汉\\uD834\\uDD1E\"")))
        assertEquals(ScalarReader.marker("body"), readString("\"\\u0062ody\""))
        val secret = "never-retain-this-credential"
        val projected = readString("\"$secret\"")
        assertFalse(projected.contains(secret))
        assertTrue(projected.length < 128)
    }

    @Test fun utf8AndEscapedUtf16NamesHaveEqualIdentityButAreNotUnicodeNormalized() {
        val pair = "\uD834\uDD1E"
        val names = keys("{\"汉$pair\":null,\"\\u6C49\\uD834\\uDD1E\":null,\"é\":null,\"e\\u0301\":null}")
        assertEquals(names[0], names[1])
        assertNotEquals(names[2], names[3])
    }

    @Test fun unpairedSurrogatesRemainDistinctOutsideBodiesAndBodiesKeepTheirExistingRejection() {
        val names = keys("{\"\\uD800\":null,\"\\uD801\":null,\"\\uFFFD\":null}")
        assertNotEquals(names[0], names[1])
        assertNotEquals(names[0], names[2])
        backupRejects<IOException> { ScalarReader.utf8Bytes(readString("\"\\uD800\"")) }
        backupRejects<IOException> { ScalarReader.utf8Bytes(readString("\"\\uDC00\"")) }
        assertEquals("rule", savedMode(StringReader("{\"unknown\":\"\\uD800\",\"mode\":\"rule\"}"), modes))
    }

    @Test fun projectionCannotTurnInvalidEscapesOrRawControlsIntoValidSdkStrings() {
        for (source in listOf("\"\\x\"", "\"\\u+123\"", "\"\\u12g4\"", "\"\\u123\"",
            "\"\\u١٢٣٤\"", "\"raw\ncontrol\"", "\"unterminated\\")) {
            backupRejects<IOException> { readString(source) }
        }
        assertEquals(9L, ScalarReader.utf8Bytes(readString("\"\\\"\\\\\\/\\b\\f\\n\\r\\t\\u0000\"")))
    }

    @Test fun oneCharacterSourceChunksAndOffsetReadsPreserveTheInspectionGrammarAndClose() {
        val source = Repeated("{\"mode\":\"r", "\\u0075", 1, "le\",\"other\":[null,true,1e+2]}", chunk = 1)
        assertEquals("rule", savedMode(source, modes))
        assertTrue(source.closed)
        val projected = ScalarReader(StringReader("[\"body\",-1.25e+2]"))
        val text = StringBuilder()
        val buffer = CharArray(3)
        while (true) {
            val count = projected.read(buffer, 1, 1)
            if (count == -1) break
            assertEquals(1, count)
            text.append(buffer[1])
        }
        assertEquals("[\"${ScalarReader.marker("body")}\",-1.25e+2]", text.toString())
        assertEquals(-1, projected.read(buffer, 1, 1))
        assertEquals(0, projected.read(buffer, 1, 0))
        projected.close()
    }

    @Test fun numbersAreNotRewrittenAndTheSdkStillParsesTheirCompleteShortLiteral() {
        for (number in listOf("0", "-0", "-1.25e+2", "1E-9", "1" + "2".repeat(1022))) {
            JsonReader(ScalarReader(StringReader("[$number]"))).use { reader ->
                reader.beginArray()
                assertEquals(JsonToken.NUMBER, reader.peek())
                assertEquals(number, reader.nextString())
                reader.endArray()
                assertEquals(JsonToken.END_DOCUMENT, reader.peek())
            }
        }
        for (number in listOf("01", "+1", "1e", "1e+", "-", "1e--2")) {
            backupRejects<IOException> {
                JsonReader(ScalarReader(StringReader("[$number]"))).use { it.beginArray(); it.nextString() }
            }
        }
    }

    @Test fun hugeUnquotedLiteralIsRejectedAtTheSameSdkStrictBoundaryWithoutReadingItAll() {
        val source = Repeated("{\"other\":", "1", 128L * 1024 * 1024, ",\"mode\":\"rule\"}")
        backupRejects<IOException> { savedMode(source, modes) }
        assertTrue(source.closed)
        assertTrue("Only a fixed input buffer may be prefetched", source.delivered <= 8192)
    }

    @Test fun giantKeysAndSkippedValuesStayShortInTheInspectionAndSavedModeUsesTheSamePath() {
        val size = 4L * 1024 * 1024
        val hugeKey = Repeated("{\"", "k", size, "\":null,\"mode\":\"direct\"}")
        assertEquals("direct", savedMode(hugeKey, modes))
        assertTrue(hugeKey.closed)
        assertTrue(hugeKey.delivered > size)
        val hugeValue = Repeated("{\"other\":\"", "\\u0061", size, "\",\"mode\":\"global\"}")
        assertEquals("global", savedMode(hugeValue, modes))
        assertTrue(hugeValue.closed)
        assertTrue(hugeValue.delivered > size * 6)
        val string = Repeated("[\"", "x", size, "\"]")
        JsonReader(ScalarReader(string)).use { reader ->
            reader.beginArray()
            val projected = reader.nextString()
            assertTrue(projected.length < 128)
            assertEquals(size, ScalarReader.utf8Bytes(projected))
            reader.endArray()
        }
    }

    @Test fun nullModeDoesNotApplyItsSmallEnumLimitToTheFollowingUnknownKeyOrValue() {
        val source = Repeated("{\"mode\":null,\"long-unknown-key\":\"", "a", 1024L * 1024, "\"}")
        assertNull(savedMode(source, modes))
        assertTrue(source.closed)
        assertEquals("rule", savedMode(StringReader("{\"\\u006dode\":\"r\\u0075le\"}"), modes))
        backupRejects<Exception> { savedMode(StringReader("{\"mode\":\"rule\",\"\\u006dode\":null}"), modes) }
        val invalidMode = Repeated("{\"mode\":\"", "a", 128L * 1024 * 1024, "\"}")
        backupRejects<IOException> { savedMode(invalidMode, modes) }
        assertTrue(invalidMode.delivered <= 4096)
    }

    @Test fun savedModeObservationBoundsNestingWithoutAddingOrdinaryStoreSizeOrNodeWriteQuotas() {
        assertEquals("direct", savedMode(StringReader("{\"mode\":\"direct\",\"x\":" + "[".repeat(31) + "0" + "]".repeat(31) + "}"), modes))
        backupRejects<IOException> {
            savedMode(StringReader("{\"mode\":\"direct\",\"x\":" + "[".repeat(32) + "0" + "]".repeat(32) + "}"), modes)
        }
        for (source in listOf("{\"x\":tru\"e\"}", "{\"x\":1e+\"4\"}", "{\"x\":\"a\" \"mode\":\"rule\"}",
            "{\"mode\" \"rule\"}", "{\"mode\":\"rule\",}", "{\"mode\":\"rule\"} []")) {
            backupRejects<Exception> { savedMode(StringReader(source), modes) }
        }
    }

    @Test fun cancellationClosesTheActualReaderWithoutFinishingAGiantScalar() {
        val source = Repeated("[\"", "a", 128L * 1024 * 1024, "\"]")
        var checks = 0
        backupRejects<CancellationException> {
            JsonReader(ScalarReader(source, check = { if (++checks == 3) throw CancellationException("fixture") })).use {
                it.beginArray(); it.nextString()
            }
        }
        assertTrue(source.closed)
        assertTrue(source.delivered <= 8192)
    }

    @Test fun completeBackupAdmissionKeepsUnknownUnpairedStringsButRejectsDuplicateDecodedKeysAndInvalidBodies() = BackupFixture.use { f ->
        val values = BackupFixture.values().toMutableMap()
        values[BackupFiles.Kind.PREFERENCES] = "{\"unknown\":\"\\uD800\"}".toByteArray()
        val candidate = f.candidate(values)
        f.files.withPart(candidate.token, BackupFiles.Kind.PREFERENCES, BackupFiles.Operation(BackupLease())) {
            assertArrayEquals(values.getValue(BackupFiles.Kind.PREFERENCES), it.readBytes())
        }
        for (json in listOf("{\"entries\":[],\"x\":1,\"\\u0078\":2}", "{\"entries\":[{\"body\":\"\\uD800\"}]}")) {
            values[BackupFiles.Kind.CONFIGURATIONS] = json.toByteArray()
            backupRejects<IOException> { f.candidate(values) }
        }
    }
}
