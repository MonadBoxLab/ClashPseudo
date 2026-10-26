package io.github.monadboxlab.clashpseudo.backup

import android.util.JsonReader
import android.util.JsonToken
import java.io.File
import java.io.InputStreamReader
import java.io.Reader
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import io.github.monadboxlab.clashpseudo.backup.BackupFiles.Kind
import io.github.monadboxlab.clashpseudo.backup.BackupFiles.Operation
import io.github.monadboxlab.clashpseudo.backup.BackupFiles.Structure
import io.github.monadboxlab.clashpseudo.backup.BackupFiles.Companion.invalid

internal fun BackupFiles.inspectParts(directory: File, operation: Operation): Structure {
    val budget = JsonBudget(operation)
    val counts = mutableMapOf<Kind, Int>()
    for (kind in Kind.entries) {
        readFile(File(directory, kind.fileName)) { path ->
            path.inputStream().use { input ->
                val decoder = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                val strings = ScalarReader(InputStreamReader(input, decoder), operation::check)
                JsonReader(strings).use { reader ->
                    reader.isLenient = false
                    counts[kind] = budget.value(reader, strings, 1, collection = kind != Kind.PREFERENCES)
                    if (reader.peek() != JsonToken.END_DOCUMENT) invalid("Trailing JSON content")
                }
            }
        }
    }
    return Structure(budget.nodes, budget.depth, counts[Kind.CONFIGURATIONS] ?: 0, counts[Kind.OVERRIDES] ?: 0)
}

/**
 * Android JsonReader materializes quoted tokens during peek/skipValue. Supply bounded
 * ASCII inspection values containing UTF-8 length, surrogate validity and decoded
 * UTF-16 SHA-256 while preserving original candidate bytes. SDK parses structure and
 * numbers. Reject unquoted literals at the same invalid 1024-character boundary before
 * AOSP's StringBuilder grows; shorter literals and numbers retain SDK validation.
 */
internal class ScalarReader(private val source: Reader, private val check: () -> Unit = {},
    private val maxNesting: Int = Int.MAX_VALUE) : Reader() {
    private val input = CharArray(4096)
    private var at = 0
    private var end = 0
    private var pending = ""
    private var emitted = 0
    private var literal = 0
    private var nesting = 0
    private var stringLimit = Long.MAX_VALUE
    private val digest = MessageDigest.getInstance("SHA-256")
    private val hashed = ByteArray(4096)
    private var hashSize = 0
    private fun raw(): Int {
        if (end == -1) return -1
        if (at == end) {
            check()
            end = source.read(input)
            at = 0
            if (end == -1) return -1
            if (end == 0) invalid("JSON reader made no progress")
        }
        return input[at++].code
    }
    private fun unread() { at-- }
    fun limitNextString(bytes: Long) { stringLimit = bytes }
    override fun read(target: CharArray, offset: Int, length: Int): Int {
        if (offset < 0 || length < 0 || offset > target.size - length) throw IndexOutOfBoundsException()
        if (length == 0) return 0
        if (emitted < pending.length) return emit(target, offset, length)
        var count = 0
        while (count < length) {
            val c = raw()
            if (c == -1) return if (count == 0) -1 else count
            if (c == '"'.code) {
                if (count != 0) { unread(); break }
                literal = 0
                pending = "\"${string()}\""
                emitted = 0
                return emit(target, offset, length)
            }
            val delimiter = c.toChar() in "{}[]:, \t\u000c\r\n/\\;#="
            literal = if (delimiter) 0 else literal + 1
            if (literal >= 1024) invalid("Unquoted JSON literal exceeds SDK strict boundary")
            if (c == '{'.code || c == '['.code) {
                if (++nesting > maxNesting) invalid("JSON observation nesting exceeds budget")
            } else if (c == '}'.code || c == ']'.code) nesting--
            target[offset + count++] = c.toChar()
        }
        return count
    }
    private fun emit(target: CharArray, offset: Int, length: Int): Int {
        val count = minOf(length, pending.length - emitted)
        pending.toCharArray(target, offset, emitted, emitted + count)
        emitted += count
        return count
    }
    private fun escape(): Char = when (val c = raw()) {
        '"'.code, '\\'.code, '/'.code -> c.toChar()
        'b'.code -> '\b'
        'f'.code -> '\u000c'
        'n'.code -> '\n'
        'r'.code -> '\r'
        't'.code -> '\t'
        'u'.code -> {
            var value = 0
            repeat(4) {
                val hex = raw()
                val digit = when (hex) {
                    in '0'.code..'9'.code -> hex - '0'.code
                    in 'a'.code..'f'.code -> hex - 'a'.code + 10
                    in 'A'.code..'F'.code -> hex - 'A'.code + 10
                    else -> invalid("Invalid JSON Unicode escape")
                }
                value = (value shl 4) or digit
            }
            value.toChar()
        }
        else -> invalid("Invalid JSON escape")
    }
    private fun hash(c: Char) {
        hashed[hashSize++] = (c.code ushr 8).toByte()
        hashed[hashSize++] = c.code.toByte()
        if (hashSize == hashed.size) { digest.update(hashed); hashSize = 0 }
    }
    private fun string(): String {
        digest.reset()
        hashSize = 0
        var bytes = 0L
        var high = false
        var validPairs = true
        while (true) {
            val raw = raw()
            if (raw == -1) invalid("Unterminated JSON string")
            if (raw == '"'.code) break
            if (raw < 0x20) invalid("Unescaped JSON control character")
            val c = if (raw == '\\'.code) escape() else raw.toChar()
            hash(c)
            if (high) {
                high = false
                if (c.isLowSurrogate()) {
                    bytes += 4
                    if (bytes > stringLimit) invalid("Backup body exceeds budget")
                    continue
                }
                validPairs = false
                bytes += 3 // only metadata for non-body strings; body still rejects invalid pairs
            }
            when {
                c.isHighSurrogate() -> high = true
                c.isLowSurrogate() -> { validPairs = false; bytes += 3 }
                c.code < 0x80 -> bytes++
                c.code < 0x800 -> bytes += 2
                else -> bytes += 3
            }
            if (bytes > stringLimit) invalid("Backup body exceeds budget")
        }
        if (high) { validPairs = false; bytes += 3 }
        if (bytes > stringLimit) invalid("Backup body exceeds budget")
        stringLimit = Long.MAX_VALUE
        if (hashSize != 0) digest.update(hashed, 0, hashSize)
        return "$bytes:${if (validPairs) 1 else 0}:${hex(digest.digest())}"
    }
    override fun close() = source.close()
    companion object {
        /** Reconstruct only fixed ASCII schema keys and enum values. */
        fun marker(value: String): String {
            require(value.all { it.code < 0x80 })
            val bytes = ByteArray(value.length * 2)
            value.forEachIndexed { index, c -> bytes[index * 2 + 1] = c.code.toByte() }
            return "${value.length}:1:${hex(MessageDigest.getInstance("SHA-256").digest(bytes))}"
        }
        fun utf8Bytes(marker: String): Long {
            val colon = marker.indexOf(':')
            if (colon < 1 || marker.getOrNull(colon + 1) != '1') invalid("Unpaired backup body surrogate")
            return marker.substring(0, colon).toLong()
        }
    }
}

