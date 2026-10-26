package io.github.monadboxlab.clashpseudo.backup

import io.github.monadboxlab.clashpseudo.app.ApplicationContract
import android.system.Os
import android.util.JsonReader
import android.util.JsonToken
import android.util.JsonWriter
import java.io.BufferedOutputStream
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.io.InputStreamReader
import java.io.OutputStream
import java.io.OutputStreamWriter
import java.io.RandomAccessFile
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import io.github.monadboxlab.clashpseudo.backup.BackupFiles.Fingerprint
import io.github.monadboxlab.clashpseudo.backup.BackupFiles.Kind
import io.github.monadboxlab.clashpseudo.backup.BackupFiles.Operation
import io.github.monadboxlab.clashpseudo.backup.BackupFiles.Companion.invalid

internal const val MIB = 1024L * 1024
internal const val MAX_ARCHIVE = ApplicationContract.BACKUP_ARCHIVE_BYTES.toLong()
internal const val MAX_EXPANDED = ApplicationContract.BACKUP_EXPANDED_BYTES.toLong()
internal const val MAX_BODY = ApplicationContract.CONFIGURATION_TEXT_BYTES.toLong()
internal const val MAX_MANIFEST = ApplicationContract.BACKUP_MANIFEST_BYTES
internal const val MAX_NODES = ApplicationContract.BACKUP_JSON_NODES
internal const val MAX_DEPTH = ApplicationContract.BACKUP_JSON_DEPTH
internal const val MAX_ENTRIES = ApplicationContract.BACKUP_COLLECTION_ENTRIES
internal const val BUFFER = 32768
internal const val MANIFEST = ApplicationContract.BACKUP_MANIFEST_FILE
internal const val ARCHIVE = "archive.zip"
private const val FORMAT = ApplicationContract.BACKUP_FORMAT
private val HASH = Regex("[0-9a-f]{64}")
internal val ENTRY_NAMES = (listOf(MANIFEST) + Kind.entries.map { it.fileName }).toSet()
internal fun makeManifest(created: Long, parts: Map<Kind, Fingerprint>): ByteArray {
    val output = ByteArrayOutputStream()
    JsonWriter(OutputStreamWriter(output, Charsets.UTF_8)).use { writer ->
        writer.beginObject().name("format").value(FORMAT).name("version").value(ApplicationContract.BACKUP_VERSION.toLong())
            .name("createdAtMillis").value(created).name("files").beginObject()
        for (kind in Kind.entries) {
            val part = parts.getValue(kind)
            writer.name(kind.fileName).beginObject().name("bytes").value(part.bytes)
                .name("sha256").value(part.sha256).endObject()
        }
        writer.endObject().endObject()
    }
    return output.toByteArray()
}

