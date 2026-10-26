package io.github.monadboxlab.clashpseudo.nativecore

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.OutputStream
import java.security.MessageDigest
import java.util.concurrent.CancellationException
import java.util.zip.GZIPOutputStream
import org.junit.Assert.*
import org.junit.Test

class BundledGeoTest {
    private val body = "fixed Geo payload\n".repeat(4096).toByteArray()
    private fun hash(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes)
        .joinToString("") { "%02x".format(it) }
    private fun data(stored: ByteArray = body, gzip: Boolean = false) =
        BundledGeo.Data("test", gzip, body.size.toLong(), hash(body), stored.size.toLong(), hash(stored))
    private fun gzip() = ByteArrayOutputStream().also { out ->
        GZIPOutputStream(out).use { it.write(body) }
    }.toByteArray()
    private fun copy(spec: BundledGeo.Data, bytes: ByteArray): ByteArray = ByteArrayOutputStream().also {
        BundledGeo.copyVerified(spec, bytes.inputStream(), it) {}
    }.toByteArray()
    private inline fun <reified T : Throwable> rejects(action: () -> Unit) {
        try { action(); fail("Expected ${T::class.java.simpleName}") } catch (error: Throwable) {
            if (error !is T) throw error
        }
    }

    @Test fun rawAndOfficialStyleGzipPreserveExpandedBytes() {
        assertArrayEquals(body, copy(data(), body))
        val compressed = gzip()
        assertArrayEquals(body, copy(data(compressed, true), compressed))
    }

    @Test fun storedSizeAndDigestAreBothRequired() {
        val compressed = gzip()
        val correct = data(compressed, true)
        for (invalid in listOf(correct.copy(storedSize = correct.storedSize + 1),
            correct.copy(storedSize = correct.storedSize - 1), correct.copy(storedSha256 = "0".repeat(64)))) {
            rejects<IOException> { copy(invalid, compressed) }
        }
    }

    @Test fun expandedSizeAndDigestAreBothRequired() {
        val compressed = gzip()
        val correct = data(compressed, true)
        for (invalid in listOf(correct.copy(size = correct.size + 1),
            correct.copy(size = correct.size - 1), correct.copy(sha256 = "0".repeat(64)))) {
            rejects<IOException> { copy(invalid, compressed) }
        }
    }

    @Test fun truncatedOrCorruptGzipCannotSucceed() {
        val compressed = gzip()
        val corrupt = compressed.copyOf().apply { this[lastIndex - 7] = (this[lastIndex - 7].toInt() xor 1).toByte() }
        for (bytes in listOf(compressed.copyOf(compressed.size - 5), corrupt, byteArrayOf(1, 2, 3))) {
            rejects<IOException> { copy(data(bytes, true), bytes) }
        }
    }

    @Test fun rawCorruptionAndExcessBytesCannotSucceed() {
        rejects<IOException> { copy(data(), body.copyOf().apply { this[0] = 0 }) }
        rejects<IOException> { copy(data(), body + byteArrayOf(0)) }
        rejects<IOException> { copy(data(), body.copyOf(body.size - 1)) }
    }

    @Test fun streamingIsBoundedAndDoesNotPublishOversizeChunks() {
        var written = 0L
        val output = object : OutputStream() {
            override fun write(value: Int) { written++ }
            override fun write(bytes: ByteArray, offset: Int, length: Int) { written += length }
        }
        val spec = data().copy(size = 100)
        rejects<IOException> { BundledGeo.copyVerified(spec, body.inputStream(), output) {} }
        assertTrue(written <= spec.size)
    }

    @Test fun cancellationIsCheckedDuringCopyNotOnlyAtTheEnd() {
        var written = 0L
        val output = object : OutputStream() {
            override fun write(value: Int) { written++ }
            override fun write(bytes: ByteArray, offset: Int, length: Int) { written += length }
        }
        rejects<CancellationException> {
            BundledGeo.copyVerified(data(), body.inputStream(), output) {
                if (written > 0) throw CancellationException("old owner")
            }
        }
        assertTrue(written in 1 until body.size.toLong())
    }

