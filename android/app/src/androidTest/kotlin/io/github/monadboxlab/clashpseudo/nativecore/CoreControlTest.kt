package io.github.monadboxlab.clashpseudo.nativecore

import android.os.Bundle
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException

class CoreControlTest {
    private fun identity() = Bundle().apply {
        putInt(Contract.CORE_FIELD_PROTOCOL, Contract.CORE_IPC_VERSION)
        putString(Contract.CORE_FIELD_PROCESS_ID, "process-原文")
        putString(Contract.CORE_FIELD_INPUT_ID, "input-原文")
        putLong(Contract.CORE_FIELD_GENERATION, 1)
        putLong(Contract.CORE_FIELD_REQUEST_ID, 1)
        putLong(Contract.CORE_FIELD_NETWORK_REVISION, 1)
    }
    private fun rejected(expectedCode: String, block: () -> Unit) {
        try { block(); fail("无效控制事务必须拒绝") }
        catch (error: CoreTransportException) { assertEquals(expectedCode, error.code) }
    }

    @Test fun protocolAndRandomProcessIdentityMustMatch() {
        CoreControl.identity(identity(), "process-原文")
        rejected(Contract.CORE_ERROR_PROTOCOL_MISMATCH) {
            CoreControl.identity(identity().apply { putInt(Contract.CORE_FIELD_PROTOCOL, 2) }, "process-原文")
        }
        rejected(Contract.CORE_ERROR_IDENTITY_MISMATCH) { CoreControl.identity(identity(), "another-process") }
    }

    @Test fun identitiesUseUtf8BytesAndRejectNegativeCounters() {
        rejected(Contract.CORE_ERROR_IDENTITY_MISMATCH) {
            CoreControl.identity(identity().apply { putString(Contract.CORE_FIELD_INPUT_ID, "字".repeat(86)) }, "process-原文")
        }
        for (key in listOf(Contract.CORE_FIELD_REQUEST_ID, Contract.CORE_FIELD_GENERATION, Contract.CORE_FIELD_NETWORK_REVISION)) {
            rejected(Contract.CORE_ERROR_IDENTITY_MISMATCH) { CoreControl.identity(identity().apply { putLong(key, -1) }, "process-原文") }
        }
    }

    @Test fun largeControlBodiesAreRejectedBeforeDispatch() {
        rejected(Contract.CORE_ERROR_INPUT_TOO_LARGE) {
            CoreControl.check(identity().apply { putByteArray("body", ByteArray(Contract.CORE_IPC_CONTROL_BYTES)) })
        }
    }

    @Test fun nativePreparationErrorsKeepOriginalFieldsReceiptTerminalAndValue() {
        val original = "https://user:pass@fixture.test/?token=原文🙂"
        val error = JSONObject().put("code", "futureCode").put("message", original)
            .put("future", JSONObject().put("raw", original))
        val receipt = JSONObject().put("error", error).put("exited", true)
            .put("cancelError", JSONObject().put("message", "取消 Close 错误"))
        val terminal = JSONObject().put("complete", false).put("error", error)
        val value = JSONObject().put("futureValue", original)
        val result = CoreNativeTransport.Result(value, terminal, receipt.toString().toByteArray())
        val encoded = CoreErrors.json(CoreNativeResultException(result, error))
        assertEquals("futureCode", encoded.getString("code"))
        assertEquals(original, encoded.getString("message"))
        assertEquals(error.toString(), encoded.getJSONObject("nativeError").toString())
        assertEquals(receipt.toString(), encoded.getJSONObject("nativeReceipt").toString())
        assertEquals(terminal.toString(), encoded.getJSONObject("nativeTerminal").toString())
        assertEquals(value.toString(), encoded.getJSONObject("nativeValue").toString())
    }

    @Test fun originalErrorsKeepTheirCauseSuppressedAndNativeReceipt() {
        val original = IOException("原始错误完整内容", IOException("原始 cause"))
        original.addSuppressed(IOException("原始 suppressed"))
        val receipt = JSONObject().put("exited", true).put("cancelError", JSONObject().put("message", "取消 Close 错误"))
        val failure = CoreNativeCallException(receipt.toString().toByteArray(), original)
        val result = CoreErrors.json(failure)
        assertEquals("原始错误完整内容", result.getJSONObject("cause").getString("message"))
        assertEquals("原始 cause", result.getJSONObject("cause").getJSONObject("cause").getString("message"))
        assertEquals("原始 suppressed", result.getJSONObject("cause").getJSONArray("suppressed").getJSONObject(0).getString("message"))
        assertEquals("取消 Close 错误", result.getJSONObject("nativeReceipt").getJSONObject("cancelError").getString("message"))
    }
}
