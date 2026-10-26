package io.github.monadboxlab.clashpseudo.debug

import io.github.monadboxlab.clashpseudo.nativecore.NativeCore

/** JNI entries exist only in explicitly instrumented native test builds. */
object NativeCoverage {
    init {
        NativeCore.version()
    }

    @JvmStatic external fun probe(first: Boolean, second: Boolean): Int
    @JvmStatic external fun write(path: String): Int
}
