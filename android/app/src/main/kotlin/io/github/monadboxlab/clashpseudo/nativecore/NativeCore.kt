package io.github.monadboxlab.clashpseudo.nativecore

object NativeCore {
    init {
        System.loadLibrary("mihomo_bridge")
    }

    @JvmStatic external fun version(): String
    @JvmStatic external fun prepare(home: String, config: ByteArray, mode: String, protector: Any,
                                    choices: ByteArray = "{}".toByteArray()): String
    @JvmStatic external fun strategies(): String
    @JvmStatic external fun setStrategy(request: ByteArray): String
    @JvmStatic external fun mode(): String
    @JvmStatic external fun setMode(mode: String): String
    // Ownership of fd transfers to native code even when it returns an error.
    @JvmStatic external fun attach(fd: Int, mtu: Int, address: String, prefixLength: Int): String
    @JvmStatic external fun cancel()
    @JvmStatic external fun stop(): String
    @JvmStatic external fun connections(request: ByteArray): String
    @JvmStatic external fun closeConnection(id: ByteArray): String
    @JvmStatic external fun snapshot(): String
}
