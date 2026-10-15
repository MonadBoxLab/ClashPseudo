package io.github.monadboxlab.clashpseudo.app

import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import io.github.monadboxlab.clashpseudo.nativecore.CoreHost
import io.github.monadboxlab.clashpseudo.vpn.NativeSession
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService

class NativeCalls(private val context: Context) {
    private val main = Handler(Looper.getMainLooper())
    private var result: MethodChannel.Result? = null
    private var generation = 0L
    private var starting = false
    private val timeout = Runnable {
        // A timed-out wait is not a successful stop. Cancel any late startup.
        sendStop()
        complete("接管操作等待超时，请核实实际状态。")
    }

    fun start(id: String, revision: Int, mode: String, owner: String, reply: MethodChannel.Result) {
        if (mode !in ModeCalls.VALUES) {
            reply.error("mode", "无法识别运行模式。", null)
            return
        }
        val state = PseudoVpnService.session.snapshot()
        if (state.phase != NativeSession.Phase.STOPPED || result != null) {
            reply.error("busy", "当前接管未停止，不能启动新配置。", null)
            return
        }
        if (PseudoVpnService.core.snapshot().phase in setOf(CoreHost.Phase.LOADING, CoreHost.Phase.RELEASING, CoreHost.Phase.FAILED)) {
            reply.error("core", "内核资源未就绪，不能启动新配置。", null)
            return
        }
        if (VpnService.prepare(context) != null) {
            reply.error("permission", "VPN 授权未完成或已失效。", null)
            return
        }
        starting = true
        generation = state.generation + 1
        result = reply
        main.postDelayed(timeout, 45000)
        try {
            val intent = Intent(context, PseudoVpnService::class.java)
                .setAction(PseudoVpnService.ACTION_START)
                .putExtra(PseudoVpnService.EXTRA_CONFIG_ID, id)
                .putExtra(PseudoVpnService.EXTRA_REVISION, revision)
                .putExtra(PseudoVpnService.EXTRA_MODE, mode)
                .putExtra(PseudoVpnService.EXTRA_INPUT_OWNER, owner)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent)
            else context.startService(intent)
        } catch (_: Exception) {
            complete("系统未允许启动 VPN 服务，请返回应用后重试。")
        }
    }

    fun stop(reply: MethodChannel.Result) {
        val state = PseudoVpnService.session.snapshot()
        if (state.phase == NativeSession.Phase.STOPPED) {
            reply.success(null)
            return
        }
        if (result != null || state.phase == NativeSession.Phase.UNKNOWN) {
            reply.error("unconfirmed", "资源释放未确认，不能报告已停止或重新启动。", null)
            return
        }
        starting = false
        generation = state.generation
        result = reply
        main.postDelayed(timeout, 45000)
        sendStop()
    }

    fun changed() {
        if (result == null) return
        val state = PseudoVpnService.session.snapshot()
        if (state.generation != generation) return
        when (state.phase) {
            NativeSession.Phase.RUNNING -> if (starting) complete(null)
            NativeSession.Phase.STOPPED -> complete(if (starting) state.error ?: "接管未能启动。" else null)
            NativeSession.Phase.UNKNOWN -> complete(state.error ?: "无法确认接管资源是否已释放。")
            else -> Unit
        }
    }

    fun abandon() {
        main.removeCallbacks(timeout)
        if (result != null) sendStop()
        result = null
    }

    private fun sendStop() {
        try {
            context.startService(Intent(context, PseudoVpnService::class.java)
                .setAction(PseudoVpnService.ACTION_STOP))
        } catch (_: Exception) {
            complete("系统未受理停止请求，接管状态未确认。")
        }
    }

    private fun complete(error: String?) {
        val receiver = result ?: return
        result = null
        main.removeCallbacks(timeout)
        if (error == null) receiver.success(null)
        else receiver.error("native", error, null)
    }
}
