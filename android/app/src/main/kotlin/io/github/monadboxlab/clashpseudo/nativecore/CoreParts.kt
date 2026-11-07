package io.github.monadboxlab.clashpseudo.nativecore

import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import org.json.JSONObject
import java.io.InputStream
import java.io.OutputStream

/** Transmit raw content and parts separately, checking each budget independently. */
object CoreParts {
    private fun budget(part: String): Int = when (part) {
        Contract.CORE_PART_CONFIG -> Contract.CONFIGURATION_TEXT_BYTES
        Contract.CORE_PART_OVERRIDES -> Contract.CONFIGURATION_OVERRIDE_JSON_BYTES
        Contract.CORE_PART_OPTIONS -> Contract.CONFIGURATION_PREPARATION_OPTIONS_BYTES
        Contract.CORE_PART_REQUEST -> Contract.CORE_IPC_CONTROL_BYTES
        Contract.CORE_PART_TRUST -> Contract.CONFIGURATION_PREPARATION_OPTIONS_BYTES
        else -> throw CoreTransportException(Contract.CORE_ERROR_TRANSPORT_INTERRUPTED, "Unknown core input part: $part")
    }

    fun validate(parts: Map<String, ByteArray>) {
        parts.forEach { (name, bytes) ->
            if (bytes.size > budget(name)) {
                throw CoreTransportException(Contract.CORE_ERROR_INPUT_TOO_LARGE, "Core input part $name exceeds ${budget(name)} bytes")
            }
            CoreFrames.utf8(bytes)
        }
        require(parts.containsKey(Contract.CORE_PART_REQUEST)) { "Missing core request part" }
    }

    fun write(output: OutputStream, parts: Map<String, ByteArray>) {
        validate(parts)
        parts.forEach { (name, bytes) ->
            CoreFrames.write(output, CoreFrames.Frame(Contract.CORE_IPC_FRAME_METADATA,
                JSONObject().put("part", name).put("bytes", bytes.size).toString().toByteArray(Charsets.UTF_8)))
            var offset = 0
            while (offset < bytes.size) {
                val end = minOf(bytes.size, offset + Contract.CORE_IPC_FRAME_BYTES)
                CoreFrames.write(output, CoreFrames.Frame(Contract.CORE_IPC_FRAME_DATA, bytes.copyOfRange(offset, end)))
                offset = end
            }
        }
        CoreFrames.write(output, CoreFrames.Frame(Contract.CORE_IPC_FRAME_TERMINAL,
            JSONObject().put(Contract.CORE_FIELD_COMPLETE, true).toString().toByteArray(Charsets.UTF_8)))
    }

    fun read(input: InputStream): Map<String, ByteArray> {
        val reader = CoreFrames.Reader(input)
        val parts = linkedMapOf<String, ByteArray>()
        var current: String? = null
        var bytes: ByteArray? = null
        var offset = 0
        fun finish() {
            val name = current ?: return
            val value = checkNotNull(bytes)
            if (offset != value.size) throw CoreTransportException(Contract.CORE_ERROR_TRANSPORT_INTERRUPTED, "Core input part $name length mismatch")
            CoreFrames.utf8(value)
            parts[name] = value
            current = null
            bytes = null
        }
        while (true) {
            val frame = reader.read()
            when (frame.kind) {
                Contract.CORE_IPC_FRAME_METADATA -> {
                    finish()
                    val metadata = JSONObject(CoreFrames.utf8(frame.payload))
                    val name = metadata.getString("part")
                    val size = metadata.getLong("bytes")
                    if (parts.containsKey(name) || size < 0 || size > budget(name)) {
                        throw CoreTransportException(Contract.CORE_ERROR_INPUT_TOO_LARGE, "Duplicate or oversized core input part: $name")
                    }
                    current = name
                    bytes = ByteArray(size.toInt())
                    offset = 0
                }
                Contract.CORE_IPC_FRAME_DATA -> {
                    val target = bytes ?: throw CoreTransportException(Contract.CORE_ERROR_TRANSPORT_INTERRUPTED, "Core data does not belong to a part")
                    if (frame.payload.size > target.size - offset) {
                        throw CoreTransportException(Contract.CORE_ERROR_INPUT_TOO_LARGE, "Core input part exceeds its declared length")
                    }
                    frame.payload.copyInto(target, offset)
                    offset += frame.payload.size
                }
                Contract.CORE_IPC_FRAME_TERMINAL -> {
                    finish()
                    if (!JSONObject(CoreFrames.utf8(frame.payload)).optBoolean(Contract.CORE_FIELD_COMPLETE)) {
                        throw CoreTransportException(Contract.CORE_ERROR_TRANSPORT_INTERRUPTED, "Core input has no complete terminal frame")
                    }
                    validate(parts)
                    return parts
                }
                else -> throw CoreTransportException(Contract.CORE_ERROR_TRANSPORT_INTERRUPTED, "Request stream cannot contain result records")
            }
        }
    }
}
