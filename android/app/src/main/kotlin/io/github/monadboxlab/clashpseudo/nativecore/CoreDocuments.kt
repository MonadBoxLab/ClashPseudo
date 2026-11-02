package io.github.monadboxlab.clashpseudo.nativecore

import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream

/** 完整 JSON 文档复用 DATA＋TERMINAL；单 frame 预算不限制整个文档。 */
internal object CoreDocuments {
    fun write(output: OutputStream, bytes: ByteArray) {
        var offset = 0
        while (offset < bytes.size) {
            val end = minOf(offset + 256 * 1024, bytes.size)
            CoreFrames.write(output, CoreFrames.Frame(Contract.CORE_IPC_FRAME_DATA, bytes.copyOfRange(offset, end)))
            offset = end
        }
        CoreFrames.write(output, CoreFrames.Frame(Contract.CORE_IPC_FRAME_TERMINAL,
            JSONObject().put("complete", true).toString().toByteArray(Charsets.UTF_8)))
    }

    fun read(input: InputStream): ByteArray {
        val reader = CoreFrames.Reader(input)
        val output = ByteArrayOutputStream()
        while (true) {
            val frame = reader.read()
            when (frame.kind) {
                Contract.CORE_IPC_FRAME_DATA -> output.write(frame.payload)
                Contract.CORE_IPC_FRAME_TERMINAL -> {
                    val terminal = JSONObject(CoreFrames.utf8(frame.payload))
                    if (terminal.get("complete") != true) throw CoreTransportException(
                        Contract.CORE_ERROR_TRANSPORT_INTERRUPTED, terminal.toString())
                    return output.toByteArray()
                }
                else -> throw CoreTransportException(Contract.CORE_ERROR_TRANSPORT_INTERRUPTED, "JSON 文档包含非 DATA frame")
            }
        }
    }
}
