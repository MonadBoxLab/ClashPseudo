package io.github.monadboxlab.clashpseudo.debug

/** 仅在启用 native coverage 的 debug build 中提供 JNI；调用方须位于 :core 并已加载 library。 */
object NativeCoverage {
    @JvmStatic external fun probe(first: Boolean, second: Boolean): Int
    @JvmStatic external fun write(path: String): Int
}
