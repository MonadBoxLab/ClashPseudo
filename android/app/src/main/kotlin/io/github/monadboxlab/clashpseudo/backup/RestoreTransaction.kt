package io.github.monadboxlab.clashpseudo.backup

import android.os.ParcelFileDescriptor
import android.system.Os
import android.system.OsConstants
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.IOException
import java.nio.channels.OverlappingFileLockException
import java.util.UUID
import java.util.concurrent.CancellationException
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.locks.ReentrantLock

/** One physical gate for all three business files, ordinary publication, recovery and full backup.
 * The host must also retain its unique business writer until the real native call has returned.
 */
class RestoreTransaction internal constructor(private val files: BackupFiles) {
    interface Owner {
        fun checkCurrent()
        /**
         * Use cancellation's arbitration to check identity and run the synchronous
         * block exactly once. Acquire the storage gate before entering this short
         * arbitration.
         */
        fun runIfCurrent(block: () -> Unit)
    }
    data class State(val ready: Boolean, val restoring: Boolean, val epoch: Long, val error: String? = null,
        val systemRestore: Boolean = false)
    data class Publication(val saved: Boolean, val durable: Boolean, val epoch: Long,
        val error: String? = null, val cause: Throwable? = null)
    data class Installation(val committed: Boolean?, val rolledBack: Boolean, val ready: Boolean,
        val epoch: Long, val error: String? = null, val cause: Throwable? = null)
    private val stateReference = AtomicReference(State(false, false, 0))
    private var state: State
        get() = stateReference.get()
        set(value) { stateReference.set(value) }
    private val gate = ReentrantLock()
    private val active get() = File(files.privateRoot, ACTIVE)

    fun snapshot(): State = state

    fun requireEpoch(expectedEpoch: Long) {
        val current = state
        if (!current.ready || current.restoring) throw IOException(current.error ?: "storageBusy")
        if (current.epoch != expectedEpoch) throw IOException("storageEpochChanged")
    }

    /** Worker only, before ANY consumer reads business files, including the system BackupAgent. */
    fun recover(): State = exclusive {
        if (state.restoring) throw IOException("storageBusy")
        state = State(false, true, state.epoch + 1)
        try {
            recoverLocked()
            state = state.copy(ready = true, restoring = false, error = null)
        } catch (error: Throwable) {
            closeGate()
            throw error
        }
        state
    }

    /** A synchronous, consistent snapshot for native reads and system backup. */
    fun <T> withStableStorage(expectedEpoch: Long, block: () -> T): T = exclusive {
        requireEpoch(expectedEpoch)
        block()
    }

    /**
     * Publish fixed same-directory kind.tmp to kind. fsync the large file before owner
     * admission and perform only rename inside the short owner block. A post-rename
     * failure retains saved=true.
     */
    fun publishStore(kind: BackupFiles.Kind, expectedEpoch: Long, owner: Owner): Publication {
        var saved = false
        return try {
            exclusive {
                requireEpoch(expectedEpoch)
                owner.checkCurrent()
                val temporary = File(files.stores, "${kind.fileName}.tmp")
                val target = File(files.stores, kind.fileName)
                var admitted = false
                files.pinDirectory(files.stores).use { directory ->
                    val base = "/proc/self/fd/${directory.fd}"
                    val descriptor = Os.open("$base/${temporary.name}", OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or
                        OsConstants.O_NONBLOCK, 0)
                    val staged = try {
                        Os.fstat(descriptor).also {
                            if (!OsConstants.S_ISREG(it.st_mode)) throw IOException("Store staging file is not regular")
                            files.sync(descriptor)
                        }
                    } finally { Os.close(descriptor) }
                    owner.checkCurrent()
                    try {
                        owner.runIfCurrent {
                            owner.checkCurrent()
                            requireEpoch(expectedEpoch)
                            checkTarget(target)
                            val now = Os.lstat("$base/${temporary.name}")
                            if (!OsConstants.S_ISREG(now.st_mode) || now.st_dev != staged.st_dev || now.st_ino != staged.st_ino) {
                                throw IOException("Store staging inode changed")
                            }
                            admitted = true
                            Os.rename("$base/${temporary.name}", "$base/${kind.fileName}")
                            saved = true
                        }
                    } catch (error: Exception) {
                        if (!saved) throw error
                        return@exclusive Publication(true, false, expectedEpoch, "publishedAdmissionFailed", error)
                    }
                    check(admitted && saved) { "Store admission was not executed" }
                    try {
                        files.sync(directory.fileDescriptor)
                        Publication(true, true, expectedEpoch)
                    } catch (error: Exception) {
                        Publication(true, false, expectedEpoch, "publishedDirectorySyncFailed", error)
                    }
                }
            }
        } catch (error: Exception) {
            if (!saved) throw error
            // Lock/channel/descriptor close can fail after the real rename as well.
            closeGate(expectedEpoch)
            Publication(true, false, expectedEpoch, "publishedCleanupFailed", error)
        }
    }

