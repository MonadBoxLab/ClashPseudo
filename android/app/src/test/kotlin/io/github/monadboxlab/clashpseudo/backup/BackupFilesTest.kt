package io.github.monadboxlab.clashpseudo.backup

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.OutputStream
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CancellationException
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import org.junit.Assert.*
import org.junit.Test

class BackupFilesTest {
    private inline fun <reified T : Throwable> rejects(block: () -> Unit) {
        try { block(); fail("Expected ${T::class.java.simpleName}") } catch (error: Throwable) { if (error !is T) throw error }
    }
    private fun temp(block: (File) -> Unit) {
        val root = File(checkNotNull(System.getProperty("backup.test.root", "build/backup-unit-tests")))
        check(root.mkdirs() || root.isDirectory)
        val directory = File(root, UUID.randomUUID().toString()).apply { check(mkdir()) }
        try { block(directory) } finally { directory.deleteRecursively() }
    }
    private fun layout(bytes: ByteArray) = temp { directory ->
        ZipLayout.inspect(File(directory, "archive.zip").apply { writeBytes(bytes) })
    }
    private fun zip(stored: Boolean = false): ByteArray = ByteArrayOutputStream().also { out ->
        ZipOutputStream(out).use { zip ->
            for (name in ENTRY_NAMES) {
                val body = "fixed:$name".toByteArray()
                val entry = ZipEntry(name)
                if (stored) {
                    entry.method = ZipEntry.STORED
                    entry.size = body.size.toLong()
                    entry.compressedSize = body.size.toLong()
                    entry.crc = CRC32().apply { update(body) }.value
                }
                zip.putNextEntry(entry)
                zip.write(body)
                zip.closeEntry()
            }
        }
    }.toByteArray()
    private fun sizedZip(target: String, size: Long): ByteArray = ByteArrayOutputStream().also { out ->
        ZipOutputStream(out).use { zip ->
            val buffer = ByteArray(32768)
            for (name in ENTRY_NAMES) {
                zip.putNextEntry(ZipEntry(name))
                var remaining = if (name == target) size else 1L
                while (remaining > 0) {
                    val count = minOf(remaining, buffer.size.toLong()).toInt()
                    zip.write(buffer, 0, count)
                    remaining -= count
                }
                zip.closeEntry()
            }
        }
    }.toByteArray()
    private fun positions(bytes: ByteArray, signature: Long): List<Int> = (0..bytes.size - 4).filter { u32(bytes, it) == signature }
    private fun u16(bytes: ByteArray, index: Int) = (bytes[index].toInt() and 255) or ((bytes[index + 1].toInt() and 255) shl 8)
    private fun u32(bytes: ByteArray, index: Int) = u16(bytes, index).toLong() or (u16(bytes, index + 2).toLong() shl 16)
    private fun put16(bytes: ByteArray, index: Int, value: Int) {
        bytes[index] = value.toByte(); bytes[index + 1] = (value ushr 8).toByte()
    }
    private fun put32(bytes: ByteArray, index: Int, value: Long) { repeat(4) { bytes[index + it] = (value ushr (it * 8)).toByte() } }

    @Test fun completeStoredAndDeflatedArchivesAreAccepted() { layout(zip()); layout(zip(stored = true)) }

    @Test fun perEntryByteLimitsAreCheckedOnOtherwiseCompleteWellFormedArchives() {
        for ((name, limit) in listOf("manifest.json" to 65536L, "preferences.json" to MIB,
            "configurations.json" to 128L * MIB, "overrides.json" to 128L * MIB)) {
            layout(sizedZip(name, limit))
            rejects<IOException> { layout(sizedZip(name, limit + 1)) }
        }
    }

    @Test fun compressedActualFileLimitRejectsEvenASparseOversizeFileBeforeReadingItsTail() = temp { directory ->
        val path = File(directory, "oversize.zip")
        java.io.RandomAccessFile(path, "rw").use { it.setLength(MAX_ARCHIVE + 1) }
        rejects<IOException> { ZipLayout.inspect(path) }
    }

    @Test fun missingOrTruncatedEndRecordAndAppendedGarbageAreRejected() {
        val good = zip()
        for (bad in listOf(byteArrayOf(), good.copyOf(10), good.copyOf(good.size - 1), good + byteArrayOf(0))) {
            rejects<IOException> { layout(bad) }
        }
    }

    @Test fun multiVolumeZip64AndIncorrectCountsAreRejected() {
        val good = zip()
        val end = positions(good, 0x06054b50).single()
        for ((field, value) in listOf(4 to 1, 6 to 1, 8 to 3, 10 to 5, 8 to 65535)) {
            rejects<IOException> { layout(good.copyOf().also { put16(it, end + field, value) }) }
        }
        rejects<IOException> { layout(good.copyOf().also { put32(it, end + 12, 0xffffffffL) }) }
        rejects<IOException> { layout(good.copyOf().also { put32(it, end + 16, 0xffffffffL) }) }
    }

