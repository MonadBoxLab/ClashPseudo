package io.github.monadboxlab.clashpseudo.app

import android.app.Application
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngineGroup
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService

class PseudoApplication : Application() {
    val engines by lazy { FlutterEngineGroup(this) }

    override fun onCreate() {
        super.onCreate()
        AppBridge.initialize(this)
        val main = Handler(Looper.getMainLooper())
        PseudoVpnService.session.changed = { main.post { AppBridge.nativeChanged() } }
    }
}