    /**
     * Require complete Dart validation, overwrite confirmation, old-network release
     * and durable PREPARED before admission into the committed install phase.
     */
    fun install(token: String, expectedEpoch: Long, operation: BackupFiles.Operation): Installation {
        var completed: Installation? = null
        return try {
            exclusive { installLocked(token, expectedEpoch, operation).also { completed = it } }
        } catch (error: Exception) {
            val actual = completed ?: throw error
            closeGate(actual.epoch)
            actual.copy(ready = false, error = "storageCloseFailed", cause = error)
        }
    }

    private fun installLocked(token: String, expectedEpoch: Long, operation: BackupFiles.Operation): Installation {
        requireEpoch(expectedEpoch)
        operation.check()
        return files.withRecord(token) { record ->
            operation.check()
            if (files.lstat(active) != null) throw IOException("Unrecovered restore transaction")
            state = State(false, true, state.epoch + 1)
            var admitted = false
            var commitPublished = false
            try {
                val journal = prepare(record, operation)
                operation.check()
                operation.owner.runIfCurrent {
                    operation.check()
                    admitted = true
                }
                check(admitted) { "Restore admission was not executed" }
                // Installation completes after this linearization point; Stop remains
                // available for networking.
                for (kind in BackupFiles.Kind.entries) {
                    checkTarget(File(files.stores, kind.fileName))
                    files.rename(File(active, "new-${kind.ordinal}"), File(files.stores, kind.fileName))
                    step("commit.rename.${kind.ordinal}")
                    files.syncDirectory(files.stores)
                    step("commit.directory.${kind.ordinal}")
                    files.syncDirectory(active)
                    step("commit.sourceDirectory.${kind.ordinal}")
                }
                marker(COMMITTED, journal)
                commitPublished = true
                retireActive()
                state = state.copy(ready = true, restoring = false, error = null)
                Installation(true, false, true, state.epoch)
            } catch (error: Exception) {
                // An I/O error can occur after rename or marker publication. Inspect real durable state.
                try {
                    val outcome = recoverLocked()
                    val committed = commitPublished || outcome == Outcome.COMMITTED
                    state = state.copy(ready = true, restoring = false, error = null)
                    Installation(committed, outcome == Outcome.ROLLED_BACK,
                        true, state.epoch, if (committed) "committedCleanupFailed"
                        else if (error is CancellationException) "restoreCancelled"
                        else if (admitted) "restoreRolledBack" else "restorePreparationFailed", error)
                } catch (recovery: Throwable) {
                    closeGate()
                    if (recovery !== error) error.addSuppressed(recovery)
                    Installation(if (commitPublished) true else null, false, false, state.epoch, "storageRecoveryFailed", error)
                }
            } catch (fatal: Throwable) {
                // Process interruption/OOM/fault-injection: leave journal and immutable rollback copies.
                closeGate()
                throw fatal
            }
        }
    }

