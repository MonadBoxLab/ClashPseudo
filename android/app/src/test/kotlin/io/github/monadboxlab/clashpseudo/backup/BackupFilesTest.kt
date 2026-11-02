package io.github.monadboxlab.clashpseudo.backup

import io.github.monadboxlab.clashpseudo.app.ApplicationContract
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.OutputStream
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CancellationException
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import org.junit.Assert.*
import org.junit.Test

class BackupFilesTest {
    private inline fun <reified T : Throwable> rejects(block: () -> Unit) {
        try { block(); fail("Expected ${T::class.java.simpleName}") } catch (error: Throwable) { if (error !is T) throw error }
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
        val entry = ZipEntry("preferences.json").apply { size = part.bytes; crc = part.crc32 }
        checkEntry(part, entry)
        rejects<IOException> { checkEntry(part.copy(bytes = part.bytes + 1), entry) }
        rejects<IOException> { checkEntry(part.copy(crc32 = part.crc32 xor 1), entry) }
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
        assertEquals(258L * 1024 * 1024 + 65536, MAX_ARCHIVE)
        assertEquals(257L * 1024 * 1024 + 65536, MAX_EXPANDED)
        assertEquals(16 * 1024 * 1024, ApplicationContract.CONFIGURATION_TEXT_BYTES)
        assertEquals(32, ApplicationContract.BACKUP_JSON_DEPTH)
        assertEquals(200000, ApplicationContract.BACKUP_JSON_NODES)
        assertEquals(4096, ApplicationContract.BACKUP_COLLECTION_ENTRIES)
        assertTrue(BackupFiles.isToken(UUID.randomUUID().toString()))
        for (token in listOf("../x", "/private/file", "1-1-1-1-1", "", "restore-active")) assertFalse(BackupFiles.isToken(token))
    }
}
