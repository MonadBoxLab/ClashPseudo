package io.github.monadboxlab.clashpseudo.trust

import java.io.File
import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest
import java.security.cert.Certificate
import java.security.cert.CertificateException
import java.security.cert.CertificateFactory
import java.security.cert.CertificateFactorySpi
import java.security.cert.X509Certificate
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager
import org.junit.Assert.*
import org.junit.Test

class AppTrustTest {
    private fun bundle() = File(System.getProperty("certificates.assets", "src/main/assets"),
        AppTrust.BUNDLE_ASSET).readBytes()
    private fun certificates(bytes: ByteArray) = CertificateFactory.getInstance("X.509")
        .generateCertificates(bytes.inputStream()).map { it as X509Certificate }
    private fun fingerprints(roots: List<ByteArray>) = roots.map {
        MessageDigest.getInstance("SHA-256").digest(it).toList()
    }
    private fun manager(issuers: () -> Array<X509Certificate>) = object : X509TrustManager {
        override fun getAcceptedIssuers() = issuers()
        override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) =
            throw AssertionError("Trust material export must not validate connections")
        override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) =
            throw AssertionError("Trust material export must not validate connections")
    }

    @Test fun formalBundleHasTheFixedBytesAndEveryRootParsesAsX509() {
        val bytes = bundle()
        assertEquals(200116, bytes.size)
        assertEquals("796f1389bfea13c0ed78f663b765baaff54a508e5483786bd6ece73c5e3e3cbe",
            MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) })
        assertTrue(bytes.toString(Charsets.UTF_8).startsWith("##\n## Bundle of CA Root Certificates\n"))
        val roots = certificates(bytes)
        assertTrue(roots.isNotEmpty())
        assertEquals(roots.size, AppTrust.rootDer(24, emptyList()) { bytes }.size)
    }

    // API 24 Conscrypt selects PEM only at a leading '-', and its collection
    // parser returns the items before the first parse error (zero for curl's '#').
    // Keep real SDK X.509 parsing, but reproduce that input-boundary contract.
    private class BoundarySpi(val failAt: Int? = null, val failDer: Boolean = false) : CertificateFactorySpi() {
        val delegate = CertificateFactory.getInstance("X.509")
        var pemCalls = 0
        var bulkCalls = 0
        val failure = CertificateException("Single certificate parse failed")

        override fun engineGenerateCertificate(input: InputStream): Certificate {
            val bytes = input.readBytes()
            if (bytes.firstOrNull() == '-'.code.toByte()) {
                val pem = bytes.toString(Charsets.US_ASCII)
                assertTrue(pem.startsWith("-----BEGIN CERTIFICATE-----\n"))
                assertTrue(pem.endsWith("-----END CERTIFICATE-----\n"))
                assertEquals(1, Regex("-----BEGIN CERTIFICATE-----").findAll(pem).count())
                pemCalls++
                if (pemCalls == failAt) throw failure
            } else if (bytes.firstOrNull() != 0x30.toByte()) {
                throw CertificateException("PEM input must begin at its certificate boundary")
            } else if (failDer) {
                throw failure
            }
            return delegate.generateCertificate(bytes.inputStream())
        }

        override fun engineGenerateCertificates(input: InputStream): Collection<Certificate> {
            bulkCalls++
            val bytes = input.readBytes()
            return if (bytes.firstOrNull() == '#'.code.toByte()) emptyList()
                else delegate.generateCertificates(bytes.inputStream())
        }

        override fun engineGenerateCRL(input: InputStream): java.security.cert.CRL =
            throw AssertionError("Root export must not parse CRLs")
        override fun engineGenerateCRLs(input: InputStream): Collection<java.security.cert.CRL> =
            throw AssertionError("Root export must not parse CRLs")
    }

    private fun boundaryFactory(spi: BoundarySpi): CertificateFactory =
        object : CertificateFactory(spi, spi.delegate.provider, "X.509") {}

    @Test fun fixedCurlBundleIsParsedOneCertificateAtATimeWithoutProviderCommentSkipping() {
        val bytes = bundle()
        val spi = BoundarySpi()
        val factory = boundaryFactory(spi)
        // This case exercises the host JDK provider; API24 behavior has its own device
        // test.
        assertEquals(118, certificates(bytes).size)
        assertTrue(factory.generateCertificates(bytes.inputStream()).isEmpty())
        spi.bulkCalls = 0
        val result = AppTrust.rootDer(24, emptyList(), factory) { bytes }
        assertEquals(fingerprints(certificates(bytes).map { it.encoded }), fingerprints(result))
        assertEquals(118, spi.pemCalls)
        assertEquals(0, spi.bulkCalls)
    }

    @Test fun aSingleBundledCertificateFailureIsNotSwallowedAsAPartialRootSet() {
        val bytes = bundle()
        val spi = BoundarySpi(failAt = 2)
        val caught = assertThrows(CertificateException::class.java) {
            AppTrust.rootDer(24, emptyList(), boundaryFactory(spi)) { bytes }
        }
        assertSame(spi.failure, caught)
        assertEquals(2, spi.pemCalls)
        assertEquals(0, spi.bulkCalls)
        assertEquals(118, AppTrust.rootDer(24, emptyList()) { bytes }.size)
    }

    @Test fun api34AndNewerNeverReadOrSubstituteTheBundle() {
        val roots = certificates(bundle()).take(2)
        for (api in listOf(34, 36, 37)) {
            val result = AppTrust.rootDer(api, roots + roots) {
                throw AssertionError("API $api must not open the bundled roots")
            }
            assertEquals(fingerprints(roots.map { it.encoded }), fingerprints(result))
        }
    }

    @Test fun aSuccessfulEmptyModernDefaultSetIsNotAnErrorOrAnImplicitFallback() {
        val empty = AppTrust.defaultRoots(arrayOf(manager { emptyArray() }))
        assertTrue(empty.isEmpty())
        assertTrue(AppTrust.rootDer(34, empty) {
            throw AssertionError("An empty default set is not permission to add bundled roots")
        }.isEmpty())
    }

    @Test fun oldSystemsAppendTheBundleAfterDefaultsAndDeduplicateByDer() {
        val bytes = bundle()
        val roots = certificates(bytes)
        val defaults = listOf(roots[1], roots[0], roots[1])
        for (api in listOf(24, 25, 33)) {
            var reads = 0
            val result = AppTrust.rootDer(api, defaults) { reads++; bytes }
            assertEquals(1, reads)
            assertEquals(roots.size, result.size)
            assertArrayEquals(roots[1].encoded, result[0])
            assertArrayEquals(roots[0].encoded, result[1])
            assertEquals(fingerprints(roots.map { it.encoded }).toSet(), fingerprints(result).toSet())
            // Deduplicate certificate values across separate CertificateFactory
            // instances.
            val separatelyParsed = certificates(bytes).take(2)
            assertEquals(2, AppTrust.rootDer(34, defaults + separatelyParsed) {
                throw AssertionError("Unexpected bundle read")
            }.size)
        }
    }

    @Test fun oldSystemsWithEmptyDefaultsStillUseOnlyTheFixedBundle() {
        val bytes = bundle()
        assertEquals(fingerprints(certificates(bytes).map { it.encoded }),
            fingerprints(AppTrust.rootDer(24, emptyList()) { bytes }))
    }

    @Test fun missingX509ProviderIsNotASuccessfulEmptyDefaultSet() {
        assertThrows(CertificateException::class.java) { AppTrust.defaultRoots(emptyArray()) }
        assertThrows(CertificateException::class.java) {
            AppTrust.defaultRoots(arrayOf(object : TrustManager {}))
        }
    }

    @Test fun allDefaultX509ManagersContributeWithoutCallingTheirTlsChecks() {
        val roots = certificates(bundle()).take(2)
        val result = AppTrust.defaultRoots(arrayOf(
            object : TrustManager {}, manager { arrayOf(roots[0]) }, manager { arrayOf(roots[1]) },
        ))
        assertEquals(roots, result)
    }

    @Test fun providerAndAssetReadErrorsPropagateWithoutBecomingEmptyTrust() {
        val providerError = IllegalStateException("Default provider unavailable")
        val caughtProvider = assertThrows(IllegalStateException::class.java) {
            AppTrust.defaultRoots(arrayOf(manager { throw providerError }))
        }
        assertSame(providerError, caughtProvider)
        val assetError = IOException("CA asset unavailable")
        val caughtAsset = assertThrows(IOException::class.java) {
            AppTrust.rootDer(24, emptyList()) { throw assetError }
        }
        assertSame(assetError, caughtAsset)
    }

    private fun testRoot(name: String): X509Certificate =
        checkNotNull(javaClass.getResourceAsStream("/certificates/$name.pem")) {
            "Missing public certificate test resource: $name"
        }.use { certificates(it.readBytes()).single() }

    @Test fun onlyTheExactNegativeLegacyDefaultAnchorIsExcludedOnApi24Through33() {
        // Public Android API24 root aeb67534.0 certificate.
        val legacy = testRoot("ec-acc")
        assertEquals("88497f01602f3154246ae28c4d5aef10f1d87ebb76626f4ae0b7f95ba7968799",
            MessageDigest.getInstance("SHA-256").digest(legacy.encoded)
                .joinToString("") { "%02x".format(it) })
        assertTrue(legacy.serialNumber.signum() < 0)
        val bytes = bundle()
        val expected = certificates(bytes).map { it.encoded }
        for (api in listOf(24, 25, 33)) {
            assertEquals(fingerprints(expected),
                fingerprints(AppTrust.rootDer(api, listOf(legacy, legacy)) { bytes }))
        }
        for (api in listOf(34, 36, 37)) {
            val result = AppTrust.rootDer(api, listOf(legacy)) {
                throw AssertionError("Modern system roots must remain unchanged")
            }
            assertEquals(fingerprints(listOf(legacy.encoded)), fingerprints(result))
        }
    }

    @Test fun sameCommonNameAndOtherNegativeSerialsAreNotAnExclusionRule() {
        val legacy = testRoot("ec-acc")
        val positive = testRoot("synthetic-ec-acc-positive")
        val negative = testRoot("synthetic-ec-acc-negative")
        assertTrue(legacy.subjectX500Principal.name.split(',').contains("CN=EC-ACC"))
        for (root in listOf(positive, negative)) {
            assertEquals("CN=EC-ACC", root.subjectX500Principal.name)
            assertFalse(root.encoded.contentEquals(legacy.encoded))
        }
        assertTrue(positive.serialNumber.signum() > 0)
        assertTrue(negative.serialNumber.signum() < 0)
        val bytes = bundle()
        val result = AppTrust.rootDer(24, listOf(legacy, positive, negative)) { bytes }
        assertArrayEquals(positive.encoded, result[0])
        assertArrayEquals(negative.encoded, result[1])
        assertEquals(certificates(bytes).size + 2, result.size)
    }

    @Test fun otherDefaultRootParseFailuresStillFailInsteadOfPublishingPartialTrust() {
        val spi = BoundarySpi(failDer = true)
        val caught = assertThrows(CertificateException::class.java) {
            AppTrust.rootDer(24, listOf(testRoot("ec-acc"), testRoot("synthetic-ec-acc-positive")),
                boundaryFactory(spi)) {
                throw AssertionError("Default parse failure must propagate before reading the bundle")
            }
        }
        assertSame(spi.failure, caught)
    }

    @Test fun truncatedChangedEmptyOrExtraCertificateBytesCannotBecomeTrusted() {
        val bytes = bundle()
        for (invalid in listOf(
            byteArrayOf(), bytes.copyOf(bytes.size - 1), bytes + byteArrayOf(0),
            bytes.copyOf().apply { this[1000] = (this[1000].toInt() xor 1).toByte() },
            "-----BEGIN CERTIFICATE-----\nnot a certificate\n-----END CERTIFICATE-----\n".toByteArray(),
        )) {
            assertThrows(IOException::class.java) { AppTrust.rootDer(24, emptyList()) { invalid } }
        }
    }
}
