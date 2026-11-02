package io.github.monadboxlab.clashpseudo.storage

import android.content.Context
import android.os.Handler
import android.os.SystemClock
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.backup.BackupFiles
import io.github.monadboxlab.clashpseudo.backup.RestoreTransaction
import io.github.monadboxlab.clashpseudo.backup.backupInteger
import io.github.monadboxlab.clashpseudo.bridge.operation.OperationState
import io.github.monadboxlab.clashpseudo.message.AppMessage
import io.github.monadboxlab.clashpseudo.nativecore.CoreClient
import io.github.monadboxlab.clashpseudo.nativecore.CoreLifecycleCalls

internal class CoreCleanupCalls(
    private val context: Context,
    private val main: Handler,
    private val operations: OperationState,
    private val publicationOwner: (String) -> RestoreTransaction.Owner,
    private val setPublicationBusy: (Boolean) -> Unit,
    private val cancelPendingRefresh: () -> Unit,
    private val cancelSystemRestore: () -> Boolean,
    private val backupBusy: () -> Boolean,
    private val notifyUi: () -> Unit,
) {
    @Volatile var exitingForCleanup = false
        private set

    fun scheduleCoreCleanup(call: MethodCall, owner: String, result: MethodChannel.Result) {
        val epoch = backupInteger(operations.command?.get("storageEpoch"))
        val admittedAt = operations.operationAdmittedAt ?: SystemClock.elapsedRealtime()
        val deadline = operations.operationDeadline ?: admittedAt
        val paths = call.argument<List<String>>("paths")
        if (operations.command?.get("action") != "scheduleCoreCleanup" || epoch == null || paths.isNullOrEmpty() || backupBusy()) {
            result.error("coreCleanup", null, AppMessage("coreCleanupRequired").toMap())
            return
        }
        val cleanup = CoreDataCleanup.get(context)
        val files = BackupFiles.get(context)
        val client = CoreClient.get(context)
        val lease = publicationOwner(owner)
        val request = try { CoreDataCleanup.Request(paths) }
        catch (error: Throwable) { result.error("coreCleanup", null, AppMessage("coreCleanupFailed").withDetail(error).toMap()); return }
        exitingForCleanup = true
        setPublicationBusy(true)
        cancelPendingRefresh()
        cancelSystemRestore()
        fun failure(error: Throwable) {
            setPublicationBusy(false)
            exitingForCleanup = false
            result.error("coreCleanup", null, AppMessage("coreCleanupFailed").withDetail(error).toMap())
            notifyUi()
        }
        try { files.ioExecutor.execute {
            val recorded = runCatching {
                files.transaction.withStableStorage(epoch) {
                    lease.checkCurrent()
                    cleanup.schedule(request, lease::runIfCurrent)
                    client.lifecycle.cleanup(true)
                }
            }
            main.post {
                recorded.fold(onFailure = ::failure, onSuccess = {
                    client.exit(client.status()[Contract.CORE_FIELD_PROCESS_ID] as? String ?: "", admittedAt,
                        deadline.coerceAtLeast(admittedAt), "cleanup") { stopError ->
                        if (stopError != null) { failure(stopError); return@exit }
                        try { files.ioExecutor.execute {
                            val outcome = runCatching {
                                val error = cleanup.drain()
                                if (error == null && cleanup.ready) client.lifecycle.cleanup(false)
                                cleanup.snapshot() + mapOf("success" to (error == null && cleanup.ready),
                                    "items" to cleanup.snapshot()["files"])
                            }
                            main.post {
                                outcome.fold(onFailure = ::failure, onSuccess = { value ->
                                    setPublicationBusy(false)
                                    exitingForCleanup = false
                                    result.success(value)
                                    notifyUi()
                                })
                            }
                        } } catch (error: Throwable) { failure(error) }
                    }
                })
            }
        } } catch (error: Throwable) { failure(error) }
    }
}
