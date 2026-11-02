package io.github.monadboxlab.clashpseudo.backup

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.io.IOException
import java.io.SequenceInputStream
import java.security.MessageDigest
import java.util.UUID
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream
import org.junit.Assert.*
import org.junit.Test

/** Exercise the production reader against SDK ZIP output, not a second layout parser. */
class BackupZipSdkTest {
    private fun packed(entries: List<Pair<String, ByteArray>>, method: Int = ZipEntry.DEFLATED,
        centralDirectory: Boolean = true): ByteArray {
        val output = ByteArrayOutputStream()
        var localBytes = 0
        ZipOutputStream(output).use { zip ->
            for ((name, bytes) in entries) {
                zip.putNextEntry(ZipEntry(name).apply {
                    this.method = method
                    if (method == ZipEntry.STORED) {
                        size = bytes.size.toLong()
                        crc = CRC32().apply { update(bytes) }.value
                    }
                })
                zip.write(bytes)
                zip.closeEntry()
            }
            localBytes = output.size()
        }
        return output.toByteArray().let { if (centralDirectory) it else it.copyOf(localBytes) }
    }

    private fun entries(f: BackupFixture, candidate: BackupFiles.Candidate): List<Pair<String, ByteArray>> {
        val output = ByteArrayOutputStream()
        f.files.writeArchive(candidate.token, output, BackupFiles.Operation(BackupLease()))
        return ZipInputStream(output.toByteArray().inputStream()).use { zip ->
            buildList {
                while (true) {
                    val entry = zip.nextEntry ?: break
                    add(entry.name to zip.readBytes())
                }
            }
        }
    }

    @Test fun storedAndDeflatedEntriesAcceptManifestFirstOrLastAndKeepEveryBusinessByte() = BackupFixture.use { f ->
        val candidate = f.candidate()
        val values = entries(f, candidate)
        for (method in listOf(ZipEntry.STORED, ZipEntry.DEFLATED)) {
            for (manifestLast in listOf(false, true)) {
                val ordered = if (manifestLast) values.drop(1) + values.first() else values
                val imported = f.files.prepareImport(packed(ordered, method).inputStream(), BackupFiles.Operation(BackupLease()))
                assertEquals(candidate.parts, imported.parts)
                assertEquals(candidate.createdAtMillis, imported.createdAtMillis)
                val paths = f.files.candidateReadPaths(imported.token)
                for ((name, bytes) in values.filter { it.first != MANIFEST }) {
                    assertArrayEquals(bytes, File(paths.getValue(name)).readBytes())
                }
                f.files.discard(imported.token)
            }
        }
    }

    @Test fun completeSdkEntriesDoNotNeedAnAdditionalCentralDirectoryAdmissionGate() = BackupFixture.use { f ->
        val candidate = f.candidate()
        for (method in listOf(ZipEntry.STORED, ZipEntry.DEFLATED)) {
            val bytes = packed(entries(f, candidate), method, centralDirectory = false)
            val imported = f.files.prepareImport(bytes.inputStream(), BackupFiles.Operation(BackupLease()))
            assertEquals(candidate.parts, imported.parts)
            f.files.discard(imported.token)
        }
    }

    @Test fun fixedEntriesRejectMissingDuplicateDirectoriesAndForeignPathsWithoutWritingOutsideTheCandidate() = BackupFixture.use { f ->
        f.old()
        val before = f.current()
        val original = f.candidate()
        val values = entries(f, original)
        val outside = File(f.root, "preferences.json").apply { writeText("untouched") }
        val invalid = listOf(
            values.filter { it.first != MANIFEST },
            values.filter { it.first != "preferences.json" },
            values + ("unknown" to byteArrayOf()),
            values + ("nested/" to byteArrayOf()),
            values.map { (name, body) -> (if (name == "preferences.json") "../preferences.json" else name) to body },
            values.map { (name, body) -> (if (name == "preferences.json") "/preferences.json" else name) to body },
            values.map { (name, body) -> (if (name == "preferences.json") "nested/preferences.json" else name) to body },
        ).map { packed(it) }.toMutableList()
        // The SDK writer rejects duplicates itself. Rename an equal-length fixture
        // entry in its output to exercise the production reader's duplicate check.
        invalid += packed(values + ("preferences.jsox" to byteArrayOf()))
            .toString(Charsets.ISO_8859_1).replace("preferences.jsox", "preferences.json").toByteArray(Charsets.ISO_8859_1)
        for (bytes in invalid) {
            backupRejects<IOException> { f.files.prepareImport(bytes.inputStream(), BackupFiles.Operation(BackupLease())) }
            assertEquals(before, f.current())
            assertEquals("untouched", outside.readText())
            assertEquals(setOf(original.token), File(f.privateRoot, "candidates").list()!!.toSet())
        }
    }

