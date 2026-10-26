package io.github.monadboxlab.clashpseudo.backup

import io.github.monadboxlab.clashpseudo.app.AppMessage

internal fun backupInteger(value: Any?): Long? =
    if (value is Int || value is Long) (value as Number).toLong().takeIf { it >= 0 } else null

internal fun restoreStatus(committed: Any?) = when (committed) { true -> "restored"; false -> "notRestored"; else -> "unconfirmed" }

/** Project only the small UI result fields. */
internal fun backupProjection(value: Any?): Map<String, Any?>? {
    val raw = value as? Map<*, *> ?: return null
    val status = (raw["status"] as? String)?.takeIf {
        it in setOf("prepared", "inspected", "restored", "notRestored", "unconfirmed", "failed", "cancelled")
    } ?: return null
    val result = linkedMapOf<String, Any?>("status" to status)
    (raw["token"] as? String)?.takeIf { BackupFiles.isToken(it) }?.let { result["token"] = it }
    (raw["requestId"] as? String)?.takeIf { it.isNotBlank() && it.length <= 128 }?.let { result["requestId"] = it }
    for (key in listOf("createdAtMillis", "epoch")) backupInteger(raw[key])?.let { result[key] = it }
    for (key in listOf("rolledBack", "ready", "previewReleased")) (raw[key] as? Boolean)?.let { result[key] = it }
    if (raw.containsKey("committed") && (raw["committed"] == null || raw["committed"] is Boolean)) result["committed"] = raw["committed"]
    (raw["errorCode"] as? String)?.takeIf { it.length <= 64 && it.matches(Regex("[A-Za-z0-9_-]+")) }?.let { result["errorCode"] = it }
    (raw["connectionStatus"] as? String)?.takeIf {
        it in setOf("unchanged", "unconfirmed", "stopped", "restored", "cancelled", "failed", "notStarted")
    }?.let { result["connectionStatus"] = it }
    for (key in listOf("settingsStatus", "scheduleStatus")) {
        (raw[key] as? String)?.takeIf { it in setOf("notRun", "done", "cancelled", "failed") }?.let { result[key] = it }
    }
    val summary = raw["summary"] as? Map<*, *>
    if (summary != null) {
        val configurations = backupInteger(summary["configurations"])
        val overrides = backupInteger(summary["overrides"])
        val selection = summary["hasSelection"] as? Boolean
        val label = summary["selectedName"]
        val validLabel = label == null || (label is String && label.length <= 1024 &&
            runCatching { utf8Length(label) <= 1024 }.getOrDefault(false))
        if (configurations != null && configurations <= 4096 && overrides != null && overrides <= 4096 && selection != null && validLabel) {
            result["summary"] = mapOf("configurations" to configurations, "overrides" to overrides,
                "hasSelection" to selection, "selectedName" to label)
        }
    }
    for (key in listOf("settingsMessage", "scheduleMessage", "connectionMessage")) {
        AppMessage.fromMap(raw[key])?.let { result[key] = it.toMap() }
    }
    return result
}
