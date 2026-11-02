package io.github.monadboxlab.clashpseudo.message

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AppMessageJsonTest {
    @Test
    fun jsonDescriptionsUseTheSameCodecWithoutFilteringFieldsOrReasons() {
        val original = "https://user:pass@fixture.test/?token=原文🙂\nAuthorization: Bearer fixture"
        val message = AppMessage("nativeConfigurationUnsupported", mapOf(
            "field" to "future.field", "reason" to AppMessage("futureReason", mapOf("value" to original)),
            "count" to 2L, "enabled" to false), detail = original)
        val json = JSONObject(message.toMap())
        assertEquals(message, AppMessage.fromMap(json))
        assertNull(AppMessage.fromMap(JSONObject().put("id", "missing-args")))
        assertNull(AppMessage.fromMap(JSONObject().put("id", "bad-detail")
            .put("args", JSONObject()).put("detail", 1)))
    }
}
