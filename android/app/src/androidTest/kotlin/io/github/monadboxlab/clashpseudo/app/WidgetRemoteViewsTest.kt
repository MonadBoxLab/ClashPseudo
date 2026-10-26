package io.github.monadboxlab.clashpseudo.app

import android.appwidget.AppWidgetHostView
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.os.Build
import android.os.Looper
import android.os.Process
import android.view.View
import android.widget.ImageButton
import android.widget.RemoteViews
import androidx.test.platform.app.InstrumentationRegistry
import io.github.monadboxlab.clashpseudo.R
import io.github.monadboxlab.clashpseudo.controls.SystemControls
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Test

/** Render production RemoteViews in an SDK host. */
class WidgetRemoteViewsTest {
    @Test fun productionViewsLoadOnTheSdkHostWithoutAProducerLooper() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val component = ComponentName(context, VpnWidgetProvider::class.java)
        val info = AppWidgetManager.getInstance(context).getInstalledProvidersForProfile(Process.myUserHandle())
            .single { it.provider == component }
        val pool = Executors.newSingleThreadExecutor { task -> Thread(task, "widget-sdk-remoteviews") }
        try {
            for (state in listOf("UNKNOWN", "RUNNING", "STOPPED", "CAPACITY")) {
                val capacity = state == "CAPACITY"
                val enabled = state in setOf("RUNNING", "STOPPED")
                val projection = SystemControls.Projection(
                    phase = if (capacity) "UNKNOWN" else state,
                    mode = null, savedMode = null, savedModeKnown = false,
                    busy = false, failed = false, pendingStart = false,
                    pendingSystemStart = false)
                val expectedDescription = when (state) {
                    "RUNNING" -> context.getString(R.string.system_control_action_stop)
                    "STOPPED" -> context.getString(R.string.system_control_action_start)
                    else -> context.getString(R.string.system_control_action_unavailable,
                        context.getString(R.string.widget_unknown))
                }
                val produced = pool.submit<RemoteViews> {
                    assertNull("Producer must not need a Looper", Looper.myLooper())
                    VpnWidgetProvider.remoteViews(context, projection, if (capacity) 140f else 160f)
                }.get(5, TimeUnit.SECONDS)
                val completed = CountDownLatch(1)
                val asyncUsed = AtomicBoolean(false)
                val asyncHadLooper = AtomicBoolean(false)
                val errorView = AtomicBoolean(false)
                val hostRef = AtomicReference<AppWidgetHostView?>()
                val executor = Executor { task -> pool.execute {
                    asyncUsed.set(true)
                    if (Looper.myLooper() != null) asyncHadLooper.set(true)
                    task.run()
                } }
                try {
                    WidgetGeometry.onMain {
                        val host = object : AppWidgetHostView(context) {
                            override fun getErrorView(): View {
                                errorView.set(true)
                                completed.countDown()
                                return super.getErrorView()
                            }
                            override fun onViewAdded(child: View) {
                                super.onViewAdded(child)
                                val control = child.findViewById<ImageButton>(R.id.widget_control)
                                val content = child.findViewById<View>(R.id.widget_content)
                                if (control != null && content != null &&
                                    (capacity && content.visibility == View.GONE ||
                                        !capacity && control.contentDescription?.toString() == expectedDescription)) {
                                    completed.countDown()
                                }
                            }
                        }
                        hostRef.set(host)
                        host.setAppWidget(AppWidgetManager.INVALID_APPWIDGET_ID, info)
                        if (Build.VERSION.SDK_INT >= 26) host.setExecutor(executor)
                        host.updateAppWidget(produced)
                    }
                    assertTrue("SDK apply did not complete: $state", completed.await(10, TimeUnit.SECONDS))
                    instrumentation.waitForIdleSync()
                    assertFalse("SDK selected its error view: $state", errorView.get())
                    if (Build.VERSION.SDK_INT >= 26) {
                        assertTrue("SDK did not use its public async executor", asyncUsed.get())
                        assertFalse("SDK async executor acquired a Looper", asyncHadLooper.get())
                    } else {
                        assertFalse("API 24/25 must use their supported synchronous SDK path", asyncUsed.get())
                    }
                    WidgetGeometry.onMain {
                        val host = checkNotNull(hostRef.get())
                        assertEquals(1, host.childCount)
                        val root = host.getChildAt(0)
                        assertNotNull(root.findViewById<View>(R.id.widget_open))
                        val supported = setOf(android.widget.FrameLayout::class.java,
                            android.widget.RelativeLayout::class.java, android.widget.LinearLayout::class.java,
                            android.widget.TextView::class.java,
                            android.widget.ImageView::class.java, ImageButton::class.java)
                        for (view in WidgetGeometry.descendants(root)) {
                            assertTrue("Unsupported RemoteViews class: ${view.javaClass.name}", view.javaClass in supported)
                        }
                        val control = root.findViewById<ImageButton>(R.id.widget_control)
                        assertEquals(enabled, control.isEnabled)
                        assertEquals(enabled, control.hasOnClickListeners())
                        assertTrue(root.findViewById<View>(R.id.widget_open).hasOnClickListeners())
                        if (!capacity) assertEquals(expectedDescription, control.contentDescription.toString())
                    }
                } finally {
                    WidgetGeometry.onMain {
                        hostRef.get()?.let { host ->
                            if (Build.VERSION.SDK_INT >= 26) host.setExecutor(null)
                            host.removeAllViews()
                        }
                    }
                }
            }
        } finally {
            pool.shutdownNow()
            assertTrue("SDK widget test worker did not drain", pool.awaitTermination(5, TimeUnit.SECONDS))
        }
    }
}
