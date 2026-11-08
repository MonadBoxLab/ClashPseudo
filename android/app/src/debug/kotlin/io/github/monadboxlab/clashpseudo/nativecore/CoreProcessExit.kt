package io.github.monadboxlab.clashpseudo.nativecore

import android.content.Context
import android.os.Process
import android.util.Log
import io.github.monadboxlab.clashpseudo.BuildConfig
import io.github.monadboxlab.clashpseudo.app.AppProcess
import io.github.monadboxlab.clashpseudo.debug.NativeCoverage
import org.json.JSONObject
import java.io.File

/** Save this process's profile only on normal exit after JNI has returned; forced exit at the original deadline does not wait. */
internal object CoreProcessExit {
    fun exit(context: Context, processId: String, normal: Boolean) {
        AppProcess.requireCore(context)
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
                check(!output.exists()) { "Coverage profile already exists" }
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
                check(!target.exists()) { "Coverage receipt already exists" }
                CorePrivateFiles.write(target, receipt.toString().toByteArray(Charsets.UTF_8))
            }
        } catch (error: Throwable) {
            receipt.put("receiptError", CoreErrors.json(error))
        }
        Log.i("NativeCoverage", receipt.toString())
    }
}
