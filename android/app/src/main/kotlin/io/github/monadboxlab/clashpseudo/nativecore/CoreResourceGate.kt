package io.github.monadboxlab.clashpseudo.nativecore

import android.content.Context
import android.os.ParcelFileDescriptor
import android.system.Os
import android.system.OsConstants
import io.github.monadboxlab.clashpseudo.app.AppProcess
import java.io.Closeable
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.channels.FileLock
import java.nio.channels.OverlappingFileLockException

/** 内核与逐项清理共用文件锁；锁文件不在 mihomo 数据目录内。 */
class CoreResourceGate(private val file: File) {
    class Held internal constructor(
        private val stream: FileOutputStream,
        private val lock: FileLock,
        private val released: () -> Unit,
    ) : Closeable {
        private var closed = false
        @Synchronized override fun close() {
            if (closed) return
            closed = true
            var failure: Throwable? = null
            try { lock.release() } catch (error: Throwable) { failure = error }
            try { stream.close() } catch (error: Throwable) {
                if (failure == null) failure = error else if (failure !== error) failure.addSuppressed(error)
            }
            released()
            failure?.let { throw it }
        }
    }

    fun tryAcquire(): Held? = synchronized(localOwners) {
        val key = file.absolutePath
        if (!localOwners.add(key)) return@synchronized null
        try { acquire(key) } catch (error: Throwable) { localOwners.remove(key); throw error }
    }

    private fun acquire(key: String): Held? {
        val descriptor = Os.open(file.path, OsConstants.O_RDWR or OsConstants.O_CREAT or
            OsConstants.O_NOFOLLOW or OsConstants.O_NONBLOCK, 0x180)
        val stream = try {
            val info = Os.fstat(descriptor)
            if (!OsConstants.S_ISREG(info.st_mode) || info.st_nlink != 1L) {
                throw IOException("内核资源锁不是私有普通文件")
            }
            val duplicate = ParcelFileDescriptor.dup(descriptor)
            try { ParcelFileDescriptor.AutoCloseOutputStream(duplicate) }
            catch (error: Throwable) { duplicate.close(); throw error }
        } finally { Os.close(descriptor) }
        try {
            val lock = try { stream.channel.tryLock() } catch (_: OverlappingFileLockException) { null }
            if (lock != null) return Held(stream, lock) { synchronized(localOwners) { localOwners.remove(key) } }
            stream.close()
            localOwners.remove(key)
            return null
        } catch (error: Throwable) {
            try { stream.close() } catch (close: Throwable) { if (close !== error) error.addSuppressed(close) }
            throw error
        }
    }

    fun <T> exclusive(action: () -> T): T =
        (tryAcquire() ?: throw IOException("内核进程仍持有数据目录，退出尚未确认")).use { action() }

    companion object {
        private val localOwners = mutableSetOf<String>()
        fun forApplication(context: Context) = CoreResourceGate(File(context.noBackupFilesDir, "core-host.lock"))
    }
}

/** 不在 Service 销毁或原生 Shutdown 返回时释放，只随 :core 进程结束。 */
internal object CoreProcessResources {
    private var held: CoreResourceGate.Held? = null

    @Synchronized fun acquire(context: Context) {
        AppProcess.requireCore(context)
        if (held != null) return
        held = CoreResourceGate.forApplication(context).tryAcquire()
            ?: throw IOException("另一个内核或清理操作仍持有数据目录")
    }
}
