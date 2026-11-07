package io.github.monadboxlab.clashpseudo.nativecore

import android.content.Context

/** Normal builds do not pause PREPARE or read instrumentation control files. */
internal object CorePreparationObserver {
    @Suppress("UNUSED_PARAMETER")
    fun beforeNativePrepare(context: Context, processId: String, inputId: String, configId: String?,
                            revision: Int, requestId: Long, deadline: Long, cancelled: () -> Boolean) = Unit

    @Suppress("UNUSED_PARAMETER")
    fun afterNativePrepare(context: Context, processId: String, inputId: String, configId: String?,
                           revision: Int, requestId: Long, deadline: Long, cancelled: () -> Boolean) = Unit
}
