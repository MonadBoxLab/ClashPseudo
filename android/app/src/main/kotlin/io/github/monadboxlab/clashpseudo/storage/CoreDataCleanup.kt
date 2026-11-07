package io.github.monadboxlab.clashpseudo.storage

import android.content.Context
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import io.github.monadboxlab.clashpseudo.message.AppMessage
import io.github.monadboxlab.clashpseudo.nativecore.CorePrivateFiles
import io.github.monadboxlab.clashpseudo.nativecore.CoreRecordPublicationException
import io.github.monadboxlab.clashpseudo.nativecore.CoreResourceGate
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException

/** Per-file confirmed cleanup; delete only after the resource lock confirms the old core has exited. */
internal class CoreDataCleanup(
    private val root: File,
    private val record: File,
    private val remove: (File) -> Unit = { Os.remove(it.absolutePath) },
    private val syncDirectory: (File) -> Unit = CorePrivateFiles::sync,
    private val writeRecord: (File, ByteArray, (() -> Unit) -> Unit) -> Unit = CorePrivateFiles::write,
) {
    data class Request(val paths: List<String>) {
        constructor(scope: String, relativePath: String? = null) : this(when (scope) {
            "cache" -> { require(relativePath == null); listOf("cache.db") }
            "resource" -> listOf(requireNotNull(relativePath))
            else -> throw IllegalArgumentException("Cleanup requires selecting individual files")
        })
        init {
            require(paths.isNotEmpty() && paths.distinct().size == paths.size) { "Cleanup file list is empty or contains duplicates" }
            paths.forEach(::validatePath)
        }
        val scope get() = "files"
        val relativePath get() = paths.singleOrNull()
    }
    private data class Item(val path: String, val completed: Boolean = false, val error: AppMessage? = null)
    private data class State(val status: String = "initializing", val items: List<Item> = emptyList(), val error: AppMessage? = null)
    private val candidatesRecord = File(record.parentFile, "core-cleanup-candidates.json")
    private val gate = CoreResourceGate(File(record.parentFile, "core-host.lock"))
    @Volatile private var state = State()
    private var initialized = false
    private var candidates = setOf("cache.db")
    val ready: Boolean get() = state.status in setOf("idle", "completed")
    val pending: Boolean get() = state.status in setOf("scheduled", "failed", "needsSelection")

    fun snapshot(): Map<String, Any?> = state.let { value -> mapOf(
        "ready" to ready, "status" to value.status, "scope" to "files",
        "paths" to value.items.map { it.path },
        "files" to value.items.map { mapOf("path" to it.path, "completed" to it.completed, "error" to it.error?.toMap()) },
        "error" to value.error?.toMap(),
    ) }

    fun requireReady() { if (!ready) throw IOException("Core file cleanup is incomplete: ${state.status}") }

    @Synchronized fun initialize() {
        if (initialized) return
        initialized = true
        try {
            CorePrivateFiles.read(candidatesRecord, 65536)?.let { bytes ->
                val paths = JSONArray(bytes.toString(Charsets.UTF_8))
                candidates = (0 until paths.length()).map { paths.getString(it).also(::validatePath) }.toSet() + "cache.db"
            }
            val bytes = CorePrivateFiles.read(record, 65536)
            if (bytes == null) { state = State("idle"); return }
            val value = JSONObject(bytes.toString(Charsets.UTF_8))
            if (value.optString("scope") == "all") {
                state = State("needsSelection", error = AppMessage("coreCleanupRequired"))
                return
            }
            val files = value.optJSONArray("files")
            if (files == null) {
                // Legacy single-file records must also match the confirmed public file list.
                val legacy = if (value.optString("scope") == "cache") "cache.db" else value.optString("path")
                if (legacy !in candidates) { state = State("needsSelection", error = AppMessage("coreCleanupRequired")); return }
                state = State("scheduled", listOf(Item(legacy)))
            } else state = State("scheduled", (0 until files.length()).map { index ->
                val item = files.getJSONObject(index)
                val path = item.getString("path").also(::validatePath)
                check(path in candidates) { "Cleanup record contains an unconfirmed file" }
                Item(path, item.optBoolean("completed"), AppMessage.fromMap(item.optJSONObject("error")?.let { json ->
                    json.keys().asSequence().associateWith { json.get(it) }
                }))
            })
            check(state.items.isNotEmpty() && state.items.map { it.path }.distinct().size == state.items.size) { "Cleanup record file list is empty or contains duplicates" }
            drain()
        } catch (error: Throwable) { state = state.copy(status = "failed", error = AppMessage("coreCleanupFailed").withDetail(error)) }
    }

    /** Paths come only from public Path getters queried in the isolated process before parsing, not from extension-based scans. */
    @Synchronized fun registerCandidates(paths: List<String>) {
        val normalized = paths.map(::relative).distinct()
        normalized.forEach(::validatePath)
        candidates = normalized.toSet() + "cache.db"
        CorePrivateFiles.write(candidatesRecord, JSONArray(candidates.toList()).toString().toByteArray(Charsets.UTF_8))
    }

    fun resource(path: String): Request {
        val relative = relative(path)
        if (relative !in candidates) throw IOException("File is not in the current public core file list")
        val target = File(root, relative)
        if (parentsPresent(target)) stat(target)?.let { info ->
            if (!OsConstants.S_ISREG(info.st_mode) || info.st_nlink != 1L) throw IOException("Cleanup target is not an unshared regular file: $relative")
        }
        return Request(listOf(relative))
    }

    /** The existing operation owner arbitrates record publication; keep resource admission closed after publication. */
    @Synchronized fun schedule(request: Request, publish: (() -> Unit) -> Unit): AppMessage? {
        check(initialized) { "Core file cleanup is still initializing" }
        require(request.paths.all { it in candidates }) { "Cleanup list contains unconfirmed files" }
        val next = State("scheduled", request.paths.map(::Item))
        try { persist(next) { rename -> publish { rename(); state = next } } }
        catch (error: CoreRecordPublicationException) {
            state = next.copy(error = AppMessage("coreCleanupFailed").withDetail(error))
            throw error
        }
        return null
    }

    @Synchronized fun drain(): AppMessage? {
        if (state.status == "needsSelection" || state.items.isEmpty()) return state.error
        return try {
            gate.exclusive {
                var items = state.items
                for (index in items.indices) {
                    val item = items[index]
                    if (item.completed) continue
                    try {
                        val target = File(root, item.path)
                        if (parentsPresent(target)) {
                            val info = stat(target)
                            if (info != null) {
                                if (!OsConstants.S_ISREG(info.st_mode) || info.st_nlink != 1L) {
                                    throw IOException("Cleanup target is not an unshared regular file: ${item.path}")
                                }
                                remove(target)
                            }
                            syncDirectory(target.parentFile!!)
                        }
                        items = items.toMutableList().apply { set(index, item.copy(completed = true, error = null)) }
                        state = State("scheduled", items)
                        persist(state)
                    } catch (error: Throwable) {
                        val detail = AppMessage("coreCleanupFailed").withDetail(error)
                        items = items.toMutableList().apply { set(index, item.copy(error = detail)) }
                        state = State("failed", items, detail)
                        try { persist(state) }
                        catch (recordError: Throwable) { if (recordError !== error) error.addSuppressed(recordError) }
                        return@exclusive AppMessage("coreCleanupFailed").withDetail(error).also { state = state.copy(error = it) }
                    }
                }
                try {
                    remove(record)
                    syncDirectory(record.parentFile!!)
                    state = State("completed", items)
                    null
                } catch (error: Throwable) {
                    state = State("failed", items, AppMessage("coreCleanupFailed").withDetail(error))
                    try { persist(state) }
                    catch (recordError: Throwable) { if (recordError !== error) error.addSuppressed(recordError) }
                    AppMessage("coreCleanupFailed").withDetail(error).also { state = state.copy(error = it) }
                }
            }
        } catch (error: Throwable) {
            AppMessage("coreCleanupFailed").withDetail(error).also { state = state.copy(status = "failed", error = it) }
        }
    }

    private fun persist(value: State, publish: (() -> Unit) -> Unit = { it() }) {
        val json = JSONObject().put("scope", "files").put("files", JSONArray(value.items.map { item ->
            JSONObject().put("path", item.path).put("completed", item.completed).put("error", item.error?.toMap()?.let(::JSONObject) ?: JSONObject.NULL)
        }))
        writeRecord(record, json.toString().toByteArray(Charsets.UTF_8), publish)
    }

    private fun relative(path: String): String {
        val file = File(path)
        val absolute = (if (file.isAbsolute) file else File(root, path)).absoluteFile.normalize().path
        val prefix = root.absoluteFile.normalize().path + File.separator
        if (!absolute.startsWith(prefix)) throw IOException("File is outside the core working directory")
        return absolute.removePrefix(prefix).also(::validatePath)
    }

    private fun parentsPresent(target: File): Boolean {
        var directory = root
        val parts = target.absolutePath.removePrefix(root.absolutePath + File.separator).split('/')
        for (index in parts.indices) {
            val info = stat(directory) ?: return false
            if (!OsConstants.S_ISDIR(info.st_mode)) throw IOException("Cleanup parent path is not a directory: $directory")
            if (index < parts.lastIndex) directory = File(directory, parts[index])
        }
        return true
    }

    private fun stat(file: File) = try { Os.lstat(file.path) }
        catch (error: ErrnoException) { if (error.errno == OsConstants.ENOENT) null else throw error }

    companion object {
        private fun validatePath(path: String) {
            require(path.isNotEmpty() && !File(path).isAbsolute && path.split('/').none { it.isEmpty() || it == "." || it == ".." } && '\u0000' !in path) {
                "Invalid core cleanup relative path"
            }
        }
        @Volatile private var instance: CoreDataCleanup? = null
        fun get(context: Context): CoreDataCleanup = instance ?: synchronized(this) {
            instance ?: CoreDataCleanup(AppFiles.core(context), File(context.noBackupFilesDir, "core-cleanup.json")).also { instance = it }
        }
    }
}
