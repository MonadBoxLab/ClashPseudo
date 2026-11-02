package io.github.monadboxlab.clashpseudo.nativecore.input

import io.github.monadboxlab.clashpseudo.app.ApplicationContract
import android.util.JsonWriter
import org.json.JSONObject
import org.json.JSONArray
import java.io.BufferedWriter
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.OutputStreamWriter
import java.nio.charset.CodingErrorAction

class CoreInput(
    val id: String?,
    val revision: Int?,
    val mode: String?,
    val body: ByteArray,
    val choices: ByteArray,
    val overrides: ByteArray = "[]".toByteArray(Charsets.UTF_8),
    val composition: String = JSONArray().put(id).put(revision).toString(),
    val access: String = "all",
    val packages: List<String> = emptyList(),
    val source: String? = null,
    val routingOverride: String? = null,
    val name: String = "",
) {
    /** Private in-memory snapshot of actual running input. */
    fun snapshotBytes(): ByteArray = JSONObject()
        .put("id", id).put("revision", revision).put("name", name).put("mode", mode ?: JSONObject.NULL)
        .put("routingOverride", routingOverride ?: JSONObject.NULL)
        .put("source", source ?: JSONObject.NULL)
        .put("body", body.toString(Charsets.UTF_8))
        .put("choices", JSONObject(choices.toString(Charsets.UTF_8)))
        .put("overrides", JSONArray(overrides.toString(Charsets.UTF_8)))
        .put("composition", composition).put("access", access)
        .put("packages", JSONArray(packages))
        .toString().toByteArray(Charsets.UTF_8)

    internal fun preparationOptions(purpose: String, generation: Long, network: JSONObject): ByteArray {
        val output = object : ByteArrayOutputStream() {
            private fun admit(length: Int) {
                check(size().toLong() + length <= MAX_PREPARATION_OPTIONS_BYTES) {
                    "Native preparation options exceed UTF-8 JSON limit"
                }
            }
            override fun write(value: Int) { admit(1); super.write(value) }
            override fun write(bytes: ByteArray, offset: Int, length: Int) {
                admit(length)
                super.write(bytes, offset, length)
            }
        }
        val utf8 = Charsets.UTF_8.newEncoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        JsonWriter(BufferedWriter(OutputStreamWriter(output, utf8))).use { writer ->
            writer.beginObject().name("purpose").value(purpose).name("generation").value(generation)
                .name("composition").value(composition).name("routingOverride").value(routingOverride ?: "")
                .name("mainOrigin").beginObject().name("id").value(id)
                .name("revision").value(revision).name("name").value(name).endObject().name("network")
            writeJson(writer, network)
            writer.endObject()
        }
        return output.toByteArray()
    }

    private fun writeJson(writer: JsonWriter, value: Any?) {
        when (value) {
            null, JSONObject.NULL -> writer.nullValue()
            is JSONObject -> {
                writer.beginObject()
                for (key in value.keys()) {
                    writer.name(key)
                    writeJson(writer, value.get(key))
                }
                writer.endObject()
            }
            is JSONArray -> {
                writer.beginArray()
                for (index in 0 until value.length()) writeJson(writer, value.get(index))
                writer.endArray()
            }
            is String -> writer.value(value)
            is Number -> writer.value(value)
            is Boolean -> writer.value(value)
            else -> error("Unsupported preparation option value")
        }
    }

    companion object {
        internal const val MAX_PREPARATION_OPTIONS_BYTES = ApplicationContract.CONFIGURATION_PREPARATION_OPTIONS_BYTES

        internal fun integerRevision(value: Any?): Int {
            val revision = when (value) {
                is Int -> value.toLong()
                is Long -> value
                else -> error("Invalid revision")
            }
            check(revision in 1L..ApplicationContract.CONFIGURATION_REVISION_MAX.toLong()) { "Invalid revision" }
            return revision.toInt()
        }

        fun read(file: File, id: String, revision: Int, mode: String?): CoreInput =
            read(JSONObject(file.readText(Charsets.UTF_8)), id, revision, mode)

        private fun utf8(value: String): ByteArray {
            val encoded = Charsets.UTF_8.newEncoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).encode(java.nio.CharBuffer.wrap(value))
            return ByteArray(encoded.remaining()).also { encoded.get(it) }
        }

        fun read(value: JSONObject, id: String, revision: Int, mode: String?): CoreInput {
            check(value.has("mode")) { "Missing mode fallback" }
            val savedMode = if (value.isNull("mode")) null else value.getString("mode")
            check(savedMode == null || savedMode in setOf("rule", "global", "direct")) { "Invalid mode fallback" }
            val routingOverride = if (value.isNull("routingOverride")) null else value.getString("routingOverride")
            check(routingOverride == null || routingOverride in setOf("rule", "global", "direct")) { "Invalid routing override" }
            check(value.getString("id") == id && integerRevision(value.get("revision")) == revision &&
                savedMode == mode) { "Run input identity changed" }
            val name = value.get("name")
            check(name is String && name.isNotBlank()) { "Missing loaded configuration name" }
            val fragments = value.getJSONArray("overrides")
            val identity = JSONArray().put(id).put(revision)
            val ids = mutableSetOf<String>()
            var textBytes = 0L
            for (index in 0 until fragments.length()) {
                val part = fragments.getJSONObject(index)
                val partId = part.getString("id")
                val partRevision = integerRevision(part.get("revision"))
                val partMode = part.getString("mode")
                val partName = part.get("name")
                check(partName is String && partName.isNotBlank() && part.has("role")) { "Missing loaded plugin source metadata" }
                if (!part.isNull("role")) check(part.get("role") in setOf("localCustom", "lanProxy")) { "Invalid plugin role" }
                check(partId.isNotEmpty() && ids.add(partId) && partRevision > 0 &&
                    partMode in setOf("prepend", "replace")) { "Invalid override identity" }
                textBytes += utf8(part.getString("body")).size
                check(textBytes <= ApplicationContract.CONFIGURATION_TEXT_BYTES) { "Override text exceeds limit" }
                identity.put(JSONArray().put(partId).put(partRevision).put(partMode))
            }
            val composition = value.getString("composition")
            check(JSONArray(composition).toString() == identity.toString()) { "Run composition changed" }
            val accessValue = value.get("access")
            check(accessValue is String && accessValue in setOf("all", "only", "except")) {
                "Invalid application access"
            }
            val access = accessValue
            val list = value.getJSONArray("packages")
            val packages = mutableListOf<String>()
            for (index in 0 until list.length()) {
                val name = list.get(index)
                check(name is String) { "Invalid application list" }
                packages.add(name)
            }
            check(packages.all { it.isNotBlank() && it == it.trim() } &&
                packages.toSet().size == packages.size) { "Invalid application list" }
            check(access != "only" || packages.isNotEmpty()) { "Application allow list is empty" }
            val body = utf8(value.getString("body"))
            check(body.size <= ApplicationContract.CONFIGURATION_TEXT_BYTES) { "Configuration text exceeds limit" }
            val fragmentBytes = utf8(fragments.toString())
            check(fragmentBytes.size <= ApplicationContract.CONFIGURATION_OVERRIDE_JSON_BYTES) { "Override JSON exceeds UTF-8 limit" }
            return CoreInput(id, revision, mode, body,
                utf8(value.getJSONObject("choices").toString()),
                fragmentBytes, composition, access, packages,
                if (value.isNull("source")) null else value.getString("source"), routingOverride, name)
        }
    }
}
