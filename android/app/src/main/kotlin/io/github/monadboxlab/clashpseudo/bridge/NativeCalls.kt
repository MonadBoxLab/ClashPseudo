package io.github.monadboxlab.clashpseudo.bridge

import io.github.monadboxlab.clashpseudo.app.AppMessage
import io.github.monadboxlab.clashpseudo.app.AppStrings

import io.github.monadboxlab.clashpseudo.R
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

class NativeCalls(private val context: Context,
                  private val alwaysOn: () -> Boolean? = { PseudoVpnService.alwaysOnState() },
                  private val core: CoreHost = PseudoVpnService.core,
                  private val session: NativeSession = PseudoVpnService.session) {
    init { CoreHost.installAndroid(context) }
    private val main = Handler(Looper.getMainLooper())
    private var result: MethodChannel.Result? = null
    private var generation = 0L
    private var starting = false
    private var internalReconnect = false
    private var stoppingPreview = false
    private val timeout = Runnable {
        // After a wait expires, cancel late startup and verify the actual Stop result.
        if (!stoppingPreview) sendStop()
        complete(AppStrings.message(R.string.error_takeover_timeout))
    }

    fun start(id: String, revision: Int, mode: String?, owner: String, reply: MethodChannel.Result) {
        if (mode != null && mode !in ModeCalls.VALUES) {
            reply.error("mode", null, AppStrings.message(R.string.error_unknown_mode).toMap())
            return
        }
        val state = session.snapshot()
        if (state.phase != NativeSession.Phase.STOPPED || result != null) {
            reply.error("busy", null, AppStrings.message(R.string.error_takeover_running).toMap())
            return
        }
        if (core.snapshot().phase in setOf(CoreHost.Phase.LOADING, CoreHost.Phase.RELEASING, CoreHost.Phase.FAILED)) {
            reply.error("core", null, AppStrings.message(R.string.error_core_not_ready).toMap())
            return
        }
        if (VpnService.prepare(context) != null) {
            reply.error("permission", null, AppStrings.message(R.string.error_vpn_permission_invalid).toMap())
            return
        }
        internalReconnect = false
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
            complete(AppStrings.message(R.string.error_vpn_service_start))
        }
    }

    fun stop(reply: MethodChannel.Result, internalReconnect: Boolean = false) {
        // Recheck at execution; preserve UNKNOWN and complete required cleanup during
        // internal reconnect.
        if (!internalReconnect && alwaysOn() == true) {
            reply.error("alwaysOn", null, AppMessage("alwaysOnNotice").toMap())
            return
        }
        if (!internalReconnect) PseudoVpnService.instance?.cancelSystemStart(terminal = true)
        val state = session.snapshot()
        if (result != null || state.phase == NativeSession.Phase.UNKNOWN) {
            reply.error("unconfirmed", null, AppStrings.message(R.string.error_release_unconfirmed).toMap())
            return
        }
        if (state.phase == NativeSession.Phase.STOPPED) {
            val source = core.snapshot()
            if (source.purpose == CoreHost.Purpose.PREVIEW) {
                stoppingPreview = true
                result = reply
                main.postDelayed(timeout, 45000)
                core.worker.execute {
                    val error = if (core.snapshot().generation == source.generation) core.releasePreview()
                        else AppStrings.message(R.string.error_core_context_reread)
                    main.post {
                        // Wait for native Stop to join its updates and preview
                        // cleanup.
                        if (result === reply && stoppingPreview) complete(error)
                    }
                }
            } else if (source.phase != CoreHost.Phase.EMPTY) {
                reply.error("core", null, (source.error ?: AppStrings.message(R.string.error_native_release_unconfirmed)).toMap())
            } else reply.success(null)
            return
        }
        this.internalReconnect = internalReconnect
        starting = false
        generation = state.generation
        result = reply
        main.postDelayed(timeout, 45000)
        sendStop()
    }

    fun changed() {
        if (result == null || stoppingPreview) return
        val state = session.snapshot()
        if (state.generation != generation) return
        when (state.phase) {
            NativeSession.Phase.RUNNING -> if (starting) complete(null)
            NativeSession.Phase.STOPPED -> complete(if (starting) state.error ?: AppStrings.message(R.string.error_takeover_start_failed) else null)
            NativeSession.Phase.UNKNOWN -> complete(state.error ?: AppStrings.message(R.string.error_takeover_release_unknown))
            else -> Unit
        }
    }

    fun abandon() {
        main.removeCallbacks(timeout)
        if (result != null && !stoppingPreview) sendStop()
        complete(AppStrings.message(R.string.error_operation_ended))
    }

    private fun sendStop() {
        try {
            context.startService(Intent(context, PseudoVpnService::class.java)
                .setAction(PseudoVpnService.ACTION_STOP)
                .putExtra(PseudoVpnService.EXTRA_INTERNAL_STOP, internalReconnect))
        } catch (_: Exception) {
            complete(AppStrings.message(R.string.error_stop_not_accepted))
        }
    }

    private fun complete(error: AppMessage?) {
        val receiver = result ?: return
        result = null
        stoppingPreview = false
        main.removeCallbacks(timeout)
        if (error == null) receiver.success(null)
        else receiver.error("native", null, error.toMap())
    }
}
