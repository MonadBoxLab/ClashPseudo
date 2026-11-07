package io.github.monadboxlab.clashpseudo.nativecore

import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.debug.CoreFixtureContract as Fixture
import io.github.monadboxlab.clashpseudo.message.AppMessage
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException

class CoreHostTest {
    @Test fun freshClientHandshakeDoesNotSerializeAnAlreadyClosedStatusDescriptor() {
        val platform = CorePlatformTestDriver()
        val client = CoreClient.get(platform.context)
        var previousProcess: String? = null
        repeat(2) {
            CoreIpcTestDriver.production().use { driver ->
                try {
                    assertNotEquals(previousProcess, driver.processId)
                    val control = driver.service.status(driver.controlIdentity())
                    assertTrue("A fresh process publishes its status through a details FD", control.containsKey("details"))
                    CoreIpcTestDriver.readStatusDetails(control)
                    val connected = platform.handshake()
                    assertEquals(driver.processId, connected[Contract.CORE_FIELD_PROCESS_ID])
                    assertEquals(Contract.CORE_PHASE_CONNECTED, connected[Contract.CORE_FIELD_PHASE])
                    platform.await("The initial status document drains") { !client.requestBusy }
                    assertEquals(driver.processId, platform.status()[Contract.CORE_FIELD_PROCESS_ID])
                } finally { driver.exit() }
                platform.await("The client confirms the original process death") {
                    client.status()[Contract.CORE_FIELD_PHASE] == Contract.CORE_PHASE_EXITED && !client.requestBusy
                }
                previousProcess = driver.processId
            }
        }
    }

    @Test fun previewUsesProductionIpcWithoutCreatingVpnResources() {
        CoreIpcTestDriver.production().use { driver ->
            val result = driver.prepare(DIRECT.toByteArray(Charsets.UTF_8))
            assertTrue(result.terminal.toString(), result.terminal.getBoolean("complete"))
            assertFalse(result.value.getJSONObject("platform").getJSONObject("vpn").getBoolean("running"))
            assertFalse(CoreIpcTestDriver.servicePresent(driver.context, PseudoVpnService::class.java))
            assertEquals(Contract.CORE_PHASE_READY, driver.status().getString("phase"))
            assertEquals(Contract.CORE_PURPOSE_PREVIEW, driver.status().getString("purpose"))
            val snapshot = driver.submit(Contract.CORE_OPERATION_SNAPSHOT).await()
            assertTrue(snapshot.terminal.toString(), snapshot.terminal.getBoolean("complete"))
            assertTrue(snapshot.value.getBoolean("prepared"))
            assertFalse(snapshot.value.getBoolean("attached"))
            val control = driver.service.status(driver.controlIdentity())
            CoreControl.check(control)
            assertFalse("Listener rows must not occupy the Binder control plane", control.containsKey("lanListeners"))
            assertFalse(control.containsKey("applicationAccess"))
            assertTrue(control.containsKey("details"))
            val full = CoreIpcTestDriver.readStatusDetails(control)
            assertEquals(snapshot.value.getLong(Contract.CORE_FIELD_LISTENER_REVISION), full.getLong(Contract.CORE_FIELD_LISTENER_REVISION))
            assertEquals(snapshot.value.getJSONArray("listeners").toString(), full.getString("lanListeners"))
            assertEquals(driver.processId, full.getString("processId"))
            assertEquals(snapshot.value.getString("inputId"), full.getString("inputId"))
            driver.exit()
            assertTrue(driver.deathConfirmed)
        }
    }

