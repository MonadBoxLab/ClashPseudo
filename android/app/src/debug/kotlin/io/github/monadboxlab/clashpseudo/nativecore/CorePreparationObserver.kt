package io.github.monadboxlab.clashpseudo.nativecore

import android.content.Context
import android.os.SystemClock
import android.system.Os
import android.system.OsConstants
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import org.json.JSONObject
import java.io.File

/** 固定 Worker 回归在新 :core 进程进入 native PREPARE 前暂停，控制文件不属于业务商店。 */
internal object CorePreparationObserver {
    private const val CONFIG_ID = "p5-worker-config-p5-load-worker-r7w12"
    private fun directory(context: Context) = File(context.noBackupFilesDir, "worker-starting-fixture")
    private fun file(context: Context, name: String) = File(directory(context), name)

    fun armWorkerGate(context: Context) {
        val directory = directory(context)
        check(directory.mkdir()) { "Worker STARTING fixture 目录已存在或无法创建" }
        check(OsConstants.S_ISDIR(Os.lstat(directory.path).st_mode))
        CorePrivateFiles.write(file(context, "armed"), byteArrayOf(1))
    }

    fun workerGateState(context: Context): JSONObject? =
        CorePrivateFiles.read(file(context, "entered.json"), Contract.CORE_IPC_CONTROL_BYTES)
            ?.let { JSONObject(CoreFrames.utf8(it)) }
            ?.put("cancelObserved", CorePrivateFiles.read(file(context, "cancelled"), 1) != null)
            ?.put("released", CorePrivateFiles.read(file(context, "released"), 1) != null)
            ?.put("finished", CorePrivateFiles.read(file(context, "finished"), 1) != null)

    fun releaseWorkerGate(context: Context) {
        if (directory(context).exists()) CorePrivateFiles.write(file(context, "released"), byteArrayOf(1))
    }

    fun removeWorkerGate(context: Context) {
        val directory = directory(context)
        if (!directory.exists()) return
        check(CorePrivateFiles.read(file(context, "released"), 1) != null) { "删除 fixture 前必须释放 gate" }
        val names = setOf("armed", "entered.json", "cancelled", "released", "finished")
        val children = checkNotNull(directory.listFiles())
        check(children.all { it.name in names }) { "Worker fixture 目录出现未知文件" }
        children.forEach { child ->
            check(OsConstants.S_ISREG(Os.lstat(child.path).st_mode))
            Os.remove(child.path)
        }
        check(directory.delete())
    }

    fun beforeNativePrepare(context: Context, processId: String, inputId: String, configId: String?,
                            revision: Int, requestId: Long, deadline: Long, cancelled: () -> Boolean) {
        if (configId != CONFIG_ID || revision != 2 ||
            CorePrivateFiles.read(file(context, "armed"), 1) == null) return
        check(CorePrivateFiles.read(file(context, "entered.json"), Contract.CORE_IPC_CONTROL_BYTES) == null) {
            "固定 STARTING gate 只能受理一个 PREPARE"
        }
        val state = JSONObject().put("processId", processId).put("inputId", inputId)
            .put("configId", configId).put("revision", revision).put("requestId", requestId)
            .put("pid", android.os.Process.myPid()).put("generation", 1L)
        CorePrivateFiles.write(file(context, "entered.json"), state.toString().toByteArray(Charsets.UTF_8))
        try {
            while (true) {
                if (cancelled()) {
                    CorePrivateFiles.write(file(context, "cancelled"), byteArrayOf(1))
                    throw CoreTransportException(Contract.CORE_ERROR_CANCELLED, "Worker PREPARE 在 native 装载前已取消")
                }
                check(SystemClock.elapsedRealtime() < deadline) { "Worker STARTING gate 超过原受理期限" }
                if (CorePrivateFiles.read(file(context, "released"), 1) != null) break
                Thread.sleep(10)
            }
            if (cancelled()) {
                CorePrivateFiles.write(file(context, "cancelled"), byteArrayOf(1))
                throw CoreTransportException(Contract.CORE_ERROR_CANCELLED, "Worker PREPARE 在 gate 释放后已取消")
            }
        } finally { CorePrivateFiles.write(file(context, "finished"), byteArrayOf(1)) }
    }
}
