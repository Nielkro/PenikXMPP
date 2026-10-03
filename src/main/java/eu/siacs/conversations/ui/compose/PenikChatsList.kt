package eu.siacs.conversations.ui.compose

import android.graphics.Bitmap
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.BottomSheetDefaults
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.colorResource
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import eu.siacs.conversations.R
import eu.siacs.conversations.entities.Account
import eu.siacs.conversations.entities.Conversation
import eu.siacs.conversations.entities.Conversational
import eu.siacs.conversations.entities.Message
import eu.siacs.conversations.entities.RtpSessionStatus
import eu.siacs.conversations.services.AvatarService
import eu.siacs.conversations.ui.XmppActivity
import eu.siacs.conversations.utils.JidHelper
import eu.siacs.conversations.utils.UIHelper
import java.time.Instant
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

interface PenikChatsListener {
    fun onConversationClick(conversation: Conversation)
    fun onArchiveConversation(conversation: Conversation)
    fun onUnarchiveConversation(conversation: Conversation)
    fun onOpenSelfChat()
    fun onOpenSettings()
    fun onNewChat()
    fun onEditAvatar()
    fun onLogout()
    fun onPublishAvatar(uri: android.net.Uri)
}

class PenikChatsState {
    var conversations by mutableStateOf<List<Conversation>>(emptyList())
    var archived by mutableStateOf<List<Conversation>>(emptyList())
    var connectionState by mutableStateOf(PenikConnectionState.OFFLINE)
    var selfChat by mutableStateOf<Conversation?>(null)
    var account by mutableStateOf<Account?>(null)
}

enum class PenikConnectionState {
    ONLINE,
    CONNECTING,
    OFFLINE
}

object PenikChatsBridge {
    @JvmStatic
    fun render(
            view: ComposeView,
            state: PenikChatsState,
            activity: XmppActivity,
            listener: PenikChatsListener
    ) {
        view.setContent {
            PenikMainScreen(state = state, activity = activity, listener = listener)
        }
    }
}

private enum class PenikTab {
    CHATS,
    CALLS,
    PROFILE
}

