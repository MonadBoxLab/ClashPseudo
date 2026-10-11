package io.github.monadboxlab.clashpseudo.nativecore

object NativeCore {
    init {
        System.loadLibrary("mihomo_bridge")
    }

    @JvmStatic external fun version(): String
    @JvmStatic external fun prepare(home: String, config: ByteArray, protector: Any): String
    // Ownership of fd transfers to native code even when it returns an error.
    @JvmStatic external fun attach(fd: Int, mtu: Int, address: String, prefixLength: Int): String
    @JvmStatic external fun cancel()
    @JvmStatic external fun stop(): String
    @JvmStatic external fun snapshot(): String
}
