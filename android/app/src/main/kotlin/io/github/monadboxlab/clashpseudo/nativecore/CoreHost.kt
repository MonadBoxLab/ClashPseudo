package io.github.monadboxlab.clashpseudo.nativecore

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.annotation.Keep
import io.github.monadboxlab.clashpseudo.vpn.NativeSession
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Owns one loaded configuration, separately from the VPN/TUN lifecycle. */
class CoreHost(
    private val session: NativeSession,
    private val changed: () -> Unit,
    val worker: Executor = Executors.newSingleThreadExecutor { task -> Thread(task, "pseudo-native") },
    private val idleMs: Long = 30000,
    private val prepareNative: (String, ByteArray, String, Any, ByteArray) -> String =
        { home, body, mode, protector, choices -> NativeCore.prepare(home, body, mode, protector, choices) },
    private val stopNative: () -> String = { NativeCore.stop() },
    private val cancelNative: () -> Unit = { NativeCore.cancel() },
) {
    enum class Phase { EMPTY, LOADING, READY, RELEASING, FAILED }
    enum class Purpose { PREVIEW, VPN }
    data class Snapshot(
        val generation: Long = 0,
        val phase: Phase = Phase.EMPTY,
        val purpose: Purpose? = null,
        val configId: String? = null,
        val revision: Int? = null,
        val error: String? = null,
    ) {
        fun toMap(): Map<String, Any?> = mapOf(
            "generation" to generation, "phase" to phase.name, "purpose" to purpose?.name,
            "configId" to configId, "revision" to revision, "error" to error,
        )
    }

    private class Lease(val state: Snapshot, val owner: String?, val vpnGeneration: Long?,
                        private val session: NativeSession) {
        val active = AtomicBoolean(true)
        @Keep
        fun protectSocket(@Suppress("UNUSED_PARAMETER") fd: Int): Boolean =
            active.get() && session.snapshot().phase == NativeSession.Phase.STOPPED
    }

    private val main = Handler(Looper.getMainLooper())
    @Volatile private var state = Snapshot()
    @Volatile private var lease: Lease? = null
    @Volatile private var visible = false
    @Volatile private var operationBusy = false
    @Volatile private var visibilityRevision = 0L
    private var hiddenAt = SystemClock.elapsedRealtime()
    private val idle = Runnable { expirePreview() }

    fun snapshot(): Snapshot = state

    fun current(generation: Long): Boolean {
        val loaded = lease ?: return false
        val now = state
        if (now.generation != generation || now.phase != Phase.READY || !loaded.active.get()) return false
        val vpn = session.snapshot()
        return when (now.purpose) {
            Purpose.PREVIEW -> vpn.phase == NativeSession.Phase.STOPPED
            Purpose.VPN -> vpn.phase == NativeSession.Phase.RUNNING && vpn.generation == loaded.vpnGeneration
            null -> false
        }
    }

    // These lifecycle inputs are delivered on the main thread.
    fun setVisible(value: Boolean) {
        if (visible == value) return
        visible = value
        visibilityRevision++
        if (!value) hiddenAt = SystemClock.elapsedRealtime()
        scheduleIdle()
    }

    fun setOperationBusy(value: Boolean) {
        operationBusy = value
        scheduleIdle()
    }

    private fun scheduleIdle() {
        main.removeCallbacks(idle)
        if (visible || operationBusy || state.purpose != Purpose.PREVIEW || state.phase != Phase.READY) return
        main.postDelayed(idle, (hiddenAt + idleMs - SystemClock.elapsedRealtime()).coerceAtLeast(0))
    }

    private fun expirePreview() {
        val revision = visibilityRevision
        val generation = state.generation
        worker.execute {
            if (visible || operationBusy || revision != visibilityRevision || state.generation != generation ||
                session.snapshot().phase != NativeSession.Phase.STOPPED) return@execute
            releasePreview()
        }
    }

    // Prepare/query/change/release callers all use worker; cancellation only invalidates a lease.
    fun preparePreview(owner: String, id: String, revision: Int, home: String,
                       active: () -> Boolean, input: () -> CoreInput): Snapshot {
        check(active() && session.snapshot().phase == NativeSession.Phase.STOPPED)
        if (state.phase == Phase.READY && state.purpose == Purpose.PREVIEW &&
            state.configId == id && state.revision == revision && current(state.generation)) return state
        return prepare(owner, id, revision, Purpose.PREVIEW, null, home,
            { active() && session.snapshot().phase == NativeSession.Phase.STOPPED }, input, null)
    }

    fun prepareVpn(generation: Long, id: String?, revision: Int?, home: String,
                   input: () -> CoreInput, protector: Any): Snapshot =
        prepare(null, id, revision, Purpose.VPN, generation, home,
            { session.canStart(generation) }, input, protector)

    private fun prepare(owner: String?, id: String?, revision: Int?, purpose: Purpose,
                        vpnGeneration: Long?, home: String, active: () -> Boolean,
                        input: () -> CoreInput, protector: Any?): Snapshot {
        check(active() && state.phase != Phase.FAILED)
        check(state.purpose != Purpose.VPN || state.phase == Phase.EMPTY) { "VPN context is still owned" }
        check(releaseOwned() == null) { "Previous cleanup is unconfirmed" }
        check(active())
        val loading = Snapshot(state.generation + 1, Phase.LOADING, purpose, id, revision)
        val token = Lease(loading, owner, vpnGeneration, session)
        lease = token
        publish(loading)
        try {
            val value = input()
            check(value.id == id && value.revision == revision)
            check(active() && token.active.get())
            check(prepareNative(home, value.body, value.mode, protector ?: token, value.choices).isEmpty())
            return synchronized(this) {
                check(active() && token.active.get())
                publish(loading.copy(phase = Phase.READY))
                state
            }
        } catch (error: Exception) {
            failedPreparation(token)
            throw error
        } catch (error: LinkageError) {
            failedPreparation(token)
            throw error
        }
    }

    private fun failedPreparation(token: Lease) {
        if (lease !== token) return
        if (releaseOwned() == null) {
            publish(state.copy(purpose = token.state.purpose, configId = token.state.configId,
                revision = token.state.revision, error = "策略配置加载未完成，请检查配置与网络后重试。"))
        }
    }

    @Synchronized
    fun cancelPreparation(owner: String) {
        val token = lease ?: return
        if (token.owner == owner && token.state.purpose == Purpose.PREVIEW) {
            token.active.set(false)
            // A waiter can expire just after native preparation becomes ready.
            // Queue identity-checked cleanup, never cancellation of a newer owner.
            if (state.phase == Phase.READY) worker.execute {
                if (lease === token) releaseOwned()
            }
        }
    }

    fun cancelVpn(generation: Long) {
        val token = lease ?: return
        if (token.state.purpose == Purpose.VPN && token.vpnGeneration == generation) {
            token.active.set(false)
            cancelSafely()
        }
    }

    private fun cancelSafely() {
        try { cancelNative() } catch (_: LinkageError) { }
    }

    fun releasePreview(): String? {
        if (state.purpose != Purpose.PREVIEW) return null
        if (state.phase == Phase.EMPTY) {
            publish(Snapshot(generation = state.generation))
            return null
        }
        return releaseOwned()
    }

    fun stopVpn(generation: Long): String? {
        val token = lease ?: return null
        if (token.state.purpose != Purpose.VPN || token.vpnGeneration != generation) return null
        return releaseOwned()
    }

    private fun releaseOwned(): String? {
        if (state.phase == Phase.FAILED) return state.error ?: "原生资源释放未确认。"
        val token = lease ?: return null
        token.active.set(false)
        publish(state.copy(phase = Phase.RELEASING))
        val error = try { stopNative().takeIf { it.isNotEmpty() }?.let { "原生资源释放未确认。" } }
            catch (_: Exception) { "原生资源释放未确认。" }
            catch (_: LinkageError) { "原生资源释放未确认。" }
        if (error == null) {
            lease = null
            publish(Snapshot(generation = state.generation))
        } else {
            publish(state.copy(phase = Phase.FAILED, error = error))
        }
        return error
    }

    private fun publish(value: Snapshot) {
        state = value
        main.post { changed(); scheduleIdle() }
    }
}
