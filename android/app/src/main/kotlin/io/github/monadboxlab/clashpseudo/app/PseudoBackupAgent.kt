package io.github.monadboxlab.clashpseudo.app

import io.github.monadboxlab.clashpseudo.backup.BackupFiles

import android.app.backup.BackupAgent
import android.app.backup.BackupDataInput
import android.app.backup.BackupDataOutput
import android.app.backup.FullBackupDataOutput
import android.os.ParcelFileDescriptor
import java.io.EOFException
import java.io.File
import java.io.IOException

/**
 * SDK full-backup lifecycle. The Manifest selects fullBackupOnly and the versioned
 * backup XML rules.
 */
open class PseudoBackupAgent : BackupAgent() {
    @Volatile private var usedFiles: BackupFiles? = null
    @Volatile private var restoreEpoch: Long? = null
    @Volatile private var destroyed = false

    protected open fun backupFiles(): BackupFiles = BackupFiles.get(this)
    protected open fun frameworkBackup(data: FullBackupDataOutput?) { super.onFullBackup(data) }
    protected open fun frameworkRestore(data: ParcelFileDescriptor, size: Long, target: File,
        type: Int, mode: Long, mtime: Long) { super.onRestoreFile(data, size, target, type, mode, mtime) }

    @Throws(IOException::class)
    override fun onFullBackup(data: FullBackupDataOutput?) = frameworkIo {
        val storage = callbackFiles().transaction
        val current = storage.snapshot()
        if (current.restoring) throw IOException("storageBusy")
        // Routine backup preserves unrelated user drafts and their storage epoch.
        val ready = if (current.ready) current else storage.recover()
        storage.withStableStorage(ready.epoch) {
            if (destroyed) throw IOException("Backup agent destroyed")
            frameworkBackup(data) // SDK traversal, exclusions and encryption/transport rules remain intact.
        }
    }

    @Throws(IOException::class)
    override fun onRestoreFile(data: ParcelFileDescriptor, size: Long, destination: File,
        type: Int, mode: Long, mtime: Long) = frameworkIo {
        val files = callbackFiles()
        val epoch = restoreEpoch ?: files.transaction.beginSystemRestore().also { restoreEpoch = it }
        try {
            if (destroyed) throw IOException("Backup agent destroyed")
            val kind = BackupFiles.Kind.entries.singleOrNull {
                destination.absolutePath == File(files.stores, it.fileName).absolutePath ||
                    destination.absolutePath == File(files.platformStores, it.fileName).absolutePath
            }
            if (type != TYPE_FILE || kind == null) {
                // The SDK File overload applies eligibility to its destination.
                // Consume exactly this entry while retaining the framework-owned PFD
                // and canonical target.
                discardEntry(data, size)
            } else {
                files.transaction.systemRestoreFile(epoch, kind, size) { target ->
                    frameworkRestore(data, size, target, type, mode, mtime)
                }
            }
        } catch (error: Throwable) {
            files.transaction.abandonSystemRestore(epoch)
            throw error
        }
    }

    override fun onRestoreFinished() {
        val epoch = restoreEpoch
        try {
            super.onRestoreFinished()
            if (epoch != null) {
                if (destroyed) throw IOException("Backup agent destroyed")
                checkNotNull(usedFiles).transaction.finishSystemRestore(epoch)
                restoreEpoch = null
            }
        } catch (error: Exception) {
            if (epoch != null) usedFiles?.transaction?.abandonSystemRestore(epoch)
            // Report SDK per-file restore failures through this callback's actual
            // exception contract.
            throw IllegalStateException("systemRestoreIncomplete", error)
        }
    }

    override fun onDestroy() {
        destroyed = true
        restoreEpoch?.let { usedFiles?.transaction?.abandonSystemRestore(it) }
        super.onDestroy()
    }

    @Throws(IOException::class)
    override fun onBackup(oldState: ParcelFileDescriptor?, data: BackupDataOutput?, newState: ParcelFileDescriptor?) {
        throw IOException("Key/value backup is not supported; fullBackupOnly is required")
    }

    @Throws(IOException::class)
    override fun onRestore(data: BackupDataInput?, appVersionCode: Int, newState: ParcelFileDescriptor?) {
        throw IOException("Key/value restore is not supported; fullBackupOnly is required")
    }

    private inline fun frameworkIo(block: () -> Unit) {
        try { block() } catch (error: IOException) { throw error }
        catch (error: Exception) { throw IOException("System backup I/O failed", error) }
    }

    private fun callbackFiles(): BackupFiles {
        if (destroyed) throw IOException("Backup agent destroyed")
        return usedFiles ?: backupFiles().also { usedFiles = it }
    }

    private fun discardEntry(data: ParcelFileDescriptor, size: Long) {
        if (size < 0) throw IOException("Invalid system restore size")
        ParcelFileDescriptor.dup(data.fileDescriptor).use { owned ->
            ParcelFileDescriptor.AutoCloseInputStream(owned).use { input ->
                val bytes = ByteArray(32768)
                var remaining = size
                while (remaining > 0) {
                    val count = input.read(bytes, 0, minOf(remaining, bytes.size.toLong()).toInt())
                    if (count < 0) throw EOFException("Incomplete skipped system restore entry")
                    remaining -= count
                }
            }
        }
    }
}