    /**
     * SDK system restore replaces individual files. Retire the local journal before
     * the first replacement and keep consumers closed through restore.
     */
    fun beginSystemRestore(): Long = exclusive {
        if (state.restoring) throw IOException("storageBusy")
        state = State(false, true, state.epoch + 1, systemRestore = true)
        val epoch = state.epoch
        try {
            recoverLocked()
            requireSystemRestore(epoch)
            epoch
        } catch (error: Throwable) {
            closeGate(epoch, "systemRestoreFailed")
            throw error
        }
    }

    /**
     * Restore to the canonical target used by SDK XML eligibility. Check namespace and
     * reported length before and after. Failure may leave this individual file partly
     * replaced.
     */
    fun systemRestoreFile(expectedEpoch: Long, kind: BackupFiles.Kind, size: Long,
        restore: (File) -> Unit) = exclusive {
        require(size >= 0) { "Invalid system restore size" }
        requireSystemRestore(expectedEpoch)
        try {
            files.pinDirectory(files.stores).use { directory ->
                val original = Os.fstat(directory.fileDescriptor)
                val target = File(files.stores, kind.fileName)
                checkTarget(target)
                // SDK restore truncates the existing inode, so require a single link
                // before writing.
                if ((files.lstat(target)?.st_nlink ?: 0L) > 1L) throw IOException("System restore target has multiple links")
                restore(target)
                requireSystemRestore(expectedEpoch)
                files.pinDirectory(files.stores).use { current ->
                    val now = Os.fstat(current.fileDescriptor)
                    if (now.st_dev != original.st_dev || now.st_ino != original.st_ino) throw IOException("System restore directory changed")
                }
                files.readFile(target) { opened ->
                    opened.inputStream().use { input ->
                        if (Os.fstat(input.fd).st_size != size) throw IOException("Incomplete system restore file")
                        files.sync(input.fd)
                    }
                }
                files.syncDirectory(files.stores)
            }
        } catch (error: Throwable) {
            closeGate(expectedEpoch, "systemRestoreFailed")
            throw error
        }
    }

    fun finishSystemRestore(expectedEpoch: Long): State = exclusive {
        val before = requireSystemRestore(expectedEpoch)
        try {
            for (kind in BackupFiles.Kind.entries) {
                val target = File(files.stores, kind.fileName)
                checkTarget(target)
                if (files.lstat(target) != null) files.readFile(target) { opened ->
                    opened.inputStream().use { files.sync(it.fd) }
                }
            }
            files.syncDirectory(files.stores)
            val completed = before.copy(ready = true, restoring = false, epoch = before.epoch + 1,
                error = null, systemRestore = false)
            if (!stateReference.compareAndSet(before, completed)) throw IOException("systemRestoreIncomplete")
            completed
        } catch (error: Throwable) {
            closeGate(expectedEpoch, "systemRestoreFailed")
            throw error
        }
    }

    /**
     * Main-thread destruction only signals invalidation. The active SDK callback holds
     * the storage gate through its actual I/O return.
     */
    fun abandonSystemRestore(expectedEpoch: Long) {
        while (true) {
            val current = stateReference.get()
            if (!current.systemRestore || current.epoch != expectedEpoch) return
            val closed = current.copy(ready = false, restoring = false,
                error = current.error ?: "systemRestoreIncomplete", systemRestore = false)
            if (stateReference.compareAndSet(current, closed)) return
        }
    }

    private fun requireSystemRestore(expectedEpoch: Long): State {
        val current = state
        if (!current.systemRestore || !current.restoring || current.ready || current.epoch != expectedEpoch) {
            throw IOException(current.error ?: "systemRestoreIncomplete")
        }
        return current
    }

    private data class Part(val old: BackupFiles.Fingerprint?, val fresh: BackupFiles.Fingerprint)
    private data class Journal(val id: String, val parts: List<Part>, val bytes: ByteArray)
    private enum class Outcome { NONE, ROLLED_BACK, COMMITTED }

