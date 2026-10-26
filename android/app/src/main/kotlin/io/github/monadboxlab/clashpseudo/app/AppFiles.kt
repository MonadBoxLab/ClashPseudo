package io.github.monadboxlab.clashpseudo.app

import android.content.Context
import java.io.File

object AppFiles {
    fun configs(context: Context) = File(context.filesDir, "configurations")
    fun runInput(context: Context, owner: String) = File(context.noBackupFilesDir, "work/run-input-$owner.json")
    // Resolve platform-owned aliases only; consumers still reject linked children.
    fun core(context: Context) = File(context.noBackupFilesDir.canonicalFile, "mihomo")
    // Always-on reads the saved system input prepared by the business engine.
    fun systemInput(context: Context) = File(context.noBackupFilesDir, "work/system-input.json")
}
