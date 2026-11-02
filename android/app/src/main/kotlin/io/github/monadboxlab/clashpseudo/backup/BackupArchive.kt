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
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream
import io.github.monadboxlab.clashpseudo.backup.BackupFiles.Fingerprint
import io.github.monadboxlab.clashpseudo.backup.BackupFiles.Kind
import io.github.monadboxlab.clashpseudo.backup.BackupFiles.Operation
import io.github.monadboxlab.clashpseudo.backup.BackupFiles.Companion.invalid

internal const val MIB = 1024L * 1024
internal const val MAX_ARCHIVE = ApplicationContract.BACKUP_ARCHIVE_BYTES.toLong()
internal const val MAX_EXPANDED = ApplicationContract.BACKUP_EXPANDED_BYTES.toLong()
internal const val MAX_MANIFEST = ApplicationContract.BACKUP_MANIFEST_BYTES
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
internal fun BackupFiles.writeZip(directory: File, operation: Operation) {
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
    return source.fingerprint()
}
internal fun checkEntry(actual: Fingerprint, expected: ZipEntry) {
    if (actual.bytes != expected.size || actual.crc32 != expected.crc) invalid("ZIP CRC or actual size mismatch")
}
/** SDK entry iteration owns ZIP decoding, descriptors and CRC validation. */
internal fun BackupFiles.readZip(directory: File, operation: Operation): Pair<Long, Map<Kind, Fingerprint>> {
    val names = HashSet<String>()
    val parts = linkedMapOf<Kind, Fingerprint>()
    var metadata: Pair<Long, Map<Kind, Fingerprint>>? = null
    var expanded = 0L
    readFile(File(directory, ARCHIVE)) { archive ->
        ZipInputStream(archive.inputStream()).use { zip ->
            while (true) {
                operation.check()
                val entry = zip.nextEntry ?: break
                if (entry.isDirectory || entry.name !in ENTRY_NAMES || !names.add(entry.name)) {
                    invalid("Unexpected or duplicate ZIP entry")
                }
                val actual = if (entry.name == MANIFEST) {
                    val output = ByteArrayOutputStream()
                    val fingerprint = transfer(zip, output, minOf(MAX_MANIFEST.toLong(), MAX_EXPANDED - expanded), operation::check)
                    val bytes = output.toByteArray()
                    metadata = parseManifest(bytes)
                    writeNew(File(directory, MANIFEST), bytes.inputStream(), MAX_MANIFEST.toLong(), operation::check)
                    fingerprint
                } else {
                    val kind = Kind.entries.single { it.fileName == entry.name }
                    writeNew(File(directory, kind.fileName), zip, minOf(kind.maxBytes, MAX_EXPANDED - expanded), operation::check)
                        .also { parts[kind] = it }
                }
                zip.closeEntry()
                checkEntry(actual, entry)
                expanded += actual.bytes
            }
        }
    }
    if (names != ENTRY_NAMES) invalid("Incomplete ZIP entries")
    val manifest = checkNotNull(metadata)
    for ((kind, actual) in parts) {
        val expected = manifest.second.getValue(kind)
        if (actual.bytes != expected.bytes || actual.sha256 != expected.sha256) invalid("Backup manifest checksum mismatch")
    }
    return manifest.first to parts
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
