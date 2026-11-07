package io.github.monadboxlab.clashpseudo.message

import io.github.monadboxlab.clashpseudo.storage.AppFiles

import android.annotation.SuppressLint
import android.content.Context
import android.content.res.Configuration
import android.os.LocaleList
import io.github.monadboxlab.clashpseudo.backup.BackupFiles
import org.json.JSONObject
import java.io.File
import java.util.Locale

/** Native display projection. Business results use untranslated [AppMessage]s. */
object AppStrings {
    private data class Display(
        val context: Context,
        val locale: Locale?,
        val nightMode: Int?,
        val brand: String,
    )

    @SuppressLint("StaticFieldLeak")
    @Volatile private var display: Display? = null

    fun initialize(context: Context) {
        // Read business files after recovery opens their storage gate.
        display = Display(context.applicationContext, null, null, "cinnabar")
    }

    /** Only native presentation fields are projected; Dart still owns the saved preferences. */
    @Synchronized
    fun refresh(context: Context) {
        val storage = BackupFiles.get(context).transaction
        val before = storage.snapshot()
        if (!before.ready || before.restoring) return
        val file = File(AppFiles.configs(context), "preferences.json")
        val preferences = try {
            if (file.exists()) JSONObject(file.readText()) else JSONObject()
        } catch (_: Exception) {
            return
        }
        val locale = when (preferences.optString("language", "system")) {
            "zh" -> Locale.SIMPLIFIED_CHINESE
            "en" -> Locale.ENGLISH
            else -> null
        }
        val night = when (preferences.optString("appearance", "system")) {
            "light" -> Configuration.UI_MODE_NIGHT_NO
            "dark" -> Configuration.UI_MODE_NIGHT_YES
            else -> null
        }
        val brand = preferences.optString("brand", "cinnabar")
            .takeIf { it in setOf("cinnabar", "jade", "cobalt") } ?: "cinnabar"
        val next = Display(wrap(context.applicationContext, locale, night), locale, night, brand)
        val after = storage.snapshot()
        if (after.ready && !after.restoring && after.epoch == before.epoch) display = next
    }

    val language: String get() = display?.locale?.language ?: "system"

    @Synchronized
    fun applyLanguage(context: Context, language: String): Boolean {
        io.github.monadboxlab.clashpseudo.app.AppProcess.requireCore(context)
        require(language in setOf("system", "zh", "en")) { "Invalid notification language" }
        if (this.language == language) return false
        val locale = when (language) { "zh" -> Locale.SIMPLIFIED_CHINESE; "en" -> Locale.ENGLISH; else -> null }
        display = Display(wrap(context.applicationContext, locale, null), locale, null, "cinnabar")
        return true
    }

    fun message(id: Int, args: Map<String, Any?> = emptyMap()): AppMessage {
        val name = requireNotNull(display).context.resources.getResourceEntryName(id)
        val key = "android" + name.split('_').joinToString("") { word ->
            word.replaceFirstChar { it.uppercaseChar() }
        }
        return AppMessage(key, args.toMap())
    }

    fun get(id: Int): String = requireNotNull(display).context.getString(id)

    fun format(id: Int, vararg args: Any): String =
        requireNotNull(display).context.getString(id, *args)

    /** Preserve the host's density and font scale while applying this app's saved display choices. */
    internal fun widgetAppearance(base: Context): Pair<Context, String> {
        val current = requireNotNull(display)
        return wrap(base, current.locale, current.nightMode) to current.brand
    }

    private fun wrap(base: Context, locale: Locale?, night: Int?): Context {
        if (locale == null && night == null) return base
        val configuration = Configuration(base.resources.configuration)
        if (locale != null) configuration.setLocales(LocaleList(locale))
        if (night != null) {
            configuration.uiMode = (configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or night
        }
        return base.createConfigurationContext(configuration)
    }
}
