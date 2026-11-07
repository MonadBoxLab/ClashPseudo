package io.github.monadboxlab.clashpseudo.backup

import io.github.monadboxlab.clashpseudo.app.ApplicationContract
import io.github.monadboxlab.clashpseudo.message.AppMessage
import android.app.Activity
import android.content.Context
import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.provider.OpenableColumns
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.CancellationException
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Process-local document resources. Commands and lifecycle run on main; picker waits
 * are independent of business/storage gates. The physical slot remains held until
 * provider I/O and close return. Candidate tokens cover actual Dart reads.
 */
class BackupCalls internal constructor(
    private val files: BackupFiles,
    private val changed: () -> Unit,
    private val launch: (Activity, Intent, Int) -> Unit,
    private val openInput: (Uri) -> InputStream,
    private val openOutput: (Uri) -> OutputStream,
    private val documentWorker: Executor,
    private val storageWorker: Executor,
    private val post: (Runnable) -> Unit,
    private val delay: (Runnable, Long) -> Unit,
    private val remove: (Runnable) -> Unit,
    private val clock: () -> Long,
    private val displayName: (Uri) -> String = { "" },
) {
    private enum class Kind { CAPTURE, IMPORT, EXPORT, INSPECT, CONFIG }
    private class ConfigTooLarge : IOException("Configuration byte budget exceeded")
    private enum class Phase { PRIVATE_IO, PICKER, DOCUMENT_IO, CLEANUP }
    private class Request(
        val id: String,
        val kind: Kind,
        var activity: Activity?,
        var reply: ((Map<String, Any?>) -> Unit)?,
        val token: String? = null,
        val businessOwner: RestoreTransaction.Owner? = null,
    ) : RestoreTransaction.Owner {
        val active = AtomicBoolean(true)
        var phase = Phase.PRIVATE_IO
        var code = 0
        var discard = false
        val discardReplies = mutableListOf<(Throwable?) -> Unit>()
        var retirement: Map<String, Any?>? = null
        var externalMayBePartial = false
        var timeout: Runnable? = null
        override fun checkCurrent() {
            if (!active.get()) throw CancellationException("Document request ended")
            businessOwner?.checkCurrent()
        }
        // Capture and archive I/O use this owner's Operation.check.
        @Synchronized override fun runIfCurrent(block: () -> Unit) { checkCurrent(); block() }
        @Synchronized fun invalidate() { active.set(false) }
    }

    private var activity: Activity? = null
    private var pending: Request? = null
    private var lastCode = FIRST_CODE - 1
    private var legacyPendingCode = 0
    private var lastErrorCode: String? = null
    private var lastErrorDetail: Map<String, Any?>? = null

    /**
     * Merge the saved request-code high-water mark before accepting a new picker
     * request.
     */
    fun attach(activity: Activity, savedState: Bundle? = null) {
        if (savedState != null) {
            lastCode = maxOf(lastCode, restoredCode(savedState, HIGH_WATER, FIRST_CODE - 1))
            legacyPendingCode = maxOf(legacyPendingCode, restoredCode(savedState, PENDING_CODE, 0))
            lastCode = maxOf(lastCode, legacyPendingCode)
        }
        if (this.activity !== activity) {
            this.activity = activity
            pending?.let { invalidate(it, "cancelled", "backupActivityChanged") }
        }
    }

    fun saveState(activity: Activity, state: Bundle) {
        if (this.activity !== activity) return
        state.putInt(HIGH_WATER, lastCode)
        state.putInt(PENDING_CODE, maxOf(legacyPendingCode,
            pending?.takeIf { it.phase == Phase.PICKER }?.code ?: 0))
    }

    fun detach(activity: Activity) {
        if (this.activity !== activity) return
        this.activity = null
        pending?.let { invalidate(it, "cancelled", "backupActivityChanged") }
    }

    fun snapshot(): Map<String, Any?> = mapOf(
        "busy" to (pending != null),
        "capturing" to (pending?.kind == Kind.CAPTURE),
        "draining" to (pending?.active?.get() == false),
        "phase" to pending?.phase?.name?.lowercase(java.util.Locale.ROOT),
        "errorCode" to lastErrorCode,
        "errorDetail" to lastErrorDetail,
    )

    /** Only absent files use Dart defaults. The unique LogicEngine validates the
     * private candidate, then releases its write gate before saveExport opens a picker.
     */
    fun prepareExport(requestId: String, createdAtMillis: Long, expectedEpoch: Long,
        defaults: Map<String, String>, owner: RestoreTransaction.Owner,
        reply: (Map<String, Any?>) -> Unit) {
        val request = begin(requestId, Kind.CAPTURE, reply, businessOwner = owner) ?: return
        if (createdAtMillis < 0 || expectedEpoch < 0 ||
            defaults.keys != BackupFiles.Kind.entries.map { it.fileName }.toSet() ||
            defaults.values.any { it.length > 4096 }) {
            finish(request, result(request, "failed", "backupInvalidDefaults"))
            return
        }
        // This limit applies to internally supplied small default values.
        val bytes = BackupFiles.Kind.entries.associateWith { defaults.getValue(it.fileName).toByteArray(Charsets.UTF_8) }
        runIo(request, storageWorker, createsCandidate = true, work = { operation ->
            candidateView { files.captureStores(createdAtMillis, expectedEpoch, operation, bytes) }
        }) { view -> finish(request, result(request, "ready") + view) }
    }

    fun pickImport(requestId: String, reply: (Map<String, Any?>) -> Unit) {
        val request = begin(requestId, Kind.IMPORT, reply) ?: return
        picker(request, Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            type = "application/zip"
            addCategory(Intent.CATEGORY_OPENABLE)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        })
    }

    fun pickConfig(requestId: String, reply: (Map<String, Any?>) -> Unit) {
        val request = begin(requestId, Kind.CONFIG, reply) ?: return
        picker(request, Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            type = "*/*"
            addCategory(Intent.CATEGORY_OPENABLE)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        })
    }

    private fun readConfig(uri: Uri, operation: BackupFiles.Operation): Map<String, Any?> {
        operation.check()
        val name = displayName(uri)
        operation.check()
        val bytes = openInput(uri).use { input ->
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(32768)
            val limit = ApplicationContract.CONFIGURATION_TEXT_BYTES
            while (true) {
                operation.check()
                val count = input.read(buffer, 0, minOf(buffer.size, limit - output.size() + 1))
                operation.check()
                if (count < 0) break
                if (count > limit - output.size()) throw ConfigTooLarge()
                output.write(buffer, 0, count)
            }
            output.toByteArray()
        }
        operation.check()
        return mapOf("name" to name, "bytes" to bytes)
    }

    fun saveExport(requestId: String, token: String, title: String,
        reply: (Map<String, Any?>) -> Unit) {
        val request = begin(requestId, Kind.EXPORT, reply, token) ?: return
        if (title.isBlank() || title.length > 256 || title.any { it == '/' || it == '\\' || it < ' ' }) {
            finish(request, result(request, "failed", "backupInvalidTitle"))
            return
        }
        // Validate the token before asking the provider to create its document.
        runIo(request, storageWorker, work = { files.candidate(token); emptyMap() }) {
            picker(request, Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                type = "application/zip"
                addCategory(Intent.CATEGORY_OPENABLE)
                putExtra(Intent.EXTRA_TITLE, title)
                addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            })
        }
    }

    /** Consume every result in the reserved range, including stale results. */
    fun onActivityResult(activity: Activity, requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode !in FIRST_CODE..LAST_CODE) return false
        val request = pending
        if (this.activity !== activity || request == null || request.activity !== activity ||
            request.phase != Phase.PICKER || request.code != requestCode || !request.active.get()) return true
        if (resultCode == Activity.RESULT_CANCELED) {
            finish(request, result(request, "cancelled"))
            return true
        }
        request.externalMayBePartial = request.kind == Kind.EXPORT && resultCode == Activity.RESULT_OK
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null || uri.scheme != "content") {
            finish(request, result(request, "failed", "backupDocumentUnavailable"))
            return true
        }
        request.phase = Phase.DOCUMENT_IO
        // Release the Activity reference during provider I/O; detach still invalidates
        // its waiter.
        request.activity = null
        runIo(request, documentWorker, createsCandidate = request.kind == Kind.IMPORT, work = { operation ->
            if (request.kind == Kind.CONFIG) readConfig(uri, operation)
            else if (request.kind == Kind.IMPORT) candidateView { files.prepareImport(openInput(uri), operation) }
            else {
                files.writeArchive(checkNotNull(request.token), openOutput(uri), operation)
                emptyMap()
            }
        }) { view ->
            if (request.kind == Kind.CONFIG && !request.active.get()) finish(request, checkNotNull(request.retirement))
            else finish(request, result(request, if (request.kind == Kind.EXPORT) "saved" else "ready") + view)
        }
        return true
    }

    /** Read candidate metadata on the same file I/O executor as private backup operations. */
    fun candidate(token: String, reply: (Map<String, Any?>) -> Unit) {
        val request = begin("candidate:$token", Kind.INSPECT, reply, token) ?: return
        runIo(request, storageWorker, work = { view(files.candidate(token)) }) {
            finish(request, result(request, "ready") + it)
        }
    }

    fun cancel(requestId: String) {
        pending?.takeIf { it.id == requestId }?.let { invalidate(it, "cancelled", "backupCancelled") }
    }

    /**
     * Schedule discard on the file I/O executor; retain the record until
     * provider I/O completes.
     */
    fun discardCandidate(token: String, reply: (Throwable?) -> Unit = {}) {
        val request = pending
        if (request != null && request.token == token) {
            request.discard = true
            request.discardReplies += reply
            return
        }
        cleanup(null, token, storageWorker, reply = reply)
    }

    private fun begin(id: String, kind: Kind, reply: (Map<String, Any?>) -> Unit,
        token: String? = null, businessOwner: RestoreTransaction.Owner? = null): Request? {
        if (id.isBlank() || id.length > 256) {
            reply(mapOf("status" to "failed", "requestId" to id, "errorCode" to "backupInvalidRequest"))
            return null
        }
        if (pending != null) {
            reply(mapOf("status" to "busy", "requestId" to id, "errorCode" to "backupBusy", "draining" to (pending?.active?.get() == false)))
            return null
        }
        val host = activity
        if (host == null) {
            reply(mapOf("status" to "failed", "requestId" to id, "errorCode" to "backupNoActivity"))
            return null
        }
        return Request(id, kind, host, reply, token, businessOwner).also {
            pending = it
            lastErrorCode = null
            lastErrorDetail = null
            changed()
        }
    }

    private fun picker(request: Request, intent: Intent) {
        if (!request.active.get() || pending !== request || activity !== request.activity) {
            invalidate(request, "cancelled", "backupActivityChanged")
            return
        }
        if (lastCode == LAST_CODE) {
            finish(request, result(request, "failed", "backupRequestCodeExhausted"))
            return
        }
        request.code = ++lastCode
        request.phase = Phase.PICKER
        try { launch(checkNotNull(request.activity), intent, request.code) }
        catch (error: Exception) { finish(request, result(request, "failed", "backupPickerUnavailable", error)) }
        changed()
    }

    private fun runIo(request: Request, worker: Executor, createsCandidate: Boolean = false,
        work: (BackupFiles.Operation) -> Map<String, Any?>,
        success: (Map<String, Any?>) -> Unit) {
        val operation = BackupFiles.Operation(request, clock)
        val timeout = Runnable { if (pending === request) invalidate(request, "expired", "backupTimedOut") }
        request.timeout = timeout
        delay(timeout, IO_TIMEOUT_MS)
        try {
            worker.execute {
                var view: Map<String, Any?>? = null
                var failure: Throwable? = null
                try {
                    operation.check()
                    view = work(operation)
                } catch (error: Exception) { failure = error }
                post(Runnable {
                    request.timeout?.let(remove)
                    request.timeout = null
                    val error = failure
                    if (error != null) {
                        val retired = request.retirement
                        val status = if (error is CancellationException) retired?.get("status") as? String ?: "expired" else "failed"
                        val code = if (error is CancellationException) retired?.get("errorCode") as? String ?: "backupExpired"
                            else errorCode(request, error)
                        finish(request, result(request, status, code, error))
                    } else if (!request.active.get() && request.kind == Kind.EXPORT && request.phase == Phase.PRIVATE_IO) {
                        // The token read completed, but cancellation cannot authorize a new picker.
                        finish(request, checkNotNull(request.retirement))
                    } else {
                        val actual = checkNotNull(view)
                        val unowned = if (createsCandidate && !request.active.get()) actual["token"] as? String else null
                        if (unowned != null) cleanup(request, unowned, storageWorker, result(request, "ready") + actual)
                        else success(actual)
                    }
                })
            }
        } catch (error: Exception) {
            remove(timeout)
            request.timeout = null
            finish(request, result(request, "failed", "backupWorkerUnavailable", error))
        }
        changed()
    }

    private fun invalidate(request: Request, status: String, error: String) {
        if (pending !== request || !request.active.get()) return
        request.invalidate()
        request.activity = null
        request.timeout?.let(remove)
        request.timeout = null
        val value = result(request, status, error)
        request.retirement = value
        if (request.phase == Phase.PICKER) finish(request, value)
        else changed() // The original reply remains pending until actual I/O and close return.
    }

    private fun finish(request: Request, value: Map<String, Any?>?) {
        if (pending !== request) return
        request.timeout?.let(remove)
        request.timeout = null
        request.activity = null
        if (request.discard && request.token != null) {
            cleanup(request, request.token, storageWorker, value)
            return
        }
        pending = null
        if (value != null) deliver(request, value)
        changed()
    }

    private fun deliver(request: Request, value: Map<String, Any?>) {
        request.invalidate()
        val reply = request.reply
        request.reply = null
        reply?.invoke(value)
    }

    private fun cleanup(request: Request?, token: String, worker: Executor,
        value: Map<String, Any?>? = null, reply: (Throwable?) -> Unit = {}) {
        if (request != null) { request.phase = Phase.CLEANUP; request.invalidate() }
        fun complete(error: Throwable?) {
            val detail = error?.let { AppMessage("backupFailed").withDetail(it).toMap() }
            if (error != null) {
                lastErrorCode = "backupCleanupFailed"
                lastErrorDetail = detail
            }
            if (request != null && pending === request) {
                pending = null
                val response = if (detail == null) value else
                    (value ?: result(request, "failed", "backupCleanupFailed")) + ("cleanupError" to detail)
                if (response != null) deliver(request, response)
            }
            request?.discardReplies?.forEach { it(error) }
            reply(error)
            changed()
        }
        try {
            worker.execute {
                val failure = try { files.discard(token); null } catch (error: Exception) { error }
                post(Runnable { complete(failure) })
            }
        } catch (error: Exception) { complete(error) }
    }

    private fun candidateView(create: () -> BackupFiles.Candidate): Map<String, Any?> {
        val candidate = create()
        try {
            return view(candidate)
        } catch (error: Throwable) {
            try { files.discard(candidate.token) } catch (cleanup: Throwable) { error.addSuppressed(cleanup) }
            throw error
        }
    }

    private fun view(candidate: BackupFiles.Candidate): Map<String, Any?> = mapOf(
        "token" to candidate.token,
        "createdAtMillis" to candidate.createdAtMillis,
        "paths" to files.candidateReadPaths(candidate.token),
        "parts" to candidate.parts.entries.associate { (kind, value) -> kind.fileName to mapOf("bytes" to value.bytes, "sha256" to value.sha256) },
    )

    private fun result(request: Request, status: String, error: String? = null,
        cause: Throwable? = null): Map<String, Any?> = mapOf(
        "status" to status, "requestId" to request.id, "errorCode" to error,
        "errorDetail" to cause?.let { AppMessage("backupFailed").withDetail(it).toMap() },
        "externalMayBePartial" to request.externalMayBePartial,
        "retired" to !request.active.get(),
        "retirement" to request.retirement,
    )

    private fun errorCode(request: Request, error: Throwable?) = when {
        error is ConfigTooLarge -> "textTooLargeImport"
        request.kind == Kind.CONFIG -> "fileUnreadable"
        error is CancellationException -> "backupExpired"
        request.phase == Phase.DOCUMENT_IO -> "backupDocumentIoFailed"
        else -> "backupCaptureFailed"
    }

    private fun restoredCode(state: Bundle, key: String, absent: Int): Int {
        if (!state.containsKey(key)) return absent
        @Suppress("DEPRECATION") val value = state.get(key)
        // Malformed saved allocator data fails closed instead of recycling possibly outstanding codes.
        return if (value is Int && (value == absent || value in FIRST_CODE..LAST_CODE)) value else LAST_CODE
    }

    companion object {
        internal const val FIRST_CODE = 0x4000
        internal const val LAST_CODE = 0x7fff
        internal const val HIGH_WATER = "clash_pseudo.backup.lastCode"
        internal const val PENDING_CODE = "clash_pseudo.backup.pendingCode"
        const val IO_TIMEOUT_MS = ApplicationContract.OPERATION_BACKUP_TIMEOUT_MS
        @Volatile private var instance: BackupCalls? = null
        private val documentExecutor: Executor by lazy {
            Executors.newSingleThreadExecutor { work -> Thread(work, "pseudo-document-io").apply { isDaemon = true } }
        }
        internal fun documentName(resolver: ContentResolver, uri: Uri): String =
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                val column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (column >= 0 && cursor.moveToFirst() && !cursor.isNull(column)) cursor.getString(column) else ""
            }.orEmpty()

        internal fun openDocumentInput(resolver: ContentResolver, uri: Uri): InputStream {
            val descriptor = resolver.openFileDescriptor(uri, "r") ?: throw IOException("Document descriptor unavailable")
            try { return ParcelFileDescriptor.AutoCloseInputStream(descriptor) }
            catch (error: Throwable) {
                try { descriptor.close() } catch (cleanup: Throwable) { error.addSuppressed(cleanup) }
                throw error
            }
        }

        @Synchronized fun get(context: Context, changed: () -> Unit): BackupCalls = instance ?: run {
            val resolver = context.applicationContext.contentResolver
            val files = BackupFiles.get(context)
            val handler = Handler(Looper.getMainLooper())
            BackupCalls(files, changed,
                launch = { activity, intent, code -> activity.startActivityForResult(intent, code) },
                openInput = { uri -> openDocumentInput(resolver, uri) },
                openOutput = { uri ->
                    val descriptor = resolver.openFileDescriptor(uri, "wt") ?: throw IOException("Document descriptor unavailable")
                    try { ParcelFileDescriptor.AutoCloseOutputStream(descriptor) }
                    catch (error: Throwable) {
                        try { descriptor.close() } catch (cleanup: Throwable) { error.addSuppressed(cleanup) }
                        throw error
                    }
                },
                documentWorker = documentExecutor, storageWorker = files.ioExecutor,
                post = { handler.post(it) }, delay = { task, millis -> handler.postDelayed(task, millis) },
                remove = { handler.removeCallbacks(it) }, clock = { SystemClock.elapsedRealtime() },
                displayName = { uri -> documentName(resolver, uri) },
            )
        }.also { instance = it }
    }
}
