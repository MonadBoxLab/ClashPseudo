package io.github.monadboxlab.clashpseudo.bridge

import io.github.monadboxlab.clashpseudo.app.AppStrings

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.monadboxlab.clashpseudo.R
import io.github.monadboxlab.clashpseudo.nativecore.NativeCore
import java.util.concurrent.Executor

/** Package information queries run on the shared worker and reply on the main thread. */
class ApplicationsCalls(
    private val context: Context,
    private val worker: Executor,
    private val coreVersion: () -> String = { NativeCore.version() },
) {
    private val main = Handler(Looper.getMainLooper())

    fun appInfo(result: MethodChannel.Result) {
        worker.execute {
            try {
                val info = context.packageManager.getPackageInfo(context.packageName, 0)
                val value = mapOf("version" to info.versionName, "coreVersion" to coreVersion())
                main.post { result.success(value) }
            } catch (_: Exception) {
                main.post { result.error("appInfo", null, AppStrings.message(R.string.error_app_info_version).toMap()) }
            } catch (_: LinkageError) {
                main.post { result.error("appInfo", null, AppStrings.message(R.string.error_app_info_native).toMap()) }
            }
        }
    }

    fun applications(result: MethodChannel.Result) {
        worker.execute {
            val value = try { readApplications() } catch (_: Exception) { null }
            main.post {
                if (value == null) result.error("applications", null, AppStrings.message(R.string.error_applications).toMap())
                else result.success(value)
            }
        }
    }

    fun applicationIcon(call: MethodCall, result: MethodChannel.Result) {
        worker.execute {
            val value = try { readIcon(call.argument<String>("package").orEmpty()) } catch (_: Exception) { null }
            main.post { result.success(value) }
        }
    }

    /** One application icon as a bounded PNG for the targeting page. */
    private fun readIcon(name: String): ByteArray? {
        if (name.isEmpty()) return null
        val application = try {
            context.packageManager.getApplicationInfo(name, 0)
        } catch (_: Exception) {
            return null
        }
        val drawable = try {
            context.packageManager.getApplicationIcon(application)
        } catch (_: Exception) {
            return null
        }
        val bitmap = Bitmap.createBitmap(ICON_SIZE, ICON_SIZE, Bitmap.Config.ARGB_8888)
        return try {
            val canvas = Canvas(bitmap)
            drawable.setBounds(0, 0, ICON_SIZE, ICON_SIZE)
            drawable.draw(canvas)
            val output = java.io.ByteArrayOutputStream()
            if (bitmap.compress(Bitmap.CompressFormat.PNG, 100, output) &&
                output.size() <= ICON_LIMIT) output.toByteArray() else null
        } finally {
            bitmap.recycle()
        }
    }

    private fun readApplications(): List<Map<String, Any?>> {
        val manager = context.packageManager
        return manager.getInstalledPackages(0).mapNotNull { info ->
            val application = info.applicationInfo ?: return@mapNotNull null
            val label = runCatching { manager.getApplicationLabel(application).toString() }
                .getOrNull()?.takeIf { it.isNotBlank() } ?: info.packageName
            mapOf(
                "package" to info.packageName,
                "label" to label,
                "uid" to application.uid,
                "system" to ((application.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0),
            )
        }.sortedBy { (it["label"] as String).lowercase() }
    }

    companion object {
        private const val ICON_SIZE = 96
        private const val ICON_LIMIT = 256 * 1024
    }
}
