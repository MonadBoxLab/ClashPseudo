package io.github.monadboxlab.clashpseudo.trust

import android.content.Context
import io.github.monadboxlab.clashpseudo.nativecore.BundledAssetContract
import android.os.Build
import android.util.Base64
import android.util.Log
import java.io.IOException
import java.nio.ByteBuffer
import java.security.KeyStore
import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import javax.net.ssl.TrustManager
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

/**
 * One immutable, process-local trust-anchor snapshot shared by both Flutter engines
 * and Go.
 */
object AppTrust {
    internal const val BUNDLE_ASSET = BundledAssetContract.CERTIFICATE_ASSET
    internal const val BUNDLE_SIZE = BundledAssetContract.CERTIFICATE_BYTES
    internal const val BUNDLE_SHA256 = BundledAssetContract.CERTIFICATE_SHA256
    private const val LEGACY_NEGATIVE_ROOT_SHA256 =
        "88497f01602f3154246ae28c4d5aef10f1d87ebb76626f4ae0b7f95ba7968799"

    @Volatile private var cachedPem: String? = null

    /**
     * Call on a worker. Propagate failures; cache successful snapshots, including an
     * empty default set on API34+.
     */
    fun pem(context: Context): String {
        cachedPem?.let { return it }
        return synchronized(this) {
            cachedPem?.let { return@synchronized it }
            val factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
            factory.init(null as KeyStore?)
            val defaults = defaultRoots(factory.trustManagers)
            val roots = rootDer(Build.VERSION.SDK_INT, defaults) {
                context.applicationContext.assets.open(BUNDLE_ASSET).use { it.readBytes() }
            }
            if (defaults.any { excludedLegacyRoot(Build.VERSION.SDK_INT, it) }) {
                Log.w("PseudoTrust", "Excluded fixed legacy negative-serial root: $LEGACY_NEGATIVE_ROOT_SHA256")
            }
            val pem = buildString {
                for (der in roots) {
                    append("-----BEGIN CERTIFICATE-----\n")
                    // Use android.util.Base64 for API24 compatibility.
                    val encoded = Base64.encodeToString(der, Base64.NO_WRAP)
                    for (line in encoded.chunked(64)) append(line).append('\n')
                    append("-----END CERTIFICATE-----\n")
                }
            }
            cachedPem = pem
            pem
        }
    }

    internal fun defaultRoots(managers: Array<TrustManager>): List<X509Certificate> {
        val x509 = managers.filterIsInstance<X509TrustManager>()
        if (x509.isEmpty()) throw CertificateException("Default trust provider has no X509TrustManager")
        return x509.flatMap { it.acceptedIssuers.toList() }
    }

    // Exclude only this exact API24–33 default anchor with its negative serial; parse
    // all other certificates normally.
    private fun excludedLegacyRoot(apiLevel: Int, certificate: X509Certificate): Boolean =
        apiLevel in 24..33 && certificate.serialNumber.signum() < 0 &&
            MessageDigest.getInstance("SHA-256").digest(certificate.encoded)
                .joinToString("") { "%02x".format(it) } == LEGACY_NEGATIVE_ROOT_SHA256

    /** Expose the API split for tests using the actual Android trust store. */
    internal fun rootDer(
        apiLevel: Int,
        defaults: List<X509Certificate>,
        factory: CertificateFactory = CertificateFactory.getInstance("X.509"),
        readBundle: () -> ByteArray,
    ): List<ByteArray> {
        val roots = LinkedHashMap<ByteBuffer, ByteArray>()
        fun add(certificate: X509Certificate) {
            val der = certificate.encoded
            val parsed = factory.generateCertificate(der.inputStream()) as? X509Certificate
                ?: throw CertificateException("Default trust anchor is not an X.509 certificate")
            if (!parsed.encoded.contentEquals(der)) {
                throw CertificateException("Trust anchor is not a complete DER certificate")
            }
            roots.putIfAbsent(ByteBuffer.wrap(der).asReadOnlyBuffer(), der)
        }
        defaults.forEach { if (!excludedLegacyRoot(apiLevel, it)) add(it) }
        if (apiLevel < 34) {
            val bytes = readBundle()
            val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
                .joinToString("") { "%02x".format(it) }
            if (bytes.size != BUNDLE_SIZE || digest != BUNDLE_SHA256) {
                throw IOException("Bundled CA snapshot does not match its fixed size and SHA-256")
            }
            // API24 Conscrypt treats curl's leading header as DER and returns zero
            // roots. Verify the fixed asset, isolate PEM boundaries, and require every
            // certificate to parse before publishing the set.
            val bundled = Regex(
                "-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----",
                RegexOption.DOT_MATCHES_ALL,
            ).findAll(bytes.toString(Charsets.UTF_8)).toList()
            if (bundled.isEmpty()) throw CertificateException("Bundled CA snapshot contains no certificates")
            for (block in bundled) {
                val certificate = factory.generateCertificate(
                    (block.value + "\n").toByteArray(Charsets.US_ASCII).inputStream(),
                )
                add(certificate as? X509Certificate
                    ?: throw CertificateException("Bundled trust anchor is not an X.509 certificate"))
            }
        }
        return roots.values.toList()
    }
}