    @Test fun sdkPayloadCrcAndTruncationFailuresRetainOriginalStoresAndCleanPartialMaterial() = BackupFixture.use { f ->
        f.old()
        val before = f.current()
        val original = f.candidate()
        val values = entries(f, original)
        val stored = packed(values, ZipEntry.STORED)
        val body = values.last().second
        val position = (0..stored.size - body.size).first { offset ->
            body.indices.all { stored[offset + it] == body[it] }
        }
        val corrupt = stored.copyOf().also { it[position] = (it[position].toInt() xor 1).toByte() }
        for (bytes in listOf(corrupt, stored.copyOf(position + body.size / 2),
            packed(values).let { it.copyOf(it.size / 3) })) {
            backupRejects<IOException> { f.files.prepareImport(bytes.inputStream(), BackupFiles.Operation(BackupLease())) }
            assertEquals(before, f.current())
            assertEquals(setOf(original.token), File(f.privateRoot, "candidates").list()!!.toSet())
        }
    }

    private fun zeros(size: Long) = object : InputStream() {
        var remaining = size
        override fun read(): Int = if (remaining == 0L) -1 else { remaining--; 0 }
        override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
            if (length == 0) return 0
            if (remaining == 0L) return -1
            val count = minOf(remaining, length.toLong()).toInt()
            bytes.fill(0, offset, offset + count)
            remaining -= count
            return count
        }
    }

    private fun streamedArchive(f: BackupFixture, sizes: Map<BackupFiles.Kind, Long>, manifestBytes: Int? = null): File {
        val archive = File(f.root, "sdk-${UUID.randomUUID()}.zip")
        ZipOutputStream(archive.outputStream().buffered()).use { zip ->
            val parts = linkedMapOf<BackupFiles.Kind, BackupFiles.Fingerprint>()
            for (kind in BackupFiles.Kind.entries) {
                zip.putNextEntry(ZipEntry(kind.fileName))
                val digest = MessageDigest.getInstance("SHA-256")
                val crc = CRC32()
                val bytes = ByteArray(BUFFER)
                var remaining = sizes.getValue(kind)
                while (remaining > 0) {
                    val count = minOf(remaining, bytes.size.toLong()).toInt()
                    zip.write(bytes, 0, count)
                    digest.update(bytes, 0, count)
                    crc.update(bytes, 0, count)
                    remaining -= count
                }
                zip.closeEntry()
                parts[kind] = BackupFiles.Fingerprint(sizes.getValue(kind), hex(digest.digest()), crc.value)
            }
            val manifest = makeManifest(1L, parts)
            val padded = manifest.copyOf(manifestBytes ?: manifest.size)
            padded.fill(' '.code.toByte(), manifest.size, padded.size)
            zip.putNextEntry(ZipEntry(MANIFEST))
            zip.write(padded)
            zip.closeEntry()
        }
        return archive
    }

    @Test fun actualExpandedAndManifestBoundariesAcceptWholeFilesAndRejectOneExtraByte() = BackupFixture.use { f ->
        f.old()
        val before = f.current()
        val maximum = BackupFiles.Kind.entries.associateWith { it.maxBytes }
        assertEquals(MAX_EXPANDED, maximum.values.sum() + MAX_MANIFEST)
        val exact = streamedArchive(f, maximum, MAX_MANIFEST)
        val imported = f.files.prepareImport(exact.inputStream(), BackupFiles.Operation(BackupLease()))
        assertEquals(maximum, imported.parts.mapValues { it.value.bytes })
        f.files.discard(imported.token)
        val badManifest = streamedArchive(f, BackupFiles.Kind.entries.associateWith { 0L }, MAX_MANIFEST + 1)
        backupRejects<IOException> { f.files.prepareImport(badManifest.inputStream(), BackupFiles.Operation(BackupLease())) }
        for (kind in BackupFiles.Kind.entries) {
            val sizes = BackupFiles.Kind.entries.associateWith { if (it == kind) it.maxBytes + 1 else 0L }
            val oversized = streamedArchive(f, sizes)
            backupRejects<IOException> { f.files.prepareImport(oversized.inputStream(), BackupFiles.Operation(BackupLease())) }
        }
        assertEquals(before, f.current())
        assertTrue(File(f.privateRoot, "candidates").list()!!.isEmpty())
    }

    @Test fun actualArchiveByteBoundaryIncludesUnreadSdkTrailerWithoutInventingALayoutRestriction() = BackupFixture.use { f ->
        val candidate = f.candidate()
        val bytes = packed(entries(f, candidate))
        for (over in listOf(false, true)) {
            val input = SequenceInputStream(bytes.inputStream(), zeros(MAX_ARCHIVE - bytes.size + if (over) 1 else 0))
            if (over) backupRejects<IOException> { f.files.prepareImport(input, BackupFiles.Operation(BackupLease())) }
            else {
                val imported = f.files.prepareImport(input, BackupFiles.Operation(BackupLease()))
                assertEquals(candidate.parts, imported.parts)
                f.files.discard(imported.token)
            }
            assertEquals(setOf(candidate.token), File(f.privateRoot, "candidates").list()!!.toSet())
        }
    }
}
