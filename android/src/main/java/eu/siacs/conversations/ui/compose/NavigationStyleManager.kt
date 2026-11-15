package eu.siacs.conversations.ui.compose

import android.content.Context
import androidx.preference.PreferenceManager
import eu.siacs.conversations.Conversations
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

enum class NavigationStyle(val displayName: String, val description: String) {
    BOTTOM_BAR("Вкладки снизу", "Панель навигации внизу экрана (по умолчанию)"),
    DRAWER("Боковое меню", "Шторка с профилем и разделами в стиле Telegram")
}

// NavigationStyleManager persists the user's choice of navigation UI (Bottom Bar vs Telegram Drawer)
// and exposes it as a reactive StateFlow.
object NavigationStyleManager {
    const val PREFS = "penik_navigation_prefs"
    const val KEY_STYLE = "nav_style"

    private var appContext: Context? = null
    private val _navigationStyle = MutableStateFlow(NavigationStyle.BOTTOM_BAR)
    val navigationStyle: StateFlow<NavigationStyle> = _navigationStyle.asStateFlow()

    @JvmStatic
    fun init(context: Context) {
        appContext = context.applicationContext
        val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        var styleName = prefs.getString(KEY_STYLE, null)
        if (styleName == null) {
            try {
                styleName = PreferenceManager.getDefaultSharedPreferences(context.applicationContext)
                    .getString(KEY_STYLE, null)
            } catch (_: Exception) {}
        }
        _navigationStyle.value = try {
            NavigationStyle.valueOf(styleName ?: NavigationStyle.BOTTOM_BAR.name)
        } catch (_: Exception) {
            NavigationStyle.BOTTOM_BAR
        }
    }

    @JvmStatic
    fun setStyle(style: NavigationStyle) {
        _navigationStyle.value = style
        val ctx = appContext ?: Conversations.getContext()
        ctx?.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            ?.edit()
            ?.putString(KEY_STYLE, style.name)
            ?.apply()
        try {
            if (ctx != null) {
                PreferenceManager.getDefaultSharedPreferences(ctx)
                    .edit()
                    .putString(KEY_STYLE, style.name)
                    .apply()
            }
        } catch (_: Exception) {}
    }

    @JvmStatic
    fun getStyle(context: Context? = null): NavigationStyle {
        if (appContext == null) {
            val ctx = context ?: Conversations.getContext()
            if (ctx != null) {
                init(ctx)
            }
        }
        return _navigationStyle.value
    }
}