    @Test fun stopRequiresProcessExitAndAnExistingContextCannotBeReplaced() {
        var originalProcess = ""
        CoreIpcTestDriver.production().use { driver ->
            assertTrue(driver.prepare(DIRECT.toByteArray()).terminal.getBoolean("complete"))
            val original = driver.status()
            val stopFailure = runCatching { driver.submit(Contract.CORE_OPERATION_STOP) }.exceptionOrNull()
            assertNotNull("STOP must use the process exit entry point, not remain in the original context", stopFailure)
            assertTrue(stopFailure.toString(), stopFailure!!.message.orEmpty().contains("Invalid core request operation or identity"))
            val snapshot = driver.submit(Contract.CORE_OPERATION_SNAPSHOT).await()
            assertTrue(snapshot.value.getBoolean("prepared"))
            val replacement = driver.prepare(DIRECT.toByteArray(), inputId = original.getString("inputId")!!)
            assertFalse(replacement.terminal.toString(), replacement.terminal.getBoolean("complete"))
            assertEquals("java.lang.IllegalStateException", replacement.terminal.getJSONObject("error").getString("type"))
            assertEquals("Each core process can prepare only one context", replacement.terminal.getJSONObject("error").getString("message"))
            assertEquals(original.getString("processId"), driver.status().getString("processId"))
            assertEquals(original.getString("inputId"), driver.status().getString("inputId"))
            assertEquals(Contract.CORE_PHASE_READY, driver.status().getString("phase"))
            assertTrue(driver.submit(Contract.CORE_OPERATION_SNAPSHOT).await().value.getBoolean("prepared"))
            originalProcess = driver.processId
            driver.exit()
            assertTrue(driver.deathConfirmed)
        }
        CoreIpcTestDriver.production().use { next ->
            assertNotEquals(originalProcess, next.processId)
            assertTrue(next.prepare(DIRECT.toByteArray()).terminal.getBoolean("complete"))
            next.exit()
            assertTrue(next.deathConfirmed)
        }
    }

    @Test fun mismatchedFdMetadataIsRejectedBeforeNativePreparation() {
        CoreIpcTestDriver.production().use { driver ->
            val pending = driver.submit(Contract.CORE_OPERATION_PREPARE, inputId = "control-input", generation = 1,
                metadata = { it.put("inputId", "other-input") })
            val rejected = pending.await()
            assertFalse(rejected.terminal.getBoolean("complete"))
            assertEquals(Contract.CORE_ERROR_IDENTITY_MISMATCH, rejected.terminal.getJSONObject("error").getString("code"))
            assertTrue(driver.receipt(pending.id).getBoolean("exited"))
            assertFalse(driver.status().getBoolean("vpnRunning"))
            assertTrue("Rejecting metadata must not occupy the sole context", driver.prepare(DIRECT.toByteArray()).terminal.getBoolean("complete"))
            driver.exit()
        }
    }

    @Test fun failedNativePreparationRetainsTheOriginalParserInputAndRequiresANewProcess() {
        val original = "https://user:pass@fixture.test/?token=原文🙂"
        var failedProcess = ""
        CoreIpcTestDriver.production().use { driver ->
            failedProcess = driver.processId
            val body = "mode: rule\nfind-process-mode: off\ngeo-auto-update: false\ngeox-url: {geoip: '', geosite: '', mmdb: '', asn: ''}\nrules:\n  - NOT-A-VALID-RULE,$original\n"
            val rejected = driver.prepare(body.toByteArray(Charsets.UTF_8))
            assertFalse(rejected.terminal.toString(), rejected.terminal.getBoolean("complete"))
            val error = rejected.terminal.getJSONObject("error")
            assertTrue(rejected.terminal.toString(), error.getString("message").contains(original))
            assertTrue(error.getJSONObject("nativeError").getString("message").contains(original))
            assertEquals(Contract.CORE_ERROR_CALL_FAILED, error.getJSONObject("nativeReceipt").getJSONObject("error").getString("code"))
            assertFalse(driver.status().getBoolean("vpnRunning"))
            driver.exit()
            assertTrue(driver.deathConfirmed)
        }
        CoreIpcTestDriver.production().use { next ->
            assertNotEquals(failedProcess, next.processId)
            assertTrue(next.prepare(DIRECT.toByteArray()).terminal.getBoolean("complete"))
            next.exit()
        }
    }

    @Test fun staleProcessIdentityCannotQueryAReplacementProcess() {
        val old = CoreIpcTestDriver.production().use { driver ->
            driver.controlIdentity().also { driver.exit(); assertTrue(driver.deathConfirmed) }
        }
        CoreIpcTestDriver.production().use { next ->
            assertNotEquals(old.getString("processId"), next.processId)
            val failure = runCatching { next.service.status(old) }.exceptionOrNull()
            assertNotNull("The actual Binder must reject an old processId", failure)
            assertTrue(failure.toString(), failure!!.message.orEmpty().contains("Request belongs to another core process"))
            assertEquals(next.processId, next.status().getString("processId"))
            next.exit()
        }
    }

