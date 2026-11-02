package io.github.monadboxlab.clashpseudo.nativecore

import android.content.Context
import android.os.Process
import io.github.monadboxlab.clashpseudo.app.AppProcess

internal object CoreProcessExit {
    @Suppress("UNUSED_PARAMETER")
    fun exit(context: Context, processId: String, normal: Boolean) {
        AppProcess.requireCore(context)
        Process.killProcess(Process.myPid())
        kotlin.system.exitProcess(0)
    }
}
