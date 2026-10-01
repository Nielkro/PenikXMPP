package eu.siacs.conversations.ui.compose

import android.graphics.Bitmap
import android.util.Patterns
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
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
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.ClickableText
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.colorResource
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import eu.siacs.conversations.R
import eu.siacs.conversations.entities.Conversation
import eu.siacs.conversations.entities.Conversational
import eu.siacs.conversations.entities.Message
import eu.siacs.conversations.ui.XmppActivity
import eu.siacs.conversations.ui.adapter.MessageAdapter
import eu.siacs.conversations.utils.UIHelper
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

interface PenikChatListener {
    fun onMessageAction(action: String, message: Message)
    fun onLoadMore()
    fun onBottomVisible(uuid: String)
}

object PenikChatActions {
    const val COPY = "copy"
    const val QUOTE = "quote"
    const val CORRECT = "correct"
    const val SHARE = "share"
    const val RESEND = "resend"
    const val OPEN = "open"
}

class PenikChatState {
    var messages by mutableStateOf<List<Message>>(emptyList())
    var isMuc by mutableStateOf(false)
}

object PenikChatBridge {
    @JvmStatic
    fun render(
            view: ComposeView,
            state: PenikChatState,
            activity: XmppActivity,
            listener: PenikChatListener
    ) {
        view.setContent {
            PenikChatRoom(
                    state = state,
                    activity = activity,
                    listener = listener
            )
        }
    }
}

private sealed interface ChatRow {
    data class DateHeader(val label: String, val key: LocalDate) : ChatRow
    data class Msg(val message: Message) : ChatRow
}

fun penikChatDateLabel(date: LocalDate): String {
    val today = LocalDate.now()
    return when (date) {
        today -> "Сегодня"
        today.minusDays(1) -> "Вчера"
        else -> {
            val fmt =
                    if (date.year == today.year) {
                        DateTimeFormatter.ofPattern("d MMMM")
                    } else {
                        DateTimeFormatter.ofPattern("d MMMM yyyy")
                    }
            date.format(fmt)
        }
    }
}

fun penikEmojiOnlyCount(text: String): Int {
    val cps = text.codePoints().toArray()
    if (cps.isEmpty() || cps.size > 16) {
        return 0
    }
    var base = 0
    for (cp in cps) {
        when {
            cp == 0x200D || cp == 0xFE0F || cp in 0x1F3FB..0x1F3FF -> continue
            cp in 0x1F1E6..0x1F1FF -> base += 1
            cp in 0x2600..0x26FF ||
                    cp in 0x2700..0x27BF ||
                    cp in 0x2B00..0x2BFF ||
                    cp in 0x1F300..0x1F5FF ||
                    cp in 0x1F600..0x1F64F ||
                    cp in 0x1F680..0x1F6FF ||
                    cp in 0x1F900..0x1F9FF ||
                    cp in 0x1FA70..0x1FAFF ||
                    cp == 0x2764 -> base += 1
            else -> return 0
        }
    }
    return (base + 1) / 2
}

fun penikLinkified(text: String, linkColor: Color) =
        buildAnnotatedString {
            val matcher = Patterns.WEB_URL.matcher(text)
            var last = 0
            while (matcher.find()) {
                val start = matcher.start()
                val end = matcher.end()
                if (start > last) {
                    append(text.substring(last, start))
                }
                var url = text.substring(start, end)
                if (!url.startsWith("http", ignoreCase = true)) {
                    url = "https://$url"
                }
                pushLink(LinkAnnotation.Url(url))
                withStyle(SpanStyle(color = linkColor)) { append(text.substring(start, end)) }
                pop()
                last = end
            }
            if (last < text.length) {
                append(text.substring(last))
            }
        }

