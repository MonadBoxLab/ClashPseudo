package io.github.monadboxlab.clashpseudo.vpn

import io.github.monadboxlab.clashpseudo.message.AppMessage

class NativeSession(private val clock: () -> Long = { android.os.SystemClock.elapsedRealtime() }) {
    enum class Phase { STOPPED, STARTING, RUNNING, STOPPING, UNKNOWN }
    data class Snapshot(val generation: Long, val phase: Phase, val error: AppMessage?,
        val configId: String?, val revision: Int?,
        val runningSinceElapsedMs: Long? = null, val elapsedRealtimeMs: Long = 0)
    var changed: () -> Unit = {}
    private var runningSinceElapsedMs: Long? = null
    private var configId: String? = null
    private var revision: Int? = null

    // Worker completions must match this generation before changing service state.
    private var generation = 0L
    private var phase = Phase.STOPPED
    private var error: AppMessage? = null

    @Synchronized fun failedStart(id: Long, reason: AppMessage) {
        if (id != generation || phase != Phase.STOPPED) return
        error = reason
        changed()
    }

    @Synchronized fun begin(configId: String? = null, revision: Int? = null): Long? {
        if (phase != Phase.STOPPED) return null
        generation += 1
        phase = Phase.STARTING
        runningSinceElapsedMs = null
        error = null
        this.configId = configId
        this.revision = revision
        changed()
        return generation
    }

    @Synchronized fun canStart(id: Long) = id == generation && phase == Phase.STARTING

    @Synchronized fun wasAttached(id: Long) = id == generation && runningSinceElapsedMs != null

    @Synchronized fun attached(id: Long): Boolean {
        if (!canStart(id)) return false
        phase = Phase.RUNNING
        runningSinceElapsedMs = clock()
        changed()
        return true
    }

    @Synchronized fun stopping(id: Long, reason: AppMessage? = null): Boolean {
        if (id != generation) return false
        if (phase == Phase.STOPPING) {
            if (reason != null) {
                error = error?.withDetail(reason.detail ?: reason.toMap()) ?: reason
                changed()
            }
            return false
        }
        if (phase !in listOf(Phase.STARTING, Phase.RUNNING)) return false
        phase = Phase.STOPPING
        if (reason != null) error = reason
        changed()
        return true
    }

    @Synchronized fun finished(id: Long, cleanupError: AppMessage?) {
        if (id != generation || phase != Phase.STOPPING) return
        phase = if (cleanupError == null) Phase.STOPPED else Phase.UNKNOWN
        if (cleanupError != null) error = error?.let { operation ->
            AppMessage("operationAndCleanupFailed", mapOf("operation" to operation, "cleanup" to cleanupError))
        } ?: cleanupError
        if (phase == Phase.STOPPED) {
            configId = null
            revision = null
        }
        changed()
    }

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
        changed()
    }

    @Synchronized fun snapshot() = Snapshot(generation, phase, error, configId, revision,
        runningSinceElapsedMs.takeIf { phase == Phase.RUNNING }, clock())
}
