package io.github.monadboxlab.clashpseudo.nativecore

import android.content.Context

/** 正常构建不暂停 PREPARE，也不读取 instrumentation 控制文件。 */
internal object CorePreparationObserver {
    @Suppress("UNUSED_PARAMETER")
    fun beforeNativePrepare(context: Context, processId: String, inputId: String, configId: String?,
                            revision: Int, requestId: Long, deadline: Long, cancelled: () -> Boolean) = Unit
}
