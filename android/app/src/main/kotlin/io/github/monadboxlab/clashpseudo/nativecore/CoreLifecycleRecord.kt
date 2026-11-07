package io.github.monadboxlab.clashpseudo.nativecore

import android.content.Context
import android.provider.Settings
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.util.UUID

/** Records preparation and exit identities without configuration content; written by the default process. */
class CoreLifecycleRecord(private val file: File, private val bootCount: () -> Int?) {
    data class State(
        val processId: String? = null,
        val inputId: String? = null,
        val stage: String = Contract.CORE_PHASE_DISCONNECTED,
        val exitReason: String? = null,
        val recoveryRequired: Boolean = false,
        val bootCount: Int? = null,
        val cleanupPending: Boolean = false,
        val error: JSONObject? = null,
    ) {
        fun json(): JSONObject = JSONObject().put(Contract.CORE_FIELD_PROCESS_ID, processId ?: JSONObject.NULL)
            .put(Contract.CORE_FIELD_INPUT_ID, inputId ?: JSONObject.NULL).put("stage", stage)
            .put("exitReason", exitReason ?: JSONObject.NULL).put("recoveryRequired", recoveryRequired)
            .put("bootCount", bootCount ?: JSONObject.NULL).put("cleanupPending", cleanupPending)
            .put(Contract.CORE_FIELD_ERROR, error ?: JSONObject.NULL)
    }

    @Volatile private var current = State()
    fun snapshot(): State = current

    @Synchronized fun initialize(lockHeld: Boolean): State {
        val bytes = CorePrivateFiles.read(file, Contract.CORE_IPC_CONTROL_BYTES)
        var saved = if (bytes == null) State() else {
            val value = JSONObject(CoreFrames.utf8(bytes))
            State(value.optStringOrNull(Contract.CORE_FIELD_PROCESS_ID), value.optStringOrNull(Contract.CORE_FIELD_INPUT_ID),
                value.getString("stage"), value.optStringOrNull("exitReason"), value.optBoolean("recoveryRequired"),
                if (value.isNull("bootCount")) null else value.getInt("bootCount"), value.optBoolean("cleanupPending"),
                value.optJSONObject(Contract.CORE_FIELD_ERROR))
        }
        val nowBoot = bootCount()
        if (!saved.recoveryRequired && !lockHeld && saved.stage in setOf("starting", "running", Contract.CORE_PHASE_STOPPING)) {
            val normalReboot = saved.bootCount != null && nowBoot != null && saved.bootCount != nowBoot
            val explicitExit = saved.exitReason in setOf("stop", "reconnect", "previewExpired", "idle", "cleanup", "revoked", "shutdown")
            saved = saved.copy(stage = if (normalReboot || explicitExit) Contract.CORE_PHASE_EXITED else Contract.CORE_PHASE_RECOVERY_REQUIRED,
                recoveryRequired = !normalReboot && !explicitExit)
            persist(saved)
        }
        current = saved
        return saved
    }

    @Synchronized fun starting(processId: String, inputId: String, userRecovery: Boolean) {
        check(!current.cleanupPending) { "Core file cleanup is incomplete" }
        if (current.recoveryRequired && !userRecovery) {
            throw CoreTransportException(Contract.CORE_ERROR_RECOVERY_REQUIRED, "Core has exited; waiting for the user to restart")
        }
        persist(State(processId, inputId, "starting", bootCount = bootCount()))
    }

    @Synchronized fun running(processId: String, inputId: String) {
        check(current.processId == processId && current.inputId == inputId && current.stage == "starting") {
            "Core preparation receipt does not match the persisted record"
        }
        persist(current.copy(stage = "running"))
    }

    @Synchronized fun requestExit(processId: String, reason: String) {
        check(current.processId == null || current.processId == processId) { "Exit request belongs to an old core process" }
        persist(current.copy(processId = processId, stage = Contract.CORE_PHASE_STOPPING, exitReason = reason))
    }

    @Synchronized fun died(processId: String, error: JSONObject? = null) {
        if (current.processId != processId) return
        val expected = current.exitReason in setOf("stop", "reconnect", "previewExpired", "idle", "cleanup", "revoked", "shutdown")
        val recovery = current.recoveryRequired || !expected && current.stage in setOf("starting", "running")
        persist(current.copy(stage = if (recovery) Contract.CORE_PHASE_RECOVERY_REQUIRED else Contract.CORE_PHASE_EXITED,
            recoveryRequired = recovery, error = error ?: current.error))
    }

