package io.github.monadboxlab.clashpseudo.backup

import android.system.Os
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileDescriptor
import java.io.IOException
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.CancellationException
import java.util.zip.ZipInputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import org.junit.Assert.*
import org.junit.Test

internal class BackupLease : RestoreTransaction.Owner {
    @Volatile private var active = true
    var beforeAdmission: () -> Unit = {}
    var afterAdmission: () -> Unit = {}
    @Synchronized fun cancel() { active = false }
    override fun checkCurrent() { if (!active) throw CancellationException("Expired backup owner") }
    @Synchronized override fun runIfCurrent(block: () -> Unit) {
        beforeAdmission(); checkCurrent(); block(); afterAdmission()
    }
}
internal class BackupFixture(val root: File, steps: (String) -> Unit, sync: (FileDescriptor) -> Unit) {
    val stores = File(root, "stores")
    val privateRoot = File(root, "private")
    val files = BackupFiles(stores, privateRoot, steps, sync)
    val storage get() = files.transaction
    init { storage.recover() }
    fun candidate(values: Map<BackupFiles.Kind, ByteArray> = values(), lease: BackupLease = BackupLease()) =
        files.capture(123456L, storage.snapshot().epoch, BackupFiles.Operation(lease)) { values.getValue(it).inputStream() }
    fun old(values: Map<BackupFiles.Kind, ByteArray?> = BackupFiles.Kind.entries.associateWith { ("damaged-old-${it.name}").toByteArray() }) {
        for ((kind, bytes) in values) {
            val file = File(stores, kind.fileName)
            if (bytes != null) file.writeBytes(bytes) else if (file.exists()) check(file.delete())
        }
    }
    fun current() = BackupFiles.Kind.entries.associateWith { kind ->
        File(stores, kind.fileName).let { if (it.exists()) it.readBytes().toList() else null }
    }
    companion object {
        fun values() = mapOf(
            BackupFiles.Kind.CONFIGURATIONS to "{\"selectedId\":\"c\",\"mode\":null,\"entries\":[{\"id\":\"c\",\"revision\":1,\"body\":\"secret: pass\\n\"}]}".toByteArray(),
            BackupFiles.Kind.OVERRIDES to "{\"entries\":[{\"id\":\"o\",\"body\":\"\",\"enabled\":true}]}".toByteArray(),
            BackupFiles.Kind.PREFERENCES to "{\"access\":\"all\",\"packages\":[],\"unknown\":\"preserved\"}".toByteArray(),
        )
        inline fun <T> use(noinline steps: (String) -> Unit = {}, noinline sync: (FileDescriptor) -> Unit = { Os.fsync(it) }, block: (BackupFixture) -> T): T {
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            val root = File(context.cacheDir.canonicalFile, "backup-isolated-${UUID.randomUUID()}")
            check(root.mkdir())
            try { return block(BackupFixture(root, steps, sync)) } finally { root.deleteRecursively() }
        }
    }
}
internal inline fun <reified T : Throwable> backupRejects(block: () -> Unit) {
    try { block(); fail("Expected ${T::class.java.simpleName}") } catch (error: Throwable) { if (error !is T) throw error }
}

class BackupFilesPlatformTest {
    private fun archive(f: BackupFixture, candidate: BackupFiles.Candidate): ByteArray = ByteArrayOutputStream().also {
        f.files.writeArchive(candidate.token, it, BackupFiles.Operation(BackupLease()))
    }.toByteArray()
    private fun rewrite(bytes: ByteArray, change: (String, ByteArray) -> ByteArray): ByteArray = ByteArrayOutputStream().also { output ->
        ZipOutputStream(output).use { zip ->
            ZipInputStream(bytes.inputStream()).use { input ->
                while (true) {
                    val entry = input.nextEntry ?: break
                    val body = input.readBytes()
                    zip.putNextEntry(ZipEntry(entry.name))
                    zip.write(change(entry.name, body))
                    zip.closeEntry()
                }
            }
        }
    }.toByteArray()

    @Test fun exactThreePartsRoundTripIncludingRawFormattingSecretsAndUnknownFields() = BackupFixture.use { f ->
        val values = BackupFixture.values().toMutableMap()
        values[BackupFiles.Kind.OVERRIDES] = "{\r\n \"entries\": [{\"body\":\"﻿a\\r\\nb\\n\"}], \"unknown\":false}\r\n".toByteArray()
        val original = f.candidate(values)
        val imported = f.files.prepareImport(archive(f, original).inputStream(), BackupFiles.Operation(BackupLease()))
        assertEquals(original.createdAtMillis, imported.createdAtMillis)
        assertEquals(original.parts, imported.parts)
        assertEquals(1, imported.structure.configurations)
        assertEquals(1, imported.structure.overrides)
        for (kind in BackupFiles.Kind.entries) {
            f.files.withPart(imported.token, kind, BackupFiles.Operation(BackupLease())) { input ->
                assertArrayEquals(values.getValue(kind), input.readBytes())
            }
        }
        f.files.discard(original.token)
        f.files.discard(imported.token)
        assertTrue(File(f.privateRoot, "candidates").list()!!.isEmpty())
    }

