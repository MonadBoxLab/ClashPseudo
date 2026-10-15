package io.github.monadboxlab.clashpseudo.nativecore

import org.json.JSONObject
import java.io.File

class CoreInput(
    val id: String?,
    val revision: Int?,
    val mode: String,
    val body: ByteArray,
    val choices: ByteArray,
) {
    companion object {
        fun read(file: File, id: String, revision: Int, mode: String): CoreInput {
            val value = JSONObject(file.readText(Charsets.UTF_8))
            check(value.getString("id") == id && value.getInt("revision") == revision &&
                value.getString("mode") == mode) { "Run input identity changed" }
            return CoreInput(id, revision, mode, value.getString("body").toByteArray(Charsets.UTF_8),
                value.getJSONObject("choices").toString().toByteArray(Charsets.UTF_8))
        }
    }
}
