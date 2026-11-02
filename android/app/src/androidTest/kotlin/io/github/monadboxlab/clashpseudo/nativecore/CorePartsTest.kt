package io.github.monadboxlab.clashpseudo.nativecore

import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream

class CorePartsTest {
    private fun encoded(block: (ByteArrayOutputStream) -> Unit): ByteArrayInputStream =
        ByteArrayOutputStream().apply(block).toByteArray().let(::ByteArrayInputStream)
    private fun metadata(output: ByteArrayOutputStream, part: String, bytes: Long) = CoreFrames.write(output,
        CoreFrames.Frame(Contract.CORE_IPC_FRAME_METADATA, JSONObject().put("part", part).put("bytes", bytes).toString().toByteArray()))
    private fun terminal(output: ByteArrayOutputStream, complete: Boolean = true) = CoreFrames.write(output,
        CoreFrames.Frame(Contract.CORE_IPC_FRAME_TERMINAL, JSONObject().put("complete", complete).toString().toByteArray()))
    private fun rejected(block: () -> Unit) {
        try { block(); fail("无效 FD parts 必须拒绝") } catch (_: CoreTransportException) { }
    }

    @Test fun rawPartsRoundTripWithoutBase64OrDefaultReencoding() {
        val parts = linkedMapOf(Contract.CORE_PART_REQUEST to "{}".toByteArray(),
            Contract.CORE_PART_CONFIG to "# 原始 YAML\nport: 0\n".toByteArray(),
            Contract.CORE_PART_OVERRIDES to "[]".toByteArray(), Contract.CORE_PART_OPTIONS to "{}".toByteArray())
        val input = encoded { CoreParts.write(it, parts) }
        val read = CoreParts.read(input)
        assertEquals(parts.keys, read.keys)
        parts.forEach { (name, bytes) -> assertArrayEquals(bytes, read[name]) }
    }

    @Test fun aCollectionMaySpanMoreThanOneMaximumSizedFrame() {
        val config = ByteArray(Contract.CORE_IPC_FRAME_BYTES + 1) { 'a'.code.toByte() }
        val parts = mapOf(Contract.CORE_PART_REQUEST to "{}".toByteArray(), Contract.CORE_PART_CONFIG to config)
        assertArrayEquals(config, CoreParts.read(encoded { CoreParts.write(it, parts) })[Contract.CORE_PART_CONFIG])
    }

    @Test fun duplicateNegativeOversizedAndUnknownPartsAreRejected() {
        rejected { CoreParts.read(encoded { metadata(it, "request", 0); metadata(it, "request", 0); terminal(it) }) }
        rejected { CoreParts.read(encoded { metadata(it, "config", -1); terminal(it) }) }
        rejected { CoreParts.read(encoded { metadata(it, "config", Contract.CONFIGURATION_TEXT_BYTES.toLong() + 1); terminal(it) }) }
        rejected { CoreParts.read(encoded { metadata(it, "unknown", 0); terminal(it) }) }
        rejected { CoreParts.read(encoded { metadata(it, "request", Contract.CORE_IPC_CONTROL_BYTES.toLong() + 1); terminal(it) }) }
    }

    @Test fun dataWithoutPartTruncatedPartAndIncompleteTerminalAreRejected() {
        rejected { CoreParts.read(encoded { CoreFrames.write(it, CoreFrames.Frame(Contract.CORE_IPC_FRAME_DATA, byteArrayOf(1))); terminal(it) }) }
        rejected { CoreParts.read(encoded { metadata(it, "request", 1); terminal(it) }) }
        rejected { CoreParts.read(encoded { metadata(it, "request", 0); terminal(it, false) }) }
    }

    @Test fun strictUtf8IsCheckedAfterAllDataFramesForOnePart() {
        val bytes = "字".toByteArray()
        val read = CoreParts.read(encoded {
            metadata(it, "request", bytes.size.toLong())
            CoreFrames.write(it, CoreFrames.Frame(Contract.CORE_IPC_FRAME_DATA, bytes.copyOfRange(0, 1)))
            CoreFrames.write(it, CoreFrames.Frame(Contract.CORE_IPC_FRAME_DATA, bytes.copyOfRange(1, 3)))
            terminal(it)
        })
        assertArrayEquals(bytes, read["request"])
        rejected { CoreParts.read(encoded {
            metadata(it, "request", 1)
            CoreFrames.write(it, CoreFrames.Frame(Contract.CORE_IPC_FRAME_DATA, byteArrayOf(0x80.toByte())))
            terminal(it)
        }) }
    }
}
