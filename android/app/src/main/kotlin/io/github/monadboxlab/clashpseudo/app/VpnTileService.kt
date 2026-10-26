package io.github.monadboxlab.clashpseudo.app

import io.github.monadboxlab.clashpseudo.bridge.AppBridge
import io.github.monadboxlab.clashpseudo.controls.SystemControls

import android.annotation.SuppressLint
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import io.github.monadboxlab.clashpseudo.R

/** The platform binds for listening passes and explicit clicks. */
class VpnTileService : TileService() {
    private var listening = false
    private var destroyed = false
    private var displaySerial = 0L
    private var displayInFlight = false
    private var displayDirty = false
    private var clickSerial = 0L

    override fun onStartListening() {
        super.onStartListening()
        listening = true
        listeningInstance = this
        readState()
    }

    override fun onStopListening() {
        listening = false
        if (listeningInstance === this) listeningInstance = null
        displaySerial++
        super.onStopListening()
    }

    override fun onTileAdded() {
        super.onTileAdded()
        SystemControls.refresh(this)
    }

    override fun onClick() {
        super.onClick()
        val click = ++clickSerial
        unlockAndRun {
            if (destroyed || click != clickSerial) return@unlockAndRun
            // A prepared start may still be STOPPED; read the admission owner's live
            // intent.
            val action = AppBridge.systemControlAction()
            if (action == null) {
                open(SystemControls.openIntent(this), 1040)
                return@unlockAndRun
            }
            SystemControls.request(this, action) { admission ->
                if (destroyed || click != clickSerial) return@request
                when (admission) {
                    SystemControls.Admission.OPEN_APP, SystemControls.Admission.VPN_SETTINGS ->
                        open(SystemControls.admissionIntent(this, action, admission),
                            if (admission == SystemControls.Admission.VPN_SETTINGS) 1041
                            else if (action == "start") 1001 else 1002)
                    else -> if (listening) readState()
                }
                SystemControls.refresh(this)
            }
        }
    }

    private fun readState() {
        val serial = ++displaySerial
        if (displayInFlight) { displayDirty = true; return }
        displayInFlight = true
        SystemControls.snapshot { value ->
            displayInFlight = false
            val again = displayDirty
            displayDirty = false
            if (destroyed || !listening) return@snapshot
            if (again) { readState(); return@snapshot }
            if (serial != displaySerial) return@snapshot
            val tile = qsTile ?: return@snapshot
            tile.label = AppStrings.get(R.string.system_control_title)
            tile.icon = Icon.createWithResource(this, R.drawable.ic_vpn_notification)
            tile.state = when {
                value.phase == "RUNNING" -> Tile.STATE_ACTIVE
                value.tileEnabled -> Tile.STATE_INACTIVE
                else -> Tile.STATE_UNAVAILABLE
            }
            val status = AppStrings.get(value.statusResource)
            val mode = SystemControls.modeText(value)
            if (Build.VERSION.SDK_INT >= 29) tile.subtitle = status
            tile.contentDescription = "${tile.label}, $status, $mode"
            tile.updateTile()
        }
    }

    // The PendingIntent overload starts at API 34; Intent is only used on API 24–33.
    @SuppressLint("StartActivityAndCollapseDeprecated")
    @Suppress("DEPRECATION")
    private fun open(intent: Intent, requestCode: Int) {
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(SystemControls.activityPendingIntent(this, intent, requestCode))
        } else {
            startActivityAndCollapse(intent)
        }
    }

    override fun onDestroy() {
        destroyed = true
        listening = false
        if (listeningInstance === this) listeningInstance = null
        displaySerial++
        clickSerial++
        super.onDestroy()
    }

    companion object {
        private var listeningInstance: VpnTileService? = null

        // Refresh the listening tile through the current event.
        internal fun refreshListening(): Boolean {
            val service = listeningInstance ?: return false
            service.readState()
            return true
        }
    }
}
