package io.github.monadboxlab.clashpseudo.bridge.core

import io.github.monadboxlab.clashpseudo.message.AppStrings

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.monadboxlab.clashpseudo.R
import io.github.monadboxlab.clashpseudo.BuildConfig
import java.util.concurrent.Executor

/** Package information queries run on the shared worker and reply on the main thread. */
class ApplicationsCalls(
    private val context: Context,
    private val worker: Executor,
    private val coreVersion: () -> String = { BuildConfig.MIHOMO_VERSION },
) {
    private val main = Handler(Looper.getMainLooper())

    fun appInfo(result: MethodChannel.Result) {
        execute(result, R.string.error_app_info_version) {
            try {
                val info = context.packageManager.getPackageInfo(context.packageName, 0)
                val value = mapOf("version" to info.versionName, "coreVersion" to coreVersion())
                main.post { result.success(value) }
            } catch (error: Exception) {
                failure(result, R.string.error_app_info_version, error)
            } catch (error: LinkageError) {
                failure(result, R.string.error_app_info_native, error)
            }
        }
    }

    fun applications(result: MethodChannel.Result) {
        execute(result, R.string.error_applications) {
            try {
                val value = readApplications()
                main.post { result.success(value) }
            } catch (error: Exception) {
                failure(result, R.string.error_applications, error)
            } catch (error: LinkageError) {
                failure(result, R.string.error_applications, error)
            }
        }
    }

    private fun failure(result: MethodChannel.Result, resource: Int, error: Throwable) {
        main.post {
            result.error(if (resource == R.string.error_applications) "applications" else "appInfo",
                null, AppStrings.message(resource).withDetail(error).toMap())
        }
    }

    /** Executor rejection is also a completed, diagnosable reply on the main thread. */
    private fun execute(result: MethodChannel.Result, resource: Int, task: () -> Unit) {
        try {
            worker.execute(task)
        } catch (error: Exception) {
            failure(result, resource, error)
        } catch (error: LinkageError) {
            failure(result, resource, error)
        }
    }

    fun applicationIcon(call: MethodCall, result: MethodChannel.Result) {
        execute(result, R.string.error_applications) {
            try {
                val value = try {
                    readIcon(call.argument<String>("package").orEmpty())
                } catch (_: Exception) { null }
                main.post { result.success(value) }
            } catch (error: LinkageError) {
                failure(result, R.string.error_applications, error)
            }
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
                "updatedAt" to info.lastUpdateTime,
                "system" to ((application.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0),
            )
        }.sortedBy { (it["label"] as String).lowercase() }
    }

    companion object {
        private const val ICON_SIZE = 96
        private const val ICON_LIMIT = 256 * 1024
    }
}
