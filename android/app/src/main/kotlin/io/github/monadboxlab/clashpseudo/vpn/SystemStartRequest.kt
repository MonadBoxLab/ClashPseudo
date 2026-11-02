package io.github.monadboxlab.clashpseudo.vpn

/**
 * Synchronize the pending restore across main and onRevoke callback threads; it
 * belongs to one Service instance.
 */
internal class SystemStartRequest {
    private var owner: Any? = null
    private var startId = 0
    private var revision = 0L
    private var destroyed = false
    private var terminalStop = false

    @Synchronized fun allow() { terminalStop = false }

    @Synchronized fun observeStart(id: Int) {
        if (owner != null) startId = id
    }

    @Synchronized fun begin(id: Int, phase: NativeSession.Phase = NativeSession.Phase.STOPPED): Any? {
        if (destroyed || terminalStop ||
            phase !in setOf(NativeSession.Phase.STOPPED, NativeSession.Phase.STOPPING)) return null
        startId = id
        if (owner != null) return null
        revision++
        return Any().also { owner = it }
    }

    @Synchronized fun pending(): Boolean = owner != null && !destroyed
    @Synchronized fun current(token: Any): Boolean = owner === token && !destroyed

    @Synchronized fun finish(token: Any): Int? {
        if (!current(token)) return null
        owner = null
        return startId
    }

    @Synchronized fun cancel(terminal: Boolean = false): Pair<Int, Long>? {
        if (terminal) terminalStop = true
        if (owner == null) return null
        revision++
        owner = null
        return startId to revision
    }

    @Synchronized fun idle(expected: Long): Boolean =
        !destroyed && owner == null && revision == expected

    @Synchronized fun destroy() {
        destroyed = true
        owner = null
        revision++
    }
}
