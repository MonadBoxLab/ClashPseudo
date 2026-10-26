package io.github.monadboxlab.clashpseudo.app

/** An application-owned message; only display boundaries choose a language. */
data class AppMessage(val id: String, val args: Map<String, Any?> = emptyMap()) {
    fun toMap(): Map<String, Any?> = mapOf("id" to id, "args" to args.mapValues { (_, value) ->
        if (value is AppMessage) value.toMap() else value
    })

    companion object {
        /** Reject malformed engine results rather than displaying raw diagnostics. */
        fun fromMap(value: Any?): AppMessage? = try { decode(value, 0) } catch (_: IllegalArgumentException) { null }

        private fun decode(value: Any?, depth: Int): AppMessage {
            require(depth <= 4 && value is Map<*, *>)
            val id = value["id"]
            val args = value["args"]
            require(id is String && id.isNotEmpty() && args is Map<*, *>)
            val decoded = args.entries.associate { (name, argument) ->
                require(name is String)
                name to when (argument) {
                    is Map<*, *> -> decode(argument, depth + 1)
                    is String, is Int, is Long, is Boolean -> argument
                    else -> throw IllegalArgumentException("Invalid message argument")
                }
            }
            return AppMessage(id, decoded)
        }
    }
}