fun penikInitialsColor(name: String): Color {
    if (name.contains("Избранное")) {
        return Color(0xFF5FA8DF)
    }
    val hash = name.fold(0L) { acc, ch -> acc + ch.code } % 360
    return Color.hsl(kotlin.math.abs(hash).toFloat(), 0.55f, 0.50f)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PenikMainScreen(
        state: PenikChatsState,
        activity: XmppActivity,
        listener: PenikChatsListener
) {
    val background = colorResource(R.color.penik_background)
    val panel = colorResource(R.color.penik_panel)
    val textPrimary = colorResource(R.color.penik_text_primary)
    val textMuted = colorResource(R.color.penik_text_muted)
    val accent = colorResource(R.color.penik_accent)
    var tab by remember { mutableStateOf(PenikTab.CHATS) }
    var searchQuery by remember { mutableStateOf("") }
    var isSearchActive by remember { mutableStateOf(false) }
    var isArchiveOpen by remember { mutableStateOf(false) }
    val focusRequester = remember { FocusRequester() }
    LaunchedEffect(isSearchActive) {
        if (isSearchActive) {
            focusRequester.requestFocus()
        }
    }
    Scaffold(
            containerColor = background,
            topBar = {
                if (tab == PenikTab.CHATS) {
                    TopAppBar(
                            title = {
                                if (isSearchActive) {
                                    OutlinedTextField(
                                            value = searchQuery,
                                            onValueChange = { searchQuery = it },
                                            modifier =
                                                    Modifier.fillMaxWidth()
                                                            .focusRequester(focusRequester),
                                            placeholder = {
                                                Text("Поиск...", color = textMuted)
                                            },
                                            singleLine = true,
                                            colors =
                                                    OutlinedTextFieldDefaults.colors(
                                                            focusedContainerColor =
                                                                    colorResource(
                                                                            R.color
                                                                                    .penik_input_bg
                                                                    ),
                                                            unfocusedContainerColor =
                                                                    colorResource(
                                                                            R.color
                                                                                    .penik_input_bg
                                                                    ),
                                                            focusedBorderColor =
                                                                    colorResource(
                                                                            R.color.penik_border
                                                                    ),
                                                            unfocusedBorderColor =
                                                                    colorResource(
                                                                            R.color.penik_border
                                                                    ),
                                                            focusedTextColor = textPrimary,
                                                            unfocusedTextColor = textPrimary
                                                    )
                                    )
                                } else if (isArchiveOpen) {
                                    Text(
                                            text = "Архив чатов",
                                            fontWeight = FontWeight.Bold,
                                            fontSize = 20.sp
                                    )
                                } else {
                                    Text(
                                            text = "Penik",
                                            fontWeight = FontWeight.Bold,
                                            fontSize = 22.sp
                                    )
                                }
                            },
                            navigationIcon = {
                                if (isSearchActive) {
                                    IconButton(
                                            onClick = {
                                                isSearchActive = false
                                                searchQuery = ""
                                            }
                                    ) {
                                        Icon(
                                                Icons.AutoMirrored.Filled.ArrowBack,
                                                contentDescription = "Закрыть поиск",
                                                tint = textPrimary
                                        )
                                    }
                                } else if (isArchiveOpen) {
                                    IconButton(onClick = { isArchiveOpen = false }) {
                                        Icon(
                                                Icons.AutoMirrored.Filled.ArrowBack,
                                                contentDescription = "Назад",
                                                tint = textPrimary
                                        )
                                    }
                                }
                            },
                            actions = {
                                if (!isSearchActive && !isArchiveOpen) {
                                    IconButton(onClick = { isSearchActive = true }) {
                                        Icon(
                                                Icons.Default.Search,
                                                contentDescription = "Поиск",
                                                tint = textPrimary
                                        )
                                    }
                                    IconButton(onClick = { listener.onOpenSettings() }) {
                                        Icon(
                                                Icons.Default.Settings,
                                                contentDescription = "Настройки",
                                                tint = textPrimary
                                        )
                                    }
                                }
                            },
                            colors =
                                    TopAppBarDefaults.topAppBarColors(
                                            containerColor = background,
                                            titleContentColor = textPrimary
                                    )
                    )
                }
            },
            bottomBar = {
                NavigationBar(containerColor = panel) {
                    NavigationBarItem(
                            selected = tab == PenikTab.CHATS,
                            onClick = { tab = PenikTab.CHATS },
                            icon = {
                                Icon(
                                        painter = painterResource(R.drawable.ic_chat_24dp),
                                        contentDescription = "Чаты"
                                )
                            },
                            label = { Text("Чаты") },
                            colors =
                                    NavigationBarItemDefaults.colors(
                                            selectedIconColor = accent,
                                            selectedTextColor = accent,
                                            unselectedIconColor = textMuted,
                                            unselectedTextColor = textMuted,
                                            indicatorColor = accent.copy(alpha = 0.15f)
                                    )
                    )
                    NavigationBarItem(
                            selected = tab == PenikTab.CALLS,
                            onClick = { tab = PenikTab.CALLS },
                            icon = {
                                Icon(
                                        painter = painterResource(R.drawable.ic_phone_24dp),
                                        contentDescription = "Звонки"
                                )
                            },
                            label = { Text("Звонки") },
                            colors =
                                    NavigationBarItemDefaults.colors(
                                            selectedIconColor = accent,
                                            selectedTextColor = accent,
                                            unselectedIconColor = textMuted,
                                            unselectedTextColor = textMuted,
                                            indicatorColor = accent.copy(alpha = 0.15f)
                                    )
                    )
                    NavigationBarItem(
                            selected = tab == PenikTab.PROFILE,
                            onClick = { tab = PenikTab.PROFILE },
                            icon = {
                                Icon(
                                        painter = painterResource(R.drawable.ic_person_24dp),
                                        contentDescription = "Профиль"
                                )
                            },
                            label = { Text("Профиль") },
                            colors =
                                    NavigationBarItemDefaults.colors(
                                            selectedIconColor = accent,
                                            selectedTextColor = accent,
                                            unselectedIconColor = textMuted,
                                            unselectedTextColor = textMuted,
                                            indicatorColor = accent.copy(alpha = 0.15f)
                                    )
                    )
                }
            },
            floatingActionButton = {
                if (tab == PenikTab.CHATS && !isArchiveOpen) {
                    FloatingActionButton(
                            onClick = { listener.onNewChat() },
                            containerColor = accent,
                            contentColor = Color.White
                    ) {
                        Icon(Icons.Default.Add, contentDescription = "Новый чат")
                    }
                }
            }
    ) { padding ->
        Box(modifier = Modifier.fillMaxSize().padding(padding)) {
            when (tab) {
                PenikTab.CHATS ->
                        PenikChatsTab(
                                state = state,
                                activity = activity,
                                listener = listener,
                                searchQuery = searchQuery,
                                isArchiveOpen = isArchiveOpen,
                                onOpenArchive = { isArchiveOpen = true }
                        )
                PenikTab.CALLS -> PenikCallsTab(state = state, activity = activity, listener = listener)
                PenikTab.PROFILE ->
                        PenikProfileTab(
                                state = state,
                                activity = activity,
                                listener = listener
                        )
            }
            if (state.connectionState != PenikConnectionState.ONLINE) {
                Box(modifier = Modifier.align(Alignment.TopCenter)) {
                    ConnectionBanner(state = state.connectionState)
                }
            }
        }
    }
}

@Composable
fun ConnectionBanner(state: PenikConnectionState) {
    val warning = colorResource(R.color.penik_warning)
    val danger = colorResource(R.color.penik_danger)
    var dots by remember(state) { mutableStateOf(0) }
    LaunchedEffect(state) {
        if (state == PenikConnectionState.CONNECTING) {
            while (true) {
                kotlinx.coroutines.delay(400)
                dots = (dots + 1) % 4
            }
        }
    }
    val isConnecting = state == PenikConnectionState.CONNECTING
    val color = if (isConnecting) warning else danger
    val text = if (isConnecting) "Подключение" + ".".repeat(dots) else "Нет соединения"
    Box(
            modifier = Modifier.fillMaxWidth().background(color.copy(alpha = 0.15f)).padding(vertical = 6.dp),
            contentAlignment = Alignment.Center
    ) {
        Text(text = text, color = color, fontSize = 13.sp)
    }
}

@Composable
fun PenikChatsTab(
        state: PenikChatsState,
        activity: XmppActivity,
        listener: PenikChatsListener,
        searchQuery: String,
        isArchiveOpen: Boolean,
        onOpenArchive: () -> Unit
) {
    val background = colorResource(R.color.penik_background)
    val border = colorResource(R.color.penik_border)
    val textMuted = colorResource(R.color.penik_text_muted)
    var pendingArchive by remember { mutableStateOf<Conversation?>(null) }
    var pendingUnarchive by remember { mutableStateOf<Conversation?>(null) }
    val feed =
            if (isArchiveOpen) {
                state.archived
            } else {
                state.conversations
            }
    val filtered =
            if (searchQuery.isBlank()) {
                feed
            } else {
                feed.filter {
                    it.name.contains(searchQuery, ignoreCase = true) ||
                            it.latestMessage?.body?.contains(searchQuery, ignoreCase = true) ==
                                    true
                }
            }
    Column(modifier = Modifier.fillMaxSize().background(background)) {
        if (isArchiveOpen) {
            if (filtered.isEmpty()) {
                Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text(text = "Архив пуст", color = textMuted, fontSize = 16.sp)
                }
            } else {
                LazyColumn(modifier = Modifier.fillMaxSize()) {
                    items(filtered, key = { it.uuid }) { conversation ->
                        PenikConversationRow(
                                conversation = conversation,
                                activity = activity,
                                onClick = { listener.onConversationClick(conversation) },
                                onLongClick = { pendingUnarchive = conversation }
                        )
                    }
                }
            }
        } else {
            LazyColumn(modifier = Modifier.fillMaxSize()) {
                item(key = "self_chat") {
                    PenikSelfRow(
                            selfChat = state.selfChat,
                            activity = activity,
                            onClick = { listener.onOpenSelfChat() }
                    )
                    HorizontalDivider(color = border, modifier = Modifier.padding(horizontal = 16.dp))
                }
                if (state.archived.isNotEmpty() && searchQuery.isBlank()) {
                    item(key = "archive_folder") {
                        PenikArchiveRow(
                                count = state.archived.size,
                                onClick = onOpenArchive
                        )
                        HorizontalDivider(
                                color = border,
                                modifier = Modifier.padding(horizontal = 16.dp)
                        )
                    }
                }
                if (filtered.isEmpty()) {
                    item(key = "empty_placeholder") {
                        Box(
                                modifier = Modifier.fillMaxWidth().padding(vertical = 48.dp),
                                contentAlignment = Alignment.Center
                        ) {
                            Text(
                                    text = "Нет переписок",
                                    color = textMuted,
                                    fontSize = 16.sp
                            )
                        }
                    }
                } else {
                    items(filtered, key = { it.uuid }) { conversation ->
                        PenikConversationRow(
                                conversation = conversation,
                                activity = activity,
                                onClick = { listener.onConversationClick(conversation) },
                                onLongClick = { pendingArchive = conversation }
                        )
                    }
                }
            }
        }
    }
    val toArchive = pendingArchive
    if (toArchive != null) {
        PenikConfirmDialog(
                title = toArchive.name.toString(),
                text = "Переместить в архив?",
                confirm = "В архив",
                onConfirm = {
                    listener.onArchiveConversation(toArchive)
                    pendingArchive = null
                },
                onDismiss = { pendingArchive = null }
        )
    }
    val toUnarchive = pendingUnarchive
    if (toUnarchive != null) {
        PenikConfirmDialog(
                title = toUnarchive.name.toString(),
                text = "Вернуть из архива на главный экран?",
                confirm = "Извлечь",
                onConfirm = {
                    listener.onUnarchiveConversation(toUnarchive)
                    pendingUnarchive = null
                },
                onDismiss = { pendingUnarchive = null }
        )
    }
}

