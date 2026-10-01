package eu.siacs.conversations.ui.compose

import android.graphics.Bitmap
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
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
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
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
import eu.siacs.conversations.entities.Conversation
import eu.siacs.conversations.entities.Conversational
import eu.siacs.conversations.entities.Message
import eu.siacs.conversations.services.AvatarService
import eu.siacs.conversations.ui.XmppActivity
import eu.siacs.conversations.utils.UIHelper
import java.time.Instant
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

interface PenikChatsListener {
    fun onConversationClick(conversation: Conversation)
    fun onArchiveConversation(conversation: Conversation)
}

class PenikChatsState {
    var conversations by mutableStateOf<List<Conversation>>(emptyList())
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
            PenikChatsList(
                    conversations = state.conversations,
                    activity = activity,
                    listener = listener
            )
        }
    }
}

@Composable
fun PenikChatsList(
        conversations: List<Conversation>,
        activity: XmppActivity,
        listener: PenikChatsListener
) {
    val background = colorResource(R.color.penik_background)
    val textMuted = colorResource(R.color.penik_text_muted)
    var pendingArchive by remember { mutableStateOf<Conversation?>(null) }
    Box(modifier = Modifier.fillMaxSize().background(background)) {
        if (conversations.isEmpty()) {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(text = "Нет переписок", color = textMuted, fontSize = 16.sp)
            }
        } else {
            LazyColumn(modifier = Modifier.fillMaxSize()) {
                items(conversations, key = { it.uuid }) { conversation ->
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
    val toArchive = pendingArchive
    if (toArchive != null) {
        val panel = colorResource(R.color.penik_panel)
        val textPrimary = colorResource(R.color.penik_text_primary)
        val accent = colorResource(R.color.penik_accent)
        AlertDialog(
                onDismissRequest = { pendingArchive = null },
                title = {
                    Text(
                            text = toArchive.name.toString(),
                            color = textPrimary,
                            fontWeight = FontWeight.Bold
                    )
                },
                text = { Text(text = "Переместить в архив?", color = textMuted) },
                confirmButton = {
                    TextButton(
                            onClick = {
                                listener.onArchiveConversation(toArchive)
                                pendingArchive = null
                            }
                    ) {
                        Text(text = "В архив", color = accent)
                    }
                },
                dismissButton = {
                    TextButton(onClick = { pendingArchive = null }) {
                        Text(text = "Отмена", color = textMuted)
                    }
                },
                containerColor = panel,
                shape = RoundedCornerShape(16.dp)
        )
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
    Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically
    ) {
        PenikAvatar(conversation = conversation, activity = activity)
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
                        color = textPrimary,
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
                                    painter =
                                            painterResource(
                                                    R.drawable.ic_notifications_off_24dp
                                            ),
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
fun PenikAvatar(conversation: Conversation, activity: XmppActivity) {
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
    val loaded = bitmap
    if (loaded != null) {
        androidx.compose.foundation.Image(
                bitmap = loaded.asImageBitmap(),
                contentDescription = null,
                modifier = Modifier.size(48.dp).clip(CircleShape)
        )
    } else {
        val name = conversation.name.toString()
        val initial = name.firstOrNull()?.uppercase() ?: "?"
        val panelSecondary = colorResource(R.color.penik_panel_secondary)
        val accent = colorResource(R.color.penik_accent)
        val initialsPalette =
                listOf(
                        accent,
                        colorResource(R.color.penik_success),
                        colorResource(R.color.penik_warning),
                        colorResource(R.color.penik_danger)
                )
        val tint =
                if (name.isEmpty()) {
                    panelSecondary
                } else {
                    initialsPalette[kotlin.math.abs(name.hashCode()) % initialsPalette.size]
                }
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
