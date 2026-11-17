package eu.siacs.conversations.ui.compose

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.colorResource
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import eu.siacs.conversations.R
import eu.siacs.conversations.ui.XmppActivity

@Composable
fun PenikSelfRow(selfChat: ConversationUi?, activity: XmppActivity, onClick: () -> Unit) {
    if (selfChat == null) return
    PenikConversationRow(
        item = selfChat,
        activity = activity,
        onClick = onClick,
        onLongClick = {}
    )
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun PenikArchiveRow(
    count: Int,
    subtitle: String? = null,
    onClick: () -> Unit,
    onLongClick: (() -> Unit)? = null
) {
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
            modifier =
                    Modifier.fillMaxWidth()
                            .combinedClickable(onClick = onClick, onLongClick = onLongClick)
                            .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
                modifier = Modifier.size(48.dp).clip(CircleShape).background(panelSecondary),
                contentAlignment = Alignment.Center
        ) {
            Icon(
                    painter = painterResource(R.drawable.ic_archive_24dp),
                    contentDescription = null,
                    tint = accent,
                    modifier = Modifier.size(24.dp)
            )
        }
        Spacer(modifier = Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                    text = "Архив чатов",
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 16.sp,
                    color = textPrimary
            )
            Text(
                text = subtitle ?: "$count $chatWord",
                fontSize = 13.sp,
                color = if (subtitle != null) accent else textMuted,
                maxLines = 1
            )
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
        item: ConversationUi,
        activity: XmppActivity,
        onClick: () -> Unit,
        onLongClick: () -> Unit
) {
    val context = LocalContext.current
    val textPrimary = colorResource(R.color.penik_text_primary)
    val textMuted = colorResource(R.color.penik_text_muted)
    val accent = colorResource(R.color.penik_accent)
    val isSelfChat = item.isSelfChat
    val avatarBitmap = if (isSelfChat) null else penikAvatarBitmap(item, activity)
    val displayName = item.displayName
    Row(
            modifier = Modifier
                    .fillMaxWidth()
                    .combinedClickable(onClick = onClick, onLongClick = onLongClick)
                    .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically
    ) {
        if (isSelfChat) {
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
        } else {
            PenikAvatarImage(
                    name = displayName,
                    bitmap = avatarBitmap,
                    backgroundColor = Color(item.avatarBackgroundColor)
            )
        }
        Spacer(modifier = Modifier.width(12.dp))
        Row(
                modifier = Modifier.weight(1f),
                verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                            text = displayName,
                            color = textPrimary,
                            fontWeight = if (item.isRead) FontWeight.Medium else FontWeight.Bold,
                            fontSize = 16.sp,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f, fill = false)
                    )
                }
                if (item.previewSender.isNotEmpty() || item.previewText.isNotEmpty() || item.previewIconRes != null) {
                    Spacer(modifier = Modifier.height(2.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        if (item.previewSender.isNotEmpty()) {
                            Text(
                                    text = item.previewSender,
                                    color = textMuted,
                                    fontSize = 14.sp,
                                    maxLines = 1
                            )
                        }
                        if (item.previewIconRes != null) {
                            Icon(
                                    painter = painterResource(item.previewIconRes),
                                    contentDescription = null,
                                    tint = textMuted,
                                    modifier = Modifier.size(16.dp)
                            )
                            Spacer(modifier = Modifier.width(4.dp))
                        }
                        Text(
                                text = item.previewText,
                                color = textMuted,
                                fontSize = 14.sp,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                        )
                    }
                }
            }
            if (item.timestamp > 0 || item.unreadCount > 0 || item.isPinned) {
                Spacer(modifier = Modifier.width(8.dp))
                Column(
                        horizontalAlignment = Alignment.End,
                        verticalArrangement = Arrangement.Center
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        if (item.isMuted) {
                            Icon(
                                    painter = painterResource(R.drawable.ic_notifications_off_24dp),
                                    contentDescription = null,
                                    tint = textMuted,
                                    modifier = Modifier.size(14.dp)
                            )
                            Spacer(modifier = Modifier.width(4.dp))
                        }
                        if (item.isEncrypted) {
                            Icon(
                                    imageVector = Icons.Default.Lock,
                                    contentDescription = null,
                                    tint = textMuted,
                                    modifier = Modifier.size(12.dp)
                            )
                            Spacer(modifier = Modifier.width(4.dp))
                        }
                        if (item.timestamp > 0) {
                            Text(
                                    text = penikRelativeTime(context, item.timestamp),
                                    color = textMuted,
                                    fontSize = 12.sp
                            )
                        }
                        if (item.isPinned) {
                            Spacer(modifier = Modifier.width(4.dp))
                            Icon(
                                    painter = painterResource(R.drawable.ic_push_pin_24dp),
                                    contentDescription = "Закреплено",
                                    tint = textMuted,
                                    modifier = Modifier.size(13.dp)
                            )
                        }
                    }
                    if (item.unreadCount > 0) {
                        Spacer(modifier = Modifier.height(4.dp))
                        Box(
                                modifier =
                                        Modifier.size(22.dp)
                                                .clip(CircleShape)
                                                .background(accent),
                                contentAlignment = Alignment.Center
                        ) {
                            Text(
                                    text = if (item.unreadCount > 99) "99+" else item.unreadCount.toString(),
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

@Preview(showBackground = true, backgroundColor = 0xFF0F172A)
@Composable
private fun PenikArchiveRowPreview() {
    Column {
        PenikArchiveRow(
            count = 4,
            subtitle = "Павел: Привет!",
            onClick = {}
        )
    }
}
