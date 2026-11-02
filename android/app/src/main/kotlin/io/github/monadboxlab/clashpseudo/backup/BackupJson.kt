package io.github.monadboxlab.clashpseudo.backup

import android.util.JsonReader
import android.util.JsonToken
import java.io.Reader

/** Read the saved fallback without decoding or rewriting unrelated fields. */
internal fun savedMode(source: Reader, modes: Set<String>): String? = JsonReader(source).use { reader ->
    reader.isLenient = false
    var found = false
    var mode: String? = null
    reader.beginObject()
    while (reader.hasNext()) {
        if (reader.nextName() != "mode") { reader.skipValue(); continue }
        check(!found) { "Duplicate saved mode" }
        found = true
        if (reader.peek() == JsonToken.NULL) reader.nextNull()
        else {
            check(reader.peek() == JsonToken.STRING) { "Saved mode must be a string or null" }
            mode = reader.nextString()
            check(mode in modes) { "Unknown saved mode: $mode" }
        }
    }
    reader.endObject()
    check(found && reader.peek() == JsonToken.END_DOCUMENT) { "Missing mode or trailing JSON content" }
    mode
}
