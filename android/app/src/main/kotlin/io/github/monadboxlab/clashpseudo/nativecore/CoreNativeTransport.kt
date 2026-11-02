package io.github.monadboxlab.clashpseudo.nativecore

import android.content.Context
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.concurrent.ExecutionException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Future

internal class CoreNativeCallException(val receipt: ByteArray, cause: Throwable) :
    java.io.IOException("native invoke 已返回，FD 结果传输失败", cause)

internal class CoreNativeResultException(val result: CoreNativeTransport.Result, val error: JSONObject) :
    java.io.IOException(error.optString("message", error.toString()))

/** JNI 仅 detach 自有 FD 副本；Kotlin 在返回前等待本次 FD I/O 实际结束。 */
internal class CoreNativeTransport(private val context: Context, private val io: ExecutorService) {
    data class Result(val value: JSONObject, val terminal: JSONObject, val receipt: ByteArray)
    private val admission = Object()
    private var closing = false
    private var sealed = false
    private var active = 0
    val idle: Boolean get() = synchronized(admission) { active == 0 }
    fun sealIfIdle(): Boolean = synchronized(admission) {
        if (active != 0) false else { sealed = true; true }
    }
    fun document(bytes: ByteArray): ParcelFileDescriptor {
        begin(Contract.CORE_OPERATION_SHUTDOWN)
        val pipe = try { ParcelFileDescriptor.createReliablePipe() } catch (error: Throwable) { ended(); throw error }
        try {
            io.execute {
                var failure: Throwable? = null
                try { CoreDocuments.write(ParcelFileDescriptor.AutoCloseOutputStream(pipe[1]), bytes) }
                catch (error: Throwable) {
                    failure = error
                    try { pipe[1].closeWithError(CoreErrors.json(error).toString()) }
                    catch (close: Throwable) { failure = combine(failure, close) }
                } finally {
                    failure = close(pipe[1], failure)
                    failure?.let { android.util.Log.e("PseudoCore", "FD document 写入失败", it) }
                    ended()
                }
            }
        } catch (error: Throwable) {
            close(pipe[0], error); close(pipe[1], error); ended(); throw error
        }
        return pipe[0]
    }
    fun closeAdmission() = synchronized(admission) { closing = true }
    fun awaitIdle(deadline: Long) {
        var interrupted = false
        try {
            synchronized(admission) {
                while (active > 0) {
                    val left = deadline - SystemClock.elapsedRealtime()
                    if (left <= 0) return
                    try { admission.wait(left) } catch (_: InterruptedException) { interrupted = true }
                }
            }
        } finally { if (interrupted) Thread.currentThread().interrupt() }
    }
    private fun begin(operation: Int) = synchronized(admission) {
        check(!sealed && (!closing || operation == Contract.CORE_OPERATION_SHUTDOWN)) { "core native admission 已关闭" }
        active++
    }
    private fun ended() = synchronized(admission) { active--; admission.notifyAll() }
    private inline fun <T> tracked(operation: Int, block: () -> T): T {
        begin(operation)
        try { return block() } finally { ended() }
    }

    fun stream(operation: Int, requestId: Long, parts: Map<String, ByteArray>, output: ParcelFileDescriptor,
               tun: ParcelFileDescriptor?, callbacks: Any): ByteArray =
        tracked(operation) { streamCall(operation, requestId, parts, output, tun, callbacks) }

