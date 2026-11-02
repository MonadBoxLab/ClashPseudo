package io.github.monadboxlab.clashpseudo.nativecore

import android.content.Context
import android.os.Process
import android.util.Log
import io.github.monadboxlab.clashpseudo.BuildConfig
import io.github.monadboxlab.clashpseudo.debug.NativeCoverage
import org.json.JSONObject
import java.io.File

/** 仅在正常退出且实际 JNI 已返回后保存本 process 的 profile；原 deadline 的强制退出不等待。 */
internal object CoreProcessExit {
    fun exit(context: Context, processId: String, normal: Boolean) {
        try {
            if (normal && BuildConfig.VALIDATION_NATIVE_COVERAGE) flush(context, processId)
        } finally {
            Process.killProcess(Process.myPid())
        }
    }

    private fun flush(context: Context, processId: String) {
        val receipt = JSONObject().put("processId", processId).put("pid", Process.myPid()).put("normal", true)
        var record: File? = null
        try {
            require(processId.length in 1..128 && Regex("[a-zA-Z0-9-]+").matches(processId))
            val basename = "validation-native-core-$processId"
            val output = File(context.filesDir, "$basename.profraw")
            record = File(context.filesDir, "$basename.json")
            receipt.put("path", output.path).put("newFile", !output.exists()).put("nativeLoaded", NativeCore.isLoaded)
            if (NativeCore.isLoaded) {
                check(!output.exists()) { "coverage profile 已存在" }
                val written = NativeCoverage.write(output.path)
                receipt.put("write", written).put("bytes", output.length()).put("regular", output.isFile)
                    .put("collected", written == 0 && output.isFile && output.length() > 0)
            } else {
                receipt.put("collected", false).put("reason", "nativeNotLoaded")
            }
        } catch (error: Throwable) {
            receipt.put("error", CoreErrors.json(error))
        }
        try {
            record?.let { target ->
                check(!target.exists()) { "coverage receipt 已存在" }
                CorePrivateFiles.write(target, receipt.toString().toByteArray(Charsets.UTF_8))
            }
        } catch (error: Throwable) {
            receipt.put("receiptError", CoreErrors.json(error))
        }
        Log.i("NativeCoverage", receipt.toString())
    }
}
