package io.github.monadboxlab.clashpseudo.logic

import android.app.Service
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import io.github.monadboxlab.clashpseudo.app.AppProcess
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.bridge.AppBridge
import io.github.monadboxlab.clashpseudo.nativecore.CoreClient
import io.github.monadboxlab.clashpseudo.nativecore.CoreControl
import io.github.monadboxlab.clashpseudo.nativecore.map
import io.github.monadboxlab.clashpseudo.nativecore.ipc.IRuntimeCallback
import io.github.monadboxlab.clashpseudo.nativecore.ipc.IRuntimeService

/** System-created :core services reuse the single existing LogicEngineHost in the default process. */
class AppRuntimeService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private val binder = object : IRuntimeService.Stub() {
        override fun dispatch(event: Bundle, callback: IRuntimeCallback) {
            CoreControl.sameUid()
            CoreControl.check(event)
            if (event.getInt(Contract.CORE_FIELD_PROTOCOL, -1) != Contract.CORE_IPC_VERSION) {
                throw IllegalArgumentException(Contract.CORE_ERROR_PROTOCOL_MISMATCH)
            }
            val processId = event.getString(Contract.CORE_FIELD_PROCESS_ID)
                ?: throw IllegalArgumentException(Contract.CORE_ERROR_IDENTITY_MISMATCH)
            fun reply(value: Bundle) {
                try { callback.onResult(value) }
                catch (error: android.os.RemoteException) {
                    android.util.Log.w("PseudoRuntime", "Runtime reply receiver is no longer available: processId=$processId", error)
                }
            }
            main.post {
                val client = CoreClient.get(this@AppRuntimeService)
                val eligibleAtAdmission = client.canAdmitSystemStart()
                if (event.getString("event") == "systemStart" && !eligibleAtAdmission) {
                    event.getParcelable<android.os.ParcelFileDescriptor>("details")?.close()
                    reply(Bundle().apply { putBoolean(Contract.CORE_FIELD_ACCEPTED, false) })
                    return@post
                }
                val deliver: (Map<String, Any?>?, Throwable?) -> Unit = deliver@{ state, error ->
                    val accepted = error == null && state?.get(Contract.CORE_FIELD_PROCESS_ID) == processId &&
                        (event.getString("event") != "revoked" || state?.get(Contract.CORE_FIELD_PHASE) !in setOf(
                            Contract.CORE_PHASE_DISCONNECTED, Contract.CORE_PHASE_EXITED))
                    if (!accepted) {
                        event.getParcelable<android.os.ParcelFileDescriptor>("details")?.close()
                        reply(Bundle().apply { putBoolean(Contract.CORE_FIELD_ACCEPTED, false) })
                        return@deliver
                    }
                    client.acceptRuntimeStatus(event) { detailsError ->
                    if (detailsError != null) {
                        reply(Bundle().apply { putBoolean(Contract.CORE_FIELD_ACCEPTED, false) })
                        return@acceptRuntimeStatus
                    }
                    when (event.getString("event")) {
                        "systemStart" -> {
                            if (!eligibleAtAdmission) {
                                reply(Bundle().apply { putBoolean(Contract.CORE_FIELD_ACCEPTED, false) })
                            } else if (client.lifecycle.snapshot().recoveryRequired) {
                                client.publishRecoveryNotice()
                                reply(Bundle().apply { putBoolean(Contract.CORE_FIELD_ACCEPTED, false) })
                            } else AppBridge.restoreSystemStart { prepared ->
                                reply(Bundle().apply { putBoolean(Contract.CORE_FIELD_ACCEPTED, prepared != null) })
                            }
                        }
                        "revoked" -> {
                            val accepted = AppBridge.systemRevoked(event.map())
                            reply(Bundle().apply { putBoolean(Contract.CORE_FIELD_ACCEPTED, accepted) })
                        }
                        else -> reply(Bundle().apply { putBoolean(Contract.CORE_FIELD_ACCEPTED, true) })
                    }
                    }
                }
                if (event.getString("event") == "revoked") {
                    val current = client.status()
                    if (current[Contract.CORE_FIELD_PROCESS_ID] != processId || current[Contract.CORE_FIELD_PHASE] in setOf(
                            Contract.CORE_PHASE_DISCONNECTED, Contract.CORE_PHASE_EXITED)) {
                        event.getParcelable<android.os.ParcelFileDescriptor>("details")?.close()
                        reply(Bundle().apply { putBoolean(Contract.CORE_FIELD_ACCEPTED, false) })
                    } else {
                        // Late revoke events only read the existing connection; they must not bind or create a core process.
                        client.refreshPresentation { error -> deliver(client.status(), error) }
                    }
                } else client.handshake(deliver)
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        AppProcess.requireApplication(this)
        AppBridge.logic.retainPlatform(true)
    }
    override fun onBind(intent: Intent?): IBinder = binder
    override fun onDestroy() {
        AppBridge.logic.retainPlatform(false)
        super.onDestroy()
    }
}