internal fun parseManifest(bytes: ByteArray): Pair<Long, Map<Kind, Fingerprint>> {
    val decoder = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
    JsonReader(InputStreamReader(ByteArrayInputStream(bytes), decoder)).use { reader ->
        reader.isLenient = false
        reader.beginObject()
        var format: String? = null
        var version: Long? = null
        var created: Long? = null
        var parts: Map<Kind, Fingerprint>? = null
        val keys = HashSet<String>()
        while (reader.hasNext()) {
            val key = reader.nextName()
            if (!keys.add(key)) invalid("Duplicate backup manifest key")
            when (key) {
                "format" -> {
                    if (reader.peek() != JsonToken.STRING) invalid("Manifest format must be a string")
                    format = reader.nextString()
                }
                "version" -> version = unsigned(reader)
                "createdAtMillis" -> created = unsigned(reader)
                "files" -> {
                    val values = linkedMapOf<Kind, Fingerprint>()
                    reader.beginObject()
                    while (reader.hasNext()) {
                        val name = reader.nextName()
                        val kind = Kind.entries.singleOrNull { it.fileName == name } ?: invalid("Unknown manifest part")
                        if (values.containsKey(kind)) invalid("Duplicate manifest part")
                        reader.beginObject()
                        var size: Long? = null
                        var hash: String? = null
                        val fields = HashSet<String>()
                        while (reader.hasNext()) {
                            val field = reader.nextName()
                            if (!fields.add(field)) invalid("Duplicate manifest fingerprint")
                            when (field) {
                                "bytes" -> size = unsigned(reader)
                                "sha256" -> {
                                    if (reader.peek() != JsonToken.STRING) invalid("Manifest hash must be a string")
                                    hash = reader.nextString()
                                }
                                else -> invalid("Unknown manifest fingerprint field")
                            }
                        }
                        reader.endObject()
                        if (size == null || size > kind.maxBytes || hash == null || !HASH.matches(hash)) invalid("Invalid manifest fingerprint")
                        values[kind] = Fingerprint(size, hash, 0)
                    }
                    reader.endObject()
                    parts = values
                }
                else -> invalid("Unknown backup manifest field")
            }
        }
        reader.endObject()
        if (reader.peek() != JsonToken.END_DOCUMENT || format != FORMAT || version != ApplicationContract.BACKUP_VERSION.toLong() || created == null ||
            parts?.keys != Kind.entries.toSet()) invalid("Unsupported or incomplete backup manifest")
        return created to parts
    }
}

private fun unsigned(reader: JsonReader): Long {
    if (reader.peek() != JsonToken.NUMBER) invalid("Manifest integer required")
    val value = reader.nextString()
    if (!Regex("0|[1-9][0-9]*").matches(value)) invalid("Manifest unsigned integer required")
    return value.toLongOrNull() ?: invalid("Manifest integer overflow")
}
internal fun BackupFiles.writeZip(directory: File, operation: Operation): Fingerprint {
    val archive = File(directory, ARCHIVE)
    writeFile(archive) { stream, descriptor ->
        val buffered = BufferedOutputStream(stream, BUFFER)
        var compressed = 0L
        val bounded = object : OutputStream() {
            override fun write(value: Int) {
                if (compressed == MAX_ARCHIVE) invalid("Compressed backup exceeds budget")
                buffered.write(value)
                compressed++
            }
            override fun write(bytes: ByteArray, offset: Int, length: Int) {
                if (length > MAX_ARCHIVE - compressed) invalid("Compressed backup exceeds budget")
                buffered.write(bytes, offset, length)
                compressed += length
            }
            override fun flush() = buffered.flush()
            // writeFile owns the descriptor and stream.
        }
        ZipOutputStream(bounded).use { zip ->
            for (name in listOf(MANIFEST) + Kind.entries.map { it.fileName }) {
                operation.check()
                zip.putNextEntry(ZipEntry(name))
                readFile(File(directory, name)) { path ->
                    path.inputStream().use { input -> transfer(input, zip, MAX_EXPANDED, operation::check) }
                }
                zip.closeEntry()
            }
            zip.finish()
            zip.flush()
            if (Os.fstat(descriptor).st_size > MAX_ARCHIVE) invalid("Compressed backup exceeds budget")
            sync(descriptor)
        }
    }
    return fingerprint(archive, MAX_ARCHIVE, operation::check)
}

internal class CountingInput(private val input: InputStream, private val limit: Long,
    private val check: () -> Unit) : InputStream() {
    private var size = 0L
    private val digest = MessageDigest.getInstance("SHA-256")
    private val crc = CRC32()
    override fun read(): Int {
        val single = ByteArray(1)
        return if (read(single, 0, 1) < 0) -1 else single[0].toInt() and 255
    }
    override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
        check()
        val count = input.read(bytes, offset, length)
        if (count > 0) {
            if (count > limit - size) invalid("Backup byte budget exceeded")
            size += count
            digest.update(bytes, offset, count)
            crc.update(bytes, offset, count)
        }
        return count
    }
    fun fingerprint() = Fingerprint(size, hex(digest.digest()), crc.value)
}