    private fun prepare(record: BackupFiles.Record, operation: BackupFiles.Operation): Journal {
        files.createDirectory(active)
        step("prepare.directory")
        // Reject linked/directory targets before any formal content can be touched.
        BackupFiles.Kind.entries.forEach { checkTarget(File(files.stores, it.fileName)) }
        val parts = mutableListOf<Part>()
        for (kind in BackupFiles.Kind.entries) {
            val fresh = files.readFile(File(record.directory, kind.fileName)) { source ->
                source.inputStream().use { input ->
                    files.writeNew(File(active, "new-${kind.ordinal}"), input, kind.maxBytes, operation::check)
                }
            }
            if (fresh != record.candidate.parts.getValue(kind)) throw IOException("Restore candidate changed")
            step("prepare.new.${kind.ordinal}")
            val target = File(files.stores, kind.fileName)
            val previous = if (files.lstat(target) == null) null else files.readFile(target) { source ->
                source.inputStream().use { input ->
                    // Preserve damaged or large old Stores as complete raw bytes.
                    files.writeNew(File(active, "old-${kind.ordinal}"), input, Long.MAX_VALUE, operation::check)
                }
            }
            step("prepare.old.${kind.ordinal}")
            parts += Part(previous, fresh)
        }
        files.syncDirectory(active)
        step("prepare.materialsSynced")
        val id = UUID.randomUUID().toString()
        val bytes = ByteArrayOutputStream().also { output ->
            DataOutputStream(output).use { data ->
                data.writeInt(JOURNAL_MAGIC)
                data.writeUTF(id)
                for ((index, part) in parts.withIndex()) {
                    data.writeUTF(BackupFiles.Kind.entries[index].fileName)
                    data.writeBoolean(part.old != null)
                    part.old?.let { writeFingerprint(data, it) }
                    writeFingerprint(data, part.fresh)
                }
            }
        }.toByteArray()
        val journal = Journal(id, parts, bytes)
        files.writeNew(File(active, "$JOURNAL.tmp"), bytes.inputStream(), MAX_JOURNAL.toLong(), operation::check)
        step("prepare.journalFile")
        files.rename(File(active, "$JOURNAL.tmp"), File(active, JOURNAL))
        step("prepare.journalRename")
        files.syncDirectory(active)
        step("prepare.journalDirectory")
        marker(PREPARED, journal)
        return journal
    }

    private fun marker(name: String, journal: Journal) {
        val body = markerBytes(journal)
        files.writeNew(File(active, "$name.tmp"), body.inputStream(), 128, {})
        step("$name.file")
        files.rename(File(active, "$name.tmp"), File(active, name))
        step("$name.rename")
        files.syncDirectory(active)
        step("$name.directory")
    }

    private fun recoverLocked(): Outcome {
        cleanRetired()
        val activeStat = files.lstat(active) ?: return Outcome.NONE
        if (!OsConstants.S_ISDIR(activeStat.st_mode)) throw IOException("Linked restore transaction directory")
        files.pinDirectory(active).close()
        checkMaterialNames()
        val prepared = files.lstat(File(active, PREPARED)) != null
        val committed = files.lstat(File(active, COMMITTED)) != null
        if (committed && !prepared) throw IOException("COMMITTED without PREPARED")
        val journal = if (files.lstat(File(active, JOURNAL)) == null) null else readJournal()
        if (prepared && journal == null) throw IOException("Missing restore journal")
        if (journal == null) {
            // Formal files remain unchanged until atomic PREPARED journal publication.
            retireActive()
            return Outcome.NONE
        }
        if (prepared) verifyMarker(PREPARED, journal)
        if (committed) verifyMarker(COMMITTED, journal)
        if (!prepared) {
            for ((index, part) in journal.parts.withIndex()) {
                verifyFile(File(active, "new-$index"), part.fresh)
                part.old?.let { verifyFile(File(active, "old-$index"), it) }
            }
            retireActive()
            return Outcome.NONE
        }
        if (committed) {
            for ((index, part) in journal.parts.withIndex()) {
                verifyFile(File(files.stores, BackupFiles.Kind.entries[index].fileName), part.fresh)
            }
            // Also complete a marker sync that may have failed after its rename in the old process.
            files.syncDirectory(active)
            step("recovery.committedSynced")
            retireActive()
            return Outcome.COMMITTED
        }
        // Validate ALL rollback sources and destinations before performing the first rollback write.
        for ((index, part) in journal.parts.withIndex()) {
            part.old?.let { verifyFile(File(active, "old-$index"), it) }
            checkTarget(File(files.stores, BackupFiles.Kind.entries[index].fileName))
        }
        for ((index, part) in journal.parts.withIndex()) {
            val target = File(files.stores, BackupFiles.Kind.entries[index].fileName)
            val temporary = File(files.stores, ".restore-${journal.id}-$index.tmp")
            if (part.old == null) {
                files.removeRegular(target)
                step("rollback.absent.$index")
            } else {
                // Copy from the retained old snapshot so interrupted rollback can
                // repeat with identical bytes.
                files.removeRegular(temporary)
                val actual = files.readFile(File(active, "old-$index")) { source ->
                    source.inputStream().use { input -> files.writeNew(temporary, input, Long.MAX_VALUE, {}) }
                }
                if (!sameBytes(actual, part.old)) throw IOException("Rollback copy checksum mismatch")
                step("rollback.copy.$index")
                files.rename(temporary, target)
                step("rollback.rename.$index")
                files.syncDirectory(files.stores)
                step("rollback.directory.$index")
            }
        }
        // Only after the whole old state is installed may the transaction be retired and cleaned.
        retireActive()
        return Outcome.ROLLED_BACK
    }

