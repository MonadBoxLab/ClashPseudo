package io.github.monadboxlab.clashpseudo.nativecore

import android.content.Context
import android.os.ParcelFileDescriptor
import androidx.annotation.Keep
import io.github.monadboxlab.clashpseudo.app.AppProcess

/** 只在 :core 完成进程校验后加载；默认进程不引用此对象。 */
@Keep
object NativeCore {
    @Volatile private var loaded = false
    internal val isLoaded: Boolean get() = loaded

    @Synchronized fun load(context: Context) {
        AppProcess.requireCore(context)
        if (loaded) return
        System.loadLibrary("mihomo_bridge")
        loaded = true
    }

    @Keep
    @JvmStatic external fun invoke(
        operation: Int,
        requestId: Long,
        input: ParcelFileDescriptor,
        output: ParcelFileDescriptor,
        tun: ParcelFileDescriptor?,
        callbacks: Any,
    ): ByteArray
}
