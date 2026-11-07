package io.github.monadboxlab.clashpseudo.nativecore

import android.content.Context
import android.os.ParcelFileDescriptor
import androidx.annotation.Keep
import io.github.monadboxlab.clashpseudo.app.AppProcess

/** Load only after verifying the :core process; the default process does not reference this object. */
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
