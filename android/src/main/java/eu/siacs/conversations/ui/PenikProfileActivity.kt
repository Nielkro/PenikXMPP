package eu.siacs.conversations.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.ViewCompositionStrategy
import androidx.compose.ui.res.colorResource
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import eu.siacs.conversations.R
import eu.siacs.conversations.entities.Account
import eu.siacs.conversations.entities.Conversation
import eu.siacs.conversations.ui.compose.PenikChatsListener
import eu.siacs.conversations.ui.compose.PenikChatsState
import eu.siacs.conversations.ui.compose.PenikProfileTab
import eu.siacs.conversations.ui.activity.SettingsActivity
import eu.siacs.conversations.xmpp.Jid

class PenikProfileActivity : XmppActivity() {

    private val state = PenikChatsState()
    private var accountJid: String? = null

    @OptIn(ExperimentalMaterial3Api::class)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        accountJid = intent.getStringExtra(EXTRA_ACCOUNT_JID) ?: intent.getStringExtra("jid")

        val composeView = ComposeView(this).apply {
            setViewCompositionStrategy(ViewCompositionStrategy.DisposeOnViewTreeLifecycleDestroyed)
            setContent {
                val background = colorResource(R.color.penik_background)
                val textPrimary = colorResource(R.color.penik_text_primary)
                var showEditProfileSheet by remember { mutableStateOf(false) }

                Scaffold(
                    topBar = {
                        TopAppBar(
                            title = {
                                Text(
                                    text = "Профиль",
                                    fontWeight = FontWeight.Bold,
                                    fontSize = 20.sp
                                )
                            },
                            navigationIcon = {
                                IconButton(onClick = { finish() }) {
                                    Icon(
                                        imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                                        contentDescription = "Назад",
                                        tint = textPrimary
                                    )
                                }
                            },
                            actions = {
                                IconButton(onClick = { showEditProfileSheet = true }) {
                                    Icon(
                                        painter = painterResource(R.drawable.ic_edit_24dp),
                                        contentDescription = "Редактировать профиль",
                                        tint = textPrimary
                                    )
                                }
                                IconButton(onClick = { listener.onOpenSettings() }) {
                                    Icon(
                                        imageVector = Icons.Default.Settings,
                                        contentDescription = "Настройки",
                                        tint = textPrimary
                                    )
                                }
                            },
                            colors = TopAppBarDefaults.topAppBarColors(
                                containerColor = background,
                                titleContentColor = textPrimary
                            )
                        )
                    },
                    containerColor = background
                ) { innerPadding ->
                    Box(modifier = Modifier.padding(innerPadding)) {
                        PenikProfileTab(
                            state = state,
                            activity = this@PenikProfileActivity,
                            listener = listener,
                            showEditProfile = showEditProfileSheet,
                            onOpenEditProfile = { showEditProfileSheet = true },
                            onDismissEditProfile = { showEditProfileSheet = false }
                        )
                    }
                }
            }
        }
        setContentView(composeView)
    }

    private val listener = object : PenikChatsListener {
        override fun onConversationClick(conversation: Conversation) {}
        override fun onArchiveConversation(conversation: Conversation) {}
        override fun onUnarchiveConversation(conversation: Conversation) {}
        override fun onTogglePin(conversation: Conversation) {}
        override fun onToggleMute(conversation: Conversation) {}
        override fun onDeleteConversation(conversation: Conversation, deleteForEveryone: Boolean) {}
        override fun onOpenSelfChat() {}
        override fun onOpenSettings() {
            startActivity(Intent(this@PenikProfileActivity, SettingsActivity::class.java))
        }
        override fun onNewChat() {}
        override fun onOpenPhoneContacts() {}
        override fun onCreateGroup() {}
        override fun onEditAvatar() {}
        override fun onLogout() {
            state.account?.let { acc ->
                xmppConnectionService?.deleteAccount(acc)
            }
            finish()
        }
        override fun onPublishAvatar(uri: Uri) {
            state.account?.let { acc ->
                xmppConnectionService?.publishAvatar(acc, uri, false, null)
            }
        }
    }

    override fun refreshUiReal() {
        updateAccount()
    }

    override fun onBackendConnected() {
        updateAccount()
    }

    private fun updateAccount() {
        val service = xmppConnectionService ?: return
        val acc = (if (accountJid != null) {
            try {
                service.findAccountByJid(Jid.of(accountJid))
            } catch (e: Exception) {
                null
            }
        } else null) ?: service.accounts.firstOrNull()

        state.account = acc
    }

    companion object {
        const val EXTRA_ACCOUNT_JID = "account_jid"

        @JvmStatic
        fun launch(context: Context, jid: String? = null) {
            val intent = Intent(context, PenikProfileActivity::class.java).apply {
                if (jid != null) putExtra(EXTRA_ACCOUNT_JID, jid)
            }
            context.startActivity(intent)
        }
    }
}