    private fun streamCall(operation: Int, requestId: Long, parts: Map<String, ByteArray>, output: ParcelFileDescriptor,
               tun: ParcelFileDescriptor?, callbacks: Any): ByteArray {
        NativeCore.load(context)
        val input = ParcelFileDescriptor.createPipe()
        val write = try {
            io.submit<Unit> { ParcelFileDescriptor.AutoCloseOutputStream(input[1]).use { CoreParts.write(it, parts) } }
        } catch (error: Throwable) {
            close(input[0], error); close(input[1], error)
            throw error
        }
        var receipt: ByteArray? = null
        var failure: Throwable? = null
        try {
            ParcelFileDescriptor.dup(input[0].fileDescriptor).use { nativeInput ->
                ParcelFileDescriptor.dup(output.fileDescriptor).use { nativeOutput ->
                    tun?.let { ParcelFileDescriptor.dup(it.fileDescriptor) }.use { nativeTun ->
                        receipt = NativeCore.invoke(operation, requestId, nativeInput, nativeOutput, nativeTun, callbacks)
                    }
                }
            }
        } catch (error: Throwable) { failure = error }
        finally {
            // Go 已返回，关闭 Kotlin reader，避免未读输入让 writer 永久停在 backpressure。
            failure = close(input[0], failure)
            if (failure != null) failure = close(input[1], failure)
            try { await(write) } catch (error: Throwable) { failure = combine(failure, error) }
        }
        failure?.let { throw receipt?.let { value -> CoreNativeCallException(value, it) } ?: it }
        return checkNotNull(receipt)
    }

    fun result(operation: Int, requestId: Long, parts: Map<String, ByteArray>, tun: ParcelFileDescriptor?, callbacks: Any): Result =
        tracked(operation) { resultCall(operation, requestId, parts, tun, callbacks) }

    private fun resultCall(operation: Int, requestId: Long, parts: Map<String, ByteArray>, tun: ParcelFileDescriptor?, callbacks: Any): Result {
        val output = ParcelFileDescriptor.createPipe()
        val read = try {
            io.submit<Pair<JSONObject, JSONObject>> {
                ParcelFileDescriptor.AutoCloseInputStream(output[0]).use { input ->
                    val reader = CoreFrames.Reader(input)
                    val value = ByteArrayOutputStream()
                    while (true) {
                        val frame = reader.read()
                        when (frame.kind) {
                            Contract.CORE_IPC_FRAME_DATA -> {
                                if (value.size().toLong() + frame.payload.size > Contract.CORE_IPC_FRAME_BYTES) {
                                    throw CoreTransportException(Contract.CORE_ERROR_RESULT_TOO_LARGE, "内核资源装载结果超过预算")
                                }
                                value.write(frame.payload)
                            }
                            Contract.CORE_IPC_FRAME_TERMINAL -> {
                                val terminal = JSONObject(CoreFrames.utf8(frame.payload))
                                val data = value.toByteArray()
                                return@submit (if (data.isEmpty()) JSONObject() else JSONObject(CoreFrames.utf8(data))) to terminal
                            }
                            else -> throw CoreTransportException(Contract.CORE_ERROR_TRANSPORT_INTERRUPTED, "平台资源调用返回了集合记录")
                        }
                    }
                    @Suppress("UNREACHABLE_CODE") error("没有内核资源终态")
                }
            }
        } catch (error: Throwable) {
            close(output[0], error); close(output[1], error)
            throw error
        }
        var receipt: ByteArray? = null
        var failure: Throwable? = null
        var result: Pair<JSONObject, JSONObject>? = null
        try { output[1].use { receipt = stream(operation, requestId, parts, it, tun, callbacks) } }
        catch (error: Throwable) {
            failure = error
            failure = close(output[0], failure)
        } finally {
            failure = close(output[1], failure)
            try { result = await(read) } catch (error: Throwable) { failure = combine(failure, error) }
        }
        failure?.let { throw receipt?.let { value -> CoreNativeCallException(value, it) } ?: it }
        return Result(checkNotNull(result).first, result!!.second, checkNotNull(receipt))
    }

    private fun <T> await(future: Future<T>): T {
        var interrupted = false
        try {
            while (true) {
                try { return future.get() }
                catch (_: InterruptedException) { interrupted = true }
                catch (error: ExecutionException) { throw error.cause ?: error }
            }
        } finally { if (interrupted) Thread.currentThread().interrupt() }
    }
    private fun combine(first: Throwable?, next: Throwable): Throwable = first?.also { if (it !== next) it.addSuppressed(next) } ?: next
    private fun close(fd: ParcelFileDescriptor, first: Throwable?): Throwable? =
        try { fd.close(); first } catch (error: Throwable) { combine(first, error) }
}
