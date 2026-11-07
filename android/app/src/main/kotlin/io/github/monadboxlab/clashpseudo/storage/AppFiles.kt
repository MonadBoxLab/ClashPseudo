package io.github.monadboxlab.clashpseudo.storage

import io.github.monadboxlab.clashpseudo.app.ApplicationContract
import io.github.monadboxlab.clashpseudo.message.AppMessage

import android.content.Context
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import java.io.Closeable
import java.io.File
import java.io.FileDescriptor
import java.io.IOException
import java.util.ArrayDeque

object AppFiles {
    fun privacyNotice(context: Context) = File(context.noBackupFilesDir, "privacy-notice-shown")

    /** Installation-local, not versioned and never part of the three business files. */
    fun privacyNoticeShown(context: Context): Boolean {
        val descriptor = try {
            Os.open(privacyNotice(context).path,
                OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or OsConstants.O_NONBLOCK, 0)
        } catch (failure: ErrnoException) {
            if (failure.errno == OsConstants.ENOENT) return false
            throw failure
        }
        return OwnedDescriptor(descriptor).use {
            val info = Os.fstat(descriptor)
            if (!OsConstants.S_ISREG(info.st_mode) || info.st_size != 1L) {
                throw IOException("Invalid privacy notice marker")
            }
            val bytes = ByteArray(2)
            if (Os.read(descriptor, bytes, 0, bytes.size) != 1 || bytes[0] != 1.toByte()) {
                throw IOException("Invalid privacy notice marker")
            }
            true
        }
    }

    /** File-worker only. A failure after writing means persistence is unconfirmed. */
    fun markPrivacyNoticeShown(context: Context) = markPrivacyNoticeShown(context, Os::fsync)

    internal fun markPrivacyNoticeShown(context: Context, sync: (FileDescriptor) -> Unit) {
        val file = privacyNotice(context)
        OwnedDescriptor(Os.open(file.path, OsConstants.O_WRONLY or OsConstants.O_CREAT or
            OsConstants.O_NOFOLLOW or OsConstants.O_NONBLOCK, 0x180)).use { owned ->
            val descriptor = owned.value
            val info = Os.fstat(descriptor)
            if (!OsConstants.S_ISREG(info.st_mode) || info.st_nlink != 1L) {
                throw IOException("Privacy notice marker is not a private regular file")
            }
            Os.ftruncate(descriptor, 0L)
            if (Os.write(descriptor, byteArrayOf(1), 0, 1) != 1) {
                throw IOException("Incomplete privacy notice marker write")
            }
            sync(descriptor)
        }
        // O_DIRECTORY is not a public Android API; validate the opened FD itself.
        OwnedDescriptor(Os.open(file.parentFile!!.path,
            OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or OsConstants.O_NONBLOCK, 0)).use { directory ->
            if (!OsConstants.S_ISDIR(Os.fstat(directory.value).st_mode)) {
                throw IOException("Privacy notice marker parent is not a directory")
            }
            sync(directory.value)
        }
    }

    // use() retains the primary I/O error and suppresses any subsequent close error.
    private class OwnedDescriptor(val value: FileDescriptor) : Closeable {
        override fun close() = Os.close(value)
    }

    fun configs(context: Context) = File(context.filesDir, "configurations")
    fun work(context: Context) = File(context.noBackupFilesDir, "work")
    fun runInput(context: Context, owner: String) = File(work(context), "run-input-$owner.json")
    const val MAX_RUN_RECORD_BYTES = ApplicationContract.CONFIGURATION_OVERRIDE_JSON_BYTES +
        ApplicationContract.CONFIGURATION_TEXT_BYTES * 6 + ApplicationContract.CONFIGURATION_PREPARATION_OPTIONS_BYTES * 2

    fun runRecord(context: Context, inputId: String): File {
        val bytes = inputId.toByteArray(Charsets.UTF_8)
        require(bytes.isNotEmpty() && bytes.size <= ApplicationContract.CORE_IPC_IDENTITY_BYTES) { "Invalid preparation input identity" }
        val hash = java.security.MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        return File(work(context), "run-record-$hash.json")
    }
    // Resolve platform-owned aliases only; consumers still reject linked children.
    fun core(context: Context) = File(context.noBackupFilesDir.canonicalFile, "mihomo")
    // Always-on reads the saved system input prepared by the business engine.
    fun systemInput(context: Context) = File(context.noBackupFilesDir, "work/system-input.json")

    fun usage(context: Context): Map<String, Any> = mapOf(
        "configurations" to usage(File(configs(context), ApplicationContract.BACKUP_CONFIGURATIONS_FILE)),
        "overrides" to usage(File(configs(context), ApplicationContract.BACKUP_OVERRIDES_FILE)),
        "preferences" to usage(File(configs(context), ApplicationContract.BACKUP_PREFERENCES_FILE)),
        "core" to usage(core(context)),
    )

    private fun usage(file: File): Map<String, Any> = try {
        mapOf("path" to file.absolutePath, "bytes" to bytes(file))
    } catch (failure: Exception) {
        mapOf("path" to file.absolutePath,
            "error" to AppMessage("storageUsageFailed").withDetail(failure).toMap())
    }

    internal fun bytes(root: File): Long {
        var total = 0L
        val pending = ArrayDeque<File>()
        pending.add(root)
        while (pending.isNotEmpty()) {
            val file = pending.removeLast()
            val stat = try {
                Os.lstat(file.absolutePath)
            } catch (failure: ErrnoException) {
                if (failure.errno == OsConstants.ENOENT) continue
                throw failure
            }
            if (OsConstants.S_ISDIR(stat.st_mode)) {
                val children = file.listFiles() ?: throw IOException("Unable to list $file")
                children.forEach(pending::add)
            } else {
                total = Math.addExact(total, stat.st_size)
            }
        }
        return total
    }
}