private class JsonBudget(private val operation: Operation) {
    private val bodyKey = ScalarReader.marker("body")
    private val entriesKey = ScalarReader.marker("entries")
    var nodes = 0
    var depth = 0
    private fun node(level: Int) {
        operation.check()
        if (++nodes > MAX_NODES || level > MAX_DEPTH) invalid("JSON structure exceeds budget")
        depth = maxOf(depth, level)
    }
    fun value(reader: JsonReader, strings: ScalarReader, level: Int, collection: Boolean = false,
        entries: Boolean = false, entry: Boolean = false): Int {
        node(level)
        var count = 0
        when (reader.peek()) {
            JsonToken.BEGIN_OBJECT -> {
                reader.beginObject()
                val names = HashSet<String>()
                while (reader.hasNext()) {
                    node(level)
                    val name = reader.nextName()
                    if (!names.add(name)) invalid("Duplicate JSON key")
                    if (entry && name == bodyKey) {
                        node(level + 1)
                        strings.limitNextString(MAX_BODY)
                        if (reader.peek() != JsonToken.STRING || ScalarReader.utf8Bytes(reader.nextString()) > MAX_BODY) {
                            invalid("Backup body exceeds budget or is not a string")
                        }
                    } else {
                        val rootEntries = collection && level == 1 && name == entriesKey
                        count = maxOf(count, value(reader, strings, level + 1, entries = rootEntries))
                    }
                }
                reader.endObject()
            }
            JsonToken.BEGIN_ARRAY -> {
                reader.beginArray()
                var size = 0
                while (reader.hasNext()) {
                    if (entries && ++size > MAX_ENTRIES) invalid("Backup collection exceeds entry budget")
                    value(reader, strings, level + 1, entry = entries)
                }
                reader.endArray()
                if (entries) count = size
            }
            JsonToken.STRING, JsonToken.NUMBER -> reader.nextString()
            JsonToken.BOOLEAN -> reader.nextBoolean()
            JsonToken.NULL -> reader.nextNull()
            else -> invalid("Invalid JSON value")
        }
        return count
    }
}

/** Read-only mode observation; excessive nesting produces an unknown observation. */
internal fun savedMode(source: Reader, modes: Set<String>): String? {
    val modeKey = ScalarReader.marker("mode")
    val values = modes.associateBy { ScalarReader.marker(it) }
    val strings = ScalarReader(source, maxNesting = MAX_DEPTH)
    return JsonReader(strings).use { reader ->
        reader.isLenient = false
        var found = false
        var mode: String? = null
        reader.beginObject()
        while (reader.hasNext()) {
            if (reader.nextName() != modeKey) { reader.skipValue(); continue }
            check(!found)
            found = true
            strings.limitNextString(modes.maxOfOrNull { it.length }?.toLong() ?: 0L)
            if (reader.peek() == JsonToken.NULL) reader.nextNull()
            else {
                check(reader.peek() == JsonToken.STRING)
                mode = values[reader.nextString()]
                check(mode != null)
            }
            strings.limitNextString(Long.MAX_VALUE)
        }
        reader.endObject()
        check(found && reader.peek() == JsonToken.END_DOCUMENT)
        mode
    }
}

internal fun utf8Length(value: String): Long {
    var bytes = 0L
    var index = 0
    while (index < value.length) {
        val char = value[index++]
        bytes += when {
            char.code < 0x80 -> 1
            char.code < 0x800 -> 2
            char.isHighSurrogate() -> {
                if (index >= value.length || !value[index++].isLowSurrogate()) invalid("Unpaired body surrogate")
                4
            }
            char.isLowSurrogate() -> invalid("Unpaired body surrogate")
            else -> 3
        }
    }
    return bytes
}
