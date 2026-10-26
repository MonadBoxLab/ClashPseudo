// 由 Geo／CA manifest 生成；修改源声明后运行 tool/contracts/generate.py。
package io.github.monadboxlab.clashpseudo.nativecore

internal object BundledAssetContract {
    val geoip = BundledGeo.Data("GeoIP.dat", false, 23258601L, "4ff4b2ec242a9e87b296ba27ddb85f8311e8d3e071eaebac5be9231c60e408dd", 23258601L, "4ff4b2ec242a9e87b296ba27ddb85f8311e8d3e071eaebac5be9231c60e408dd")
    val geosite = BundledGeo.Data("GeoSite.dat", false, 2328878L, "0a38573dee9f6eb16c67e457c6d5d7f0755f12a8cdaa25ec26b358fdbcf9e79d", 2328878L, "0a38573dee9f6eb16c67e457c6d5d7f0755f12a8cdaa25ec26b358fdbcf9e79d")
    val mmdb = BundledGeo.Data("dbip-country-lite-2026-10.mmdb.gzip", true, 8348509L, "dbd70ccfa2a13627eaf4913d19920a1a229f1b3c5439ac01c509995b6364202a", 4123384L, "4cd44536ddfd40fec7eca94a233f7d19f38d470e6522e653cb8d27001f5fe177")
    val asn = BundledGeo.Data("dbip-asn-lite-2026-10.mmdb.gzip", true, 9566363L, "4384bfcfb594391bc4e0ab37751f44661eaf7cadbeee28a90a6b82dc935fec4c", 5186202L, "6cdde02baa8c1bd619ab84c2e505ecd91d45288b5a87faadf1b7c41525a17a94")
    const val CERTIFICATE_ASSET = "certificates/cacert-2026-09-25.pem"
    const val CERTIFICATE_BYTES = 188900
    const val CERTIFICATE_SHA256 = "a41b5d356aea97a529fe27e0f7316d2f9d946d75927476cf9cf1b90637d00505"
}
