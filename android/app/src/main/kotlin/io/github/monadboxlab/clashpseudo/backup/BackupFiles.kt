package io.github.monadboxlab.clashpseudo.backup

import io.github.monadboxlab.clashpseudo.app.ApplicationContract
import android.content.Context
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.FileDescriptor
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.CancellationException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executor
import java.util.concurrent.Executors

/** Fixed backup format and private candidates. Business model validation remains in Dart. */
class BackupFiles internal constructor(
    internal val stores: File,
    internal val privateRoot: File,
    internal val afterStep: (String) -> Unit = {},
    internal val sync: (FileDescriptor) -> Unit = { Os.fsync(it) },
    internal val platformStores: File = stores,
    private val openDirectory: (String) -> FileDescriptor = { path ->
        Os.open(path, OsConstants.O_RDONLY or OsConstants.O_NONBLOCK or OsConstants.O_NOFOLLOW, 0)
    },
) {
    enum class Kind(val fileName: String, val maxBytes: Long) {
        CONFIGURATIONS(ApplicationContract.BACKUP_CONFIGURATIONS_FILE, ApplicationContract.BACKUP_CONFIGURATIONS_JSON_BYTES.toLong()),
        OVERRIDES(ApplicationContract.BACKUP_OVERRIDES_FILE, ApplicationContract.BACKUP_OVERRIDES_JSON_BYTES.toLong()),
        PREFERENCES(ApplicationContract.BACKUP_PREFERENCES_FILE, ApplicationContract.BACKUP_PREFERENCES_JSON_BYTES.toLong()),
    }
    data class Fingerprint(val bytes: Long, val sha256: String, val crc32: Long)
    data class Candidate(val token: String, val createdAtMillis: Long, val parts: Map<Kind, Fingerprint>)

    class Operation(val owner: RestoreTransaction.Owner,
        private val clock: () -> Long = { SystemClock.elapsedRealtime() }) {
        private val started = clock()
        fun check() {
            owner.checkCurrent()
            if (Thread.currentThread().isInterrupted || clock() - started >= ApplicationContract.OPERATION_BACKUP_TIMEOUT_MS) {
                throw CancellationException("Backup operation expired")
            }
        }
    }

    internal class Record(val directory: File, val candidate: Candidate) {
        var retired = false
    }
    private val candidates = ConcurrentHashMap<String, Record>()
    val transaction: RestoreTransaction by lazy { RestoreTransaction(this) }
    /** File work is separate from the native network/Stop worker. */
    val ioExecutor: Executor by lazy {
        Executors.newSingleThreadExecutor { work ->
            Thread(work, "pseudo-storage-io").apply { isDaemon = true }
        }
    }

    /** Cold-process cleanup runs inside recovery, before any new file owner is admitted. */
    internal fun cleanupOrphans(work: File, core: File) {
        checkWorker()
        var failure: Exception? = null
        fun attempt(block: () -> Unit) {
            try { block() } catch (error: Exception) {
                if (failure == null) failure = error else if (failure !== error) failure.addSuppressed(error)
            }
        }
        attempt {
            val parent = File(privateRoot, "candidates")
            if (lstat(parent) != null) {
                ensureDirectory(parent)
                val children = parent.listFiles() ?: invalid("Cannot enumerate backup candidates: $parent")
                for (child in children) attempt {
                    if (!candidates.containsKey(child.name)) removePrivateDirectory(child)
                }
            }
        }
        for (kind in Kind.entries) attempt { removeRegular(File(stores, "${kind.fileName}.tmp")) }
        attempt { removeRegular(File(work.parentFile, "core-cleanup.json.tmp")) }
        attempt {
            val held = io.github.monadboxlab.clashpseudo.nativecore.CoreResourceGate(
                File(work.parentFile, "core-host.lock")).tryAcquire()
            held?.use {
                if (lstat(core) != null) {
                    ensureDirectory(core)
                    val children = core.listFiles() ?: invalid("Cannot enumerate Geo staging files: $core")
                    for (child in children) {
                        if (child.name.startsWith(".bundled-geo-") && child.name.endsWith(".tmp")) {
                            attempt { removeRegular(child) }
                        }
                    }
                }
            }
        }
        attempt {
            if (lstat(work) != null) {
                ensureDirectory(work)
                val children = work.listFiles() ?: invalid("Cannot enumerate run inputs: $work")
                for (child in children) {
                    if ((child.name.startsWith("run-input-") &&
                            (child.name.endsWith(".json") || child.name.endsWith(".json.tmp"))) ||
                        child.name == "system-input.json.tmp") {
                        attempt { removeRegular(child) }
                    }
                }
            }
        }
        failure?.let { throw it }
    }

    /** Capture raw files consistently; Dart validates the three business models. */
    fun capture(createdAtMillis: Long, expectedEpoch: Long, operation: Operation,
        openPart: (Kind) -> InputStream): Candidate = transaction.withStableStorage(expectedEpoch) {
        operation.check()
        require(createdAtMillis >= 0)
        prepareDirectory { directory ->
            val parts = linkedMapOf<Kind, Fingerprint>()
            var total = 0L
            for (kind in Kind.entries) {
                operation.check()
                parts[kind] = openPart(kind).use { input ->
                    writeNew(File(directory, kind.fileName), input, minOf(kind.maxBytes, MAX_EXPANDED - total), operation::check)
                }
                total += parts.getValue(kind).bytes
            }
            val manifest = makeManifest(createdAtMillis, parts)
            if (manifest.size > MAX_MANIFEST || total + manifest.size > MAX_EXPANDED) invalid("Expanded backup exceeds budget")
            writeNew(File(directory, MANIFEST), manifest.inputStream(), MAX_MANIFEST.toLong(), operation::check)
            writeZip(directory, operation)
            register(directory, createdAtMillis, parts)
        }
    }

    /** Only missing files use the defaults serialized by Dart. */
    fun captureStores(createdAtMillis: Long, expectedEpoch: Long, operation: Operation,
        defaults: Map<Kind, ByteArray>): Candidate = capture(createdAtMillis, expectedEpoch, operation) { kind ->
        val target = File(stores, kind.fileName)
        if (lstat(target) == null) defaults.getValue(kind).inputStream()
        else readFile(target) { it.inputStream() }
    }

    /** Own input through actual close; expand only the fixed SDK ZIP entries. */
    fun prepareImport(input: InputStream, operation: Operation): Candidate {
        var prepared: Candidate? = null
        try {
            return input.use { source ->
                operation.check()
                prepareDirectory { directory ->
                    writeNew(File(directory, ARCHIVE), source, MAX_ARCHIVE, operation::check)
                    val (created, parts) = readZip(directory, operation)
                    register(directory, created, parts).also { prepared = it }
                }
            }
        } catch (error: Throwable) {
            prepared?.let { candidate ->
                try { discard(candidate.token) } catch (cleanup: Throwable) { error.addSuppressed(cleanup) }
            }
            throw error
        }
    }

    /** Provider write/flush/close failures leave the external document in place. */
    fun writeArchive(token: String, output: OutputStream, operation: Operation) = output.use { destination ->
        withRecord(token) { record ->
            readFile(File(record.directory, ARCHIVE)) { path ->
                path.inputStream().use { source -> transfer(source, destination, MAX_ARCHIVE, operation::check) }
            }
            destination.flush()
        }
    }

    fun candidate(token: String): Candidate = withRecord(token) { it.candidate }

    fun candidateReadPaths(token: String): Map<String, String> = withRecord(token) { record ->
        Kind.entries.associate { kind ->
            val part = File(record.directory, kind.fileName)
            readFile(part) { }
            kind.fileName to part.absolutePath
        }
    }

    /** Worker cleanup waits for actual readers and installers to finish. */
    fun discard(token: String) {
        checkWorker()
        val record = candidates[token] ?: return
        synchronized(record) {
            if (record.retired) return
            removePrivateDirectory(record.directory)
            record.retired = true
            candidates.remove(token, record)
        }
    }

    internal fun <T> withRecord(token: String, block: (Record) -> T): T {
        checkWorker()
        if (!isToken(token)) invalid("Invalid backup token")
        val record = candidates[token] ?: invalid("Unknown backup token")
        return synchronized(record) {
            if (record.retired) invalid("Retired backup token")
            block(record)
        }
    }

    private fun register(directory: File, created: Long, parts: Map<Kind, Fingerprint>): Candidate {
        val candidate = Candidate(directory.name, created, parts.toMap())
        syncDirectory(directory)
        candidates[candidate.token] = Record(directory, candidate)
        return candidate
    }

    private fun <T> prepareDirectory(block: (File) -> T): T {
        ensureWorkspace()
        val parent = File(privateRoot, "candidates")
        ensureDirectory(parent)
        val directory = File(parent, UUID.randomUUID().toString())
        createDirectory(directory)
        return try { block(directory) } catch (error: Throwable) {
            candidates.remove(directory.name)?.retired = true
            try { removePrivateDirectory(directory) } catch (cleanup: Throwable) { error.addSuppressed(cleanup) }
            throw error
        }
    }

    internal fun ensureWorkspace() {
        checkWorker()
        ensureDirectory(privateRoot)
        ensureDirectory(stores)
        if (Os.lstat(privateRoot.path).st_dev != Os.lstat(stores.path).st_dev) invalid("Backup directories span filesystems")
    }

    internal fun writeNew(file: File, input: InputStream, limit: Long, check: () -> Unit): Fingerprint {
        var result: Fingerprint? = null
        writeFile(file) { output, descriptor ->
            result = transfer(input, output, limit, check)
            output.flush()
            check()
            sync(descriptor)
        }
        return checkNotNull(result)
    }

    internal fun writeFile(file: File, block: (OutputStream, FileDescriptor) -> Unit) {
        val descriptor = Os.open(file.path, OsConstants.O_WRONLY or OsConstants.O_CREAT or OsConstants.O_EXCL or
            OsConstants.O_NOFOLLOW, 0x180)
        val owned = try { ParcelFileDescriptor.dup(descriptor) } finally { Os.close(descriptor) }
        ParcelFileDescriptor.AutoCloseOutputStream(owned).use { stream -> block(stream, owned.fileDescriptor) }
    }

    internal fun <T> readFile(file: File, block: (File) -> T): T {
        if (!OsConstants.S_ISREG(Os.lstat(file.path).st_mode)) invalid("Backup source is not a regular file")
        return block(file)
    }

    internal fun fingerprint(file: File, limit: Long = Long.MAX_VALUE, check: () -> Unit = {}): Fingerprint =
        readFile(file) { path -> path.inputStream().use { transfer(it, DISCARD, limit, check) } }

    internal fun syncDirectory(directory: File) = pinDirectory(directory).use { sync(it.fileDescriptor) }

    internal fun pinDirectory(directory: File): ParcelFileDescriptor {
        val descriptor = openDirectory(directory.path)
        return try {
            if (!OsConstants.S_ISDIR(Os.fstat(descriptor).st_mode)) invalid("Backup path is not a directory")
            ParcelFileDescriptor.dup(descriptor)
        } finally { Os.close(descriptor) }
    }

    internal fun ensureDirectory(directory: File) {
        val existing = lstat(directory)
        if (existing == null) createDirectory(directory)
        else if (!OsConstants.S_ISDIR(existing.st_mode)) invalid("Backup path is not a directory")
    }

    internal fun createDirectory(directory: File) {
        Os.mkdir(directory.path, 0x1c0)
        syncDirectory(checkNotNull(directory.parentFile))
    }

    internal fun lstat(file: File) = try { Os.lstat(file.path) } catch (error: ErrnoException) {
        if (error.errno == OsConstants.ENOENT) null else throw error
    }

    internal fun removePrivateDirectory(directory: File) {
        if (!OsConstants.S_ISDIR(Os.lstat(directory.path).st_mode)) invalid("Backup path is not a directory")
        val names = directory.list() ?: invalid("Cannot enumerate backup material")
        for (name in names) {
            if (!OsConstants.S_ISREG(Os.lstat(File(directory, name).path).st_mode)) invalid("Unexpected linked backup material")
        }
        for (name in names) Os.remove(File(directory, name).path)
        syncDirectory(directory)
        Os.remove(directory.path)
        syncDirectory(checkNotNull(directory.parentFile))
    }

    internal fun rename(source: File, target: File) = Os.rename(source.path, target.path)

    internal fun removeRegular(file: File) {
        val stat = lstat(file) ?: return
        if (!OsConstants.S_ISREG(stat.st_mode)) invalid("Refusing to remove non-regular backup file")
        Os.remove(file.path)
        syncDirectory(checkNotNull(file.parentFile))
    }

    companion object {
        private val DISCARD = object : OutputStream() {
            override fun write(value: Int) {}
            override fun write(bytes: ByteArray, offset: Int, length: Int) {}
        }
        @Volatile private var instance: BackupFiles? = null
        @Synchronized fun get(context: Context): BackupFiles = instance ?: BackupFiles(
            File(context.filesDir.canonicalFile, "configurations"),
            File(context.noBackupFilesDir.canonicalFile, "backup"),
            platformStores = File(context.filesDir, "configurations"),
        ).also { instance = it }

        internal fun checkWorker() {
            check(Looper.myLooper() != Looper.getMainLooper()) { "Backup file operations require a worker" }
        }
        internal fun invalid(message: String): Nothing = throw java.io.IOException(message)
        internal fun isToken(value: String) = try { UUID.fromString(value).toString() == value } catch (_: IllegalArgumentException) { false }
    }
}
