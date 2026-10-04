package eu.siacs.conversations.ui

import android.content.Intent
import android.content.pm.ActivityInfo
import android.net.Uri
import android.os.Bundle
import android.util.Log
import android.widget.Toast
import androidx.activity.compose.setContent
import androidx.appcompat.app.AppCompatActivity
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import eu.siacs.conversations.Config
import eu.siacs.conversations.R
import eu.siacs.conversations.entities.Account
import eu.siacs.conversations.services.XmppConnectionService
import eu.siacs.conversations.ui.compose.PenikAuthListener
import eu.siacs.conversations.ui.compose.PenikAuthMode
import eu.siacs.conversations.ui.compose.PenikAuthScreen
import eu.siacs.conversations.ui.compose.PenikAuthState
import eu.siacs.conversations.utils.InstallReferrerUtils
import eu.siacs.conversations.xmpp.Jid

class WelcomeActivity : QrCodeProcessingActivity(),
    PenikAuthListener,
    XmppConnectionService.OnAccountCreated,
    XmppConnectionService.OnAccountUpdate {

    private var authState by mutableStateOf(PenikAuthState())
    private var currentTargetAccountJid by mutableStateOf<Jid?>(null)
    private var isRegistering by mutableStateOf(false)
    private var pendingDisplayName by mutableStateOf<String?>(null)
    private var pendingAvatarUri by mutableStateOf<Uri?>(null)

    companion object {
        const val EXTRA_DOMAIN = "domain"
        const val EXTRA_PRE_AUTH = "pre_auth"
        const val EXTRA_USERNAME = "username"
        private const val REQUEST_IMPORT_BACKUP = 0x63fb

        @JvmStatic
        fun launch(activity: AppCompatActivity) {
            val intent = Intent(activity, WelcomeActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
            }
            activity.startActivity(intent)
            activity.overridePendingTransition(0, 0)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        if (resources.getBoolean(R.bool.portrait_only)) {
            requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        }
        super.onCreate(savedInstanceState)
        Activities.setStatusAndNavigationBarColors(this, window.decorView)

        parseIntent(intent)

        setContent {
            PenikAuthScreen(
                state = authState,
                listener = this
            )
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        parseIntent(intent)
    }

    private fun parseIntent(intent: Intent) {
        var domain = intent.getStringExtra(EXTRA_DOMAIN)
        var preAuth = intent.getStringExtra(EXTRA_PRE_AUTH)
        var username = intent.getStringExtra(EXTRA_USERNAME)

        val data = intent.data
        if (data != null) {
            val path = data.path
            if (path != null && path.contains("/invite/")) {
                val parts = path.split("/")
                for (i in parts.indices) {
                    if (parts[i] == "invite" && i + 1 < parts.size && parts[i + 1].isNotEmpty()) {
                        preAuth = parts[i + 1]
                        break
                    }
                }
                if (domain == null && !data.host.isNullOrBlank()) {
                    domain = data.host
                }
            }
        }

        if (domain != null || preAuth != null || username != null) {
            authState = authState.copy(
                initialMode = PenikAuthMode.REGISTER,
                initialNickname = username ?: "",
                inviteDomain = domain,
                preAuthToken = preAuth
            )
        }
    }

    override fun onStart() {
        super.onStart()
        InstallReferrerUtils(this)
    }

    fun onInstallReferrerDiscovered(referrer: Uri) {
        Log.d(Config.LOGTAG, "welcome activity: on install referrer discovered $referrer")
    }

    override fun refreshUiReal() {
        if (currentTargetAccountJid == null) {
            if (checkAlreadyLoggedIn()) return
        }
        checkAccountStatus()
    }

    override fun onBackendConnected() {
        if (currentTargetAccountJid == null) {
            if (checkAlreadyLoggedIn()) return
        }
        checkAccountStatus()
    }

    private fun checkAlreadyLoggedIn(): Boolean {
        if (isRegistering || authState.isLoading) {
            return false
        }
        val service = xmppConnectionService ?: return false
        val accounts = service.accounts
        if (accounts != null && accounts.any { it.isEnabled && (it.isOnlineAndConnected || it.isOptionSet(Account.OPTION_LOGGED_IN_SUCCESSFULLY)) }) {
            Toast.makeText(this, "Вы уже вошли в аккаунт. Регистрация не требуется.", Toast.LENGTH_LONG).show()
            val intent = Intent(this, ConversationsActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
            }
            startActivity(intent)
            finish()
            return true
        }
        return false
    }

    override fun onAccountUpdate() {
        refreshUi()
    }

    private fun checkAccountStatus() {
        val targetJid = currentTargetAccountJid ?: return
        val service = xmppConnectionService ?: return
        val account = service.findAccountByJid(targetJid) ?: return

        when (account.status) {
            Account.State.ONLINE, Account.State.REGISTRATION_SUCCESSFUL -> {
                if (isRegistering) {
                    account.setOption(Account.OPTION_LOGGED_IN_SUCCESSFULLY, true)
                    account.setOption(Account.OPTION_REGISTER, false)
                    service.updateAccount(account)
                    val disp = pendingDisplayName
                    if (!disp.isNullOrBlank()) {
                        account.displayName = disp
                        service.publishDisplayName(account)
                    }
                    val avUri = pendingAvatarUri
                    if (avUri != null) {
                        service.publishAvatar(account, avUri, false, null)
                    }
                } else {
                    account.setOption(Account.OPTION_LOGGED_IN_SUCCESSFULLY, true)
                    service.updateAccount(account)
                }
                authState = authState.copy(isLoading = false, error = null)
                val intent = Intent(this, ConversationsActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
                }
                startActivity(intent)
                finish()
            }
            Account.State.REGISTRATION_CONFLICT -> {
                authState = authState.copy(
                    isLoading = false,
                    error = "Этот никнейм уже занят. Пожалуйста, выберите другой."
                )
                service.deleteAccount(account)
                currentTargetAccountJid = null
            }
            Account.State.UNAUTHORIZED -> {
                authState = authState.copy(
                    isLoading = false,
                    error = "Неверный никнейм или пароль."
                )
            }
            Account.State.REGISTRATION_PASSWORD_TOO_WEAK -> {
                authState = authState.copy(
                    isLoading = false,
                    error = "Пароль слишком простой. Придумайте более сложный пароль."
                )
                service.deleteAccount(account)
                currentTargetAccountJid = null
            }
            Account.State.REGISTRATION_FAILED, Account.State.REGISTRATION_NOT_SUPPORTED -> {
                authState = authState.copy(
                    isLoading = false,
                    error = "Не удалось зарегистрировать аккаунт на сервере."
                )
                service.deleteAccount(account)
                currentTargetAccountJid = null
            }
            Account.State.SERVER_NOT_FOUND, Account.State.NO_INTERNET, Account.State.CONNECTION_TIMEOUT -> {
                authState = authState.copy(
                    isLoading = false,
                    error = "Не удалось подключиться к серверу. Проверьте интернет."
                )
            }
            else -> {
                // Connecting or progressing
            }
        }
    }

    override fun onRegister(nickname: String, password: String, displayName: String, avatarUri: Uri?) {
        val service = xmppConnectionService
        if (service == null) {
            authState = authState.copy(error = "Сервис инициализируется, подождите...")
            return
        }
        val domain = authState.inviteDomain ?: Config.MAGIC_CREATE_DOMAIN ?: "snikket.penik.ru"
        val jid: Jid
        try {
            jid = Jid.ofLocalAndDomain(nickname.trim().lowercase(), domain)
        } catch (e: Exception) {
            authState = authState.copy(error = "Недопустимый никнейм")
            return
        }

        authState = authState.copy(isLoading = true, error = null)
        isRegistering = true
        val resolvedName = displayName.ifBlank { nickname }
        pendingDisplayName = resolvedName
        pendingAvatarUri = avatarUri
        currentTargetAccountJid = jid

        var account = service.findAccountByJid(jid)
        if (account == null) {
            account = Account(jid, password)
            account.setOption(Account.OPTION_REGISTER, true)
            account.setOption(Account.OPTION_MAGIC_CREATE, true)
            val token = authState.preAuthToken
            if (!token.isNullOrBlank()) {
                account.setPreAuthRegistrationToken(token)
            }
            if (resolvedName.isNotBlank()) {
                account.displayName = resolvedName
            }
            service.createAccount(account)
        } else {
            account.password = password
            account.setOption(Account.OPTION_REGISTER, true)
            account.setOption(Account.OPTION_DISABLED, false)
            val token = authState.preAuthToken
            if (!token.isNullOrBlank()) {
                account.setPreAuthRegistrationToken(token)
            }
            if (resolvedName.isNotBlank()) {
                account.displayName = resolvedName
            }
            service.updateAccount(account)
        }
    }

    override fun onLogin(usernameOrJid: String, password: String) {
        val service = xmppConnectionService
        if (service == null) {
            authState = authState.copy(error = "Сервис инициализируется, подождите...")
            return
        }

        val domain = Config.MAGIC_CREATE_DOMAIN ?: "snikket.penik.ru"
        val raw = usernameOrJid.trim().lowercase()
        val jid: Jid
        try {
            jid = if (raw.contains("@")) Jid.of(raw) else Jid.ofLocalAndDomain(raw, domain)
        } catch (e: Exception) {
            authState = authState.copy(error = "Недопустимый никнейм или JID")
            return
        }

        authState = authState.copy(isLoading = true, error = null)
        isRegistering = false
        currentTargetAccountJid = jid

        var account = service.findAccountByJid(jid)
        if (account == null) {
            account = Account(jid, password)
            account.setOption(Account.OPTION_REGISTER, false)
            service.createAccount(account)
        } else {
            account.password = password
            account.setOption(Account.OPTION_REGISTER, false)
            account.setOption(Account.OPTION_DISABLED, false)
            service.updateAccount(account)
        }
    }

    override fun onImportBackup() {
        if (hasStoragePermission(REQUEST_IMPORT_BACKUP)) {
            startActivity(Intent(this, ImportBackupActivity::class.java))
        }
    }

    override fun onAccountCreated(account: Account?) {
        refreshUiReal()
    }

    override fun informUser(r: Int) {
        runOnUiThread { Toast.makeText(this, r, Toast.LENGTH_LONG).show() }
    }
}