    private fun readJournal(): Journal {
        val bytes = files.readFile(File(active, JOURNAL)) { file ->
            file.inputStream().use { input ->
                val output = ByteArrayOutputStream()
                transfer(input, output, MAX_JOURNAL.toLong(), {})
                output.toByteArray()
            }
        }
        return DataInputStream(ByteArrayInputStream(bytes)).use { input ->
            if (input.readInt() != JOURNAL_MAGIC) throw IOException("Invalid restore journal version")
            val id = input.readUTF()
            if (!BackupFiles.isToken(id)) throw IOException("Invalid restore identity")
            val parts = BackupFiles.Kind.entries.map { kind ->
                if (input.readUTF() != kind.fileName) throw IOException("Invalid restore journal part")
                val previous = if (input.readBoolean()) readFingerprint(input) else null
                val fresh = readFingerprint(input)
                if (fresh.bytes > kind.maxBytes) throw IOException("Invalid new restore size")
                Part(previous, fresh)
            }
            if (input.read() != -1) throw IOException("Trailing restore journal bytes")
            Journal(id, parts, bytes)
        }
    }

    private fun verifyMarker(name: String, journal: Journal) {
        val expected = markerBytes(journal)
        val actual = files.fingerprint(File(active, name), 128)
        val hash = java.security.MessageDigest.getInstance("SHA-256").digest(expected)
        if (actual.bytes != expected.size.toLong() || actual.sha256 != hex(hash)) {
            throw IOException("Invalid restore $name marker")
        }
    }

    private fun markerBytes(journal: Journal): ByteArray =
        ("clash-pseudo-restore-1\n" + hex(java.security.MessageDigest.getInstance("SHA-256")
            .digest(journal.bytes)) + "\n").toByteArray(Charsets.US_ASCII)

    private fun verifyFile(file: File, expected: BackupFiles.Fingerprint) {
        val actual = files.fingerprint(file, expected.bytes)
        if (!sameBytes(actual, expected)) throw IOException("Missing or damaged restore material")
    }

    private fun checkTarget(file: File) {
        val stat = files.lstat(file)
        if (stat != null && !OsConstants.S_ISREG(stat.st_mode)) throw IOException("Business target is not a regular file")
    }

