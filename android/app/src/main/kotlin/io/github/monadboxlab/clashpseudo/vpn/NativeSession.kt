package io.github.monadboxlab.clashpseudo.vpn

import io.github.monadboxlab.clashpseudo.message.AppMessage

class NativeSession(private val clock: () -> Long = { android.os.SystemClock.elapsedRealtime() }) {
    enum class Phase { STOPPED, STARTING, RUNNING, STOPPING, UNKNOWN }
    data class Snapshot(val generation: Long, val phase: Phase, val error: AppMessage?,
        val configId: String?, val revision: Int?,
        val runningSinceElapsedMs: Long? = null, val elapsedRealtimeMs: Long = 0)
    private var runningSinceElapsedMs: Long? = null
    private var configId: String? = null
    private var revision: Int? = null
    private var generation = 0L
    private var phase = Phase.STOPPED
    private var error: AppMessage? = null

    /** 将已校验的远端系统状态投影给现有界面；进程身份由 CoreClient 核对。 */
    @Synchronized fun project(value: Map<String, Any?>) {
        generation = (value["generation"] as? Number)?.toLong() ?: generation
        configId = value["configId"] as? String
        revision = (value["revision"] as? Number)?.toInt()
        phase = when (value["phase"]) {
            "loading", "starting" -> Phase.STARTING
            "stopping" -> Phase.STOPPING
            "communicationLost" -> Phase.UNKNOWN
            "ready" -> if (value["vpnRunning"] == true) Phase.RUNNING else Phase.STOPPED
            else -> Phase.STOPPED
        }
        runningSinceElapsedMs = (value["runningSinceElapsedMs"] as? Number)?.toLong()
        error = (value["error"] as? String)?.let { AppMessage("operationNotCompletedRetry").withDetail(it) }
    }

    @Synchronized fun snapshot() = Snapshot(generation, phase, error, configId, revision,
        runningSinceElapsedMs.takeIf { phase == Phase.RUNNING }, clock())
}
