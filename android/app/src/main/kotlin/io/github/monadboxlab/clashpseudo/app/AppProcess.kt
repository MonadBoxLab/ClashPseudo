package io.github.monadboxlab.clashpseudo.app

import android.app.ActivityManager
import android.app.Application
import android.content.Context
import android.os.Build
import android.os.Process

/** Determine the process role before creating the application host or loading the native library. */
object AppProcess {
    fun name(context: Context): String {
        if (Build.VERSION.SDK_INT >= 28) return Application.getProcessName()
        val manager = context.getSystemService(ActivityManager::class.java)
        return manager.runningAppProcesses?.firstOrNull { it.pid == Process.myPid() }?.processName
            ?: throw IllegalStateException("Cannot determine the current application process")
    }

    fun isCore(context: Context): Boolean = name(context) == "${context.packageName}:core"
    fun isApplication(context: Context): Boolean = name(context) == context.packageName

    fun requireCore(context: Context) = check(isCore(context)) { "The native core can only be accessed in the :core process" }
    fun requireApplication(context: Context) = check(isApplication(context)) { "The application host can only be created in the default application process" }
}
