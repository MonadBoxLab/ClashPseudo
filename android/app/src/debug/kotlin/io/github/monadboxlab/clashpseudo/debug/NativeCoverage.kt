package io.github.monadboxlab.clashpseudo.debug

/** JNI is available only in debug builds with native coverage enabled; callers must be in :core with the library loaded. */
object NativeCoverage {
    @JvmStatic external fun probe(first: Boolean, second: Boolean): Int
    @JvmStatic external fun write(path: String): Int
}
