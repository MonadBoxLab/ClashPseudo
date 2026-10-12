package io.github.monadboxlab.clashpseudo.app

import android.content.Context
import java.io.File

object AppFiles {
    fun configs(context: Context) = File(context.filesDir, "configurations")
    fun runInput(context: Context) = File(context.noBackupFilesDir, "work/run-input.yaml")
    fun core(context: Context) = File(context.noBackupFilesDir, "mihomo")
}
