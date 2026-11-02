package io.github.monadboxlab.clashpseudo.app

import android.app.ActivityManager
import android.app.Application
import android.content.Context
import android.os.Build
import android.os.Process

/** 在创建业务宿主或加载原生库前确定进程职责。 */
object AppProcess {
    fun name(context: Context): String {
        if (Build.VERSION.SDK_INT >= 28) return Application.getProcessName()
        val manager = context.getSystemService(ActivityManager::class.java)
        return manager.runningAppProcesses?.firstOrNull { it.pid == Process.myPid() }?.processName
            ?: throw IllegalStateException("无法确定当前应用进程")
    }

    fun isCore(context: Context): Boolean = name(context) == "${context.packageName}:core"
    fun isApplication(context: Context): Boolean = name(context) == context.packageName

    fun requireCore(context: Context) = check(isCore(context)) { "原生内核只能在 :core 进程访问" }
    fun requireApplication(context: Context) = check(isApplication(context)) { "业务宿主只能在默认应用进程创建" }
}