@Composable
fun PenikChatRoom(
        state: PenikChatState,
        activity: XmppActivity,
        listener: PenikChatListener
) {
    val background = colorResource(R.color.penik_background)
    val scope = rememberCoroutineScope()
    val listState = rememberLazyListState()
    val rows =
            remember(state.messages) {
                val inOrder =
                        state.messages.filter { m ->
                            val body = m.body ?: ""
                            m.type != Message.TYPE_STATUS ||
                                    (body != MessageAdapter.BODY_DATE_SEPARATOR &&
                                            body != MessageAdapter.BODY_LOAD_MORE &&
                                            body != MessageAdapter.BODY_LOCAL_TIME &&
                                            body != MessageAdapter.BODY_DND)
                        }
                val out = ArrayList<ChatRow>()
                var lastDay: LocalDate? = null
                for (m in inOrder.asReversed()) {
                    val day =
                            Instant.ofEpochMilli(m.timeSent)
                                    .atZone(ZoneId.systemDefault())
                                    .toLocalDate()
                    if (day != lastDay) {
                        lastDay = day
                        out.add(ChatRow.DateHeader(penikChatDateLabel(day), day))
                    }
                    out.add(ChatRow.Msg(m))
                }
                out
            }
    val showScrollDown by remember {
        derivedStateOf {
            listState.firstVisibleItemIndex > 2
        }
    }
    LaunchedEffect(rows.size, rows.firstOrNull()) {
        if (listState.firstVisibleItemIndex <= 2 && rows.isNotEmpty()) {
            listState.scrollToItem(0)
        }
        val last = rows.lastOrNull()
        if (last is ChatRow.Msg) {
            listener.onBottomVisible(last.message.uuid)
        }
    }
    LaunchedEffect(listState.firstVisibleItemIndex, rows.size) {
        if (rows.isNotEmpty() && listState.firstVisibleItemIndex >= rows.size - 5) {
            listener.onLoadMore()
        }
        val last = rows.lastOrNull()
        if (last is ChatRow.Msg &&
                        listState.layoutInfo.visibleItemsInfo.any { it.key == last.message.uuid }
        ) {
            listener.onBottomVisible(last.message.uuid)
        }
    }
    Scaffold(
            containerColor = background,
            floatingActionButton = {
                if (showScrollDown) {
                    FloatingActionButton(
                            onClick = { scope.launch { listState.animateScrollToItem(0) } },
                            containerColor = colorResource(R.color.penik_panel_secondary),
                            contentColor = colorResource(R.color.penik_text_primary),
                            modifier = Modifier.size(44.dp)
                    ) {
                        Text(text = "↓", fontSize = 20.sp)
                    }
                }
            }
    ) { padding ->
        LazyColumn(
                state = listState,
                reverseLayout = true,
                modifier = Modifier.fillMaxSize()
        ) {
            items(rows, key = { row ->
                when (row) {
                    is ChatRow.DateHeader -> "date-${row.key}"
                    is ChatRow.Msg -> "msg-${row.message.uuid}"
                }
            }) { row ->
                when (row) {
                    is ChatRow.DateHeader -> PenikDateHeader(label = row.label)
                    is ChatRow.Msg ->
                            PenikMessageRow(
                                    message = row.message,
                                    activity = activity,
                                    isMuc = state.isMuc,
                                    listener = listener
                            )
                }
            }
        }
    }
}