    @Test fun unsupportedVersionMissingManifestFieldsWrongHashAndInvalidUtf8FailWithoutTouchingStores() = BackupFixture.use { f ->
        f.old()
        val before = f.current()
        val bytes = archive(f, f.candidate())
        val badManifest: List<(String) -> String> = listOf(
            { it.replace("\"version\":1", "\"version\":2") },
            { it.replace("clash-pseudo-backup", "unknown-backup") },
            { it.replace("\"sha256\":\"", "\"sha256\":\"0") },
            { it.replace("\"createdAtMillis\":123456,", "") },
            { it.replace("\"version\":1", "\"version\":1,\"version\":1") },
        )
        for (mutate in badManifest) {
            val malformed = rewrite(bytes) { name, body -> if (name == "manifest.json") mutate(String(body, Charsets.UTF_8)).toByteArray() else body }
            backupRejects<Exception> { f.files.prepareImport(malformed.inputStream(), BackupFiles.Operation(BackupLease())) }
        }
        val invalidUtf8 = rewrite(bytes) { name, body -> if (name == "manifest.json") byteArrayOf(0xc3.toByte(), 0x28) else body }
        backupRejects<Exception> { f.files.prepareImport(invalidUtf8.inputStream(), BackupFiles.Operation(BackupLease())) }
        assertEquals(before, f.current())
    }

    @Test fun actualPayloadCrcAndManifestDigestAreVerifiedNotJustZipMetadata() = BackupFixture.use { f ->
        val bytes = archive(f, f.candidate())
        val modified = rewrite(bytes) { name, body -> if (name == "preferences.json") body + ' '.code.toByte() else body }
        // New ZIP CRC is valid; the fixed manifest digest/size is deliberately stale.
        backupRejects<IOException> { f.files.prepareImport(modified.inputStream(), BackupFiles.Operation(BackupLease())) }
        val corrupt = bytes.copyOf()
        val payload = (0..corrupt.size - 4).first { index ->
            (corrupt[index].toInt() and 255) == 0x50 && (corrupt[index + 1].toInt() and 255) == 0x4b &&
                (corrupt[index + 2].toInt() and 255) == 3 && (corrupt[index + 3].toInt() and 255) == 4
        }
        // Corrupt the compressed manifest while retaining the original directory CRC.
        val nameSize = (corrupt[payload + 26].toInt() and 255) or ((corrupt[payload + 27].toInt() and 255) shl 8)
        val extra = (corrupt[payload + 28].toInt() and 255) or ((corrupt[payload + 29].toInt() and 255) shl 8)
        val position = payload + 30 + nameSize + extra + 4
        corrupt[position] = (corrupt[position].toInt() xor 1).toByte()
        backupRejects<Exception> { f.files.prepareImport(corrupt.inputStream(), BackupFiles.Operation(BackupLease())) }
    }

    @Test fun jsonDepthEntryAndTotalNodeBudgetsHaveExactBoundaries() = BackupFixture.use { f ->
        fun values() = mapOf(
            BackupFiles.Kind.CONFIGURATIONS to "{\"entries\":[]}".toByteArray(),
            BackupFiles.Kind.OVERRIDES to "{\"entries\":[]}".toByteArray(),
            BackupFiles.Kind.PREFERENCES to "{}".toByteArray(),
        ).toMutableMap()
        val collection = values()
        collection[BackupFiles.Kind.CONFIGURATIONS] = ("{\"entries\":[" + List(4096) { "{}" }.joinToString(",") + "]}").toByteArray()
        assertEquals(4096, f.candidate(collection).structure.configurations)
        collection[BackupFiles.Kind.CONFIGURATIONS] = ("{\"entries\":[" + List(4097) { "{}" }.joinToString(",") + "]}").toByteArray()
        backupRejects<IOException> { f.candidate(collection) }
        val deep = values()
        deep[BackupFiles.Kind.PREFERENCES] = ("{\"a\":" + "[".repeat(30) + "0" + "]".repeat(30) + "}").toByteArray()
        assertEquals(32, f.candidate(deep).structure.depth)
        deep[BackupFiles.Kind.PREFERENCES] = ("{\"a\":" + "[".repeat(31) + "0" + "]".repeat(31) + "}").toByteArray()
        backupRejects<IOException> { f.candidate(deep) }
        val nodes = values()
        nodes[BackupFiles.Kind.PREFERENCES] = ("{\"a\":[" + List(199991) { "null" }.joinToString(",") + "]}").toByteArray()
        assertEquals(200000, f.candidate(nodes).structure.nodes)
        nodes[BackupFiles.Kind.PREFERENCES] = ("{\"a\":[" + List(199992) { "null" }.joinToString(",") + "]}").toByteArray()
        backupRejects<IOException> { f.candidate(nodes) }
    }