    @Synchronized fun cleanup(pending: Boolean) = persist(current.copy(cleanupPending = pending))

    private fun persist(value: State) {
        try { CorePrivateFiles.write(file, value.json().toString().toByteArray(Charsets.UTF_8)) }
        catch (error: CoreRecordPublicationException) { current = value; throw error }
        current = value
    }

    companion object {
        fun forApplication(context: Context) = CoreLifecycleRecord(File(context.noBackupFilesDir, "core-lifecycle.json")) {
            try { Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT) }
            catch (_: Settings.SettingNotFoundException) { null }
            catch (_: SecurityException) { null }
        }
    }
}

internal fun JSONObject.optStringOrNull(key: String): String? =
    if (!has(key) || isNull(key)) null else getString(key)

internal class CoreRecordPublicationException(cause: Throwable) : IOException("Record saved; directory sync is unconfirmed", cause)

/** Atomically publish private records and sync directories, rejecting links and non-regular files. */
internal object CorePrivateFiles {
    fun read(file: File, limit: Int): ByteArray? {
        val parent = try { Os.lstat(file.parentFile!!.path) }
        catch (error: ErrnoException) { if (error.errno == OsConstants.ENOENT) return null else throw error }
        if (!OsConstants.S_ISDIR(parent.st_mode)) throw IOException("Private core record parent path is not a directory")
        val fd = try { Os.open(file.path, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or OsConstants.O_NONBLOCK, 0) }
        catch (error: ErrnoException) { if (error.errno == OsConstants.ENOENT) return null else throw error }
        return withFd(fd) {
            val info = Os.fstat(fd)
            if (!OsConstants.S_ISREG(info.st_mode) || info.st_nlink != 1L || info.st_size > limit || info.st_size < 0) {
                throw IOException("Private core record is not a regular file within the budget: ${file.name}")
            }
            val bytes = ByteArray(info.st_size.toInt())
            var offset = 0
            while (offset < bytes.size) {
                val count = Os.read(fd, bytes, offset, bytes.size - offset)
                if (count <= 0) throw IOException("Incomplete private core record read: ${file.name}")
                offset += count
            }
            if (Os.read(fd, ByteArray(1), 0, 1) != 0) throw IOException("Private core record changed while being read")
            bytes
        }
    }

    fun write(file: File, bytes: ByteArray) = write(file, bytes) { it() }

    fun write(file: File, bytes: ByteArray, publish: (() -> Unit) -> Unit) {
        val parent = file.parentFile!!
        check(parent.isDirectory || parent.mkdirs()) { "Cannot create the core record directory" }
        check(OsConstants.S_ISDIR(Os.lstat(parent.path).st_mode)) { "Core record parent path is not a regular directory" }
        val temporary = File(parent, ".${file.name}.${UUID.randomUUID()}.tmp")
        var saved = false
        try {
            val fd = Os.open(temporary.path, OsConstants.O_WRONLY or OsConstants.O_CREAT or OsConstants.O_EXCL or OsConstants.O_NOFOLLOW, 0x180)
            withFd(fd) {
                var offset = 0
                while (offset < bytes.size) {
                    val count = Os.write(fd, bytes, offset, bytes.size - offset)
                    if (count <= 0) throw IOException("Incomplete core record write")
                    offset += count
                }
                Os.fsync(fd)
            }
            publish { Os.rename(temporary.path, file.path); saved = true }
            check(saved) { "Record publication did not run" }
            sync(parent)
        } catch (error: Throwable) {
            try { if (temporary.exists()) Os.remove(temporary.path) }
            catch (cleanup: Throwable) { if (cleanup !== error) error.addSuppressed(cleanup) }
            if (saved) throw CoreRecordPublicationException(error)
            throw error
        }
    }

    private inline fun <T> withFd(fd: java.io.FileDescriptor, action: () -> T): T {
        var failure: Throwable? = null
        try { return action() }
        catch (error: Throwable) { failure = error; throw error }
        finally {
            try { Os.close(fd) }
            catch (close: Throwable) { if (failure == null) throw close else if (failure !== close) failure.addSuppressed(close) }
        }
    }

    fun sync(directory: File) {
        val fd = Os.open(directory.path, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or OsConstants.O_NONBLOCK, 0)
        withFd(fd) {
            if (!OsConstants.S_ISDIR(Os.fstat(fd).st_mode)) throw IOException("Core record parent path is not a directory")
            Os.fsync(fd)
        }
    }
}
