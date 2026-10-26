package io.github.monadboxlab.clashpseudo.backup

import io.github.monadboxlab.clashpseudo.app.ApplicationContract
import android.content.Context
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileDescriptor
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.CancellationException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.zip.ZipEntry
import java.util.zip.ZipFile

/** Fixed backup format and private candidates. Business model validation remains in Dart. */
class BackupFiles internal constructor(
    internal val stores: File,
    internal val privateRoot: File,
    internal val afterStep: (String) -> Unit = {},
    internal val sync: (FileDescriptor) -> Unit = { Os.fsync(it) },
    internal val platformStores: File = stores,
    private val trustedRoots: List<File> = listOf(checkNotNull(stores.parentFile), checkNotNull(privateRoot.parentFile)),
    private val openDirectory: (String) -> FileDescriptor = { path ->
        Os.open(path, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or OsConstants.O_NONBLOCK, 0)
    },
) {
    enum class Kind(val fileName: String, val maxBytes: Long) {
        CONFIGURATIONS(ApplicationContract.BACKUP_CONFIGURATIONS_FILE, ApplicationContract.BACKUP_CONFIGURATIONS_JSON_BYTES.toLong()),
        OVERRIDES(ApplicationContract.BACKUP_OVERRIDES_FILE, ApplicationContract.BACKUP_OVERRIDES_JSON_BYTES.toLong()),
        PREFERENCES(ApplicationContract.BACKUP_PREFERENCES_FILE, ApplicationContract.BACKUP_PREFERENCES_JSON_BYTES.toLong()),
    }
    data class Fingerprint(val bytes: Long, val sha256: String, val crc32: Long)
    data class Structure(val nodes: Int, val depth: Int, val configurations: Int, val overrides: Int)
    data class Candidate(val token: String, val createdAtMillis: Long,
        val parts: Map<Kind, Fingerprint>, val structure: Structure)

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

    internal class Record(val directory: File, val candidate: Candidate, val archive: Fingerprint) {
        var retired = false
    }
    private val candidates = ConcurrentHashMap<String, Record>()
    val transaction: RestoreTransaction by lazy { RestoreTransaction(this) }
    /**
     * One lazy, singleton-owned file-I/O lane, separate from the native network/Stop
     * worker. BackupAgent Binder callbacks acquire the shared transaction gate
     * directly.
     */
    val ioExecutor: Executor by lazy {
        Executors.newSingleThreadExecutor { work ->
            Thread(work, "pseudo-storage-io").apply { isDaemon = true }
        }
    }

    /**
     * Capture a consistent three-part raw snapshot under the physical storage gate,
     * including Dart-serialized defaults. SDK admission precedes complete Dart model
     * validation.
     */
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
            val structure = inspectParts(directory, operation)
            val manifest = makeManifest(createdAtMillis, parts)
            if (manifest.size > MAX_MANIFEST || total + manifest.size > MAX_EXPANDED) invalid("Expanded backup exceeds budget")
            writeNew(File(directory, MANIFEST), manifest.inputStream(), MAX_MANIFEST.toLong(), operation::check)
            val archive = writeZip(directory, operation)
            // Exercise exactly the same central-directory admission used for imported archives.
            readFile(File(directory, ARCHIVE)) { opened -> ZipLayout.inspect(opened) }
            register(directory, createdAtMillis, parts, structure, archive)
        }
    }

    /** Capture the current stores using defaults serialized by Dart. */
    fun captureStores(createdAtMillis: Long, expectedEpoch: Long, operation: Operation,
        defaults: Map<Kind, ByteArray>): Candidate = capture(createdAtMillis, expectedEpoch, operation) { kind ->
        val target = File(stores, kind.fileName)
        if (lstat(target) == null) defaults.getValue(kind).inputStream()
        else {
            // The returned stream owns its open file description. Close it if pin
            // closure fails before delivery.
            var stream: InputStream? = null
            try {
                readFile(target) { stream = it.inputStream() }
                checkNotNull(stream)
            } catch (error: Throwable) {
                try { stream?.close() } catch (cleanup: Throwable) { error.addSuppressed(cleanup) }
                throw error
            }
        }
    }

    /** Owns/closes input, checks actual compressed bytes, then fully verifies and expands fixed entries. */
    fun prepareImport(input: InputStream, operation: Operation): Candidate {
        var prepared: Candidate? = null
        try {
            return input.use { source ->
                operation.check()
                prepareDirectory { directory ->
                    val archive = writeNew(File(directory, ARCHIVE), source, MAX_ARCHIVE, operation::check)
                    readFile(File(directory, ARCHIVE)) { opened ->
                        val layout = ZipLayout.inspect(opened)
                        ZipFile(opened).use { zip ->
                            val entries = linkedMapOf<String, ZipEntry>()
                            val enumeration = zip.entries()
                            while (enumeration.hasMoreElements()) {
                                val entry = enumeration.nextElement()
                                if (entries.put(entry.name, entry) != null) invalid("Duplicate ZIP entry")
                                val declared = layout.getValue(entry.name)
                                if (entry.isDirectory || entry.size != declared.size || entry.compressedSize != declared.compressed ||
                                    entry.crc != declared.crc || entry.method != declared.method) invalid("ZIP directory disagreement")
                            }
                            if (entries.keys != ENTRY_NAMES) invalid("Incomplete ZIP entries")
                            val manifestEntry = entries.getValue(MANIFEST)
                            val manifestBytes = ByteArrayOutputStream()
                            val manifestHash = zip.getInputStream(manifestEntry).use { stream ->
                                transfer(stream, manifestBytes, MAX_MANIFEST.toLong(), operation::check)
                            }
                            checkEntry(manifestHash, manifestEntry)
                            val metadata = parseManifest(manifestBytes.toByteArray())
                            var total = manifestHash.bytes
                            val parts = linkedMapOf<Kind, Fingerprint>()
                            for (kind in Kind.entries) {
                                operation.check()
                                val entry = entries.getValue(kind.fileName)
                                val part = zip.getInputStream(entry).use { stream ->
                                    writeNew(File(directory, kind.fileName), stream,
                                        minOf(kind.maxBytes, MAX_EXPANDED - total), operation::check)
                                }
                                checkEntry(part, entry)
                                val expected = metadata.second.getValue(kind)
                                if (part.bytes != expected.bytes || part.sha256 != expected.sha256) invalid("Backup manifest checksum mismatch")
                                total += part.bytes
                                parts[kind] = part
                            }
                            writeNew(File(directory, MANIFEST), manifestBytes.toByteArray().inputStream(),
                                MAX_MANIFEST.toLong(), operation::check)
                            val structure = inspectParts(directory, operation)
                            register(directory, metadata.first, parts, structure, archive).also { prepared = it }
                        }
                    }
                }
            }
        } catch (error: Throwable) {
            // Registration cleanup owns the candidate if input closure fails before
            // handoff.
            prepared?.let { candidate ->
                try { discard(candidate.token) } catch (cleanup: Throwable) { error.addSuppressed(cleanup) }
            }
            throw error
        }
    }

    /**
     * Report external write and close results independently; preserve the provider's
     * document on failure.
     */
    fun writeArchive(token: String, output: OutputStream, operation: Operation) = output.use { destination ->
        withRecord(token) { record ->
            readFile(File(record.directory, ARCHIVE)) { path ->
                path.inputStream().use { source ->
                    val actual = transfer(source, destination, MAX_ARCHIVE, operation::check)
                    if (actual != record.archive) invalid("Private backup archive changed")
                }
            }
            destination.flush()
            operation.check()
        }
    }

    /**
     * The trusted host identifies a registered part by token and kind. Complete Dart
     * model validation before install, then drain and check on return.
     */
    fun <T> withPart(token: String, kind: Kind, operation: Operation, consume: (InputStream) -> T): T =
        withRecord(token) { record ->
            readFile(File(record.directory, kind.fileName)) { opened ->
                opened.inputStream().use { input ->
                    val checked = CountingInput(input, kind.maxBytes, operation::check)
                    val result = consume(checked)
                    val buffer = ByteArray(BUFFER)
                    while (checked.read(buffer) != -1) operation.check()
                    val actual = checked.fingerprint()
                    if (actual != record.candidate.parts.getValue(kind)) invalid("Private backup part changed")
                    result
                }
            }
        }

    fun candidate(token: String): Candidate = withRecord(token) { it.candidate }

    /**
     * Registered candidates use fixed basenames. Retain the token through actual Dart
     * reads and recheck original hashes at install.
     */
    fun candidateReadPaths(token: String): Map<String, String> = withRecord(token) { record ->
        Kind.entries.associate { kind ->
            val part = File(record.directory, kind.fileName)
            readFile(part) { /* Verify NOFOLLOW regular-file admission before exposing this fixed path. */ }
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

    private fun register(directory: File, created: Long, parts: Map<Kind, Fingerprint>,
        structure: Structure, archive: Fingerprint): Candidate {
        val candidate = Candidate(directory.name, created, parts.toMap(), structure)
        syncDirectory(directory)
        candidates[candidate.token] = Record(directory, candidate, archive)
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
        // A restore must remain on the same filesystem as the three business stores.
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
        pinDirectory(checkNotNull(file.parentFile)).use { parent ->
            val path = "/proc/self/fd/${parent.fd}/${file.name}"
            val descriptor = Os.open(path, OsConstants.O_WRONLY or OsConstants.O_CREAT or OsConstants.O_EXCL or
                OsConstants.O_NOFOLLOW, 0x180)
            val owned = try { ParcelFileDescriptor.dup(descriptor) } finally { Os.close(descriptor) }
            owned.use { handle ->
                ParcelFileDescriptor.AutoCloseOutputStream(handle).use { stream -> block(stream, handle.fileDescriptor) }
            }
        }
    }

    internal fun <T> readFile(file: File, block: (File) -> T): T {
        pinDirectory(checkNotNull(file.parentFile)).use { parent ->
            val descriptor = Os.open("/proc/self/fd/${parent.fd}/${file.name}",
                OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or OsConstants.O_NONBLOCK, 0)
            val owned = try {
                if (!OsConstants.S_ISREG(Os.fstat(descriptor).st_mode)) invalid("Backup source is not a regular file")
                ParcelFileDescriptor.dup(descriptor)
            } finally { Os.close(descriptor) }
            return owned.use { block(File("/proc/self/fd/${it.fd}")) }
        }
    }

    internal fun fingerprint(file: File, limit: Long = Long.MAX_VALUE, check: () -> Unit = {}): Fingerprint =
        readFile(file) { path -> path.inputStream().use { transfer(it, DISCARD, limit, check) } }

    internal fun syncDirectory(directory: File) = pinDirectory(directory).use { sync(it.fileDescriptor) }

    internal fun pinDirectory(directory: File): ParcelFileDescriptor {
        require(directory.isAbsolute)
        require(directory.path.split('/').none { it == "." || it == ".." })
        // Start from the SDK canonical private root; Android sandbox traversal and
        // read-open permissions differ for system ancestors.
        val anchor = trustedRoots.filter { root ->
            root.isAbsolute && root.path != "/" &&
                (directory.path == root.path || directory.path.startsWith(root.path + "/"))
        }.maxByOrNull { it.path.length } ?: invalid("Backup directory is outside trusted private roots")
        require(anchor.path.split('/').none { it == "." || it == ".." })
        val parts = directory.path.removePrefix(anchor.path).split('/').filter { it.isNotEmpty() }
        fun open(path: String): ParcelFileDescriptor {
            val descriptor = openDirectory(path)
            return try {
                if (!OsConstants.S_ISDIR(Os.fstat(descriptor).st_mode)) invalid("Backup ancestor is not a directory")
                ParcelFileDescriptor.dup(descriptor)
            } finally { Os.close(descriptor) }
        }
        var current = open(anchor.path)
        try {
            for (part in parts) {
                val next = open("/proc/self/fd/${current.fd}/$part")
                val previous = current
                current = next
                previous.close()
            }
            return current
        } catch (error: Throwable) {
            try { current.close() } catch (cleanup: Throwable) { error.addSuppressed(cleanup) }
            throw error
        }
    }

    internal fun ensureDirectory(directory: File) {
        val existing = lstat(directory)
        if (existing == null) createDirectory(directory)
        else pinDirectory(directory).close()
    }

    internal fun createDirectory(directory: File) {
        pinDirectory(checkNotNull(directory.parentFile)).use { parent ->
            Os.mkdir("/proc/self/fd/${parent.fd}/${directory.name}", 0x1c0) // 0700
            sync(parent.fileDescriptor)
        }
    }

    internal fun lstat(file: File) = try { Os.lstat(file.path) } catch (error: ErrnoException) {
        if (error.errno == OsConstants.ENOENT) null else throw error
    }

    internal fun removePrivateDirectory(directory: File) {
        // Accept only the fixed, flat candidate and transaction directories.
        pinDirectory(directory).use { opened ->
            val base = File("/proc/self/fd/${opened.fd}")
            val names = base.list() ?: invalid("Cannot enumerate backup material")
            for (name in names) {
                val file = File(base, name)
                if (!OsConstants.S_ISREG(Os.lstat(file.path).st_mode)) invalid("Unexpected linked backup material")
            }
            for (name in names) Os.remove(File(base, name).path)
            sync(opened.fileDescriptor)
        }
        pinDirectory(checkNotNull(directory.parentFile)).use { parent ->
            Os.remove("/proc/self/fd/${parent.fd}/${directory.name}")
            sync(parent.fileDescriptor)
        }
    }

    internal fun rename(source: File, target: File) {
        pinDirectory(checkNotNull(source.parentFile)).use { from ->
            pinDirectory(checkNotNull(target.parentFile)).use { to ->
                Os.rename("/proc/self/fd/${from.fd}/${source.name}", "/proc/self/fd/${to.fd}/${target.name}")
            }
        }
    }

    internal fun removeRegular(file: File) {
        pinDirectory(checkNotNull(file.parentFile)).use { parent ->
            val path = "/proc/self/fd/${parent.fd}/${file.name}"
            val stat = try { Os.lstat(path) } catch (error: ErrnoException) {
                if (error.errno == OsConstants.ENOENT) null else throw error
            }
            if (stat != null) {
                if (!OsConstants.S_ISREG(stat.st_mode)) invalid("Refusing to remove non-regular backup file")
                Os.remove(path)
                sync(parent.fileDescriptor)
            }
        }
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
            trustedRoots = listOf(context.filesDir.canonicalFile, context.noBackupFilesDir.canonicalFile),
        ).also { instance = it }

        internal fun checkWorker() {
            check(Looper.myLooper() != Looper.getMainLooper()) { "Backup file operations require a worker" }
        }
        internal fun invalid(message: String): Nothing = throw IOException(message)
        internal fun isToken(value: String) = try { UUID.fromString(value).toString() == value } catch (_: IllegalArgumentException) { false }
    }
}