@Composable
fun PenikConfirmDialog(
        title: String,
        text: String,
        confirm: String,
        onConfirm: () -> Unit,
        onDismiss: () -> Unit
) {
    val panel = colorResource(R.color.penik_panel)
    val textPrimary = colorResource(R.color.penik_text_primary)
    val textMuted = colorResource(R.color.penik_text_muted)
    val accent = colorResource(R.color.penik_accent)
    AlertDialog(
            onDismissRequest = onDismiss,
            title = { Text(text = title, color = textPrimary, fontWeight = FontWeight.Bold) },
            text = { Text(text = text, color = textMuted) },
            confirmButton = {
                TextButton(onClick = onConfirm) { Text(text = confirm, color = accent) }
            },
            dismissButton = {
                TextButton(onClick = onDismiss) { Text(text = "Отмена", color = textMuted) }
            },
            containerColor = panel,
            shape = RoundedCornerShape(16.dp)
    )
}

@Composable
fun PenikSelfRow(selfChat: Conversation?, activity: XmppActivity, onClick: () -> Unit) {
    val context = LocalContext.current
    val textPrimary = colorResource(R.color.penik_text_primary)
    val textMuted = colorResource(R.color.penik_text_muted)
    val latest = selfChat?.latestMessage
    Row(
            modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
                modifier = Modifier.size(48.dp).clip(CircleShape).background(Color(0xFF5FA8DF)),
                contentAlignment = Alignment.Center
        ) {
            Icon(
                    imageVector = Icons.Default.Bookmark,
                    contentDescription = null,
                    tint = Color.White,
                    modifier = Modifier.size(26.dp)
            )
        }
        Spacer(modifier = Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                    text = "Избранное",
                    color = penikInitialsColor("Избранное"),
                    fontWeight = FontWeight.Medium,
                    fontSize = 16.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
            )
            if (latest != null) {
                Spacer(modifier = Modifier.height(2.dp))
                Text(
                        text = UIHelper.getMessagePreview(context, latest).first.toString(),
                        color = textMuted,
                        fontSize = 14.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                )
            }
        }
        if (latest != null && latest.timeSent > 0) {
            Spacer(modifier = Modifier.width(8.dp))
            Text(
                    text = UIHelper.readableTimeDifference(activity, latest.timeSent),
                    color = textMuted,
                    fontSize = 12.sp
            )
        }
    }
}

