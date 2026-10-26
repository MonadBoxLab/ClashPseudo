package io.github.monadboxlab.clashpseudo.nativecore

import android.content.Context
import android.content.res.AssetManager
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.FileDescriptor
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID
import java.util.zip.GZIPInputStream

/** Offline, missing-only seeding. The caller owns composition, eligibility and serialization. */
class BundledGeo internal constructor(
    private val trustedRoot: File,
    private val openAsset: (String) -> InputStream,
    private val sync: (FileDescriptor) -> Unit = { Os.fsync(it) },
    private val directoryOpen: (String) -> FileDescriptor = { path ->
        Os.open(path, OsConstants.O_RDONLY or OsConstants.O_NONBLOCK or OsConstants.O_NOFOLLOW, 0)
    },
) {
    constructor(context: Context) : this(context.noBackupFilesDir.canonicalFile,
        { context.assets.open("geodata/$it", AssetManager.ACCESS_STREAMING) })

    enum class Kind(val geoxKey: String, internal val data: Data, internal val names: Set<String>) {
        GEOIP("geoip", BundledAssetContract.geoip, setOf("geoip.dat")),
        GEOSITE("geosite", BundledAssetContract.geosite, setOf("geosite.dat")),
        MMDB("mmdb", BundledAssetContract.mmdb, setOf("country.mmdb", "geoip.db", "geoip.metadb")),
        ASN("asn", BundledAssetContract.asn, setOf("asn.mmdb"));

        // ASCII fixed basenames follow Go EqualFold: long-s folds to s; dotted and
        // dotless Turkish I remain distinct from i.
        internal fun acceptsName(value: String) = value.lowercase(Locale.ROOT).replace('ſ', 's') in names
    }

    /**
     * Emit only requests with absent composed geox-url subkeys, using the
     * core-selected fixed basename.
     */
    data class Request(val kind: Kind, val targetName: String) {
        init {
            require(kind.acceptsName(targetName)) { "Invalid Geo target" }
        }
    }

    interface Owner {
        /** Throw on cancellation, stale lease or changed composition. Called throughout streaming. */
        fun checkCurrent()
        /**
         * After old updaters join, arbitrate owner validity, final existence and
         * rename synchronously exactly once. Copy and fsync run outside this short
         * block.
         */
        fun publishIfCurrent(block: () -> Unit)
    }

    enum class State { INSTALLED, PRESERVED }
    data class Result(val kind: Kind, val targetName: String, val state: State)

    /**
     * Run on a worker after old leases/updaters exit and before ParseRawConfig. The
     * app-owned noBackup home already exists. Preserve completed items; retry checks
     * each requested file again.
     */
    fun install(home: File, requests: List<Request>, owner: Owner): List<Result> {
        check(Looper.myLooper() != Looper.getMainLooper()) { "Geo installation requires a worker" }
        require(requests.map { it.kind }.distinct().size == requests.size) { "Duplicate Geo request" }
        if (requests.isEmpty()) return emptyList()
        owner.checkCurrent()
        return pinHome(home).use { directory ->
            requests.map { request -> installOne(home, directory, request, owner) }
        }
    }

    private fun installOne(home: File, directory: ParcelFileDescriptor, request: Request, owner: Owner): Result {
        owner.checkCurrent()
        val base = "/proc/self/fd/${directory.fd}"
        existing(base, request.kind)?.let { return Result(request.kind, it, State.PRESERVED) }
        val temporary = "$base/.bundled-geo-${UUID.randomUUID()}.tmp"
        val descriptor = Os.open(temporary, OsConstants.O_WRONLY or OsConstants.O_CREAT or
            OsConstants.O_EXCL or OsConstants.O_NOFOLLOW, 0x180) // 0600
        var created: android.system.StructStat? = null
        var failure: Throwable? = null
        try {
            val owned = try {
                created = Os.fstat(descriptor)
                ParcelFileDescriptor.dup(descriptor)
            } finally { Os.close(descriptor) }
            // Android FileOutputStream(FileDescriptor) borrows, rather than owns, the FD.
            // Use the SDK owning stream; the outer use also covers constructor failure.
            owned.use { file ->
                ParcelFileDescriptor.AutoCloseOutputStream(file).use { output ->
                    openAsset(request.kind.data.asset).use { input ->
                        copyVerified(request.kind.data, input, output, owner::checkCurrent)
                    }
                    output.flush()
                    owner.checkCurrent()
                    sync(file.fileDescriptor)
                }
            }
            val expected = checkNotNull(created)
            var result: Result? = null
            owner.publishIfCurrent {
                owner.checkCurrent()
                // All accesses use a pinned directory, even if a pathname is replaced mid-copy.
                pinHome(home).use { current ->
                    val old = Os.fstat(directory.fileDescriptor)
                    val now = Os.fstat(current.fileDescriptor)
                    if (old.st_dev != now.st_dev || old.st_ino != now.st_ino) throw IOException("Geo home changed")
                }
                val staged = Os.lstat(temporary)
                if (!OsConstants.S_ISREG(staged.st_mode) || staged.st_dev != expected.st_dev ||
                    staged.st_ino != expected.st_ino) throw IOException("Geo temporary file changed")
                val found = existing(base, request.kind)
                if (found != null) {
                    result = Result(request.kind, found, State.PRESERVED)
                } else {
                    // The single preparation owner serializes final existence checking
                    // and atomic rename after old updaters join. This path uses rename
                    // under API24 app_data_file policy.
                    Os.rename(temporary, "$base/${request.targetName}")
                    result = Result(request.kind, request.targetName, State.INSTALLED)
                }
            }
            val actual = checkNotNull(result) { "Geo publication was not executed" }
            // Complete directory durability before return, outside owner arbitration.
            if (actual.state == State.INSTALLED) sync(directory.fileDescriptor)
            return actual
        } catch (error: Throwable) {
            failure = error
            throw error
        } finally {
            // Remove only the exclusively created temporary inode.
            try {
                val staged = lstatOrMissing(temporary)
                if (staged != null) {
                    val expected = created ?: throw IOException("Cannot verify Geo temporary inode for cleanup")
                    if (staged.st_dev != expected.st_dev || staged.st_ino != expected.st_ino) {
                        throw IOException("Geo temporary file changed during cleanup")
                    }
                    Os.remove(temporary)
                    sync(directory.fileDescriptor)
                }
            } catch (cleanup: Throwable) {
                if (failure != null) failure.addSuppressed(cleanup) else throw cleanup
            }
        }
    }

    private fun existing(base: String, kind: Kind): String? {
        val names = File(base).list()?.sorted() ?: throw IOException("Cannot list Geo home")
        var selected: String? = null
        for (name in names) {
            if (!kind.acceptsName(name)) continue
            val stat = lstatOrMissing("$base/$name") ?: continue
            if (!OsConstants.S_ISREG(stat.st_mode)) throw IOException("Geo target is not a regular file: $name")
            // Match the core's sorted, case-insensitive lookup, including MMDB aliases.
            if (selected == null) selected = name
        }
        // Preserve existing files, including damaged or empty files, for normal core
        // loading and update handling.
        return selected
    }

    private fun pinHome(home: File): ParcelFileDescriptor {
        require(trustedRoot.isAbsolute && trustedRoot.path != "/") { "Geo requires a private SDK root" }
        require(home.isAbsolute && home.path.startsWith(trustedRoot.path + "/")) { "Geo home is outside its private root" }
        require(listOf(trustedRoot, home).all { directory -> directory.path.split('/').none { it == "." || it == ".." } }) { "Invalid Geo home" }
        val parts = home.path.removePrefix(trustedRoot.path).split('/').filter { it.isNotEmpty() }
        // Open the SDK canonical noBackup root, then pin application descendants
        // through NOFOLLOW descriptors.
        var current = openDirectory(trustedRoot.path)
        try {
            for (part in parts) {
                val next = openDirectory("/proc/self/fd/${current.fd}/$part")
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

    private fun openDirectory(path: String): ParcelFileDescriptor {
        // Use NONBLOCK to bound FIFO opening, then fstat the inode before directory
        // use.
        val fd = directoryOpen(path)
        return try {
            if (!OsConstants.S_ISDIR(Os.fstat(fd).st_mode)) throw IOException("Geo ancestor is not a directory")
            ParcelFileDescriptor.dup(fd)
        } finally { Os.close(fd) }
    }

    private fun lstatOrMissing(path: String) = try { Os.lstat(path) } catch (error: ErrnoException) {
        if (error.errno == OsConstants.ENOENT) null else throw error
    }

    internal data class Data(val asset: String, val gzip: Boolean, val size: Long, val sha256: String,
        val storedSize: Long = size, val storedSha256: String = sha256)

    companion object {
        /**
         * Bound stored and expanded bytes while leaving output ownership with the
         * caller.
         */
        internal fun copyVerified(data: Data, input: InputStream, output: OutputStream, checkCurrent: () -> Unit) {
            VerifiedInput(input, data.storedSize, data.storedSha256, checkCurrent).use { stored ->
                val expanded = if (data.gzip) GZIPInputStream(stored, 32 * 1024) else stored
                val digest = MessageDigest.getInstance("SHA-256")
                val buffer = ByteArray(32 * 1024)
                var size = 0L
                // Closing a gzip stream releases its Inflater on copy failure/cancellation.
                // The outer use also closes input when construction fails while reading its header.
                expanded.use {
                    while (true) {
                        checkCurrent()
                        val count = it.read(buffer)
                        if (count < 0) break
                        size += count
                        if (size > data.size) throw IOException("Expanded Geo asset exceeds fixed size")
                        digest.update(buffer, 0, count)
                        output.write(buffer, 0, count)
                    }
                    if (size != data.size || hex(digest.digest()) != data.sha256) throw IOException("Geo asset checksum mismatch")
                    // Gzip may stop at its final member. Hash every stored byte, including any trailer.
                    while (stored.read(buffer) != -1) checkCurrent()
                    stored.verify()
                    checkCurrent()
                }
            }
        }

        private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }
    }

    private class VerifiedInput(private val input: InputStream, private val expectedSize: Long,
        private val expectedHash: String, private val checkCurrent: () -> Unit) : InputStream() {
        private val digest = MessageDigest.getInstance("SHA-256")
        private var size = 0L
        override fun read(): Int {
            val single = ByteArray(1)
            return if (read(single, 0, 1) == -1) -1 else single[0].toInt() and 0xff
        }
        override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
            checkCurrent()
            val count = input.read(bytes, offset, length)
            if (count > 0) {
                size += count
                if (size > expectedSize) throw IOException("Stored Geo asset exceeds fixed size")
                digest.update(bytes, offset, count)
            }
            return count
        }
        fun verify() {
            if (size != expectedSize || hex(digest.digest()) != expectedHash) throw IOException("Stored Geo asset checksum mismatch")
        }
        override fun close() = input.close()
    }
}
