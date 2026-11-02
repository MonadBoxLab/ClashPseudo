package io.github.monadboxlab.clashpseudo.nativecore

import android.os.Binder
import android.os.Bundle
import android.os.Parcel
import android.os.Process
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import org.json.JSONArray
import org.json.JSONObject
import java.util.Collections
import java.util.IdentityHashMap

internal object CoreControl {
    fun sameUid() {
        if (Binder.getCallingUid() != Process.myUid()) {
            throw SecurityException(Contract.CORE_ERROR_PERMISSION_DENIED)
        }
    }

    fun check(bundle: Bundle) {
        val parcel = Parcel.obtain()
        try {
            parcel.writeBundle(bundle)
            if (parcel.dataSize() > Contract.CORE_IPC_CONTROL_BYTES) {
                throw CoreTransportException(Contract.CORE_ERROR_INPUT_TOO_LARGE, "内核控制事务超过预算")
            }
        } finally { parcel.recycle() }
    }

    fun identity(bundle: Bundle, processId: String) {
        check(bundle)
        if (bundle.getInt(Contract.CORE_FIELD_PROTOCOL, -1) != Contract.CORE_IPC_VERSION) {
            throw CoreTransportException(Contract.CORE_ERROR_PROTOCOL_MISMATCH, "内核协议版本不一致")
        }
        if (bundle.getString(Contract.CORE_FIELD_PROCESS_ID) != processId) {
            throw CoreTransportException(Contract.CORE_ERROR_IDENTITY_MISMATCH, "请求属于其他内核进程")
        }
        listOf(Contract.CORE_FIELD_PROCESS_ID, Contract.CORE_FIELD_INPUT_ID).forEach { key ->
            if ((bundle.getString(key)?.toByteArray(Charsets.UTF_8)?.size ?: 0) > Contract.CORE_IPC_IDENTITY_BYTES) {
                throw CoreTransportException(Contract.CORE_ERROR_IDENTITY_MISMATCH, "内核请求身份超过预算")
            }
        }
        if (bundle.getLong(Contract.CORE_FIELD_REQUEST_ID, 0) < 0 ||
            bundle.getLong(Contract.CORE_FIELD_GENERATION, 0) < 0 ||
            bundle.getLong(Contract.CORE_FIELD_NETWORK_REVISION, 0) < 0) {
            throw CoreTransportException(Contract.CORE_ERROR_IDENTITY_MISMATCH, "内核请求身份包含负数")
        }
    }
}

internal class NativePreparationFailure(val detail: io.github.monadboxlab.clashpseudo.message.AppMessage) :
    IllegalArgumentException(detail.id)

internal object CoreErrors {
    fun json(error: Throwable, code: String = when (error) {
        is CoreTransportException -> error.code
        is CoreNativeResultException -> error.error.optString("code", Contract.CORE_ERROR_CALL_FAILED)
        else -> Contract.CORE_ERROR_CALL_FAILED
    }): JSONObject {
        val seen = Collections.newSetFromMap(IdentityHashMap<Throwable, Boolean>())
        fun cause(value: Throwable): JSONObject {
            if (!seen.add(value)) return JSONObject().put("type", value.javaClass.name).put("message", value.message).put("cycle", true)
            return JSONObject().put("type", value.javaClass.name).put("message", value.message ?: JSONObject.NULL)
                .put("stack", value.stackTraceToString())
                .put("cause", value.cause?.let(::cause) ?: JSONObject.NULL)
                .put("suppressed", JSONArray(value.suppressed.map(::cause)))
                .apply {
                    if (value is CoreNativeResultException) {
                        put("nativeError", value.error)
                        put("nativeReceipt", JSONObject(CoreFrames.utf8(value.result.receipt)))
                        put("nativeTerminal", value.result.terminal)
                        put("nativeValue", value.result.value)
                    }
                    if (value is CoreNativeCallException) {
                        try { put("nativeReceipt", JSONObject(CoreFrames.utf8(value.receipt))) }
                        catch (decode: Throwable) {
                            put("nativeReceiptError", cause(decode))
                            put("nativeReceiptBytes", android.util.Base64.encodeToString(value.receipt, android.util.Base64.NO_WRAP))
                        }
                    }
                }
        }
        return cause(error).put("code", code)
    }

    fun receipt(error: Throwable): ByteArray = JSONObject().put(Contract.CORE_FIELD_ERROR, json(error))
        .put(Contract.CORE_FIELD_EXITED, true).toString().toByteArray(Charsets.UTF_8)
}

internal fun JSONObject.bundle(): Bundle = Bundle().also { target ->
    keys().forEach { key -> when (val value = get(key)) {
        JSONObject.NULL -> Unit
        is String -> target.putString(key, value)
        is Boolean -> target.putBoolean(key, value)
        is Int -> target.putInt(key, value)
        is Long -> target.putLong(key, value)
        is Double -> target.putDouble(key, value)
        else -> target.putString(key, value.toString())
    } }
}

internal fun Bundle.map(): Map<String, Any?> = keySet().associateWith { key -> get(key) }

/** 每个 core process 共用一个 allocator，达到上限后拒绝新请求。 */
internal class CoreRequestIds(initial: Long = 0) {
    private val value = java.util.concurrent.atomic.AtomicLong(initial.also { require(it >= 0) })
    fun next(): Long {
        while (true) {
            val previous = value.get()
            check(previous < Long.MAX_VALUE) { "core requestId 已耗尽" }
            if (value.compareAndSet(previous, previous + 1)) return previous + 1
        }
    }
}

internal fun JSONObject.objectMap(): Map<String, Any?> = keys().asSequence().associateWith { jsonValue(get(it)) }
private fun jsonValue(value: Any?): Any? = when (value) {
    null, JSONObject.NULL -> null
    is JSONObject -> value.objectMap()
    is JSONArray -> (0 until value.length()).map { jsonValue(value.get(it)) }
    else -> value
}
