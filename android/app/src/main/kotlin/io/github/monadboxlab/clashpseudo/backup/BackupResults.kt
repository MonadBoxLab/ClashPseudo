package io.github.monadboxlab.clashpseudo.backup

internal fun backupInteger(value: Any?): Long? =
    if (value is Int || value is Long) (value as Number).toLong().takeIf { it >= 0 } else null

internal fun restoreStatus(committed: Any?) = when (committed) { true -> "restored"; false -> "notRestored"; else -> "unconfirmed" }

/** Keep actual feedback; display and action eligibility are derived by its consumers. */
internal fun backupProjection(value: Any?): Map<String, Any?>? =
    (value as? Map<*, *>)?.entries?.associate { (key, field) -> (key as String) to field }
