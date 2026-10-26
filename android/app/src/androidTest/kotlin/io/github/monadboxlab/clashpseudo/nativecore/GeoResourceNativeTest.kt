package io.github.monadboxlab.clashpseudo.nativecore

import android.os.SystemClock
import android.util.Base64
import androidx.test.platform.app.InstrumentationRegistry
import io.github.monadboxlab.clashpseudo.app.AppTrust
import java.io.File
import java.net.URI
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Exercises real JNI updates in an isolated cache home. */
class GeoResourceNativeTest {
    @Test fun updateReplacesTheLoadedMatcherWithoutRepreparing() = checkUpdate(automatic = false)

    @Test fun automaticUpdateReplacesTheLoadedMatcherWithoutRepreparing() = checkUpdate(automatic = true)

    @Test fun stopWaitsForTheActualGeoIoBeforeAnotherHomeCanPrepare() =
        checkUpdate(automatic = false, stopInFlight = true)

    private fun checkUpdate(automatic: Boolean, stopInFlight: Boolean = false) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
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
        val context = instrumentation.targetContext
        CoreHost.installAndroid(context)
        assertEquals("", NativeCore.initializeTrust(AppTrust.pem(context).toByteArray(Charsets.UTF_8)))
        assertFalse(JSONObject(NativeCore.snapshot()).getBoolean("prepared"))
        val home = File(context.cacheDir, "native-geo-${UUID.randomUUID()}")
        assertTrue(home.mkdir())
        val filenames = mapOf("GeoIP" to "GeoIP.dat", "GeoSite" to "GeoSite.dat",
            "MMDB" to "Country.mmdb", "ASN" to "ASN.mmdb")
        try {
            for ((name, filename) in filenames) {
                val file = File(home, filename)
                file.writeBytes(Base64.decode(fixture.getJSONObject("before").getString(name), Base64.DEFAULT))
                if (automatic) assertTrue(file.setLastModified(System.currentTimeMillis() - 2 * 60 * 60 * 1000))
            }
            val hostname = "owned.$nonce.test"
            val sourceHost = if (kind == "GeoSite") hostname else "192.168.100.2"
            val source = URI("http", null, sourceHost, base.port,
                base.path + if (stopInFlight) "/hold" else "/" + kind,
                if (stopInFlight) "id=a-0" else null, null)
            val urlKey = mapOf("GeoIP" to "geoip", "GeoSite" to "geosite", "MMDB" to "mmdb", "ASN" to "asn").getValue(kind)
            val geoUrls = listOf("geoip", "geosite", "mmdb", "asn").joinToString(", ") {
                "$it: '${if (it == urlKey) source else ""}'"
            }
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
            """.trimIndent() + "\n"
            val protector = NativeCoreFailureTest.Protector()
            val options = JSONObject().put("purpose", "PREVIEW").put("generation", 1)
                .put("composition", "native-geo-$kind").toString().toByteArray(Charsets.UTF_8)
            assertEquals("", NativeCore.prepare(home.path, body.toByteArray(Charsets.UTF_8), "rule", protector,
                options = options))
            assertTrue(JSONObject(NativeCore.snapshot()).getBoolean("prepared"))
            assertFalse(JSONObject(NativeCore.snapshot()).getBoolean("attached"))
            val query = JSONObject().put("kind", "geo").put("name", kind).toString().toByteArray(Charsets.UTF_8)
            if (stopInFlight) {
                checkInFlight(query, protector, home, body, options)
                return
            }
            val expected = Base64.decode(fixture.getJSONObject("after").getString(kind), Base64.DEFAULT)
            if (automatic) {
                // Only isolated test-file mtimes are old; the device clock is unchanged.
                val deadline = SystemClock.elapsedRealtime() + 10_000
                while (true) {
                    val rows = JSONObject(NativeCore.resources()).getJSONArray("resources")
                    val target = (0 until rows.length()).map { rows.getJSONObject(it) }
                        .single { it.getString("kind") == "geo" && it.getString("name") == kind }
                    if (target.optString("lastResult") == "success" &&
                        File(home, filenames.getValue(kind)).readBytes().contentEquals(expected)) break
                    check(SystemClock.elapsedRealtime() < deadline) { "Automatic Geo update did not settle" }
                    Thread.sleep(10)
                }
            } else {
                val first = JSONObject(NativeCore.updateResource(query))
                assertEquals(first.toString(), "ok", first.optString("status"))
            }
            assertArrayEquals(expected, File(home, filenames.getValue(kind)).readBytes())
            protector.assertCalled()
            // After the first HTTP connection closes, evaluate the same loaded rule
            // against the newly installed database.
            val second = JSONObject(NativeCore.updateResource(query))
            assertEquals(second.toString(), "updateFailed", second.optString("error"))
            assertArrayEquals(expected, File(home, filenames.getValue(kind)).readBytes())
            // A real DIRECT control excludes a dead host/transport as the cause
            // of rejection; returning to rule must reject again with the same DB.
            assertEquals("", NativeCore.setMode("direct"))
            val direct = JSONObject(NativeCore.updateResource(query))
            assertEquals(direct.toString(), "ok", direct.optString("status"))
            assertEquals("", NativeCore.setMode("rule"))
            assertEquals("updateFailed", JSONObject(NativeCore.updateResource(query)).optString("error"))
            assertArrayEquals(expected, File(home, filenames.getValue(kind)).readBytes())
            assertTrue(JSONObject(NativeCore.snapshot()).getBoolean("prepared"))
            assertFalse(JSONObject(NativeCore.snapshot()).getBoolean("attached"))
        } finally {
            NativeCore.cancel()
            assertEquals("", NativeCore.stop())
            val state = JSONObject(NativeCore.snapshot())
            val cleanupConfirmed = !state.getBoolean("prepared") && !state.getBoolean("attached") && !state.getBoolean("cleanupFailed")
            assertTrue("Native cleanup was not confirmed", cleanupConfirmed)
            if (cleanupConfirmed) assertTrue(home.deleteRecursively())
        }
    }

    private fun checkInFlight(query: ByteArray, protector: NativeCoreFailureTest.Protector,
                              home: File, body: String, options: ByteArray) {
        val updated = CountDownLatch(1)
        val stopped = CountDownLatch(1)
        val updateResult = AtomicReference<String>()
        val stopResult = AtomicReference<String>()
        val failure = AtomicReference<Throwable?>()
        val oldBytes = File(home, "GeoIP.dat").readBytes()
        val nextHome = File(home.parentFile, "native-geo-${UUID.randomUUID()}")
        assertTrue(nextHome.mkdir())
        val updater = Thread({
            try { updateResult.set(NativeCore.updateResource(query)) }
            catch (error: Throwable) { failure.compareAndSet(null, error) }
            finally { updated.countDown() }
        }, "native-geo-update")
        var stopper: Thread? = null
        try {
            updater.start()
            val deadline = SystemClock.elapsedRealtime() + 5000
            while (protector.calls.get() == 0) {
                check(updated.count == 1L && SystemClock.elapsedRealtime() < deadline) { "Geo I/O did not start" }
                Thread.sleep(10)
            }
            NativeCore.cancel()
            stopper = Thread({
                try { stopResult.set(NativeCore.stop()) }
                catch (error: Throwable) { failure.compareAndSet(null, error) }
                finally { stopped.countDown() }
            }, "native-geo-stop").apply { start() }
            // The controlled server holds the response body until its controller
            // closes accepted sockets after eight seconds.
            assertFalse("Stop returned before actual HTTP I/O ended", stopped.await(6200, TimeUnit.MILLISECONDS))
            assertEquals(1L, updated.count)
            assertTrue(JSONObject(NativeCore.snapshot()).getBoolean("prepared"))
            val nextOptions = JSONObject(String(options, Charsets.UTF_8)).put("generation", 2)
                .put("composition", "native-geo-replacement").toString().toByteArray(Charsets.UTF_8)
            assertTrue("New home accepted before old I/O drained",
                NativeCore.prepare(nextHome.path, body.toByteArray(Charsets.UTF_8), "rule",
                    NativeCoreFailureTest.Protector(), options = nextOptions).isNotEmpty())
            assertFalse(File(nextHome, "GeoIP.dat").exists())
            assertTrue(stopped.await(15, TimeUnit.SECONDS))
            assertTrue(updated.await(5, TimeUnit.SECONDS))
            failure.get()?.let { throw it }
            assertEquals("", stopResult.get())
            assertEquals("stopped", JSONObject(updateResult.get()).getString("error"))
            assertArrayEquals(oldBytes, File(home, "GeoIP.dat").readBytes())
            assertFalse(JSONObject(NativeCore.snapshot()).getBoolean("prepared"))
            assertEquals("", NativeCore.prepare(nextHome.path, body.toByteArray(Charsets.UTF_8), "rule",
                NativeCoreFailureTest.Protector(), options = nextOptions))
            assertEquals("", NativeCore.stop())
        } finally {
            updater.join(20_000)
            stopper?.join(20_000)
            assertFalse("Geo update thread survived", updater.isAlive)
            assertFalse("Geo Stop thread survived", stopper?.isAlive == true)
            NativeCore.cancel()
            assertEquals("", NativeCore.stop())
            assertTrue(nextHome.deleteRecursively())
        }
    }
}
