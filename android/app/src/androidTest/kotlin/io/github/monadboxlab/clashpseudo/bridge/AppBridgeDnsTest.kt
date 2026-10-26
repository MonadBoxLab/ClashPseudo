package io.github.monadboxlab.clashpseudo.bridge

import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.monadboxlab.clashpseudo.nativecore.CoreHost
import io.github.monadboxlab.clashpseudo.nativecore.CoreInput
import io.github.monadboxlab.clashpseudo.vpn.NativeSession
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Test

/** Exercises production admission with an isolated CoreHost. */
class AppBridgeDnsTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private fun main(block: () -> Unit) = instrumentation.runOnMainSync(block)
    private class Reply : MethodChannel.Result {
        val done = CountDownLatch(1)
        var error: String? = null
        var success = false
        override fun success(result: Any?) { success = true; done.countDown() }
        override fun error(code: String, message: String?, details: Any?) { error = code; done.countDown() }
        override fun notImplemented() { fail("production DNS method not implemented") }
        fun await() { assertTrue(done.await(2, TimeUnit.SECONDS)) }
    }

    @Test fun fullIdentityAndQueryOwnerAreRequiredBeforeAnyNativeOperation() {
        main {
            assertEquals(NativeSession.Phase.STOPPED, PseudoVpnService.session.snapshot().phase)
            assertEquals(CoreHost.Phase.EMPTY, PseudoVpnService.core.snapshot().phase)
        }
        val clears = AtomicInteger()
        val queries = AtomicInteger()
        val cancels = AtomicInteger()
        val core = CoreHost(PseudoVpnService.session, {}, Executor { it.run() },
            prepareNative = { _, _, _, _, _, _ -> "" }, stopNative = { "" }, cancelNative = {}, readLogWindow = { null })
        val source = core.preparePreview("bridge-dns", "dns-main", 7, "unused", { true }) {
            CoreInput("dns-main", 7, null, byteArrayOf(), "{}".toByteArray(), name = "Main")
        }
        lateinit var reads: CoreReadCalls
        main {
            reads = CoreReadCalls(core,
                queryDns = { queries.incrementAndGet(); "{}" }, cancelDns = { cancels.incrementAndGet() },
                clearDns = { clears.incrementAndGet(); "{\"status\":\"completed\",\"resolverActive\":true,\"systemResolverActive\":false}" },
                dnsWorker = Executor { it.run() }, networkEpoch = { 3 })
        }
        fun identity() = mutableMapOf<String, Any?>("generation" to source.generation, "composition" to source.composition,
            "configId" to source.configId, "revision" to source.revision, "purpose" to "PREVIEW",
            "queryOwner" to "dns-request-one", "query" to mapOf("name" to "test.test", "type" to "A"))
        fun invoke(method: String, body: Map<String, Any?>): Reply {
            val reply = Reply()
            main { reads.handleDns(MethodCall(method, body), reply) }
            reply.await()
            return reply
        }
        try {
            for (method in listOf("dnsQuery", "clearDnsCache", "flushFakeIp")) {
                for (field in listOf("generation", "composition", "configId", "revision", "purpose")) {
                    val missing = identity().apply { remove(field) }
                    assertNotNull("$method accepted missing $field", invoke(method, missing).error)
                    val mismatch = identity().apply { this[field] = if (field == "generation" || field == "revision") -1L else "wrong" }
                    assertNotNull("$method accepted wrong $field", invoke(method, mismatch).error)
                }
                for (field in listOf("generation", "revision")) {
                    assertNotNull(invoke(method, identity().apply { this[field] = 1.5 }).error)
                }
            }
            for (owner in listOf(null, "", "x".repeat(129))) {
                assertNotNull(invoke("dnsQuery", identity().apply { this["queryOwner"] = owner }).error)
            }
            assertEquals(0, clears.get()); assertEquals(0, queries.get())
            // Valid controls distinguish identity validation from unconditional rejection.
            assertTrue(invoke("clearDnsCache", identity()).success)
            assertEquals(1, clears.get())
            assertTrue(invoke("dnsQuery", identity()).success)
            assertEquals(1, queries.get())
            assertTrue(invoke("cancelDnsQuery", identity().apply { this["generation"] = source.generation + 1 }).success)
            assertEquals(0, cancels.get())
        } finally {
            val drained = CountDownLatch(1)
            core.worker.execute { drained.countDown() }
            assertTrue(drained.await(2, TimeUnit.SECONDS))
            core.releasePreview()
        }
    }
}