    @Test fun full16MiBBodyIncludingBomIsPreservedAndOneByteOverRejected() = BackupFixture.use { f ->
        val values = BackupFixture.values().toMutableMap()
        val prefix = "{\"entries\":[{\"body\":\"﻿"
        val suffix = "\"}]}"
        values[BackupFiles.Kind.CONFIGURATIONS] = (prefix + "x".repeat(MAX_BODY.toInt() - 3) + suffix).toByteArray()
        val accepted = f.candidate(values)
        assertEquals(values.getValue(BackupFiles.Kind.CONFIGURATIONS).size.toLong(), accepted.parts.getValue(BackupFiles.Kind.CONFIGURATIONS).bytes)
        f.files.discard(accepted.token)
        values[BackupFiles.Kind.CONFIGURATIONS] = (prefix + "x".repeat(MAX_BODY.toInt() - 2) + suffix).toByteArray()
        backupRejects<IOException> { f.candidate(values) }
    }

    @Test fun duplicateJsonKeysNullBodyAndMalformedUtf8CannotBeExported() = BackupFixture.use { f ->
        for (invalid in listOf("{\"entries\":[],\"entries\":[]}".toByteArray(),
            "{\"entries\":[{\"body\":null}]}".toByteArray(), byteArrayOf(0xff.toByte()),
            "{\"entries\":[{\"body\":\"\\uD800\"}]}".toByteArray(), "{} trailing".toByteArray())) {
            val values = BackupFixture.values().toMutableMap().apply { this[BackupFiles.Kind.CONFIGURATIONS] = invalid }
            backupRejects<Exception> { f.candidate(values) }
        }
    }

    @Test fun importCancellationOwnsInputAndDoesNotPublishCandidateOrTouchBusinessData() = BackupFixture.use { f ->
        f.old()
        val before = f.current()
        val bytes = archive(f, f.candidate())
        val lease = BackupLease()
        var closed = false
        val input = object : java.io.ByteArrayInputStream(bytes) {
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                val count = super.read(buffer, offset, length)
                lease.cancel()
                return count
            }
            override fun close() { closed = true; super.close() }
        }
        backupRejects<CancellationException> { f.files.prepareImport(input, BackupFiles.Operation(lease)) }
        assertTrue(closed)
        assertEquals(before, f.current())
        assertEquals(1, File(f.privateRoot, "candidates").list()!!.size) // Only the original export token.
    }

    @Test fun externalWriteAndCloseFailuresAreNotReportedAsSuccessAndDoNotDeleteCandidate() = BackupFixture.use { f ->
        val candidate = f.candidate()
        for (closeFailure in listOf(false, true)) {
            var closed = false
            val output = object : OutputStream() {
                override fun write(value: Int) { if (!closeFailure) throw IOException("injected provider write failure") }
                override fun close() { closed = true; if (closeFailure) throw IOException("injected provider close failure") }
            }
            backupRejects<IOException> { f.files.writeArchive(candidate.token, output, BackupFiles.Operation(BackupLease())) }
            assertTrue(closed)
            assertEquals(candidate, f.files.candidate(candidate.token))
        }
    }

    @Test fun forgedStaleAndMutatedCandidateTokensAreRejected() = BackupFixture.use { f ->
        val candidate = f.candidate()
        for (token in listOf("../configurations.json", UUID.randomUUID().toString(), "/data/file")) {
            backupRejects<IOException> { f.files.candidate(token) }
        }
        val part = File(f.privateRoot, "candidates/${candidate.token}/preferences.json")
        part.appendText(" ")
        backupRejects<IOException> {
            f.files.withPart(candidate.token, BackupFiles.Kind.PREFERENCES, BackupFiles.Operation(BackupLease())) { it.readBytes() }
        }
        f.files.discard(candidate.token)
        backupRejects<IOException> { f.files.candidate(candidate.token) }
    }
}