    @Test fun encryptedDirectorySymlinkAndUnsupportedCompressionEntriesAreRejected() {
        val good = zip(stored = true)
        val central = positions(good, 0x02014b50).first()
        val local = positions(good, 0x04034b50).first()
        rejects<IOException> { layout(good.copyOf().also { put16(it, central + 8, 1); put16(it, local + 6, 1) }) }
        rejects<IOException> { layout(good.copyOf().also { put32(it, central + 38, 0x10) }) }
        rejects<IOException> { layout(good.copyOf().also { put32(it, central + 38, 0xa0000000L) }) }
        rejects<IOException> { layout(good.copyOf().also { put16(it, central + 10, 9); put16(it, local + 8, 9) }) }
    }

    @Test fun centralAndLocalNamesMethodsSizesAndCrcMustAgree() {
        val good = zip(stored = true)
        val central = positions(good, 0x02014b50).first()
        val local = positions(good, 0x04034b50).first()
        val mutations: List<(ByteArray) -> Unit> = listOf(
            { it[central + 46] = '.'.code.toByte() },
            { it[local + 30] = '.'.code.toByte() },
            { put16(it, local + 8, 8) },
            { put32(it, local + 14, 1) },
            { put32(it, local + 18, 1) },
            { put32(it, local + 22, 1) },
            { put32(it, central + 24, 0xffffffffL) },
        )
        for (mutate in mutations) rejects<IOException> { layout(good.copyOf().also(mutate)) }
    }

    @Test fun overlappingOrUnaccountedLocalAndCentralRangesAreRejected() {
        val good = zip()
        val central = positions(good, 0x02014b50)
        val end = positions(good, 0x06054b50).single()
        rejects<IOException> { layout(good.copyOf().also { put32(it, central[1] + 42, 0) }) }
        rejects<IOException> { layout(good.copyOf().also { put32(it, central[0] + 42, 1) }) }
        rejects<IOException> { layout(good.copyOf().also { put32(it, end + 16, u32(it, end + 16) + 1) }) }
        rejects<IOException> { layout(good.copyOf().also { put32(it, end + 12, u32(it, end + 12) - 1) }) }
    }

    @Test fun deflateDataDescriptorIsRequiredAndChecked() {
        val good = zip()
        val descriptor = positions(good, 0x08074b50).first()
        rejects<IOException> { layout(good.copyOf().also { put32(it, descriptor + 4, 1) }) }
        rejects<IOException> { layout(good.copyOf().also { put32(it, descriptor + 8, 0) }) }
        rejects<IOException> { layout(good.copyOf().also { put32(it, descriptor + 12, 0) }) }
    }

    @Test fun boundedTransferUsesActualUnknownLengthBytesAndChecksCrcAndHash() {
        val bytes = "body\u0000﻿你好".repeat(1000).toByteArray()
        val out = ByteArrayOutputStream()
        val source = object : java.io.ByteArrayInputStream(bytes) { override fun available() = 0 }
        val part = transfer(source, out, bytes.size.toLong()) {}
        assertArrayEquals(bytes, out.toByteArray())
        assertEquals(bytes.size.toLong(), part.bytes)
        assertEquals(CRC32().apply { update(bytes) }.value, part.crc32)
        assertEquals(hex(MessageDigest.getInstance("SHA-256").digest(bytes)), part.sha256)
    }

    @Test fun transferRejectsOneByteOverTheLimitWithoutWritingPastIt() {
        val out = ByteArrayOutputStream()
        rejects<IOException> { transfer(ByteArray(65537).inputStream(), out, 65536) {} }
        assertEquals(65536, out.size())
    }

    @Test fun transferPropagatesDiskFullAndChecksCancellationDuringRealProgress() {
        val full = object : OutputStream() { override fun write(value: Int) { throw IOException("injected disk full") } }
        rejects<IOException> { transfer(ByteArray(50000).inputStream(), full, 50000) {} }
        val out = ByteArrayOutputStream()
        rejects<CancellationException> {
            transfer(ByteArray(100000).inputStream(), out, 100000) {
                if (out.size() > 0) throw CancellationException()
            }
        }
        assertTrue(out.size() in 1 until 100000)
    }

    @Test fun operationDeadlineIs300SecondsAndOwnerCancellationIsNotSwallowed() {
        var now = 1000L
        var active = true
        val owner = object : RestoreTransaction.Owner {
            override fun checkCurrent() { if (!active) throw CancellationException() }
            override fun runIfCurrent(block: () -> Unit) { checkCurrent(); block() }
        }
        val operation = BackupFiles.Operation(owner) { now }
        now += 299999
        operation.check()
        now++
        rejects<CancellationException> { operation.check() }
        now = 1001
        active = false
        rejects<CancellationException> { operation.check() }
    }

    @Test fun approvedBudgetsAndStrictPrivateTokensAreFixed() {
        assertEquals(256L * 1024 * 1024, MAX_ARCHIVE)
        assertEquals(256L * 1024 * 1024, MAX_EXPANDED)
        assertEquals(16L * 1024 * 1024, MAX_BODY)
        assertEquals(32, MAX_DEPTH)
        assertEquals(200000, MAX_NODES)
        assertEquals(4096, MAX_ENTRIES)
        assertTrue(BackupFiles.isToken(UUID.randomUUID().toString()))
        for (token in listOf("../x", "/private/file", "1-1-1-1-1", "", "restore-active")) assertFalse(BackupFiles.isToken(token))
    }
}