    @Test fun bundledGeoCallbackKeepsTheActualParsingAndStalePreparationFailures() {
        withGeoCallbacks { value ->
            val failure = value.getJSONObject("invalidSeed").getJSONObject("error")
            val expected = try { JSONArray("{原文🙂"); error("Invalid fixture was parsed") } catch (error: JSONException) { error }
            assertEquals(expected.javaClass.name, failure.getString("type"))
            assertEquals(expected.message, failure.getString("message"))
            val stale = value.getJSONObject("staleSeed").getJSONObject("error")
            assertEquals("java.lang.IllegalStateException", stale.getString("type"))
            assertEquals("The context owning the core resource has ended", stale.getString("message"))
        }
    }

    @Test fun geoPublicationAndCancellationUseTheSameLeaseArbitration() {
        withGeoCallbacks { value ->
            assertEquals(1, value.getInt("published"))
            val error = value.getJSONObject("publicationError")
            assertEquals("java.lang.IllegalStateException", error.getString("type"))
            assertEquals("The context owning the core resource has ended", error.getString("message"))
        }
    }

    @Test fun platformLimitMessagesKeepTheirArgumentsAndEveryOriginalError() {
        val original = "{\"id\":\"nativeConfigurationUnsupported\",\"args\":{\"field\":\"tun.include-android-user\",\"reason\":{\"id\":\"nativeReasonAndroidUserUnavailable\",\"args\":{}}}}"
        val detail = AppMessage.fromMap(JSONObject(original))!!.withDetail(original).toMap()
        val args = detail["args"] as Map<*, *>
        assertEquals("nativeConfigurationUnsupported", detail["id"])
        assertEquals("nativeReasonAndroidUserUnavailable", (args["reason"] as Map<*, *>)["id"])
        assertEquals(original, detail["detail"])
        val text = "https://user:pass@fixture.test/?token=原文🙂\nAuthorization: Bearer fixture"
        assertEquals(text, CoreErrors.json(IOException(text)).getString("message"))
        val unknown = "{\"id\":\"nativeConfigurationUnsupported\",\"args\":{\"field\":\"future.field\",\"reason\":{\"id\":\"futureReason\",\"args\":{\"value\":\"原文🙂\"}}}}"
        val future = AppMessage.fromMap(JSONObject(unknown))!!.withDetail(unknown)
        assertEquals("future.field", future.args["field"])
        assertEquals("futureReason", (future.args["reason"] as AppMessage).id)
        assertEquals(unknown, future.detail)
        val malformed = "{\"id\":\"nativeConfigurationUnsupported\",\"args\":{\"field\":\"tun\",\"reason\":{\"id\":\"inventedSecret\"}}}"
        assertNull(AppMessage.fromMap(JSONObject(malformed)))
        assertEquals(malformed, CoreErrors.json(IOException(malformed)).getString("message"))
    }

    private fun withGeoCallbacks(check: (JSONObject) -> Unit) {
        CoreIpcTestDriver.fixture().use { driver ->
            val reply = driver.fixture(Fixture.GEO_CALLBACK).await()
            assertTrue(reply.terminal.toString(), reply.terminal.getBoolean("complete"))
            check(reply.value)
            NativeCoreFailureTest.assertSuccess(reply.value.getJSONObject("shutdown"))
            NativeCoreFailureTest.assertStopped(reply.value.getJSONObject("after").getJSONObject("value"))
            driver.exit()
            CoreIpcTestDriver.removeFixtureHome(driver.context, reply.value)
        }
    }

    companion object {
        const val DIRECT = "mode: rule\nfind-process-mode: off\nlog-level: silent\ngeo-auto-update: false\n" +
            "geox-url: {geoip: '', geosite: '', mmdb: '', asn: ''}\nrules:\n  - MATCH,DIRECT\n"
    }
}

class CoreHostFailureCauseTest {
    @Test fun preparationFailureCanRetainTheOriginalTrustCauseAndItsSuppressedDetails() {
        val original = IOException("original trust material I/O error")
        val suppressed = IOException("original trust material close error")
        original.addSuppressed(suppressed)
        val detail = AppMessage("trustedRootsUnavailable").withDetail(original)
        val failure = IOException(detail.detail, original)
        assertSame(original, failure.cause)
        assertSame(suppressed, failure.cause!!.suppressed.single())
        assertTrue(detail.detail!!.contains(original.toString()))
        val encoded = CoreErrors.json(failure)
        assertEquals(original.message, encoded.getJSONObject("cause").getString("message"))
        assertEquals(suppressed.message, encoded.getJSONObject("cause").getJSONArray("suppressed").getJSONObject(0).getString("message"))
        assertSame(original, failure.cause)
    }
}
