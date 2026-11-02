package io.github.monadboxlab.clashpseudo.nativecore

import android.util.Base64
import androidx.test.platform.app.InstrumentationRegistry
import io.github.monadboxlab.clashpseudo.debug.CoreFixtureContract as Fixture
import io.github.monadboxlab.clashpseudo.debug.GeoFixtureFiles
import java.io.File
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.net.URI

/** 在一次性 :core process 的隔离 home 中调用真实上游 Geo 更新。 */
class GeoResourceNativeTest {
    private lateinit var fixtureDirectory: File
    @Test fun updateReplacesTheLoadedMatcherWithoutRepreparing() = checkUpdate(automatic = false)
    @Test fun automaticUpdateReplacesTheLoadedMatcherWithoutRepreparing() = checkUpdate(automatic = true)
    @Test fun stopWaitsForTheActualGeoIoBeforeAnotherHomeCanPrepare() = checkUpdate(automatic = false, stopInFlight = true)

    private fun checkUpdate(automatic: Boolean, stopInFlight: Boolean = false) {
        val arguments = InstrumentationRegistry.getArguments()
        val kind = requireNotNull(arguments.getString("geoKind"))
        require(kind in listOf("GeoIP", "GeoSite", "MMDB", "ASN"))
        require(!stopInFlight || kind == "GeoIP")
        val base = URI(requireNotNull(arguments.getString("geoBaseURL")))
        require(base.scheme == "http" && base.host == "192.168.100.2" && base.port in 1..65535)
        require(Regex("/p5-load-geo-[a-z0-9-]{4,32}").matches(base.path) && base.rawQuery == null && base.rawUserInfo == null)
        val nonce = base.path.removePrefix("/")
        val dnsPort = requireNotNull(arguments.getString("geoDnsPort")).toInt()
        require(dnsPort in 1..65535)
        val encoded = requireNotNull(arguments.getString("geoFixture"))
        require(encoded.length <= 4096)
        val fixture = JSONObject(String(Base64.decode(encoded, Base64.DEFAULT), Charsets.UTF_8))
        require(fixture.getString("directory") == "validation-geo-$nonce")
        fixtureDirectory = GeoFixtureFiles.directory(InstrumentationRegistry.getInstrumentation().targetContext, fixture)
        val sourceHost = if (kind == "GeoSite") "owned.$nonce.test" else "192.168.100.2"
        val source = URI("http", null, sourceHost, base.port, base.path + if (stopInFlight) "/hold" else "/$kind",
            if (stopInFlight) "id=a-0" else null, null)
        val urlKey = mapOf("GeoIP" to "geoip", "GeoSite" to "geosite", "MMDB" to "mmdb", "ASN" to "asn").getValue(kind)
        val geoUrls = listOf("geoip", "geosite", "mmdb", "asn").joinToString(", ") { "$it: '${if (it == urlKey) source else ""}'" }
        val rule = if (stopInFlight) "MATCH,DIRECT" else when (kind) {
            "GeoSite" -> "GEOSITE,cn,REJECT"
            "ASN" -> "IP-ASN,64500,REJECT"
            else -> "GEOIP,cn,REJECT"
        }
        val body = """
            mode: rule
            log-level: silent
            ipv6: false
            find-process-mode: off
            geodata-loader: standard
            geodata-mode: ${kind == "GeoIP"}
            geo-auto-update: $automatic
            geo-update-interval: 1
            geox-url: {$geoUrls}
            dns:
              enable: true
              enhanced-mode: redir-host
              nameserver: ['192.168.100.2:$dnsPort']
              default-nameserver: ['192.168.100.2:$dnsPort']
              fallback: []
            rules:
              - $rule
              - MATCH,DIRECT
        """.trimIndent().plus("\n").toByteArray(Charsets.UTF_8)
        val input = JSONObject().put("kind", kind).put("fixture", fixture)
        var previousProcess = ""
        var previousHome = ""
        CoreIpcTestDriver.fixture().use { driver ->
            previousProcess = driver.processId
            val pending = driver.fixture(if (stopInFlight) Fixture.GEO_HOLD else if (automatic) Fixture.GEO_AUTOMATIC else Fixture.GEO_MANUAL, input, body)
            assertNull("旧 process 的资源锁不能由调用方取得", CoreResourceGate.forApplication(driver.context).tryAcquire())
            val reply = pending.await(60)
            assertTrue(reply.terminal.toString(), reply.terminal.getBoolean("complete"))
            val result = reply.value
            previousHome = result.getString("home")
            NativeCoreFailureTest.assertSuccess(result.getJSONObject("trust"))
            NativeCoreFailureTest.assertStopped(result.getJSONObject("before").getJSONObject("value"))
            NativeCoreFailureTest.assertSuccess(result.getJSONObject("prepare"))
            val prepared = result.getJSONObject("preparedSnapshot").getJSONObject("value")
            assertTrue(prepared.getBoolean("prepared"))
            assertFalse(prepared.getBoolean("attached"))
            if (stopInFlight) {
                assertTrue("读取 runtimeConfig 前，原 Geo update 必须仍在执行", result.getBoolean("updatePendingBeforeDiagnostic"))
                NativeCoreFailureTest.assertSuccess(result.getJSONObject("heldRuntimeConfig"))
                val configuration = result.getJSONObject("heldRuntimeConfig").getJSONObject("value")
                assertEquals("rule", configuration.getJSONObject("general").getString("mode"))
                assertEquals("rule", configuration.getJSONObject("requested").getString("mode"))
                assertTrue("读取 runtimeConfig 不能等待原 Geo update 结束", result.getBoolean("updatePendingAfterDiagnostic"))
                NativeCoreFailureTest.assertSuccess(result.getJSONObject("heldDiagnosticSnapshot"))
                val diagnosticState = result.getJSONObject("heldDiagnosticSnapshot").getJSONObject("value")
                assertTrue(diagnosticState.getBoolean("prepared"))
                assertFalse(diagnosticState.getBoolean("attached"))
                assertArrayEquals(bytes(fixture.getJSONObject("before").getString(kind)), bytes(result.getString("heldDiagnosticBytes")))
                assertFalse("Stop 不能在真实 HTTP I/O 返回前结束", result.getBoolean("stopReturnedBeforeIo"))
                assertFalse("Geo update 必须仍在等待受控 HTTP I/O", result.getBoolean("updateReturnedBeforeIo"))
                assertTrue(result.getLong("holdObservedMs") >= 6200)
                assertTrue(result.getJSONObject("heldSnapshot").getJSONObject("value").getBoolean("prepared"))
                assertNativeFailure(result.getJSONObject("nextBeforeDrain"))
                assertFalse(result.getBoolean("nextGeoExists"))
                NativeCoreFailureTest.assertSuccess(result.getJSONObject("cancel"))
                NativeCoreFailureTest.assertSuccess(result.getJSONObject("stop"))
                // 取消后的 FD 可返回 EOF；实际 invoke receipt 必须保留上游错误，不替换为 stopped。
                assertNativeFailure(result.getJSONObject("update"))
                assertArrayEquals(bytes(fixture.getJSONObject("before").getString(kind)), bytes(result.getString("finalBytes")))
            } else {
                val expected = bytes(fixture.getJSONObject("after").getString(kind))
                if (automatic) {
                    val stream = result.getJSONObject("automaticResources")
                    NativeCoreFailureTest.assertSuccess(stream)
                    val rows = stream.getJSONArray("records")
                    val target = (0 until rows.length()).map(rows::getJSONObject)
                        .single { it.getString("kind") == "geo" && it.getString("name") == kind }
                    assertTrue(target.getBoolean("autoUpdate"))
                    assertEquals("present", target.getString("fileStatus"))
                    assertEquals(expected.size.toLong(), target.getLong("bytes"))
                } else assertUpdateSuccess(result.getJSONObject("first"))
                assertArrayEquals(expected, bytes(result.getString("afterFirst")))
                assertNativeFailure(result.getJSONObject("second"))
                assertArrayEquals(expected, bytes(result.getString("afterSecond")))
                NativeCoreFailureTest.assertSuccess(result.getJSONObject("directMode"))
                assertUpdateSuccess(result.getJSONObject("direct"))
                NativeCoreFailureTest.assertSuccess(result.getJSONObject("ruleMode"))
                assertNativeFailure(result.getJSONObject("rule"))
                assertArrayEquals(expected, bytes(result.getString("afterRule")))
                val state = result.getJSONObject("snapshot").getJSONObject("value")
                assertTrue(state.getBoolean("prepared"))
                assertFalse(state.getBoolean("attached"))
            }
            assertTrue("必须实际调用 socket callback", result.getJSONObject("callbacks").getInt("calls") > 0)
            assertTrue(result.getJSONObject("callbacks").isNull("invalidSocket"))
            NativeCoreFailureTest.assertSuccess(result.getJSONObject("shutdown"))
            NativeCoreFailureTest.assertStopped(result.getJSONObject("after").getJSONObject("value"))
            assertNull("Shutdown 返回后资源锁仍须保留到 process death", CoreResourceGate.forApplication(driver.context).tryAcquire())
            driver.exit()
            assertTrue(driver.deathConfirmed)
            val released = CoreResourceGate.forApplication(driver.context).tryAcquire()
            assertNotNull("只有真实 process death 后才释放资源锁", released)
            released!!.close()
            CoreIpcTestDriver.removeFixtureHome(driver.context, result)
        }
        if (stopInFlight) CoreIpcTestDriver.fixture().use { driver ->
            assertNotEquals(previousProcess, driver.processId)
            val reply = driver.fixture(Fixture.GEO_PREPARE, input, body).await()
            assertTrue(reply.terminal.toString(), reply.terminal.getBoolean("complete"))
            assertNotEquals(previousHome, reply.value.getString("home"))
            NativeCoreFailureTest.assertSuccess(reply.value.getJSONObject("prepare"))
            NativeCoreFailureTest.assertSuccess(reply.value.getJSONObject("shutdown"))
            NativeCoreFailureTest.assertStopped(reply.value.getJSONObject("after").getJSONObject("value"))
            driver.exit()
            CoreIpcTestDriver.removeFixtureHome(driver.context, reply.value)
        }
    }

    private fun assertUpdateSuccess(call: JSONObject) {
        NativeCoreFailureTest.assertSuccess(call)
        assertEquals("ok", call.getJSONObject("value").getString("status"))
    }
    private fun assertNativeFailure(call: JSONObject) {
        val receipt = call.getJSONObject("receipt")
        assertTrue(receipt.toString(), receipt.getBoolean("exited"))
        assertEquals("callFailed", receipt.getJSONObject("error").getString("code"))
        assertTrue(receipt.toString(), receipt.getJSONObject("error").getString("message").isNotEmpty())
        call.optJSONObject("terminal")?.let { assertFalse(it.toString(), it.getBoolean("complete")) }
    }
    private fun bytes(value: String) = GeoFixtureFiles.read(fixtureDirectory, value)
}