internal fun transfer(input: InputStream, output: OutputStream, limit: Long, check: () -> Unit): Fingerprint {
    val source = CountingInput(input, limit, check)
    val bytes = ByteArray(BUFFER)
    while (true) {
        val count = source.read(bytes)
        if (count < 0) break
        output.write(bytes, 0, count)
    }
    check()
    return source.fingerprint()
}
internal fun checkEntry(actual: Fingerprint, expected: ZipEntry) {
    if (actual.bytes != expected.size || actual.crc32 != expected.crc) invalid("ZIP CRC or actual size mismatch")
}
/** EOCD + complete central directory + local ranges, before ZipFile performs any expansion. */
internal object ZipLayout {
    data class Entry(val size: Long, val compressed: Long, val crc: Long, val method: Int)
    fun inspect(file: File): Map<String, Entry> = RandomAccessFile(file, "r").use { input ->
        val length = input.length()
        if (length !in 22..MAX_ARCHIVE) invalid("Invalid ZIP length")
        val tailSize = minOf(length, 65557).toInt()
        val tail = ByteArray(tailSize)
        input.seek(length - tailSize)
        input.readFully(tail)
        fun u16(bytes: ByteArray, index: Int) = (bytes[index].toInt() and 255) or ((bytes[index + 1].toInt() and 255) shl 8)
        fun u32(bytes: ByteArray, index: Int) = (u16(bytes, index).toLong() or (u16(bytes, index + 2).toLong() shl 16))
        var end = -1
        for (index in tailSize - 22 downTo 0) {
            if (u32(tail, index) == 0x06054b50L && index + 22 + u16(tail, index + 20) == tailSize) { end = index; break }
        }
        if (end < 0) invalid("ZIP end record is missing")
        val centralSize = u32(tail, end + 12)
        val centralOffset = u32(tail, end + 16)
        val endOffset = length - tailSize + end
        if (u16(tail, end + 4) != 0 || u16(tail, end + 6) != 0 || u16(tail, end + 8) != 4 ||
            u16(tail, end + 10) != 4 || centralSize > ApplicationContract.BACKUP_CENTRAL_DIRECTORY_BYTES || centralOffset + centralSize != endOffset) {
            invalid("Multi-volume, ZIP64 or invalid ZIP directory")
        }
        fun readAt(offset: Long, count: Int): ByteArray {
            if (offset < 0 || count < 0 || offset > length - count) invalid("ZIP range exceeds actual file")
            return ByteArray(count).also { input.seek(offset); input.readFully(it) }
        }
        fun extras(bytes: ByteArray) {
            var index = 0
            while (index < bytes.size) {
                if (bytes.size - index < 4) invalid("Truncated ZIP extra field")
                val id = u16(bytes, index)
                val size = u16(bytes, index + 2)
                if (id == 1 || size > bytes.size - index - 4) invalid("ZIP64 or invalid ZIP extra field")
                index += 4 + size
            }
        }
        val entries = linkedMapOf<String, Entry>()
        val ranges = mutableListOf<Pair<Long, Long>>()
        var cursor = centralOffset
        repeat(4) {
            val header = readAt(cursor, 46)
            if (u32(header, 0) != 0x02014b50L) invalid("Invalid ZIP central header")
            val flags = u16(header, 8)
            val method = u16(header, 10)
            val crc = u32(header, 16)
            val compressed = u32(header, 20)
            val size = u32(header, 24)
            val nameSize = u16(header, 28)
            val extraSize = u16(header, 30)
            val commentSize = u16(header, 32)
            val localOffset = u32(header, 42)
            val attributes = u32(header, 38)
            val type = (attributes ushr 16).toInt() and 0xf000
            if (u16(header, 6) > 20 || flags and 0xf7f1 != 0 || method !in setOf(0, 8) ||
                u16(header, 34) != 0 || attributes and 0x10L != 0L || type !in setOf(0, 0x8000) ||
                compressed > MAX_ARCHIVE || size > MAX_EXPANDED || (method == 0 && size != compressed)) invalid("Unsupported or non-regular ZIP entry")
            val next = cursor + 46 + nameSize + extraSize + commentSize
            if (next > centralOffset + centralSize) invalid("ZIP directory range overflow")
            val nameBytes = readAt(cursor + 46, nameSize)
            val name = String(nameBytes, Charsets.US_ASCII)
            if (name !in ENTRY_NAMES || !nameBytes.contentEquals(name.toByteArray(Charsets.US_ASCII)) || entries.containsKey(name)) {
                invalid("Unexpected or duplicate ZIP entry")
            }
            val max = if (name == MANIFEST) MAX_MANIFEST.toLong() else Kind.entries.single { it.fileName == name }.maxBytes
            if (size > max) invalid("ZIP entry exceeds byte budget")
            extras(readAt(cursor + 46 + nameSize, extraSize))
            val local = readAt(localOffset, 30)
            if (u32(local, 0) != 0x04034b50L || u16(local, 4) > 20 || u16(local, 6) != flags ||
                u16(local, 8) != method || u16(local, 26) != nameSize) invalid("ZIP local header disagreement")
            if (!readAt(localOffset + 30, nameSize).contentEquals(nameBytes)) invalid("ZIP local name disagreement")
            val localExtra = u16(local, 28)
            extras(readAt(localOffset + 30 + nameSize, localExtra))
            val hasDescriptor = flags and 8 != 0
            for ((offset, expected) in listOf(14 to crc, 18 to compressed, 22 to size)) {
                val localValue = u32(local, offset)
                if (localValue != expected && (!hasDescriptor || localValue != 0L)) invalid("ZIP local size disagreement")
            }
            var dataEnd = localOffset + 30 + nameSize + localExtra + compressed
            if (dataEnd > centralOffset) invalid("ZIP entry overlaps central directory")
            if (hasDescriptor) {
                val descriptor = readAt(dataEnd, 12)
                if (u32(descriptor, 0) == 0x08074b50L && dataEnd + 16 <= centralOffset) {
                    val signed = readAt(dataEnd, 16)
                    if (u32(signed, 4) == crc && u32(signed, 8) == compressed && u32(signed, 12) == size) dataEnd += 16
                    else if (u32(descriptor, 0) == crc && u32(descriptor, 4) == compressed && u32(descriptor, 8) == size) dataEnd += 12
                    else invalid("Invalid ZIP data descriptor")
                } else {
                    if (u32(descriptor, 0) != crc || u32(descriptor, 4) != compressed || u32(descriptor, 8) != size) invalid("Invalid ZIP data descriptor")
                    dataEnd += 12
                }
            }
            if (dataEnd > centralOffset) invalid("ZIP data descriptor overlaps directory")
            ranges += localOffset to dataEnd
            entries[name] = Entry(size, compressed, crc, method)
            cursor = next
        }
        if (cursor != centralOffset + centralSize || entries.keys != ENTRY_NAMES) invalid("Incomplete ZIP directory")
        var boundary = 0L
        for ((start, stop) in ranges.sortedBy { it.first }) {
            if (start != boundary || stop < start) invalid("Overlapping or unaccounted ZIP local ranges")
            boundary = stop
        }
        if (boundary != centralOffset) invalid("Unaccounted ZIP payload")
        entries
    }
}

internal fun hex(bytes: ByteArray): String {
    val digits = "0123456789abcdef"
    val text = CharArray(bytes.size * 2)
    bytes.forEachIndexed { index, value ->
        text[index * 2] = digits[(value.toInt() and 255) ushr 4]
        text[index * 2 + 1] = digits[value.toInt() and 15]
    }
    return String(text)
}