@Composable
fun PenikArchiveRow(count: Int, onClick: () -> Unit) {
    val panelSecondary = colorResource(R.color.penik_panel_secondary)
    val textPrimary = colorResource(R.color.penik_text_primary)
    val textMuted = colorResource(R.color.penik_text_muted)
    val accent = colorResource(R.color.penik_accent)
    val chatWord =
            if (count % 10 == 1 && count % 100 != 11) {
                "чат"
            } else if (count % 10 in 2..4 && (count % 100 !in 12..14)) {
                "чата"
            } else {
                "чатов"
            }
    Row(
            modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
                modifier = Modifier.size(48.dp).clip(CircleShape).background(panelSecondary),
                contentAlignment = Alignment.Center
        ) {
            Text("📁", fontSize = 22.sp)
        }
        Spacer(modifier = Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                    text = "Архив чатов",
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 16.sp,
                    color = textPrimary
            )
            Text(text = "$count $chatWord", fontSize = 13.sp, color = textMuted)
        }
        Box(
                modifier = Modifier.background(accent.copy(alpha = 0.2f), RoundedCornerShape(12.dp)).padding(horizontal = 8.dp, vertical = 4.dp)
        ) {
            Text(
                    text = "$count",
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Bold,
                    color = accent
            )
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun PenikConversationRow(
        conversation: Conversation,
        activity: XmppActivity,
        onClick: () -> Unit,
        onLongClick: () -> Unit
) {
    val context = LocalContext.current
    val textPrimary = colorResource(R.color.penik_text_primary)
    val textMuted = colorResource(R.color.penik_text_muted)
    val accent = colorResource(R.color.penik_accent)
    val latest = conversation.latestMessage
    val draft = if (conversation.isRead) conversation.draft else null
    val timestamp =
            if (draft != null) {
                draft.instant().toEpochMilli()
            } else {
                latest?.timeSent ?: 0L
            }
    val previewText =
            if (draft != null) {
                "Черновик: ${draft.message()}"
            } else if (latest != null) {
                val preview = UIHelper.getMessagePreview(context, latest).first.toString()
                val sender =
                        if (latest.status == Message.STATUS_RECEIVED &&
                                        conversation.mode == Conversational.MODE_MULTI
                        ) {
                            UIHelper.getMessageDisplayName(latest).split("\\s+".toRegex())
                                    .firstOrNull()
                                    ?.plus(": ")
                                    ?: ""
                        } else if (latest.status != Message.STATUS_RECEIVED &&
                                        latest.type != Message.TYPE_STATUS
                        ) {
                            "Вы: "
                        } else {
                            ""
                        }
                sender + preview
            } else {
                ""
            }
    val unreadCount = conversation.unreadCount()
    val isMuted =
            conversation.mutedTill?.let { it == Instant.MAX || it.isAfter(Instant.now()) }
                    ?: false
    val isEncrypted = conversation.nextEncryption != Message.ENCRYPTION_NONE
    val avatarBitmap = penikAvatarBitmap(conversation, activity)
    Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically
    ) {
        PenikAvatarImage(
                name = conversation.name.toString(),
                bitmap = avatarBitmap
        )
        Spacer(modifier = Modifier.width(12.dp))
        Row(
                modifier =
                        Modifier.weight(1f)
                                .combinedClickable(onClick = onClick, onLongClick = onLongClick),
                verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                        text = conversation.name.toString(),
                        color = if (avatarBitmap != null) textPrimary else penikInitialsColor(conversation.name.toString()),
                        fontWeight = if (conversation.isRead) FontWeight.Medium else FontWeight.Bold,
                        fontSize = 16.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                )
                if (previewText.isNotEmpty()) {
                    Spacer(modifier = Modifier.height(2.dp))
                    Text(
                            text = previewText,
                            color = textMuted,
                            fontSize = 14.sp,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                    )
                }
            }
            if (timestamp > 0 || unreadCount > 0) {
                Spacer(modifier = Modifier.width(8.dp))
                Column(
                        horizontalAlignment = Alignment.End,
                        verticalArrangement = Arrangement.Center
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        if (isMuted) {
                            Icon(
                                    painter = painterResource(R.drawable.ic_notifications_off_24dp),
                                    contentDescription = null,
                                    tint = textMuted,
                                    modifier = Modifier.size(14.dp)
                            )
                            Spacer(modifier = Modifier.width(4.dp))
                        }
                        if (isEncrypted) {
                            Icon(
                                    imageVector = Icons.Default.Lock,
                                    contentDescription = null,
                                    tint = textMuted,
                                    modifier = Modifier.size(12.dp)
                            )
                            Spacer(modifier = Modifier.width(4.dp))
                        }
                        if (timestamp > 0) {
                            Text(
                                    text = UIHelper.readableTimeDifference(context, timestamp),
                                    color = textMuted,
                                    fontSize = 12.sp
                            )
                        }
                    }
                    if (unreadCount > 0) {
                        Spacer(modifier = Modifier.height(4.dp))
                        Box(
                                modifier =
                                        Modifier.size(22.dp)
                                                .clip(CircleShape)
                                                .background(accent),
                                contentAlignment = Alignment.Center
                        ) {
                            Text(
                                    text = if (unreadCount > 99) "99+" else unreadCount.toString(),
                                    color = Color.White,
                                    fontSize = 11.sp,
                                    fontWeight = FontWeight.Bold
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun penikAvatarBitmap(conversation: Conversation, activity: XmppActivity): Bitmap? {
    val density = LocalDensity.current
    val avatarService = activity.avatarService()
    var bitmap by remember(conversation.uuid) { mutableStateOf<Bitmap?>(null) }
    LaunchedEffect(conversation.uuid) {
        if (avatarService == null) {
            return@LaunchedEffect
        }
        val sizePx = with(density) { 48.dp.roundToPx() }
        bitmap =
                withContext(Dispatchers.IO) {
                    try {
                        avatarService.get(conversation, sizePx, false)
                    } catch (e: Exception) {
                        null
                    }
                }
    }
    return bitmap
}

@Composable
fun PenikAvatarImage(name: String, bitmap: Bitmap?) {
    if (bitmap != null) {
        androidx.compose.foundation.Image(
                bitmap = bitmap.asImageBitmap(),
                contentDescription = null,
                modifier = Modifier.size(48.dp).clip(CircleShape)
        )
    } else {
        val panelSecondary = colorResource(R.color.penik_panel_secondary)
        val tint = if (name.isEmpty()) panelSecondary else penikInitialsColor(name)
        val initial = name.firstOrNull()?.uppercase() ?: "?"
        Box(
                modifier = Modifier.size(48.dp).clip(CircleShape).background(tint),
                contentAlignment = Alignment.Center
        ) {
            Text(
                    text = initial,
                    color = Color.White,
                    fontSize = 20.sp,
                    fontWeight = FontWeight.SemiBold
            )
        }
    }
}

data class PenikCallEntry(val conversation: Conversation, val message: Message)

fun penikAbsoluteTime(context: android.content.Context, millis: Long): String {
    if (millis <= 0) {
        return ""
    }
    val zone = java.time.ZoneId.systemDefault()
    val date = java.time.Instant.ofEpochMilli(millis).atZone(zone).toLocalDate()
    val today = java.time.LocalDate.now(zone)
    return if (date == today) {
        android.text.format.DateFormat.getTimeFormat(context).format(java.util.Date(millis))
    } else {
        val fmt =
                if (date.year == today.year) {
                    java.time.format.DateTimeFormatter.ofPattern("d MMM")
                } else {
                    java.time.format.DateTimeFormatter.ofPattern("d MMM yyyy")
                }
        date.format(fmt)
    }
}

fun penikCallDuration(rawDuration: Long, timeSentMs: Long): String {
    if (rawDuration <= 0) {
        return ""
    }
    val seconds =
            if (timeSentMs < RTP_SECONDS_CUTOFF_MS) {
                rawDuration / 1000
            } else {
                rawDuration
            }
    if (seconds <= 0 || seconds > 7 * 24 * 3600) {
        return ""
    }
    val h = seconds / 3600
    val m = (seconds % 3600) / 60
    val s = seconds % 60
    return when {
        h > 0 -> "$h ч" + (if (m > 0) " $m мин" else "")
        m > 0 -> "$m мин" + (if (s > 0) " $s сек" else "")
        else -> "$s сек"
    }
}

private const val RTP_SECONDS_CUTOFF_MS = 1791010127000L

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PenikCallsTab(
        state: PenikChatsState,
        activity: XmppActivity,
        listener: PenikChatsListener
) {
    val background = colorResource(R.color.penik_background)
    val border = colorResource(R.color.penik_border)
    val textMuted = colorResource(R.color.penik_text_muted)
    var calls by remember { mutableStateOf<List<PenikCallEntry>>(emptyList()) }
    var loaded by remember { mutableStateOf(false) }
    LaunchedEffect(state.conversations, state.archived) {
        val all = state.conversations + state.archived
        val service = activity.xmppConnectionService
        if (service == null) {
            loaded = true
            return@LaunchedEffect
        }
        val result =
                withContext(Dispatchers.IO) {
                    val found = ArrayList<PenikCallEntry>()
                    for (conversation in all) {
                        try {
                            val messages = service.databaseBackend.getMessages(conversation, 40)
                            for (message in messages) {
                                if (message.type == Message.TYPE_RTP_SESSION) {
                                    found.add(PenikCallEntry(conversation, message))
                                }
                            }
                        } catch (e: Exception) {
                            // ignore per-conversation failures
                        }
                    }
                    found.sortedByDescending { it.message.timeSent }.take(60)
                }
        calls = result
        loaded = true
    }
    Column(modifier = Modifier.fillMaxSize().background(background)) {
        TopAppBar(
                title = {
                    Text(
                            text = "Звонки",
                            fontWeight = FontWeight.Bold,
                            fontSize = 22.sp
                    )
                },
                colors =
                        TopAppBarDefaults.topAppBarColors(
                                containerColor = background,
                                titleContentColor = colorResource(R.color.penik_text_primary)
                        )
        )
        if (!loaded) {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(text = "Загрузка...", color = textMuted, fontSize = 16.sp)
            }
        } else if (calls.isEmpty()) {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(text = "Звонков пока нет", color = textMuted, fontSize = 16.sp)
            }
        } else {
            LazyColumn(modifier = Modifier.fillMaxSize()) {
                items(calls, key = { it.message.uuid }) { entry ->
                    PenikCallRow(
                            entry = entry,
                            activity = activity,
                            onClick = { listener.onConversationClick(entry.conversation) }
                    )
                    HorizontalDivider(color = border, modifier = Modifier.padding(horizontal = 16.dp))
                }
            }
        }
    }
}

@Composable
fun PenikCallRow(entry: PenikCallEntry, activity: XmppActivity, onClick: () -> Unit) {
    val context = LocalContext.current
    val textPrimary = colorResource(R.color.penik_text_primary)
    val textMuted = colorResource(R.color.penik_text_muted)
    val danger = colorResource(R.color.penik_danger)
    val conversation = entry.conversation
    val message = entry.message
    val received = message.status == Message.STATUS_RECEIVED
    val status = RtpSessionStatus.of(message.body)
    val missed = !status.successful
    val avatarBitmap = penikAvatarBitmap(conversation, activity)
    val durationText =
            if (status.successful) {
                penikCallDuration(status.duration, message.timeSent)
            } else {
                ""
            }
    val statusTitle =
            if (received) {
                if (status.successful) {
                    context.getString(R.string.incoming_call) +
                            (if (durationText.isNotEmpty()) " ($durationText)" else "")
                } else {
                    context.getString(R.string.missed_call)
                }
            } else {
                context.getString(R.string.outgoing_call) +
                        (if (durationText.isNotEmpty()) " ($durationText)" else "")
            }
    Row(
            modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically
    ) {
        PenikAvatarImage(name = conversation.name.toString(), bitmap = avatarBitmap)
        Spacer(modifier = Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                    text = conversation.name.toString(),
                    color = if (missed) danger else textPrimary,
                    fontWeight = FontWeight.Medium,
                    fontSize = 16.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
            )
            Spacer(modifier = Modifier.height(2.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                        painter =
                                painterResource(
                                        RtpSessionStatus.getDrawable(received, status.successful)
                                ),
                        contentDescription = null,
                        tint = if (missed) danger else textMuted,
                        modifier = Modifier.size(16.dp)
                )
                Spacer(modifier = Modifier.width(6.dp))
                val timeText = penikAbsoluteTime(context, message.timeSent)
                Text(
                        text = "$statusTitle · $timeText",
                        color = if (missed) danger else textMuted,
                        fontSize = 14.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PenikProfileTab(state: PenikChatsState, activity: XmppActivity, listener: PenikChatsListener) {
    val background = colorResource(R.color.penik_background)
    val panel = colorResource(R.color.penik_panel)
    val textPrimary = colorResource(R.color.penik_text_primary)
    val textMuted = colorResource(R.color.penik_text_muted)
    val accent = colorResource(R.color.penik_accent)
    val danger = colorResource(R.color.penik_danger)
    val context = LocalContext.current
    val account = state.account
    var showAvatarOptions by remember { mutableStateOf(false) }
    var tempCameraUri by remember { mutableStateOf<android.net.Uri?>(null) }
    val galleryLauncher =
            rememberLauncherForActivityResult(
                    androidx.activity.result.contract.ActivityResultContracts.GetContent()
            ) { uri ->
                if (uri != null) {
                    listener.onPublishAvatar(uri)
                }
            }
    val permissionLauncher =
            rememberLauncherForActivityResult(
                    androidx.activity.result.contract.ActivityResultContracts.RequestPermission()
            ) { granted ->
                if (granted) {
                    launchPenikCamera(context) { tempCameraUri = it }
                            ?.let { galleryLauncher.launch("") }
                }
            }
    val cameraLauncher =
            rememberLauncherForActivityResult(
                    androidx.activity.result.contract.ActivityResultContracts.TakePicture()
            ) { success ->
                val uri = tempCameraUri
                if (success && uri != null) {
                    listener.onPublishAvatar(uri)
                }
            }
    Column(
            modifier =
                    Modifier.fillMaxSize().background(background).padding(horizontal = 24.dp)
                            .padding(bottom = 16.dp),
            horizontalAlignment = Alignment.CenterHorizontally
    ) {
        if (account == null) {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(text = "Нет аккаунта", color = textMuted, fontSize = 16.sp)
            }
            return@Column
        }
        val density = LocalDensity.current
        val avatarService = activity.avatarService()
        var bitmap by remember(account.uuid) { mutableStateOf<Bitmap?>(null) }
        LaunchedEffect(account.uuid) {
            if (avatarService == null) {
                return@LaunchedEffect
            }
            val sizePx = with(density) { 96.dp.roundToPx() }
            bitmap =
                    withContext(Dispatchers.IO) {
                        try {
                            avatarService.get(account, sizePx, false)
                        } catch (e: Exception) {
                            null
                        }
                    }
        }
        Spacer(modifier = Modifier.height(40.dp))
        Box(modifier = Modifier.size(104.dp), contentAlignment = Alignment.Center) {
            val loaded = bitmap
            Box(
                    modifier =
                            Modifier.size(96.dp)
                                    .clip(CircleShape)
                                    .clickable { showAvatarOptions = true },
                    contentAlignment = Alignment.Center
            ) {
                if (loaded != null) {
                    androidx.compose.foundation.Image(
                            bitmap = loaded.asImageBitmap(),
                            contentDescription = null,
                            modifier = Modifier.fillMaxSize()
                    )
                } else {
                    val local = JidHelper.displayAddress(account.jid.asBareJid())
                    Box(
                            modifier =
                                    Modifier.fillMaxSize()
                                            .background(penikInitialsColor(local)),
                            contentAlignment = Alignment.Center
                    ) {
                        Text(
                                text = local.firstOrNull()?.uppercase() ?: "?",
                                color = Color.White,
                                fontSize = 40.sp,
                                fontWeight = FontWeight.SemiBold
                        )
                    }
                }
            }
            Box(
                    modifier =
                            Modifier.align(Alignment.BottomEnd)
                                    .size(34.dp)
                                    .clip(CircleShape)
                                    .background(accent)
                                    .clickable { showAvatarOptions = true },
                    contentAlignment = Alignment.Center
            ) {
                Icon(
                        painter = painterResource(R.drawable.ic_camera_alt_24dp),
                        contentDescription = "Сменить аватар",
                        tint = Color.White,
                        modifier = Modifier.size(18.dp)
                )
            }
        }
        Spacer(modifier = Modifier.height(20.dp))
        val local = JidHelper.displayAddress(account.jid.asBareJid())
        if (local.isNotBlank()) {
            Text(
                    text = local,
                    color = textPrimary,
                    fontSize = 20.sp,
                    fontWeight = FontWeight.SemiBold
            )
        }
        Spacer(modifier = Modifier.weight(1f))
        androidx.compose.material3.Button(
                onClick = { listener.onLogout() },
                modifier = Modifier.fillMaxWidth().height(52.dp),
                shape = RoundedCornerShape(14.dp),
                colors =
                        androidx.compose.material3.ButtonDefaults.buttonColors(
                                containerColor = danger.copy(alpha = 0.15f)
                        )
        ) {
            Text(
                    text = "Выйти",
                    color = danger,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Medium
            )
        }
    }
    if (showAvatarOptions) {
        ModalBottomSheet(
                onDismissRequest = { showAvatarOptions = false },
                containerColor = panel,
                dragHandle = { BottomSheetDefaults.DragHandle() }
        ) {
            Column(
                    modifier =
                            Modifier.fillMaxWidth()
                                    .padding(horizontal = 24.dp)
                                    .padding(bottom = 32.dp, top = 8.dp)
            ) {
                Text(
                        text = "Фотография профиля",
                        fontSize = 18.sp,
                        fontWeight = FontWeight.Bold,
                        color = textPrimary,
                        modifier = Modifier.padding(bottom = 16.dp)
                )
                Row(
                        modifier =
                                Modifier.fillMaxWidth()
                                        .clip(RoundedCornerShape(12.dp))
                                        .clickable {
                                            showAvatarOptions = false
                                            if (context.checkSelfPermission(
                                                            android.Manifest.permission.CAMERA
                                                    ) ==
                                                    android.content.pm.PackageManager
                                                            .PERMISSION_GRANTED
                                            ) {
                                                launchPenikCamera(context) { tempCameraUri = it }
                                                        ?.let { cameraLauncher.launch(it) }
                                            } else {
                                                permissionLauncher.launch(
                                                        android.Manifest.permission.CAMERA
                                                )
                                            }
                                        }
                                        .padding(vertical = 14.dp, horizontal = 12.dp),
                        verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(
                            painter = painterResource(R.drawable.ic_photo_24dp),
                            contentDescription = null,
                            tint = accent,
                            modifier = Modifier.size(24.dp)
                    )
                    Spacer(modifier = Modifier.width(16.dp))
                    Text(
                            text = "Сделать снимок",
                            fontSize = 16.sp,
                            fontWeight = FontWeight.Medium,
                            color = textPrimary
                    )
                }
                Spacer(modifier = Modifier.height(4.dp))
                Row(
                        modifier =
                                Modifier.fillMaxWidth()
                                        .clip(RoundedCornerShape(12.dp))
                                        .clickable {
                                            showAvatarOptions = false
                                            galleryLauncher.launch("image/*")
                                        }
                                        .padding(vertical = 14.dp, horizontal = 12.dp),
                        verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(
                            painter = painterResource(R.drawable.ic_image_24dp),
                            contentDescription = null,
                            tint = accent,
                            modifier = Modifier.size(24.dp)
                    )
                    Spacer(modifier = Modifier.width(16.dp))
                    Text(
                            text = "Выбрать из галереи",
                            fontSize = 16.sp,
                            fontWeight = FontWeight.Medium,
                            color = textPrimary
                    )
                }
            }
        }
    }
}

private fun launchPenikCamera(
        context: android.content.Context,
        onUri: (android.net.Uri) -> Unit
): android.net.Uri? {
    return try {
        val dir = java.io.File(context.cacheDir, "Camera").apply { mkdirs() }
        val file = java.io.File(dir, "avatar_${System.currentTimeMillis()}.jpg")
        val uri =
                androidx.core.content.FileProvider.getUriForFile(
                        context,
                        "${context.packageName}.files",
                        file
                )
        onUri(uri)
        uri
    } catch (e: Exception) {
        android.widget.Toast.makeText(context, "Не удалось открыть камеру", android.widget.Toast.LENGTH_SHORT).show()
        null
    }
}
