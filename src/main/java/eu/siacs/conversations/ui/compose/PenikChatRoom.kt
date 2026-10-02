package eu.siacs.conversations.ui.compose

import android.graphics.Bitmap
import android.util.Patterns
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
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
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
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
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import eu.siacs.conversations.R
import eu.siacs.conversations.entities.Conversation
import eu.siacs.conversations.entities.Conversational
import eu.siacs.conversations.entities.Message
import eu.siacs.conversations.entities.RtpSessionStatus
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.runtime.DisposableEffect
import java.io.File
import kotlinx.coroutines.delay
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
    const val OPEN_URL = "open_url"
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
                        Icon(
                                painter =
                                        painterResource(
                                                R.drawable.ic_keyboard_double_arrow_down_24dp
                                        ),
                                contentDescription = null,
                                modifier = Modifier.size(24.dp)
                        )
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

class PenikBubbleShape(private val isSentByMe: Boolean) : Shape {
    override fun createOutline(
            size: androidx.compose.ui.geometry.Size,
            layoutDirection: LayoutDirection,
            density: Density
    ): Outline {
        val path =
                Path().apply {
                    val width = size.width
                    val height = size.height
                    val radius = with(density) { 14.dp.toPx() }
                    val tailWidth = with(density) { 6.dp.toPx() }
                    val ctrlOffset = with(density) { 2.dp.toPx() }
                    if (isSentByMe) {
                        moveTo(radius, 0f)
                        lineTo(width - tailWidth - radius, 0f)
                        quadraticBezierTo(width - tailWidth, 0f, width - tailWidth, radius)
                        lineTo(width - tailWidth, height - radius)
                        quadraticBezierTo(width - tailWidth, height - ctrlOffset, width, height)
                        quadraticBezierTo(
                                width - tailWidth + ctrlOffset,
                                height,
                                width - tailWidth - radius,
                                height
                        )
                        lineTo(radius, height)
                        quadraticBezierTo(0f, height, 0f, height - radius)
                        lineTo(0f, radius)
                        quadraticBezierTo(0f, 0f, radius, 0f)
                    } else {
                        moveTo(tailWidth + radius, 0f)
                        lineTo(width - radius, 0f)
                        quadraticBezierTo(width, 0f, width, radius)
                        lineTo(width, height - radius)
                        quadraticBezierTo(width, height, width - radius, height)
                        lineTo(tailWidth + radius, height)
                        quadraticBezierTo(tailWidth - ctrlOffset, height, 0f, height)
                        quadraticBezierTo(tailWidth, height - ctrlOffset, tailWidth, height - radius)
                        lineTo(tailWidth, radius)
                        quadraticBezierTo(tailWidth, 0f, tailWidth + radius, 0f)
                    }
                    close()
                }
        return Outline.Generic(path)
    }
}

@Composable
fun PenikTicksIcon(
        double: Boolean,
        read: Boolean,
        tint: Color,
        accent: Color,
        modifier: Modifier = Modifier
) {
    val second = if (read) accent else tint
    val first = if (read && double) accent else tint
    Canvas(modifier = modifier.size(if (double) 20.dp else 11.dp, 13.dp)) {
        val stroke = (size.height * 0.15f).coerceAtLeast(1.5.dp.toPx())
        val style = Stroke(width = stroke, cap = StrokeCap.Round, join = StrokeJoin.Round)
        val slot = if (double) size.width * 0.62f else size.width
        val dx = if (double) size.width * 0.38f else 0f
        fun check(offsetX: Float, color: Color) {
            val p =
                    Path().apply {
                        moveTo(offsetX + slot * 0.08f, size.height * 0.52f)
                        lineTo(offsetX + slot * 0.38f, size.height * 0.78f)
                        lineTo(offsetX + slot * 0.96f, size.height * 0.18f)
                    }
            drawPath(p, color, style = style)
        }
        check(0f, first)
        if (double) {
            check(dx, second)
        }
    }
}

