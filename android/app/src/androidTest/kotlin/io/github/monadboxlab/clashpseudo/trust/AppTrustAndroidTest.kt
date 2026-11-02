package io.github.monadboxlab.clashpseudo.trust

import android.os.Build
import android.util.Base64
import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import io.github.monadboxlab.clashpseudo.debug.CoreFixtureContract
import io.github.monadboxlab.clashpseudo.nativecore.BundledAssetContract
import io.github.monadboxlab.clashpseudo.nativecore.CoreIpcTestDriver
import io.github.monadboxlab.clashpseudo.nativecore.NativeCoreFailureTest
import io.github.monadboxlab.clashpseudo.vpn.NativeSession
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService
import java.security.KeyStore
import java.security.MessageDigest
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.net.ssl.TrustManagerFactory
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Read-only inspection of Android trust anchors. */
class AppTrustAndroidTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private fun fingerprint(der: ByteArray) = MessageDigest.getInstance("SHA-256").digest(der).toList()
    // Independent inventory using PEM boundaries, SDK Base64 and single-certificate
    // DER parsing. API24 collection parsing returns zero roots for the curl header.
    private fun encoded(pem: String): List<ByteArray> {
        val factory = CertificateFactory.getInstance("X.509")
        val roots = mutableListOf<ByteArray>()
        var body: StringBuilder? = null
        for (line in pem.lineSequence()) {
            when (line) {
                "-----BEGIN CERTIFICATE-----" -> {
                    assertNull("Nested certificate boundary", body)
                    body = StringBuilder()
                }
                "-----END CERTIFICATE-----" -> {
                    val base64 = checkNotNull(body) { "Certificate end without a beginning" }
                    val der = Base64.decode(base64.toString(), Base64.DEFAULT)
                    val certificate = factory.generateCertificate(der.inputStream()) as X509Certificate
                    assertArrayEquals(der, certificate.encoded)
                    roots += der
                    body = null
                }
                else -> body?.append(line)?.append('\n')
            }
        }
        assertNull("Unterminated certificate boundary", body)
        return roots
    }

    @Test fun fixedCommentedBundleExportsEveryRootOnTheActualProvider() {
        val bytes = context.assets.open(AppTrust.BUNDLE_ASSET).use { it.readBytes() }
        val expected = encoded(bytes.toString(Charsets.UTF_8))
        assertEquals(BundledAssetContract.CERTIFICATE_ROOTS, expected.size)
        assertEquals(BundledAssetContract.CERTIFICATE_ROOTS, expected.map(::fingerprint).toSet().size)
        // Deliberately exercise the old-API branch even on a newer test device.
        // On API 24 this runs the real provider that rejected the whole curl file.
        val actual = AppTrust.rootDer(24, emptyList()) { bytes }
        assertEquals(expected.map(::fingerprint), actual.map(::fingerprint))
    }

    @Test fun realDefaultRootsAndOnlyThePermittedSupplementReachTheMaterial() {
        val factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        factory.init(null as KeyStore?)
        val defaults = AppTrust.defaultRoots(factory.trustManagers)
        val excluded = defaults.filter { certificate ->
            Build.VERSION.SDK_INT in 24..33 && certificate.serialNumber.signum() < 0 &&
                fingerprint(certificate.encoded).joinToString("") { "%02x".format(it) } ==
                "88497f01602f3154246ae28c4d5aef10f1d87ebb76626f4ae0b7f95ba7968799"
        }
        val expected = defaults.filterNot { it in excluded }.map { it.encoded }.toMutableList()
        if (Build.VERSION.SDK_INT < 34) {
            val bundled = context.assets.open(AppTrust.BUNDLE_ASSET).use { it.readBytes() }
            val roots = encoded(bundled.toString(Charsets.UTF_8))
            assertEquals(BundledAssetContract.CERTIFICATE_ROOTS, roots.size)
            expected += roots
        }
        val pem = AppTrust.pem(context)
        val actual = encoded(pem)
        assertTrue(pem.all { it.code in 0..127 })
        assertEquals(expected.map(::fingerprint).toSet(), actual.map(::fingerprint).toSet())
        assertEquals(actual.size, actual.map(::fingerprint).toSet().size)
        Log.i("AppTrustAndroidTest", "sharedRootSet api=${Build.VERSION.SDK_INT} " +
            "defaults=${defaults.size} excludedLegacy=${excluded.size} exported=${actual.size}")
        if (pem.isNotEmpty()) {
            assertTrue(pem.startsWith("-----BEGIN CERTIFICATE-----\n"))
            assertTrue(pem.endsWith("-----END CERTIFICATE-----\n"))
            pem.lineSequence().filter { it.isNotEmpty() && !it.startsWith("-----") }.forEach {
                assertTrue(it.length <= 64)
                assertTrue(it.matches(Regex("[A-Za-z0-9+/]+={0,2}")))
            }
        }
    }

    @Test fun reportsEveryNegativeSerialRootAndItsSourceWithoutExportingCertificates() {
        val actual = encoded(AppTrust.pem(context))
        val managers = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        managers.init(null as KeyStore?)
        val defaults = AppTrust.defaultRoots(managers.trustManagers).map { fingerprint(it.encoded) }.toSet()
        val supplement = context.assets.open(AppTrust.BUNDLE_ASSET).use { it.readBytes() }
        val bundled = encoded(supplement.toString(Charsets.UTF_8)).map(::fingerprint).toSet()
        val factory = CertificateFactory.getInstance("X.509")
        var negative = 0
        var unclassified = 0
        for ((index, der) in actual.withIndex()) {
            val certificate = factory.generateCertificate(der.inputStream()) as X509Certificate
            if (certificate.serialNumber.signum() >= 0) continue
            negative++
            val hash = fingerprint(der)
            val source = listOfNotNull(
                "default".takeIf { hash in defaults },
                "fixedBundle".takeIf { Build.VERSION.SDK_INT < 34 && hash in bundled },
            ).joinToString("+").ifEmpty { unclassified++; "unclassified" }
            // DER fingerprints identify roots; diagnostics contain names, serials and
            // fingerprints only.
            val metadata = JSONObject().put("index", index + 1)
                .put("sha256", hash.joinToString("") { "%02x".format(it) })
                .put("source", source).put("subject", certificate.subjectX500Principal.name)
                .put("issuer", certificate.issuerX500Principal.name)
                .put("serial", certificate.serialNumber.toString()).toString()
            // Split bounded logcat entries at complete UTF-16 code points.
            var start = 0
            var part = 0
            while (start < metadata.length) {
                var end = minOf(start + 512, metadata.length)
                if (end < metadata.length && metadata[end - 1].isHighSurrogate() &&
                    metadata[end].isLowSurrogate()) end--
                Log.i("AppTrustAndroidTest", "negativeSerialRoot index=${index + 1} part=${++part} " +
                    metadata.substring(start, end))
                start = end
            }
        }
        Log.i("AppTrustAndroidTest", "negativeSerialInventory api=${Build.VERSION.SDK_INT} " +
            "exported=${actual.size} negative=$negative unclassified=$unclassified")
        // Report the complete inventory before failing if the default snapshot changed meanwhile.
        assertEquals("Negative root is outside the current default/permitted bundle sets", 0, unclassified)
        assertEquals("Current device material must initialize Go without a global negative-serial exception", 0, negative)
    }

    @Test fun sharedMaterialInitializesGoTrustWithoutPreparingCore() {
        CoreIpcTestDriver.assertNoGoInApplication()
        assertEquals(NativeSession.Phase.STOPPED, PseudoVpnService.session.snapshot().phase)
        val material = AppTrust.pem(context)
        CoreIpcTestDriver.fixture().use { driver ->
            val reply = driver.fixture(CoreFixtureContract.TRUST).await()
            assertTrue(reply.terminal.toString(), reply.terminal.getBoolean("complete"))
            assertTrue(reply.terminal.toString(), reply.terminal.getBoolean("exited"))
            val result = reply.value
            for (name in listOf("trust", "trustRepeated")) {
                val initialization = result.getJSONObject(name)
                NativeCoreFailureTest.assertSuccess(initialization)
                assertTrue(initialization.getJSONObject("value").getBoolean("initialized"))
            }
            for (name in listOf("before", "after")) {
                val snapshot = result.getJSONObject(name)
                NativeCoreFailureTest.assertSuccess(snapshot)
                val state = snapshot.getJSONObject("value")
                assertFalse(state.getBoolean("prepared"))
                assertFalse(state.getBoolean("attached"))
                assertFalse(state.getBoolean("cleanupFailed"))
            }
            NativeCoreFailureTest.assertSuccess(result.getJSONObject("shutdown"))
            driver.exit()
            assertTrue(driver.deathConfirmed)
            CoreIpcTestDriver.removeFixtureHome(context, result)
        }
        assertSame(material, AppTrust.pem(context))
        assertEquals(NativeSession.Phase.STOPPED, PseudoVpnService.session.snapshot().phase)
        CoreIpcTestDriver.assertNoGoInApplication()
        Log.i("AppTrustAndroidTest", "sharedGoTrust api=${Build.VERSION.SDK_INT} initialized=true " +
            "prepared=false attached=false idempotent=true")
    }

    @Test fun concurrentConsumersReceiveTheSameImmutableCachedSnapshot() {
        val workers = Executors.newFixedThreadPool(4)
        try {
            val results = workers.invokeAll(List(8) { Callable { AppTrust.pem(context) } })
                .map { it.get(10, TimeUnit.SECONDS) }
            results.forEach { assertSame(results.first(), it) }
            assertSame(results.first(), AppTrust.pem(context.applicationContext))
        } finally {
            workers.shutdownNow()
            assertTrue("Trust export workers must actually terminate", workers.awaitTermination(10, TimeUnit.SECONDS))
        }
    }

    @Test fun packagedSupplementKeepsItsExactOfficialBytesOnEveryApi() {
        val bytes = context.assets.open(AppTrust.BUNDLE_ASSET).use { it.readBytes() }
        assertEquals(AppTrust.BUNDLE_SIZE, bytes.size)
        assertEquals(AppTrust.BUNDLE_SHA256,
            MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) })
    }
}
