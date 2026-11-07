package io.github.monadboxlab.clashpseudo.bridge.core

import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.bridge.core.CoreBridgeIpcScenario.Companion.collection
import io.github.monadboxlab.clashpseudo.bridge.core.CoreBridgeIpcScenario.Companion.failure
import android.os.SystemClock
import io.github.monadboxlab.clashpseudo.nativecore.CoreIpcTestDriver
import io.github.monadboxlab.clashpseudo.nativecore.CoreResourceGate
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ResourceCallsTest {
    @Test fun stoppedQueuedGeoIpRejectsReplacementUntilItsActualInputAndProcessDrain() {
        var previousProcess = ""
        CoreIpcTestDriver.production().use { driver ->
            CoreBridgeIpcScenario.success(driver.prepare(byteArrayOf(), configId = "main", revision = 1, mode = "rule"))
            val source = driver.status()
            previousProcess = driver.processId
            assertEquals(Contract.CORE_PHASE_READY, source.getString("phase"))
            val admitted = CompletableFuture<Long>()
            val release = CountDownLatch(1)
            val submission = CompletableFuture.supplyAsync {
                driver.submit(Contract.CORE_OPERATION_RESOURCE_UPDATE,
                    JSONObject().put("kind", "geo").put("name", "GeoIP"),
                    source.getString("inputId"), source.getLong("generation")) { metadata ->
                    admitted.complete(metadata.getLong("requestId"))
                    check(release.await(20, TimeUnit.SECONDS)) { "Timed out waiting to release the original GeoIP input FD" }
                }
            }
            try {
                val id = admitted.get(10, TimeUnit.SECONDS)
                assertFalse(submission.isDone)
                assertFalse(driver.receipts[id]?.isDone == true)
                val now = SystemClock.elapsedRealtime()
                driver.service.requestExit(driver.controlIdentity().apply {
                    putLong("admittedAt", now)
                    putLong("deadline", now + 20_000)
                    putString("reason", "previewExpired")
                })
                assertEquals(Contract.CORE_PHASE_STOPPING, driver.status().getString("phase"))
                var rejected: IllegalStateException? = null
                try {
                    driver.prepare(byteArrayOf(), configId = "main", revision = 1, mode = "rule")
                } catch (error: IllegalStateException) {
                    rejected = error
                }
                assertNotNull("Replacement prepare must be rejected before the old GeoIP input drains", rejected)
                assertTrue(rejected!!.message.orEmpty().contains("Core process is exiting"))
                assertFalse(driver.deathConfirmed)
                assertFalse(submission.isDone)
                assertFalse(driver.receipts[id]?.isDone == true)
                val earlyLease = CoreResourceGate.forApplication(driver.context).tryAcquire()
                earlyLease?.close()
                assertNull("The original process must still hold the resource lock", earlyLease)

                release.countDown()
                val reply = submission.get(10, TimeUnit.SECONDS).await()
                val error = failure(reply)
                assertEquals(Contract.CORE_ERROR_CANCELLED, error.getString("code"))
                assertEquals("Request was cancelled before entering the core", error.getString("message"))
                assertTrue(error.getString("stack").contains("CoreHost"))
                assertEquals(0, reply.value.length())
                assertTrue(reply.records.isEmpty())
                val receipt = driver.receipt(id)
                assertTrue(receipt.getBoolean("exited"))
                assertEquals(error.getString("message"), receipt.getJSONObject("error").getString("message"))
                driver.awaitDeath()
                val released = CoreResourceGate.forApplication(driver.context).tryAcquire()
                assertNotNull("Release the resource lock after actual input, receipt, and process drain", released)
                released!!.close()
            } finally {
                release.countDown()
                submission.get(25, TimeUnit.SECONDS)
            }
        }
        CoreIpcTestDriver.production().use { replacement ->
            assertNotEquals(previousProcess, replacement.processId)
            CoreBridgeIpcScenario.success(replacement.prepare(byteArrayOf(), configId = "main", revision = 1, mode = "rule"))
            val ready = replacement.status()
            assertEquals(Contract.CORE_PHASE_READY, ready.getString("phase"))
            assertEquals("main", ready.getString("configId"))
            assertEquals(1, ready.getInt("revision"))
        }
    }

    @Test fun invalidUpdateRetainsTheActualNativeFailureAndDoesNotBlockDiagnostics() {
        CoreBridgeIpcScenario().use { core ->
            val before = core.query(Contract.CORE_OPERATION_RESOURCES)
            val rows = collection(before).map { it.getString("kind") to it.getString("name") }
            val rejected = core.query(Contract.CORE_OPERATION_RESOURCE_UPDATE, JSONObject().put("kind", "geo").put("name", "missing-原文🙂"))
            assertEquals("invalid resource", failure(rejected).getString("message"))
            val after = core.query(Contract.CORE_OPERATION_RESOURCES)
            assertEquals(rows, collection(after).map { it.getString("kind") to it.getString("name") })
            assertEquals(before.terminal.getString("source"), after.terminal.getString("source"))
            core.assertSameContext()
        }
    }

    @Test fun inlineResourceUpdateCannotBecomeAnEmptySuccessOrEnableExternalIo() {
        val body = CoreBridgeIpcScenario.DIRECT + "rule-providers:\n  fixture: {type: inline, behavior: domain, payload: [exact.test]}\n"
        CoreBridgeIpcScenario(body).use { core ->
            val row = collection(core.query(Contract.CORE_OPERATION_RESOURCES)).single { it.getString("kind") == "ruleProvider" && it.getString("name") == "fixture" }
            assertFalse(row.getBoolean("updateSupported"))
            val rejected = core.query(Contract.CORE_OPERATION_RESOURCE_UPDATE, JSONObject().put("kind", "ruleProvider").put("name", "fixture"))
            assertEquals("inline resource has no external source", failure(rejected).getString("message"))
            assertEquals("exact.test", collection(core.query(Contract.CORE_OPERATION_RULES, JSONObject().put("kind", "provider").put("name", "fixture"))).single().getString("payload"))
            core.assertSameContext()
        }
    }

    @Test fun staleResourceFdMetadataCannotEnterNativeAndDoesNotRetainAdmission() {
        CoreBridgeIpcScenario().use { core ->
            val pending = core.start(Contract.CORE_OPERATION_RESOURCE_UPDATE,
                JSONObject().put("kind", "geo").put("name", "GeoIP")) { it.put("inputId", "replacement") }
            assertEquals(Contract.CORE_ERROR_IDENTITY_MISMATCH, failure(core.await(pending)).getString("code"))
            assertEquals("invalid resource", failure(core.query(Contract.CORE_OPERATION_RESOURCE_UPDATE,
                JSONObject().put("kind", "geo").put("name", "missing"))).getString("message"))
            core.assertSameContext()
        }
    }
}
