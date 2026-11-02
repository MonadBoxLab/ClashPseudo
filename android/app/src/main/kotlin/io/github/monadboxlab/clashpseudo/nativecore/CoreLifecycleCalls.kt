package io.github.monadboxlab.clashpseudo.nativecore

import android.content.Context
import android.os.SystemClock
import io.flutter.plugin.common.MethodChannel
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.bridge.AppBridge
import io.github.monadboxlab.clashpseudo.message.AppMessage
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService

/** 备份、清理和重连共用的进程退出入口，沿原命令的受理期限。 */
class CoreLifecycleCalls(private val context: Context) {
    fun stop(reply: MethodChannel.Result, internalReconnect: Boolean = false) {
        if (!internalReconnect && PseudoVpnService.alwaysOnState() == true) {
            reply.error("alwaysOn", null, AppMessage("alwaysOnNotice").toMap())
            return
        }
        val client = CoreClient.get(context)
        val admittedAt = AppBridge.operationAdmittedAt ?: SystemClock.elapsedRealtime()
        val deadline = AppBridge.operationDeadline ?: admittedAt
        client.exit(client.status()[Contract.CORE_FIELD_PROCESS_ID] as? String ?: "", admittedAt,
            deadline.coerceAtLeast(admittedAt), if (internalReconnect) "reconnect" else "stop") { error ->
            if (error == null) reply.success(null)
            else reply.error("unconfirmed", null, AppMessage("operationNotCompletedRetry").withDetail(error).toMap())
        }
    }

    fun abandon(owner: String? = AppBridge.operationId) { if (owner != null) CoreClient.get(context).cancelOwner(owner) }

    fun cancelStarting(processId: String, inputId: String, admittedAt: Long, deadline: Long) {
        val client = CoreClient.get(context)
        val captured = client.status()
        if (captured[Contract.CORE_FIELD_PROCESS_ID] != processId || captured[Contract.CORE_FIELD_INPUT_ID] != inputId) return
        client.exit(processId, admittedAt, deadline, "stop") { error ->
            if (error != null) android.util.Log.e("PseudoSchedule", "取消 STARTING 后未确认 core 退出", error)
        }
    }

}