    private fun checkMaterialNames() {
        val allowed = setOf(JOURNAL, "$JOURNAL.tmp", PREPARED, "$PREPARED.tmp", COMMITTED, "$COMMITTED.tmp") +
            BackupFiles.Kind.entries.flatMap { listOf("new-${it.ordinal}", "old-${it.ordinal}") }
        files.pinDirectory(active).use { opened ->
            val directory = File("/proc/self/fd/${opened.fd}")
            for (name in directory.list() ?: throw IOException("Cannot enumerate restore material")) {
                if (name !in allowed || !OsConstants.S_ISREG(Os.lstat(File(directory, name).path).st_mode)) {
                    throw IOException("Unexpected restore material")
                }
            }
        }
    }

    private fun retireActive() {
        val retired = File(files.privateRoot, "retired-${UUID.randomUUID()}")
        files.rename(active, retired)
        step("retire.rename")
        files.syncDirectory(files.privateRoot)
        step("retire.directory")
        files.removePrivateDirectory(retired)
        step("retire.cleaned")
    }

    private fun cleanRetired() {
        files.pinDirectory(files.privateRoot).use { opened ->
            val names = File("/proc/self/fd/${opened.fd}").list() ?: throw IOException("Cannot enumerate restore workspace")
            for (name in names) {
                if (name.startsWith("retired-") && BackupFiles.isToken(name.removePrefix("retired-"))) {
                    files.removePrivateDirectory(File(files.privateRoot, name))
                    step("recovery.retiredCleaned")
                }
            }
        }
    }

    private fun closeGate(expectedEpoch: Long? = null, reason: String = "storageRecoveryFailed") {
        while (true) {
            val current = stateReference.get()
            if (expectedEpoch != null && current.epoch != expectedEpoch) return
            val closed = current.copy(ready = false, restoring = false,
                error = current.error ?: reason, systemRestore = false)
            if (stateReference.compareAndSet(current, closed)) return
        }
    }
    private fun step(name: String) = files.afterStep(name)

    /**
     * All entry points use the shared JVM gate and physical lock through actual
     * execution.
     */
    private fun <T> exclusive(block: () -> T): T {
        BackupFiles.checkWorker()
        if (!gate.tryLock()) throw IOException("storageBusy")
        try {
            try { files.ensureWorkspace() } catch (error: Throwable) { closeGate(); throw error }
            files.pinDirectory(files.privateRoot).use { root ->
                val raw = Os.open("/proc/self/fd/${root.fd}/storage.lock", OsConstants.O_RDWR or
                    OsConstants.O_CREAT or OsConstants.O_NOFOLLOW, 0x180)
                val owned = try {
                    if (!OsConstants.S_ISREG(Os.fstat(raw).st_mode)) throw IOException("Storage lock is not regular")
                    ParcelFileDescriptor.dup(raw)
                } finally { Os.close(raw) }
                return owned.use { descriptor ->
                    ParcelFileDescriptor.AutoCloseOutputStream(descriptor).use { stream ->
                        val lock = try { stream.channel.tryLock() } catch (_: OverlappingFileLockException) { null }
                            ?: throw IOException("storageBusy")
                        lock.use { block() }
                    }
                }
            }
        } finally { gate.unlock() }
    }

    companion object {
        private const val ACTIVE = "restore-active"
        private const val JOURNAL = "journal.bin"
        private const val PREPARED = "PREPARED"
        private const val COMMITTED = "COMMITTED"
        private const val JOURNAL_MAGIC = 0x43505231 // CPR1; internal mechanical log, not a business schema.
        private const val MAX_JOURNAL = 4096
        private fun sameBytes(a: BackupFiles.Fingerprint, b: BackupFiles.Fingerprint) = a.bytes == b.bytes && a.sha256 == b.sha256
        private fun writeFingerprint(output: DataOutputStream, value: BackupFiles.Fingerprint) {
            output.writeLong(value.bytes)
            output.writeUTF(value.sha256)
        }
        private fun readFingerprint(input: DataInputStream): BackupFiles.Fingerprint {
            val size = input.readLong()
            val hash = input.readUTF()
            if (size < 0 || !Regex("[0-9a-f]{64}").matches(hash)) throw IOException("Invalid restore fingerprint")
            return BackupFiles.Fingerprint(size, hash, 0)
        }
    }
}
