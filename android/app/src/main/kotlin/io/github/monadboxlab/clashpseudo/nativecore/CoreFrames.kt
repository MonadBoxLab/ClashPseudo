package io.github.monadboxlab.clashpseudo.nativecore

import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

class CoreTransportException(val code: String, message: String, cause: Throwable? = null) : IOException(message, cause)

/** Use the same codec on both sides of Binder and in JNI pipes; the frame limit is not a collection size limit. */
object CoreFrames {
    data class Frame(val kind: Int, val payload: ByteArray)

    fun utf8(bytes: ByteArray): String = try {
        Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
    } catch (error: Exception) {
        throw CoreTransportException(Contract.CORE_ERROR_INVALID_ENCODING, "Core transport data is not valid UTF-8", error)
    }

    fun write(output: OutputStream, frame: Frame) {
        validate(frame.kind, frame.payload.size.toLong())
        val stream = DataOutputStream(output)
        stream.writeInt(frame.payload.size)
        stream.writeByte(frame.kind)
        stream.write(frame.payload)
        stream.flush()
    }

    class Reader(private val input: InputStream) {
        private var terminal = false
        @Synchronized fun read(): Frame {
            if (terminal) throw CoreTransportException(Contract.CORE_ERROR_TRANSPORT_INTERRUPTED, "No frames can be read after the terminal frame")
            val stream = DataInputStream(input)
            val size: Long
            val kind: Int
            try {
                size = stream.readInt().toLong() and 0xffffffffL
                kind = stream.readUnsignedByte()
            } catch (error: EOFException) {
                throw CoreTransportException(Contract.CORE_ERROR_TRANSPORT_INTERRUPTED, "Pipe ended or frame header was incomplete before the terminal frame", error)
            }
            validate(kind, size)
            val payload = ByteArray(size.toInt())
            try { stream.readFully(payload) } catch (error: EOFException) {
                throw CoreTransportException(Contract.CORE_ERROR_TRANSPORT_INTERRUPTED, "Incomplete core transport frame", error)
            }
            if (kind != Contract.CORE_IPC_FRAME_DATA) utf8(payload)
            if (kind == Contract.CORE_IPC_FRAME_TERMINAL) terminal = true
            return Frame(kind, payload)
        }
    }

    private fun validate(kind: Int, size: Long) {
        if (size > Contract.CORE_IPC_FRAME_BYTES) {
            throw CoreTransportException(Contract.CORE_ERROR_RESULT_TOO_LARGE, "Core transport frame exceeds ${Contract.CORE_IPC_FRAME_BYTES} bytes")
        }
        if (kind !in setOf(Contract.CORE_IPC_FRAME_DATA, Contract.CORE_IPC_FRAME_RECORD,
                Contract.CORE_IPC_FRAME_TERMINAL, Contract.CORE_IPC_FRAME_METADATA)) {
            throw CoreTransportException(Contract.CORE_ERROR_TRANSPORT_INTERRUPTED, "Unknown core transport frame kind: $kind")
        }
    }
}
