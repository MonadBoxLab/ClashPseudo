package io.github.monadboxlab.clashpseudo.message

import org.json.JSONObject

/** An application-owned message; only display boundaries choose a language. */
data class AppMessage(
    val id: String,
    val args: Map<String, Any?> = emptyMap(),
    val detail: String? = null,
) {
    fun withDetail(error: Any?): AppMessage {
        val text = if (error is Throwable) error.stackTraceToString() else error?.toString()
        if (text.isNullOrEmpty() || text == detail) return this
        return copy(detail = if (detail == null) text else "$detail\n$text")
    }

    fun toMap(): Map<String, Any?> = buildMap {
        put("id", id)
        put("args", args.mapValues { (_, value) ->
            if (value is AppMessage) value.toMap() else value
        })
        if (detail != null) put("detail", detail)
    }

    companion object {
        /** Decode the shared descriptor while retaining original diagnostics. */
        fun fromMap(value: Any?): AppMessage? = try { decode(value, 0) } catch (_: IllegalArgumentException) { null }

        private fun objectValues(value: Any?): Map<*, *> = when (value) {
            is Map<*, *> -> value
            is JSONObject -> value.keys().asSequence().associateWith {
                value.opt(it).takeUnless { field -> field === JSONObject.NULL }
            }
            else -> throw IllegalArgumentException("Invalid application message object")
        }

        private fun decode(value: Any?, depth: Int): AppMessage {
            require(depth <= 4)
            val fields = objectValues(value)
            val id = fields["id"]
            val args = objectValues(fields["args"])
            val detail = fields["detail"]
            require(id is String && id.isNotEmpty())
            require(detail == null || detail is String)
            val decoded = args.entries.associate { (name, argument) ->
                require(name is String)
                name to when (argument) {
                    is Map<*, *>, is JSONObject -> decode(argument, depth + 1)
                    is String, is Int, is Long, is Boolean -> argument
                    else -> throw IllegalArgumentException("Invalid message argument")
                }
            }
            return AppMessage(id, decoded, detail as String?)
        }
    }
}