fun penikBareImageUrl(text: String): String? {
    val trimmed = text.trim()
    if (trimmed.isEmpty() || trimmed.contains("\n") || trimmed.contains(" ")) {
        return null
    }
    if (!eu.siacs.conversations.utils.MessageUtils.treatAsDownloadable(trimmed, false)) {
        return null
    }
    val lower = trimmed.lowercase().substringBefore("?").substringBefore("#")
    return if (lower.endsWith(".jpg") ||
                    lower.endsWith(".jpeg") ||
                    lower.endsWith(".png") ||
                    lower.endsWith(".gif") ||
                    lower.endsWith(".webp")
    ) {
        trimmed
    } else {
        null
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
    if (message.type == Message.TYPE_RTP_SESSION) {
        PenikCallCard(message = message, activity = activity, listener = listener)
        return
    }
    if (message.type == Message.TYPE_STATUS) {
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
    if (message.type == Message.TYPE_TEXT) {
        val bareUrl = remember(body) { penikBareImageUrl(body) }
        if (bareUrl != null) {
            PenikUrlImageRow(
                    url = bareUrl,
                    message = message,
                    isSentByMe = isSentByMe,
                    listener = listener
            )
            return
        }
    }
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

fun splitPenikQuote(text: String): Pair<String?, String> {
    val lines = text.lines()
    val quoted = ArrayList<String>()
    var i = 0
    while (i < lines.size) {
        val trimmed = lines[i].trimStart()
        if (trimmed.startsWith(">") || trimmed.startsWith("»")) {
            quoted.add(trimmed.trimStart('>', '»', ' ').trimEnd())
            i++
        } else {
            break
        }
    }
    if (quoted.isEmpty()) {
        return null to text
    }
    return quoted.joinToString("\n") to lines.drop(i).joinToString("\n").trimStart('\n')
}

@Composable
fun PenikQuoteBlock(quote: String, barColor: Color, textColor: Color) {
    Row(modifier = Modifier.padding(bottom = 4.dp)) {
        Box(
                modifier =
                        Modifier.width(3.dp)
                                .height(androidx.compose.foundation.layout.IntrinsicSize.Max)
                                .clip(RoundedCornerShape(2.dp))
                                .background(barColor)
        ) {
            Spacer(modifier = Modifier.height(4.dp))
        }
        Spacer(modifier = Modifier.width(8.dp))
        Text(
                text = quote,
                color = textColor,
                fontSize = 13.sp,
                maxLines = 4,
                overflow = TextOverflow.Ellipsis
        )
    }
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
        val bubbleShape = PenikBubbleShape(isSentByMe = isSentByMe)
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
                        val (quote, rest) =
                                remember(rawBody) { splitPenikQuote(rawBody) }
                        if (quote != null) {
                            PenikQuoteBlock(
                                    quote = quote,
                                    barColor = accent,
                                    textColor = textMuted
                            )
                        }
                        val mainText = if (quote != null) rest else rawBody
                        if (mainText.isNotEmpty()) {
                            ClickableText(
                                    text = penikLinkified(mainText, linkColor),
                                    style =
                                            androidx.compose.ui.text.TextStyle(
                                                    color = fgColor,
                                                    fontSize = 15.sp
                                            ),
                                    onClick = { /* links handled by annotation */ }
                            )
                        }
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
                        if (isSentByMe) {
                            if (message.status == Message.STATUS_SEND_FAILED) {
                                Spacer(modifier = Modifier.width(4.dp))
                                Text(
                                        text = "!",
                                        color = danger,
                                        fontSize = 11.sp,
                                        fontWeight = FontWeight.Bold
                                )
                            } else if (ticks.isNotEmpty()) {
                                Spacer(modifier = Modifier.width(4.dp))
                                PenikTicksIcon(
                                        double = ticks.length > 1,
                                        read = message.status == Message.STATUS_SEND_DISPLAYED,
                                        tint = textMuted,
                                        accent = accent
                                )
                            }
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
fun PenikCallCard(message: Message, activity: XmppActivity, listener: PenikChatListener) {
    val context = LocalContext.current
    val sentBg = colorResource(R.color.penik_sent_message_bg)
    val recvBg = colorResource(R.color.penik_recv_message_bg)
    val textPrimary = colorResource(R.color.penik_text_primary)
    val textMuted = colorResource(R.color.penik_text_muted)
    val sentText = colorResource(R.color.penik_sent_message_text)
    val accent = colorResource(R.color.penik_accent)
    val danger = colorResource(R.color.penik_danger)
    val isSentByMe = message.status != Message.STATUS_RECEIVED
    val status = RtpSessionStatus.of(message.body)
    val received = message.status <= Message.STATUS_RECEIVED
    val missed = !status.successful
    val title =
            when {
                received && status.duration > 0 -> context.getString(R.string.incoming_call)
                received && status.successful -> context.getString(R.string.incoming_call)
                received -> context.getString(R.string.missed_call)
                else -> context.getString(R.string.outgoing_call)
            }
    val timeFormat = remember { android.text.format.DateFormat.getTimeFormat(context) }
    val timeText =
            if (message.timeSent > 0) {
                timeFormat.format(java.util.Date(message.timeSent))
            } else {
                ""
            }
    val durationText =
            if (status.duration > 0) {
                eu.siacs.conversations.utils.TimeFrameUtils.resolve(context, status.duration)
                        .toString()
            } else {
                ""
            }
    val bgColor = if (isSentByMe) sentBg else recvBg
    val fgColor = if (isSentByMe) sentText else textPrimary
    val boxAlignment = if (isSentByMe) Alignment.CenterEnd else Alignment.CenterStart
    Box(
            modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp),
            contentAlignment = boxAlignment
    ) {
        Row(
                modifier =
                        Modifier.padding(horizontal = 12.dp)
                                .widthIn(max = 300.dp)
                                .clip(RoundedCornerShape(16.dp))
                                .background(bgColor)
                                .clickable { listener.onMessageAction(PenikChatActions.OPEN, message) }
                                .padding(12.dp),
                verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                    modifier =
                            Modifier.size(44.dp)
                                    .clip(CircleShape)
                                    .background(accent.copy(alpha = 0.2f)),
                    contentAlignment = Alignment.Center
            ) {
                Icon(
                        painter =
                                painterResource(
                                        RtpSessionStatus.getDrawable(received, status.successful)
                                ),
                        contentDescription = null,
                        tint = if (missed) danger else accent,
                        modifier = Modifier.size(24.dp)
                )
            }
            Spacer(modifier = Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                        text = title,
                        color = if (missed && !isSentByMe) danger else fgColor,
                        fontWeight = FontWeight.Bold,
                        fontSize = 15.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                )
                if (durationText.isNotEmpty()) {
                    Text(text = durationText, color = textMuted, fontSize = 13.sp)
                }
            }
            if (timeText.isNotEmpty()) {
                Spacer(modifier = Modifier.width(8.dp))
                Text(text = timeText, color = textMuted, fontSize = 11.sp)
            }
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

object PenikVoicePlayer {
    private var player: android.media.MediaPlayer? = null
    var currentUuid by mutableStateOf<String?>(null)
        private set
    var isPlaying by mutableStateOf(false)
        private set
    var progressMs by mutableStateOf(0)
    var durationMs by mutableStateOf(0)
        private set

    fun position(): Int {
        return try {
            player?.currentPosition ?: progressMs
        } catch (e: Exception) {
            progressMs
        }
    }

    fun toggle(context: android.content.Context, file: File, uuid: String, fallbackDurationMs: Int) {
        if (currentUuid == uuid && player != null) {
            try {
                if (isPlaying) {
                    player?.pause()
                    isPlaying = false
                    progressMs = position()
                } else {
                    player?.start()
                    isPlaying = true
                }
            } catch (e: Exception) {
                stop()
            }
            return
        }
        stop()
        try {
            val p = android.media.MediaPlayer()
            p.setDataSource(file.absolutePath)
            p.prepare()
            durationMs = p.duration.takeIf { it > 0 } ?: fallbackDurationMs
            p.setOnCompletionListener { stop() }
            p.start()
            player = p
            currentUuid = uuid
            isPlaying = true
            progressMs = 0
        } catch (e: Exception) {
            stop()
            android.widget.Toast.makeText(context, "Не удалось воспроизвести", android.widget.Toast.LENGTH_SHORT).show()
        }
    }

    fun seekTo(ms: Int) {
        try {
            player?.seekTo(ms)
        } catch (e: Exception) {
            // ignore
        }
        progressMs = ms
    }

    fun stop() {
        try {
            player?.stop()
        } catch (e: Exception) {
            // ignore
        }
        try {
            player?.release()
        } catch (e: Exception) {
            // ignore
        }
        player = null
        currentUuid = null
        isPlaying = false
        progressMs = 0
        durationMs = 0
    }
}

fun penikFormatVoiceTime(ms: Int): String {
    val totalSec = ms / 1000
    return "%d:%02d".format(totalSec / 60, totalSec % 60)
}

@Composable
fun PenikVoiceRow(message: Message, activity: XmppActivity, fgColor: Color, textMuted: Color) {
    val context = LocalContext.current
    val accent = colorResource(R.color.penik_accent)
    val service = activity.xmppConnectionService
    val file =
            remember(message.uuid) {
                try {
                    service?.fileBackend?.getFile(message)
                } catch (e: Exception) {
                    null
                }
            }
    if (file == null || !file.exists()) {
        PenikFileRow(message = message, fgColor = fgColor, textMuted = textMuted)
        return
    }
    val uuid = message.uuid
    val runtimeMs =
            remember(message.uuid) {
                val runtime = message.fileParams?.runtime ?: 0
                if (runtime > 0) runtime * 1000 else 0
            }
    val playingThis = PenikVoicePlayer.currentUuid == uuid && PenikVoicePlayer.isPlaying
    val progress =
            if (PenikVoicePlayer.currentUuid == uuid) {
                PenikVoicePlayer.progressMs
            } else {
                0
            }
    val duration =
            if (PenikVoicePlayer.currentUuid == uuid && PenikVoicePlayer.durationMs > 0) {
                PenikVoicePlayer.durationMs
            } else {
                runtimeMs
            }
    LaunchedEffect(playingThis, uuid) {
        while (PenikVoicePlayer.currentUuid == uuid && PenikVoicePlayer.isPlaying) {
            delay(250)
            PenikVoicePlayer.progressMs = PenikVoicePlayer.position()
        }
    }
    DisposableEffect(uuid) {
        onDispose {
            if (PenikVoicePlayer.currentUuid == uuid) {
                PenikVoicePlayer.stop()
            }
        }
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(
                modifier =
                        Modifier.size(44.dp)
                                .clip(CircleShape)
                                .background(accent)
                                .clickable {
                                    PenikVoicePlayer.toggle(context, file, uuid, runtimeMs)
                                },
                contentAlignment = Alignment.Center
        ) {
            Icon(
                    painter =
                            painterResource(
                                    if (playingThis) R.drawable.ic_pause_24dp
                                    else R.drawable.ic_play_arrow_24dp
                            ),
                    contentDescription = null,
                    tint = Color.White,
                    modifier = Modifier.size(24.dp)
            )
        }
        Spacer(modifier = Modifier.width(10.dp))
        Column(modifier = Modifier.weight(1f)) {
            Slider(
                    value = progress.toFloat(),
                    onValueChange = { PenikVoicePlayer.seekTo(it.toInt()) },
                    valueRange = 0f..(if (duration > 0) duration.toFloat() else 1f),
                    enabled = duration > 0,
                    colors =
                            SliderDefaults.colors(
                                    thumbColor = accent,
                                    activeTrackColor = accent,
                                    inactiveTrackColor = textMuted.copy(alpha = 0.4f)
                            )
            )
            Text(
                    text =
                            "${penikFormatVoiceTime(progress)} / ${penikFormatVoiceTime(duration)}",
                    color = textMuted,
                    fontSize = 12.sp
            )
        }
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
    val danger = colorResource(R.color.penik_danger)
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
        val bubbleShape = PenikBubbleShape(isSentByMe = isSentByMe)
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
                if (mime.startsWith("audio/")) {
                    PenikVoiceRow(
                            message = message,
                            activity = activity,
                            fgColor = fgColor,
                            textMuted = textMuted
                    )
                } else if ((message.type == Message.TYPE_IMAGE || mime.startsWith("image/")) &&
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
                    if (isSentByMe) {
                        if (message.status == Message.STATUS_SEND_FAILED) {
                            Spacer(modifier = Modifier.width(4.dp))
                            Text(
                                    text = "!",
                                    color = danger,
                                    fontSize = 11.sp,
                                    fontWeight = FontWeight.Bold
                            )
                        } else if (ticks.isNotEmpty()) {
                            Spacer(modifier = Modifier.width(4.dp))
                            PenikTicksIcon(
                                    double = ticks.length > 1,
                                    read = message.status == Message.STATUS_SEND_DISPLAYED,
                                    tint = textMuted,
                                    accent = accent
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
fun PenikUrlImageRow(
        url: String,
        message: Message,
        isSentByMe: Boolean,
        listener: PenikChatListener
) {
    val context = LocalContext.current
    val sentBg = colorResource(R.color.penik_sent_message_bg)
    val recvBg = colorResource(R.color.penik_recv_message_bg)
    val textMuted = colorResource(R.color.penik_text_muted)
    val accent = colorResource(R.color.penik_accent)
    val bgColor = if (isSentByMe) sentBg else recvBg
    val boxAlignment = if (isSentByMe) Alignment.CenterEnd else Alignment.CenterStart
    val timeFormat = remember { android.text.format.DateFormat.getTimeFormat(context) }
    val timeText =
            if (message.timeSent > 0) {
                timeFormat.format(java.util.Date(message.timeSent))
            } else {
                ""
            }
    Box(
            modifier = Modifier.fillMaxWidth().padding(vertical = 1.dp),
            contentAlignment = boxAlignment
    ) {
        Box(
                modifier =
                        Modifier.padding(horizontal = 12.dp)
                                .widthIn(max = 300.dp)
                                .clip(PenikBubbleShape(isSentByMe = isSentByMe))
                                .background(bgColor)
                                .combinedClickable(
                                        onClick = {
                                            listener.onMessageAction(
                                                    PenikChatActions.OPEN_URL,
                                                    message
                                            )
                                        },
                                        onLongClick = {}
                                )
                                .padding(4.dp)
        ) {
            Column {
                coil.compose.AsyncImage(
                        model = url,
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier =
                                Modifier.width(260.dp)
                                        .clip(RoundedCornerShape(8.dp))
                )
                Spacer(modifier = Modifier.height(4.dp))
                Row(
                        modifier = Modifier.align(Alignment.End),
                        verticalAlignment = Alignment.CenterVertically
                ) {
                    if (timeText.isNotEmpty()) {
                        Text(text = timeText, color = textMuted, fontSize = 11.sp)
                    }
                    if (isSentByMe && message.status == Message.STATUS_SEND_DISPLAYED) {
                        Spacer(modifier = Modifier.width(4.dp))
                        PenikTicksIcon(
                                double = true,
                                read = true,
                                tint = textMuted,
                                accent = accent
                        )
                    }
                }
            }
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
    val params = message.fileParams
    val aspect =
            if (params != null && params.width > 0 && params.height > 0) {
                (params.width.toFloat() / params.height.toFloat()).coerceIn(0.4f, 2.5f)
            } else {
                0f
            }
    if (loaded != null) {
        Image(
                bitmap = loaded.asImageBitmap(),
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier =
                        if (aspect > 0f) {
                            Modifier.width(260.dp)
                                    .aspectRatio(aspect)
                                    .clip(RoundedCornerShape(8.dp))
                        } else {
                            Modifier.widthIn(max = 280.dp).clip(RoundedCornerShape(8.dp))
                        }
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
