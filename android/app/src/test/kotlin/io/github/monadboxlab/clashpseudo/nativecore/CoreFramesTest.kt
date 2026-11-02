package io.github.monadboxlab.clashpseudo.nativecore

import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream

class CoreFramesTest {
    @Test fun sharedVectorsHaveTheExactBigEndianLengthAndKind() {
        listOf(
            CoreFrames.Frame(Contract.CORE_IPC_FRAME_DATA, byteArrayOf(65)) to byteArrayOf(0, 0, 0, 1, 1, 65),
            CoreFrames.Frame(Contract.CORE_IPC_FRAME_DATA, byteArrayOf()) to byteArrayOf(0, 0, 0, 0, 1),
            CoreFrames.Frame(Contract.CORE_IPC_FRAME_TERMINAL, "{}".toByteArray()) to byteArrayOf(0, 0, 0, 2, 3, 123, 125),
        ).forEach { (frame, vector) ->
            val output = ByteArrayOutputStream()
            CoreFrames.write(output, frame)
            assertArrayEquals(vector, output.toByteArray())
            val decoded = CoreFrames.Reader(ByteArrayInputStream(vector)).read()
            assertEquals(frame.kind, decoded.kind)
            assertArrayEquals(frame.payload, decoded.payload)
        }
    }

    @Test fun exactFrameLimitIsAcceptedAndLimitPlusOneIsRejectedBeforeReadingPayload() {
        val output = ByteArrayOutputStream()
        CoreFrames.write(output, CoreFrames.Frame(Contract.CORE_IPC_FRAME_DATA, ByteArray(Contract.CORE_IPC_FRAME_BYTES)))
        assertEquals(Contract.CORE_IPC_FRAME_BYTES,
            CoreFrames.Reader(ByteArrayInputStream(output.toByteArray())).read().payload.size)
        assertThrows(CoreTransportException::class.java) {
            CoreFrames.write(ByteArrayOutputStream(), CoreFrames.Frame(Contract.CORE_IPC_FRAME_DATA,
                ByteArray(Contract.CORE_IPC_FRAME_BYTES + 1)))
        }
        assertThrows(CoreTransportException::class.java) {
            CoreFrames.Reader(ByteArrayInputStream(byteArrayOf(0, -128, 0, 1, 1))).read()
        }
    }

    @Test fun truncatedHeaderPayloadUnknownKindAndMissingTerminalRemainTransportFailures() {
        listOf(byteArrayOf(), byteArrayOf(0), byteArrayOf(0, 0, 0, 0),
            byteArrayOf(0, 0, 0, 2, 1, 65), byteArrayOf(0, 0, 0, 0, 9)).forEach { bytes ->
            val failure = assertThrows(CoreTransportException::class.java) {
                CoreFrames.Reader(ByteArrayInputStream(bytes)).read()
            }
            assertEquals(Contract.CORE_ERROR_TRANSPORT_INTERRUPTED, failure.code)
        }
        val reader = CoreFrames.Reader(ByteArrayInputStream(byteArrayOf(0, 0, 0, 1, 1, 65)))
        reader.read()
        assertEquals(Contract.CORE_ERROR_TRANSPORT_INTERRUPTED,
            assertThrows(CoreTransportException::class.java) { reader.read() }.code)
    }

    @Test fun strictUtf8RejectsMalformedRecordButDataMaySplitOneCodePointAcrossFrames() {
        val invalid = byteArrayOf(0, 0, 0, 1, 2, -1)
        assertEquals(Contract.CORE_ERROR_INVALID_ENCODING,
            assertThrows(CoreTransportException::class.java) {
                CoreFrames.Reader(ByteArrayInputStream(invalid)).read()
            }.code)
        val data = CoreFrames.Reader(ByteArrayInputStream(byteArrayOf(0, 0, 0, 1, 1, -28))).read()
        assertArrayEquals(byteArrayOf(-28), data.payload)
    }
}
