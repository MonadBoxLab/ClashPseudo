package io.github.monadboxlab.clashpseudo.bridge

import java.lang.reflect.Field

internal object BridgeTestState {
    private val operationFields = setOf(
        "operationId", "operationAdmittedAt", "operationDeadline", "command", "authorization", "authorizationCode",
        "operation", "resultId", "resultMessage", "resultSuccess", "connectionStatus", "configStatus",
        "overrideStatus", "resourceStatus", "scheduleStatus", "backupResult", "targetId", "savedRevision",
        "publicationGate",
    )
    private val backupFields = setOf(
        "backupUses", "preparedBackups", "retiredBackups", "restoreStopRequested", "restoreStopOwner",
        "restoreStopReply", "restoreInterruption", "installedBackup",
    )

    fun coordinator(name: String): Any = checkNotNull(
        AppBridge::class.java.getDeclaredField(name).apply { isAccessible = true }.get(AppBridge),
    ) { "Bridge coordinator is not initialized: $name" }

    fun field(name: String): BoundField {
        val target = when {
            name in operationFields -> coordinator("operations")
            name in backupFields -> coordinator("backupCoordinator")
            name == "systemRestoreOwner" || name == "discardedSystemInput" -> coordinator("systemRestore")
            name == "exitingForCleanup" -> coordinator("cleanupCalls")
            name == "scheduled" -> coordinator("scheduledRuns")
            else -> AppBridge
        }
        val field = target.javaClass.getDeclaredField(name).apply { isAccessible = true }
        return BoundField(target, field)
    }

    fun acceptOwner(id: String?) {
        AppBridge::class.java.getDeclaredMethod("replaceOwner", String::class.java)
            .apply { isAccessible = true }.invoke(AppBridge, id)
    }

    @Suppress("UNUSED_PARAMETER")
    class BoundField internal constructor(private val target: Any, private val field: Field) {
        fun get(ignored: Any? = null): Any? = field.get(target)
        fun set(ignored: Any?, value: Any?) = field.set(target, value)
        fun getBoolean(ignored: Any? = null): Boolean = field.getBoolean(target)
        fun setBoolean(ignored: Any?, value: Boolean) = field.setBoolean(target, value)
        fun getInt(ignored: Any? = null): Int = field.getInt(target)
        fun setInt(ignored: Any?, value: Int) = field.setInt(target, value)
    }
}