@Composable
fun PenikDateHeader(label: String) {
    val panelSecondary = colorResource(R.color.penik_panel_secondary)
    val textMuted = colorResource(R.color.penik_text_muted)
    Box(
            modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
            contentAlignment = Alignment.Center
    ) {
        Box(
                modifier =
                        Modifier.clip(RoundedCornerShape(12.dp))
                                .background(panelSecondary)
                                .padding(horizontal = 12.dp, vertical = 4.dp)
        ) {
            Text(text = label, color = textMuted, fontSize = 12.sp)
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun PenikMessageRow(
        message: Message,
        activity: XmppActivity,
        isMuc: Boolean,
        listener: PenikChatListener
) {
    if (message.type == Message.TYPE_STATUS || message.type == Message.TYPE_RTP_SESSION) {
        PenikStatusRow(text = message.body ?: "")
        return
    }
    val body = message.body ?: ""
    if (body == MessageAdapter.BODY_DATE_SEPARATOR ||
                    body == MessageAdapter.BODY_LOAD_MORE ||
                    body == MessageAdapter.BODY_LOCAL_TIME ||
                    body == MessageAdapter.BODY_DND
    ) {
        return
    }
    val isSentByMe = message.status != Message.STATUS_RECEIVED
    if (message.isFileOrImage || message.isGeoUri) {
        PenikAttachmentRow(
                message = message,
                activity = activity,
                isSentByMe = isSentByMe,
                listener = listener
        )
        return
    }
    PenikTextBubble(
            message = message,
            activity = activity,
            isMuc = isMuc,
            listener = listener
    )
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun PenikTextBubble(
        message: Message,
        activity: XmppActivity,
        isMuc: Boolean,
        listener: PenikChatListener
) {
    val context = LocalContext.current
    val sentBg = colorResource(R.color.penik_sent_message_bg)
    val sentText = colorResource(R.color.penik_sent_message_text)
    val recvBg = colorResource(R.color.penik_recv_message_bg)
    val textPrimary = colorResource(R.color.penik_text_primary)
    val textMuted = colorResource(R.color.penik_text_muted)
    val accent = colorResource(R.color.penik_accent)
    val danger = colorResource(R.color.penik_danger)
    val isSentByMe = message.status != Message.STATUS_RECEIVED
    var showMenu by remember(message.uuid) { mutableStateOf(false) }
    var expandedBug by remember(message.uuid) { mutableStateOf(false) }
    val rawBody = message.body ?: ""
    val isBugReport =
            rawBody.length > 800 && rawBody.contains("Version:") && rawBody.contains("Manufacturer:")
    val collapsed = isBugReport && !expandedBug
    val emojiCount = if (collapsed) 0 else penikEmojiOnlyCount(rawBody)
    val isEmojiOnly = emojiCount in 1..3
    val bgColor = if (isSentByMe) sentBg else recvBg
    val fgColor = if (isSentByMe) sentText else textPrimary
    val linkColor = if (isSentByMe) Color(0xFF64B5F6) else Color(0xFF409CFF)
    val timeFormat = remember { android.text.format.DateFormat.getTimeFormat(context) }
    val timeText =
            if (message.timeSent > 0) {
                timeFormat.format(java.util.Date(message.timeSent))
            } else {
                ""
            }
    val ticks =
            when (message.status) {
                Message.STATUS_SEND -> "✓"
                Message.STATUS_SEND_RECEIVED -> "✓✓"
                Message.STATUS_SEND_DISPLAYED -> "✓✓"
                Message.STATUS_SEND_FAILED -> "⚠"
                else -> ""
            }
    val ticksColor =
            when (message.status) {
                Message.STATUS_SEND_DISPLAYED -> accent
                Message.STATUS_SEND_FAILED -> danger
                else -> textMuted
            }
    val showSender = isMuc && !isSentByMe
    val senderName =
            if (showSender) {
                UIHelper.getMessageDisplayName(message).split("\\s+".toRegex()).firstOrNull() ?: ""
            } else {
                ""
            }
    val boxAlignment = if (isSentByMe) Alignment.CenterEnd else Alignment.CenterStart
    Box(
            modifier = Modifier.fillMaxWidth().padding(vertical = 1.dp),
            contentAlignment = boxAlignment
    ) {
        val bubbleShape =
                RoundedCornerShape(
                        topStart = 16.dp,
                        topEnd = 16.dp,
                        bottomStart = if (isSentByMe) 16.dp else 4.dp,
                        bottomEnd = if (isSentByMe) 4.dp else 16.dp
                )
        if (isEmojiOnly) {
            val fontSize = if (emojiCount == 1) 64.sp else 40.sp
            Box(
                    modifier =
                            Modifier.padding(horizontal = 16.dp, vertical = 4.dp)
                                    .combinedClickable(
                                            onClick = {},
                                            onLongClick = { showMenu = true }
                                    )
            ) {
                Column(horizontalAlignment = if (isSentByMe) Alignment.End else Alignment.Start) {
                    Text(text = rawBody, fontSize = fontSize)
                    PenikMetaRow(
                            timeText = timeText,
                            ticks = ticks,
                            ticksColor = ticksColor,
                            isEncrypted = message.encryption != Message.ENCRYPTION_NONE,
                            edited = message.edited(),
                            overlayDark = false,
                            baseColor = textMuted
                    )
                }
            }
        } else {
            Box(
                    modifier =
                            Modifier.padding(horizontal = 12.dp)
                                    .widthIn(max = 300.dp)
                                    .clip(bubbleShape)
                                    .background(if (collapsed) recvBg else bgColor)
                                    .combinedClickable(
                                            onClick = {
                                                if (collapsed) {
                                                    expandedBug = true
                                                }
                                            },
                                            onLongClick = { showMenu = true }
                                    )
                                    .padding(horizontal = 12.dp, vertical = 8.dp)
            ) {
                Column {
                    if (showSender && senderName.isNotEmpty()) {
                        Text(
                                text = senderName,
                                color = penikInitialsColor(senderName),
                                fontWeight = FontWeight.Bold,
                                fontSize = 13.sp,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                        )
                        Spacer(modifier = Modifier.height(2.dp))
                    }
                    if (collapsed) {
                        Text(
                                text = "Отчёт об ошибке",
                                color = fgColor,
                                fontWeight = FontWeight.Bold,
                                fontSize = 14.sp
                        )
                        Text(
                                text = "Этот отчёт поможет нам разобраться с ошибкой. Нажмите, чтобы показать.",
                                color = textMuted,
                                fontSize = 13.sp
                        )
                    } else {
                        ClickableText(
                                text = penikLinkified(rawBody, linkColor),
                                style =
                                        androidx.compose.ui.text.TextStyle(
                                                color = fgColor,
                                                fontSize = 15.sp
                                        ),
                                onClick = { /* links handled by annotation; tap = collapse if bug */ }
                        )
                    }
                    Spacer(modifier = Modifier.height(2.dp))
                    Row(
                            modifier = Modifier.align(Alignment.End),
                            verticalAlignment = Alignment.CenterVertically
                    ) {
                        if (message.edited()) {
                            Text(text = "изм. ", color = textMuted, fontSize = 11.sp)
                        }
                        if (message.encryption != Message.ENCRYPTION_NONE) {
                            Icon(
                                    imageVector = Icons.Default.Lock,
                                    contentDescription = null,
                                    tint = textMuted,
                                    modifier = Modifier.size(11.dp)
                            )
                            Spacer(modifier = Modifier.width(3.dp))
                        }
                        if (timeText.isNotEmpty()) {
                            Text(text = timeText, color = textMuted, fontSize = 11.sp)
                        }
                        if (ticks.isNotEmpty() && isSentByMe) {
                            Spacer(modifier = Modifier.width(4.dp))
                            Text(
                                    text = ticks,
                                    color = ticksColor,
                                    fontSize = 11.sp,
                                    fontWeight = FontWeight.Bold
                            )
                        }
                    }
                }
            }
        }
        if (showMenu) {
            PenikMessageMenu(
                    message = message,
                    isSentByMe = isSentByMe,
                    onDismiss = { showMenu = false },
                    onAction = {
                        showMenu = false
                        listener.onMessageAction(it, message)
                    }
            )
        }
    }
}

@Composable
fun PenikMetaRow(
        timeText: String,
        ticks: String,
        ticksColor: Color,
        isEncrypted: Boolean,
        edited: Boolean,
        overlayDark: Boolean,
        baseColor: Color
) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        if (edited) {
            Text(text = "изм. ", color = baseColor, fontSize = 11.sp)
        }
        if (isEncrypted) {
            Icon(
                    imageVector = Icons.Default.Lock,
                    contentDescription = null,
                    tint = baseColor,
                    modifier = Modifier.size(11.dp)
            )
            Spacer(modifier = Modifier.width(3.dp))
        }
        if (timeText.isNotEmpty()) {
            Text(
                    text = timeText,
                    color = if (overlayDark) Color.White.copy(alpha = 0.85f) else baseColor,
                    fontSize = 11.sp
            )
        }
        if (ticks.isNotEmpty()) {
            Spacer(modifier = Modifier.width(4.dp))
            Text(
                    text = ticks,
                    color = if (overlayDark) Color.White else ticksColor,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold
            )
        }
    }
}

@Composable
fun PenikStatusRow(text: String) {
    if (text.isBlank()) {
        return
    }
    val textMuted = colorResource(R.color.penik_text_muted)
    Box(
            modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp, horizontal = 32.dp),
            contentAlignment = Alignment.Center
    ) {
        Text(
                text = text,
                color = textMuted,
                fontSize = 12.sp,
                textAlign = TextAlign.Center
        )
    }
}

@Composable
fun PenikMessageMenu(
        message: Message,
        isSentByMe: Boolean,
        onDismiss: () -> Unit,
        onAction: (String) -> Unit
) {
    val panel = colorResource(R.color.penik_panel)
    val textPrimary = colorResource(R.color.penik_text_primary)
    val isText = message.type == Message.TYPE_TEXT
    DropdownMenu(
            expanded = true,
            onDismissRequest = onDismiss,
            modifier = Modifier.background(panel)
    ) {
        if (isText) {
            DropdownMenuItem(
                    text = { Text("Копировать", color = textPrimary) },
                    onClick = { onAction(PenikChatActions.COPY) }
            )
        }
        if (isText) {
            DropdownMenuItem(
                    text = { Text("Ответить", color = textPrimary) },
                    onClick = { onAction(PenikChatActions.QUOTE) }
            )
        }
        if (isText && isSentByMe && message.status != Message.STATUS_SEND_FAILED) {
            DropdownMenuItem(
                    text = { Text("Изменить", color = textPrimary) },
                    onClick = { onAction(PenikChatActions.CORRECT) }
            )
        }
        if (message.status == Message.STATUS_SEND_FAILED) {
            DropdownMenuItem(
                    text = { Text("Отправить снова", color = textPrimary) },
                    onClick = { onAction(PenikChatActions.RESEND) }
            )
        }
        DropdownMenuItem(
                text = { Text("Поделиться", color = textPrimary) },
                onClick = { onAction(PenikChatActions.SHARE) }
        )
    }
}

@Composable
fun PenikAttachmentRow(
        message: Message,
        activity: XmppActivity,
        isSentByMe: Boolean,
        listener: PenikChatListener
) {
    val context = LocalContext.current
    val sentBg = colorResource(R.color.penik_sent_message_bg)
    val sentText = colorResource(R.color.penik_sent_message_text)
    val recvBg = colorResource(R.color.penik_recv_message_bg)
    val textPrimary = colorResource(R.color.penik_text_primary)
    val textMuted = colorResource(R.color.penik_text_muted)
    val accent = colorResource(R.color.penik_accent)
    val bgColor = if (isSentByMe) sentBg else recvBg
    val fgColor = if (isSentByMe) sentText else textPrimary
    val timeFormat = remember { android.text.format.DateFormat.getTimeFormat(context) }
    val timeText =
            if (message.timeSent > 0) {
                timeFormat.format(java.util.Date(message.timeSent))
            } else {
                ""
            }
    val ticks =
            when (message.status) {
                Message.STATUS_SEND -> "✓"
                Message.STATUS_SEND_RECEIVED -> "✓✓"
                Message.STATUS_SEND_DISPLAYED -> "✓✓"
                else -> ""
            }
    val boxAlignment = if (isSentByMe) Alignment.CenterEnd else Alignment.CenterStart
    var showMenu by remember(message.uuid) { mutableStateOf(false) }
    Box(
            modifier = Modifier.fillMaxWidth().padding(vertical = 1.dp),
            contentAlignment = boxAlignment
    ) {
        val bubbleShape =
                RoundedCornerShape(
                        topStart = 16.dp,
                        topEnd = 16.dp,
                        bottomStart = if (isSentByMe) 16.dp else 4.dp,
                        bottomEnd = if (isSentByMe) 4.dp else 16.dp
                )
        Box(
                modifier =
                        Modifier.padding(horizontal = 12.dp)
                                .widthIn(max = 300.dp)
                                .clip(bubbleShape)
                                .background(bgColor)
                                .combinedClickable(
                                        onClick = { listener.onMessageAction(PenikChatActions.OPEN, message) },
                                        onLongClick = { showMenu = true }
                                )
                                .padding(10.dp)
        ) {
            Column {
                val mime = message.mimeType ?: ""
                if ((message.type == Message.TYPE_IMAGE || mime.startsWith("image/")) &&
                                !message.isGeoUri
                ) {
                    PenikImageThumb(message = message, activity = activity, fgColor = fgColor)
                } else {
                    PenikFileRow(message = message, fgColor = fgColor, textMuted = textMuted)
                }
                Spacer(modifier = Modifier.height(4.dp))
                Row(
                        modifier = Modifier.align(Alignment.End),
                        verticalAlignment = Alignment.CenterVertically
                ) {
                    if (timeText.isNotEmpty()) {
                        Text(text = timeText, color = textMuted, fontSize = 11.sp)
                    }
                    if (ticks.isNotEmpty() && isSentByMe) {
                        Spacer(modifier = Modifier.width(4.dp))
                        Text(
                                text = ticks,
                                color =
                                        if (message.status == Message.STATUS_SEND_DISPLAYED) {
                                            accent
                                        } else {
                                            textMuted
                                        },
                                fontSize = 11.sp,
                                fontWeight = FontWeight.Bold
                        )
                    }
                }
            }
        }
        if (showMenu) {
            PenikMessageMenu(
                    message = message,
                    isSentByMe = isSentByMe,
                    onDismiss = { showMenu = false },
                    onAction = {
                        showMenu = false
                        listener.onMessageAction(it, message)
                    }
            )
        }
    }
}

@Composable
fun PenikImageThumb(message: Message, activity: XmppActivity, fgColor: Color) {
    val service = activity.xmppConnectionService
    var bitmap by remember(message.uuid) { mutableStateOf<Bitmap?>(null) }
    LaunchedEffect(message.uuid) {
        if (service == null) {
            return@LaunchedEffect
        }
        bitmap =
                withContext(Dispatchers.IO) {
                    try {
                        service.fileBackend.getThumbnail(message, 640, false)
                    } catch (e: Exception) {
                        null
                    }
                }
    }
    val loaded = bitmap
    if (loaded != null) {
        Image(
                bitmap = loaded.asImageBitmap(),
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.widthIn(max = 280.dp).clip(RoundedCornerShape(8.dp))
        )
    } else {
        PenikFileRow(
                message = message,
                fgColor = fgColor,
                textMuted = fgColor.copy(alpha = 0.7f)
        )
    }
}

@Composable
fun PenikFileRow(message: Message, fgColor: Color, textMuted: Color) {
    val params = message.fileParams
    val mime = message.mimeType ?: ""
    val iconText =
            when {
                message.isGeoUri -> "📍"
                mime.startsWith("video/") -> "🎬"
                mime.startsWith("audio/") -> "🎵"
                else -> "📎"
            }
    val name =
            when {
                message.isGeoUri -> "Местоположение"
                else -> {
                    val urlName =
                            try {
                                params?.url?.let {
                                    java.net.URL(it).path.substringAfterLast("/")
                                }
                            } catch (e: Exception) {
                                null
                            }
                    urlName?.takeIf { it.isNotBlank() } ?: "Файл"
                }
            }
    val sizeText =
            if (!message.isGeoUri && params != null && params.getSize() > 0) {
                " · " + android.text.format.Formatter.formatShortFileSize(
                        androidx.compose.ui.platform.LocalContext.current,
                        params.getSize()
                )
            } else if (params != null && params.runtime > 0) {
                " · %d:%02d".format(params.runtime / 60, params.runtime % 60)
            } else {
                ""
            }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(text = iconText, fontSize = 26.sp)
        Spacer(modifier = Modifier.width(10.dp))
        Column {
            Text(
                    text = name,
                    color = fgColor,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis
            )
            if (sizeText.isNotBlank()) {
                Text(text = sizeText.trimStart(' ', '·'), color = textMuted, fontSize = 12.sp)
            }
        }
    }
}