    @Test fun inputClosesOnOutputFailureAndOutputRemainsCallersResponsibility() {
        var closed = false
        val input = object : ByteArrayInputStream(body) { override fun close() { closed = true; super.close() } }
        val output = object : OutputStream() {
            override fun write(value: Int) { throw IOException("disk full") }
            override fun close() { fail("copy does not own output") }
        }
        rejects<IOException> { BundledGeo.copyVerified(data(), input, output) {} }
        assertTrue(closed)
    }

    @Test fun cancellationDuringGzipHeaderConstructionStillClosesInput() {
        var closed = false
        val compressed = gzip()
        val input = object : ByteArrayInputStream(compressed) {
            override fun close() { closed = true; super.close() }
        }
        var checks = 0
        rejects<CancellationException> {
            BundledGeo.copyVerified(data(compressed, true), input, ByteArrayOutputStream()) {
                if (++checks > 4) throw CancellationException()
            }
        }
        assertTrue(closed)
    }

    @Test fun requestsAcceptOnlyFixedBasenamesIncludingCoreAliases() {
        for (kind in BundledGeo.Kind.entries) {
            for (name in kind.names) {
                BundledGeo.Request(kind, name)
                BundledGeo.Request(kind, name.uppercase())
            }
            for (name in listOf("../GeoIP.dat", "/GeoIP.dat", "provider.yaml", "cache.db", "tailscale", "", "GeoIP.dat/")) {
                rejects<IllegalArgumentException> { BundledGeo.Request(kind, name) }
            }
        }
        rejects<IllegalArgumentException> { BundledGeo.Request(BundledGeo.Kind.ASN, "Country.mmdb") }
    }

    @Test fun fixedBasenamesUseCoreCaseFoldingNotTurkishJavaCaseInsensitivity() {
        assertTrue(BundledGeo.Kind.GEOSITE.acceptsName("Geoſite.dat"))
        assertTrue(BundledGeo.Kind.GEOSITE.acceptsName("GEOSITE.DAT"))
        for (name in listOf("GeoSİte.dat", "GeoSıte.dat")) {
            assertFalse(BundledGeo.Kind.GEOSITE.acceptsName(name))
            rejects<IllegalArgumentException> { BundledGeo.Request(BundledGeo.Kind.GEOSITE, name) }
        }
    }

    @Test fun localGzipAssetNamesAvoidAndroidGradleAutomaticGzExpansion() {
        assertEquals("dbip-country-lite-2026-10.mmdb.gzip", BundledGeo.Kind.MMDB.data.asset)
        assertEquals("dbip-asn-lite-2026-10.mmdb.gzip", BundledGeo.Kind.ASN.data.asset)
        for (kind in listOf(BundledGeo.Kind.MMDB, BundledGeo.Kind.ASN)) {
            assertTrue(kind.data.gzip)
            assertFalse(kind.data.asset.endsWith(".gz", ignoreCase = true))
        }
    }

    @Test fun formalFourAssetsMatchTheInstallersFixedStoredAndExpandedFingerprints() {
        val assets = File(checkNotNull(System.getProperty("geodata.assets", "src/main/assets/geodata")))
        assertTrue("Formal Geo assets are required", assets.isDirectory)
        var expanded = 0L
        var stored = 0L
        for (kind in BundledGeo.Kind.entries) {
            val path = File(assets, kind.data.asset)
            assertEquals(kind.data.storedSize, path.length())
            path.inputStream().use { input ->
                BundledGeo.copyVerified(kind.data, input, object : OutputStream() {
                    override fun write(value: Int) { expanded++ }
                    override fun write(bytes: ByteArray, offset: Int, length: Int) {
                        assertTrue(length <= 32 * 1024)
                        expanded += length
                    }
                }) {}
            }
            stored += path.length()
        }
        assertEquals(43502351L, expanded)
        assertEquals(34897065L, stored)
    }
}
