package io.github.monadboxlab.clashpseudo.bridge.core

import io.github.monadboxlab.clashpseudo.message.AppStrings

import android.content.ContextWrapper
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.os.Looper
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.monadboxlab.clashpseudo.R
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class ApplicationsCallsTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val worker = Executor { it.run() }

    @Test fun applicationRowsCarryTheActualAndroidUid() {
        val calls = ApplicationsCalls(context, worker)
        val rows = reply(calls::applications).value as List<*>
        val own = rows.map { it as Map<*, *> }.single { it["package"] == context.packageName }
        assertEquals(context.applicationInfo.uid, (own["uid"] as Number).toInt())
        val labels = rows.map { (it as Map<*, *>)["label"] as String }
        assertEquals(labels.sortedBy { it.lowercase() }, labels)
        rows.forEach { value ->
            val row = value as Map<*, *>
            val name = row["package"] as String
            val info = context.packageManager.getApplicationInfo(name, 0)
            assertTrue((row["label"] as String).isNotBlank())
            assertEquals(info.uid, (row["uid"] as Number).toInt())
            assertEquals((info.flags and ApplicationInfo.FLAG_SYSTEM) != 0, row["system"])
        }
    }

    @Test fun iconsAreBoundedPngsAndMissingApplicationsHaveNoIcon() {
        val calls = ApplicationsCalls(context, worker)
        repeat(3) {
            val bytes = reply { calls.applicationIcon(icon(context.packageName), it) }.value as ByteArray
            assertTrue(bytes.isNotEmpty())
            assertTrue(bytes.size <= 256 * 1024)
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            assertEquals(96, bounds.outWidth)
            assertEquals(96, bounds.outHeight)
        }
        for (name in listOf(null, "", "${context.packageName}.not_installed", 123)) {
            val result = reply { calls.applicationIcon(icon(name), it) }
            assertNull(result.value)
            assertNull(result.code)
        }
    }

    @Test fun queriesWaitForTheWorkerAndReplyOnMain() {
        val jobs = LinkedBlockingQueue<Runnable>()
        val calls = ApplicationsCalls(context, Executor { jobs.add(it) }) {
            assertNotSame(Looper.getMainLooper(), Looper.myLooper())
            "test-core"
        }
        val replies = listOf(Reply(), Reply(), Reply())
        calls.appInfo(replies[0])
        calls.applications(replies[1])
        calls.applicationIcon(icon(""), replies[2])
        assertEquals(3, jobs.size)
        replies.forEach { assertFalse(it.completed) }
        repeat(3) { jobs.remove().run() }
        replies.forEach { it.await(); assertNull(it.code) }
        assertEquals(mapOf("version" to context.packageManager.getPackageInfo(context.packageName, 0).versionName,
            "coreVersion" to "test-core"), replies[0].value)
        assertTrue(replies[1].value is List<*>)
        assertNull(replies[2].value)
    }

    @Test fun packageAndNativeFailuresKeepTheirExistingReplySemantics() {
        val packageFailure = IllegalStateException("package query unavailable",
            IllegalArgumentException("package source cause")).apply {
            addSuppressed(java.io.IOException("package cleanup failed"))
        }
        val unavailable = object : ContextWrapper(context) {
            override fun getPackageManager(): PackageManager = throw packageFailure
        }
        val calls = ApplicationsCalls(unavailable, worker)
        reply(calls::applications).assertError("applications", R.string.error_applications, packageFailure)
        reply(calls::appInfo).assertError("appInfo", R.string.error_app_info_version, packageFailure)
        val missingIcon = reply { calls.applicationIcon(icon(context.packageName), it) }
        assertNull(missingIcon.value)
        assertNull(missingIcon.code)
        val linkage = UnsatisfiedLinkError("unavailable").apply {
            initCause(IllegalStateException("linkage cause"))
            addSuppressed(java.io.IOException("linkage cleanup"))
        }
        val nativeUnavailable = ApplicationsCalls(context, worker) { throw linkage }
        reply(nativeUnavailable::appInfo).assertError("appInfo", R.string.error_app_info_native, linkage)
    }

    @Test fun rejectedWorkerRepliesOnMainWithTheOriginalCauseAndSuppressedFailure() {
        val rejection = java.util.concurrent.RejectedExecutionException("worker closed",
            IllegalStateException("shutdown cause")).apply {
            addSuppressed(java.io.IOException("worker cleanup"))
        }
        val calls = ApplicationsCalls(context, Executor { throw rejection })
        reply(calls::applications).assertError("applications", R.string.error_applications, rejection)
        reply(calls::appInfo).assertError("appInfo", R.string.error_app_info_version, rejection)
        reply { calls.applicationIcon(icon(context.packageName), it) }
            .assertError("applications", R.string.error_applications, rejection)
    }

    @Test fun workerLinkageFailureKeepsCauseAndSuppressedForEveryQuery() {
        val linkage = UnsatisfiedLinkError("executor linkage").apply {
            initCause(IllegalStateException("executor cause"))
            addSuppressed(java.io.IOException("executor cleanup"))
        }
        val calls = ApplicationsCalls(context, Executor { throw linkage })
        reply(calls::applications).assertError("applications", R.string.error_applications, linkage)
        reply(calls::appInfo).assertError("appInfo", R.string.error_app_info_version, linkage)
        reply { calls.applicationIcon(icon(context.packageName), it) }
            .assertError("applications", R.string.error_applications, linkage)
    }

    private fun icon(name: Any?) = MethodCall("applicationIcon", mapOf("package" to name))

    private fun reply(action: (MethodChannel.Result) -> Unit): Reply = Reply().also {
        action(it)
        it.await()
    }

    private class Reply : MethodChannel.Result {
        private val done = CountDownLatch(1)
        private var looper: Looper? = null
        var value: Any? = null
            private set
        var code: String? = null
            private set
        private var message: String? = null
        private var details: Any? = null
        val completed: Boolean get() = done.count == 0L

        override fun success(result: Any?) {
            value = result
            looper = Looper.myLooper()
            done.countDown()
        }

        override fun error(code: String, message: String?, details: Any?) {
            this.code = code
            this.message = message
            this.details = details
            looper = Looper.myLooper()
            done.countDown()
        }

        override fun notImplemented() = error("notImplemented", null, null)

        fun await() {
            assertTrue("application query did not reply", done.await(5, TimeUnit.SECONDS))
            assertSame(Looper.getMainLooper(), looper)
        }

        fun assertError(expectedCode: String, resource: Int, failure: Throwable) {
            assertEquals(expectedCode, code)
            assertNull(value)
            assertNull(message)
            assertEquals(AppStrings.message(resource).withDetail(failure).toMap(), details)
        }
    }
}
