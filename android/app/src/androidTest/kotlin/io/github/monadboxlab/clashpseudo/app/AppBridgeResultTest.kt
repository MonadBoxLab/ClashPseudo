package io.github.monadboxlab.clashpseudo.app

import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.*
import org.junit.Test

class AppBridgeResultTest {
    @Test fun latePermissionResultCannotCompleteTheNextRequest() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            // Seed only the pending reply; no real permission or VPN is changed.
            val pending = AppBridge::class.java.getDeclaredField("authorization").apply { isAccessible = true }
            val code = AppBridge::class.java.getDeclaredField("authorizationCode").apply { isAccessible = true }
            val oldPending = pending.get(AppBridge)
            val oldCode = code.getInt(AppBridge)
            var replies = 0
            val result = object : MethodChannel.Result {
                override fun success(value: Any?) { replies++; assertEquals(false, value) }
                override fun error(code: String, message: String?, details: Any?) { fail("Unexpected error") }
                override fun notImplemented() { fail("Unexpected missing method") }
            }
            try {
                assertNull(oldPending)
                code.setInt(AppBridge, 202)
                pending.set(AppBridge, result)
                AppBridge.authorizationResult(201, false)
                assertEquals(0, replies)
                assertSame(result, pending.get(AppBridge))
                AppBridge.authorizationResult(202, false)
                assertEquals(1, replies)
                assertNull(pending.get(AppBridge))
                AppBridge.authorizationResult(202, false)
                assertEquals(1, replies)
            } finally {
                pending.set(AppBridge, oldPending)
                code.setInt(AppBridge, oldCode)
            }
        }
    }

    @Test fun nativeStateChangeExpiresEarlierSuccessFeedback() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val message = AppBridge::class.java.getDeclaredField("resultMessage").apply { isAccessible = true }
            val old = message.get(AppBridge)
            try {
                assertNull(AppBridge.operationId)
                message.set(AppBridge, "接管已启动。")
                AppBridge.nativeChanged()
                assertNull(message.get(AppBridge))
            } finally {
                message.set(AppBridge, old)
            }
        }
    }

    @Test fun lateOperationResultCannotFinishCurrentWork() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val id = AppBridge::class.java.getDeclaredField("operationId").apply { isAccessible = true }
            val old = id.get(AppBridge)
            try {
                assertNull(old)
                id.set(AppBridge, "current-operation")
                AppBridge.finish("old-operation", mapOf("message" to "stale"))
                assertEquals("current-operation", AppBridge.operationId)
            } finally {
                id.set(AppBridge, old)
            }
        }
    }
}
