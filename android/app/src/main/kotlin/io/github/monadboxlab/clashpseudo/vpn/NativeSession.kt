package io.github.monadboxlab.clashpseudo.vpn

class NativeSession {
    enum class Phase { STOPPED, STARTING, RUNNING, STOPPING, UNKNOWN }
    data class Snapshot(val generation: Long, val phase: Phase, val error: String?,
        val configId: String?, val revision: Int?)
    var changed: () -> Unit = {}
    private var configId: String? = null
    private var revision: Int? = null

    // Worker completions must match this generation before changing service state.
    private var generation = 0L
    private var phase = Phase.STOPPED
    private var error: String? = null

    @Synchronized fun begin(configId: String? = null, revision: Int? = null): Long? {
        if (phase != Phase.STOPPED) return null
        generation += 1
        phase = Phase.STARTING
        error = null
        this.configId = configId
        this.revision = revision
        changed()
        return generation
    }

    @Synchronized fun canStart(id: Long) = id == generation && phase == Phase.STARTING

    @Synchronized fun attached(id: Long): Boolean {
        if (!canStart(id)) return false
        phase = Phase.RUNNING
        changed()
        return true
    }

    @Synchronized fun stopping(id: Long, reason: String? = null): Boolean {
        if (id != generation || phase !in listOf(Phase.STARTING, Phase.RUNNING)) return false
        phase = Phase.STOPPING
        if (reason != null) error = reason
        changed()
        return true
    }

    @Synchronized fun finished(id: Long, cleanupError: String?) {
        if (id != generation || phase != Phase.STOPPING) return
        phase = if (cleanupError == null) Phase.STOPPED else Phase.UNKNOWN
        if (cleanupError != null) error = listOfNotNull(error, cleanupError).joinToString("; ")
        if (phase == Phase.STOPPED) {
            configId = null
            revision = null
        }
        changed()
    }

    @Synchronized fun snapshot() = Snapshot(generation, phase, error, configId, revision)
}
