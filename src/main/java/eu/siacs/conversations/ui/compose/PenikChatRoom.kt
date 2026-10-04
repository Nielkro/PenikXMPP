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
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
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
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.automirrored.filled.Reply
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
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
import androidx.compose.ui.graphics.Brush
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
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.TextLayoutResult
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
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.ui.draw.scale
import androidx.compose.ui.unit.IntOffset
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.viewinterop.AndroidView
import android.net.Uri
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
    const val COPY_URL = "copy_url"
    const val QUOTE = "quote"
    const val CORRECT = "correct"
    const val SHARE = "share"
    const val RESEND = "resend"
    const val OPEN = "open"
    const val OPEN_URL = "open_url"
    const val SAVE_FILE = "save_file"
    const val DELETE = "delete"
}

class PenikChatState {
    var messages by mutableStateOf<List<Message>>(emptyList())
    var isMuc by mutableStateOf(false)
    var revision by mutableStateOf(0L)

    fun update(newMessages: List<Message>, muc: Boolean) {
        messages = newMessages
        isMuc = muc
        revision++
    }
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
            val patterns =
                    listOf(
                            android.util.Patterns.EMAIL_ADDRESS to
                                    { m: String ->
                                        if (m.startsWith("mailto:", ignoreCase = true)) m
                                        else "mailto:$m"
                                    },
                            android.util.Patterns.WEB_URL to
                                    { m: String ->
                                        if (m.startsWith("http", ignoreCase = true)) m
                                        else "https://$m"
                                    }
                    )
            data class Span(val start: Int, val end: Int, val url: String, val display: String)
            val found = ArrayList<Span>()
            for ((pattern, toUrl) in patterns) {
                val matcher = pattern.matcher(text)
                while (matcher.find()) {
                    val start = matcher.start()
                    val end = matcher.end()
                    if (found.none { it.start < end && start < it.end }) {
                        found.add(Span(start, end, toUrl(text.substring(start, end)), text.substring(start, end)))
                    }
                }
            }
            found.sortBy { it.start }
            var last = 0
            for (span in found) {
                if (span.start > last) {
                    append(text.substring(last, span.start))
                }
                pushLink(LinkAnnotation.Url(span.url))
                withStyle(SpanStyle(color = linkColor)) { append(span.display) }
                pop()
                last = span.end
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
            remember(state.messages, state.revision) {
                val inOrder =
                        state.messages
                                .sortedBy { it.timeSent }
                                .filter { m ->
                                    val body = m.body ?: ""
                                    if (m.type == Message.TYPE_STATUS) {
                                        body.isNotBlank() &&
                                                body != MessageAdapter.BODY_DATE_SEPARATOR &&
                                                body != MessageAdapter.BODY_LOAD_MORE &&
                                                body != MessageAdapter.BODY_LOCAL_TIME &&
                                                body != MessageAdapter.BODY_DND
                                    } else {
                                        true
                                    }
                                }
                val items = ArrayList<ChatRow>()
                var lastDay: LocalDate? = null
                for (m in inOrder) {
                    val day =
                            Instant.ofEpochMilli(m.timeSent)
                                    .atZone(ZoneId.systemDefault())
                                    .toLocalDate()
                    if (day != lastDay) {
                        lastDay = day
                        items.add(ChatRow.DateHeader(penikChatDateLabel(day), day))
                    }
                    items.add(ChatRow.Msg(m))
                }
                items.asReversed()
            }
    val showScrollDown by remember {
        derivedStateOf {
            listState.firstVisibleItemIndex > 2
        }
    }
    val lastVisibleIndex by remember {
        derivedStateOf {
            listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0
        }
    }
    LaunchedEffect(rows.firstOrNull()) {
        if (listState.firstVisibleItemIndex <= 2 && rows.isNotEmpty()) {
            listState.scrollToItem(0)
        }
        val newest = rows.firstOrNull()
        if (newest is ChatRow.Msg) {
            listener.onBottomVisible(newest.message.uuid)
        }
    }
    LaunchedEffect(lastVisibleIndex, rows.size) {
        if (rows.isNotEmpty() && lastVisibleIndex >= rows.size - 5) {
            listener.onLoadMore()
        }
    }
    LaunchedEffect(listState.firstVisibleItemIndex) {
        val newest = rows.firstOrNull()
        if (newest is ChatRow.Msg && listState.firstVisibleItemIndex == 0) {
            listener.onBottomVisible(newest.message.uuid)
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
                                    listener = listener,
                                    revision = state.revision
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
    val cleanUrl = (if (trimmed.startsWith("aesgcm://", ignoreCase = true)) trimmed.substring("aesgcm://".length) else trimmed).substringBefore("|").trim()
    val lower = cleanUrl.lowercase().substringBefore("?").substringBefore("#")
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

fun penikBareVideoUrl(text: String): String? {
    val trimmed = text.trim()
    if (trimmed.isEmpty() || trimmed.contains("\n") || trimmed.contains(" ")) {
        return null
    }
    if (!eu.siacs.conversations.utils.MessageUtils.treatAsDownloadable(trimmed, false)) {
        return null
    }
    val cleanUrl = (if (trimmed.startsWith("aesgcm://", ignoreCase = true)) trimmed.substring("aesgcm://".length) else trimmed).substringBefore("|").trim()
    val lower = cleanUrl.lowercase().substringBefore("?").substringBefore("#")
    return if (lower.endsWith(".mp4") ||
                    lower.endsWith(".webm") ||
                    lower.endsWith(".mov") ||
                    lower.endsWith(".mkv") ||
                    lower.endsWith(".3gp") ||
                    lower.endsWith(".avi")
    ) {
        trimmed
    } else {
        null
    }
}

fun penikIsVideo(message: Message): Boolean {
    if (message.isGeoUri) return false
    val mime = message.mimeType ?: ""
    if (mime.startsWith("video/")) return true
    val body = message.body ?: ""
    val cleanUrl = (if (body.startsWith("aesgcm://", ignoreCase = true)) body.substring("aesgcm://".length) else body).substringBefore("|").trim()
    val lower = cleanUrl.lowercase().substringBefore("?").substringBefore("#")
    return lower.endsWith(".mp4") ||
            lower.endsWith(".webm") ||
            lower.endsWith(".mov") ||
            lower.endsWith(".mkv") ||
            lower.endsWith(".3gp") ||
            lower.endsWith(".avi")
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun PenikMessageRow(
        message: Message,
        activity: XmppActivity,
        isMuc: Boolean,
        listener: PenikChatListener,
        revision: Long = 0L
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
                    listener = listener,
                    revision = revision
            )
            return
        }
        val bareVideoUrl = remember(body) { penikBareVideoUrl(body) }
        if (bareVideoUrl != null) {
            PenikAttachmentRow(
                    message = message,
                    activity = activity,
                    isSentByMe = isSentByMe,
                    listener = listener,
                    revision = revision
            )
            return
        }
    }
    if (message.isFileOrImage || message.isGeoUri || penikIsVideo(message)) {
        PenikAttachmentRow(
                message = message,
                activity = activity,
                isSentByMe = isSentByMe,
                listener = listener,
                revision = revision
        )
        return
    }
    PenikTextBubble(
            message = message,
            activity = activity,
            isMuc = isMuc,
            listener = listener,
            revision = revision
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

fun formatPenikQuoteContent(raw: String): String {
    val trimmed = raw.trim()
    val cleanUrl = (if (trimmed.startsWith("aesgcm://", ignoreCase = true)) trimmed.substring("aesgcm://".length) else trimmed).substringBefore("|").trim()
    val lower = cleanUrl.lowercase().substringBefore("?").substringBefore("#")
    return when {
        trimmed.startsWith("geo:") -> "📍 Местоположение"
        lower.endsWith(".jpg") || lower.endsWith(".jpeg") || lower.endsWith(".png") || lower.endsWith(".webp") || lower.endsWith(".gif") || lower.endsWith(".bmp") || lower.contains("/image") -> "📷 Фото"
        lower.endsWith(".ogg") || lower.endsWith(".mp3") || lower.endsWith(".m4a") || lower.endsWith(".opus") || lower.endsWith(".wav") || lower.endsWith(".aac") || lower.contains("/audio") || lower.contains("voice") -> "🎙 Голосовое сообщение"
        lower.endsWith(".mp4") || lower.endsWith(".webm") || lower.endsWith(".mov") || lower.endsWith(".mkv") || lower.contains("/video") -> "🎬 Видео"
        trimmed.startsWith("http://", ignoreCase = true) || trimmed.startsWith("https://", ignoreCase = true) || trimmed.startsWith("aesgcm://", ignoreCase = true) -> {
            val fileName = try {
                val path = if (trimmed.startsWith("aesgcm://", ignoreCase = true)) "https://${trimmed.substring("aesgcm://".length)}" else trimmed
                java.net.URL(path.substringBefore("#").substringBefore("|")).path.substringAfterLast("/").takeIf { it.isNotBlank() }
            } catch (e: Exception) {
                null
            }
            if (fileName != null) "📎 $fileName" else "📎 Файл"
        }
        else -> raw
    }
}

@Composable
fun PenikQuoteBlock(
        quote: String,
        barColor: Color,
        textColor: Color,
        isSentByMe: Boolean = false
) {
    val lines = quote.lines()
    val firstLine = lines.firstOrNull() ?: ""
    val hasColon = firstLine.contains(":") && !firstLine.startsWith("http://") && !firstLine.startsWith("https://")
    val author = if (hasColon) firstLine.substringBefore(":").trim() else null
    val content = if (hasColon) {
        val remainder = firstLine.substringAfter(":").trim()
        (listOf(remainder) + lines.drop(1)).joinToString("\n").trim()
    } else {
        quote
    }

    Row(
            modifier =
                    Modifier.fillMaxWidth()
                            .padding(bottom = 6.dp)
                            .clip(RoundedCornerShape(6.dp))
                            .background(Color(0x12FFFFFF))
                            .height(androidx.compose.foundation.layout.IntrinsicSize.Max),
            verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
                modifier =
                        Modifier.width(3.dp)
                                .fillMaxHeight()
                                .background(barColor)
        )
        Spacer(modifier = Modifier.width(8.dp))
        Column(
                modifier =
                        Modifier.weight(1f, fill = false)
                                .padding(vertical = 5.dp, horizontal = 4.dp)
        ) {
            if (author != null && author.isNotEmpty()) {
                Text(
                        text = author,
                        color = if (isSentByMe) Color(0xFFB8D4FF) else barColor,
                        fontWeight = FontWeight.Bold,
                        fontSize = 11.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                )
            }
            Text(
                    text = formatPenikQuoteContent(content),
                    color = textColor,
                    fontSize = 12.sp,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis
            )
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun PenikTextBubble(
        message: Message,
        activity: XmppActivity,
        isMuc: Boolean,
        listener: PenikChatListener,
        revision: Long = 0L
) {
    val context = LocalContext.current
    val haptic = LocalHapticFeedback.current
    val uriHandler = LocalUriHandler.current
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
                Message.STATUS_UNSEND, Message.STATUS_WAITING, Message.STATUS_OFFERED, Message.STATUS_SEND -> "✓"
                Message.STATUS_SEND_RECEIVED -> "✓✓"
                Message.STATUS_SEND_DISPLAYED -> "✓✓"
                Message.STATUS_SEND_FAILED -> "⚠"
                else -> if (isSentByMe) "✓" else ""
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
                                            onLongClick = {
                                                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                                showMenu = true
                                            }
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
                                            onLongClick = {
                                                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                                showMenu = true
                                            }
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
                                    textColor = textMuted,
                                    isSentByMe = isSentByMe
                            )
                        }
                        val mainText = if (quote != null) rest else rawBody
                        if (mainText.isNotEmpty()) {
                            val annotated = remember(mainText, linkColor) { penikLinkified(mainText, linkColor) }
                            var layoutResult by remember { mutableStateOf<TextLayoutResult?>(null) }
                            Text(
                                    text = annotated,
                                    color = fgColor,
                                    fontSize = 15.sp,
                                    onTextLayout = { layoutResult = it },
                                    modifier = Modifier.pointerInput(annotated) {
                                        detectTapGestures(
                                                onLongPress = {
                                                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                                    showMenu = true
                                                },
                                                onTap = { offset ->
                                                    layoutResult?.let { textLayoutResult ->
                                                        val position = textLayoutResult.getOffsetForPosition(offset)
                                                        annotated.getLinkAnnotations(start = position, end = position)
                                                                .firstOrNull()?.let { annotation ->
                                                                    if (annotation.item is LinkAnnotation.Url) {
                                                                        try {
                                                                            uriHandler.openUri((annotation.item as LinkAnnotation.Url).url)
                                                                        } catch (ignored: Exception) {}
                                                                    }
                                                                }
                                                    }
                                                }
                                        )
                                    }
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
                            } else {
                                Spacer(modifier = Modifier.width(4.dp))
                                val isDouble =
                                        message.status == Message.STATUS_SEND_RECEIVED ||
                                                message.status == Message.STATUS_SEND_DISPLAYED
                                PenikTicksIcon(
                                        double = isDouble,
                                        read = message.status == Message.STATUS_SEND_DISPLAYED,
                                        tint = textMuted,
                                        accent = accent
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
    val durationText = penikCallDuration(status.duration, message.timeSent)
    val mediaText =
            when (status.media) {
                "video" -> context.getString(R.string.video).replaceFirstChar { it.uppercase() }
                "audio" -> context.getString(R.string.audio).replaceFirstChar { it.uppercase() }
                else -> ""
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
                                .clip(PenikBubbleShape(isSentByMe = isSentByMe))
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
                val details =
                        listOf(durationText, mediaText).filter { it.isNotEmpty() }.joinToString(" ")
                if (details.isNotEmpty()) {
                    Text(text = details, color = textMuted, fontSize = 13.sp)
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
    val textMuted = colorResource(R.color.penik_text_muted)
    val accent = colorResource(R.color.penik_accent)
    val danger = colorResource(R.color.penik_danger)
    val mime = message.mimeType ?: ""
    val isMedia = message.isFileOrImage || mime.startsWith("image/") || mime.startsWith("audio/") || mime.startsWith("video/") || message.isGeoUri
    val body = message.body ?: ""
    val hasText = body.isNotBlank() && !message.isGeoUri
    val hasUrl = message.fileParams?.url != null || (hasText && (body.contains("http://") || body.contains("https://") || body.startsWith("geo:")))

    DropdownMenu(
            expanded = true,
            onDismissRequest = onDismiss,
            modifier = Modifier.background(panel)
    ) {
        if (message.status == Message.STATUS_SEND_FAILED) {
            DropdownMenuItem(
                    text = { Text("Повторить попытку", color = accent) },
                    leadingIcon = {
                        Icon(
                                imageVector = Icons.Default.Refresh,
                                contentDescription = null,
                                tint = accent,
                                modifier = Modifier.size(20.dp)
                        )
                    },
                    onClick = { onAction(PenikChatActions.RESEND) }
            )
        }
        DropdownMenuItem(
                text = { Text("Ответить", color = textPrimary) },
                leadingIcon = {
                    Icon(
                            imageVector = Icons.AutoMirrored.Filled.Reply,
                            contentDescription = null,
                            tint = textMuted,
                            modifier = Modifier.size(20.dp)
                    )
                },
                onClick = { onAction(PenikChatActions.QUOTE) }
        )
        if (hasText) {
            DropdownMenuItem(
                    text = { Text("Копировать текст", color = textPrimary) },
                    leadingIcon = {
                        Icon(
                                imageVector = Icons.Default.ContentCopy,
                                contentDescription = null,
                                tint = textMuted,
                                modifier = Modifier.size(20.dp)
                        )
                    },
                    onClick = { onAction(PenikChatActions.COPY) }
            )
        }
        if (!isMedia && isSentByMe && message.status != Message.STATUS_SEND_FAILED && message.acceptMessageCorrection()) {
            DropdownMenuItem(
                    text = { Text("Изменить", color = textPrimary) },
                    leadingIcon = {
                        Icon(
                                imageVector = Icons.Default.Edit,
                                contentDescription = null,
                                tint = textMuted,
                                modifier = Modifier.size(20.dp)
                        )
                    },
                    onClick = { onAction(PenikChatActions.CORRECT) }
            )
        }
        DropdownMenuItem(
                text = { Text("Поделиться", color = textPrimary) },
                leadingIcon = {
                    Icon(
                            imageVector = Icons.Default.Share,
                            contentDescription = null,
                            tint = textMuted,
                            modifier = Modifier.size(20.dp)
                    )
                },
                onClick = { onAction(PenikChatActions.SHARE) }
        )
        DropdownMenuItem(
                text = { Text("Удалить", color = danger) },
                leadingIcon = {
                    Icon(
                            imageVector = Icons.Default.Delete,
                            contentDescription = null,
                            tint = danger,
                            modifier = Modifier.size(20.dp)
                    )
                },
                onClick = { onAction(PenikChatActions.DELETE) }
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
    return "%02d:%02d".format(totalSec / 60, totalSec % 60)
}

fun generateVoiceWaveform(seed: String, barCount: Int = 45): List<Float> {
    val rng = kotlin.random.Random(seed.hashCode())
    val result = ArrayList<Float>(barCount)
    var current = 0.25f
    for (i in 0 until barCount) {
        val trend = (kotlin.math.sin(i * 0.35) * 0.35 + 0.45).toFloat()
        val noise = rng.nextFloat() * 0.4f - 0.2f
        val peakChance = rng.nextFloat()
        val amp = when {
            peakChance > 0.82f -> rng.nextFloat() * 0.45f + 0.55f
            peakChance < 0.12f -> rng.nextFloat() * 0.12f + 0.08f
            else -> (current * 0.25f + (trend + noise) * 0.75f).coerceIn(0.12f, 0.95f)
        }
        current = amp
        result.add(amp.coerceIn(0.1f, 1.0f))
    }
    return result
}

@Composable
fun PenikWaveform(
        progress: Float,
        amplitudes: List<Float>,
        activeColor: Color,
        inactiveColor: Color,
        onSeek: (Float) -> Unit,
        modifier: Modifier = Modifier
) {
    val barWidthDp = 2.5.dp
    val barGapDp = 1.5.dp

    Canvas(
            modifier =
                    modifier
                            .pointerInput(Unit) {
                                detectTapGestures { offset ->
                                    if (size.width > 0) {
                                        onSeek((offset.x / size.width).coerceIn(0f, 1f))
                                    }
                                }
                            }
                            .pointerInput(Unit) {
                                detectHorizontalDragGestures { change, _ ->
                                    change.consume()
                                    if (size.width > 0) {
                                        onSeek((change.position.x / size.width).coerceIn(0f, 1f))
                                    }
                                }
                            }
    ) {
        val totalWidth = size.width
        val maxHeight = size.height
        val minBarHeight = 3.dp.toPx()
        val barWidthPx = barWidthDp.toPx()
        val barGapPx = barGapDp.toPx()
        val stepPx = barWidthPx + barGapPx
        if (stepPx <= 0 || totalWidth <= 0) return@Canvas

        val maxBars = (totalWidth / stepPx).toInt()
        if (maxBars <= 0) return@Canvas

        val progressX = progress * totalWidth

        for (i in 0 until maxBars) {
            val x = i * stepPx + barWidthPx / 2f
            val amp =
                    if (amplitudes.isNotEmpty()) {
                        val idx = (i * amplitudes.size / maxBars).coerceIn(0, amplitudes.size - 1)
                        amplitudes[idx]
                    } else {
                        0.25f
                    }
            val barHeight =
                    (minBarHeight + amp * (maxHeight - minBarHeight)).coerceIn(
                            minBarHeight,
                            maxHeight
                    )
            val startY = (maxHeight - barHeight) / 2f
            val endY = startY + barHeight

            val color = if (x <= progressX) activeColor else inactiveColor

            drawLine(
                    color = color,
                    start = Offset(x, startY),
                    end = Offset(x, endY),
                    strokeWidth = barWidthPx,
                    cap = StrokeCap.Round
            )
        }
    }
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
            remember(message.uuid, file) {
                val paramsRuntime = message.fileParams?.runtime ?: 0
                if (paramsRuntime > 0) {
                    paramsRuntime
                } else if (file != null && file.exists()) {
                    try {
                        val mmr = android.media.MediaMetadataRetriever()
                        mmr.setDataSource(file.absolutePath)
                        val durStr =
                                mmr.extractMetadata(
                                        android.media.MediaMetadataRetriever.METADATA_KEY_DURATION
                                )
                        durStr?.toIntOrNull() ?: 0
                    } catch (e: Exception) {
                        0
                    }
                } else {
                    0
                }
            }
    val playingThis = PenikVoicePlayer.currentUuid == uuid && PenikVoicePlayer.isPlaying
    val progressMs =
            if (PenikVoicePlayer.currentUuid == uuid) {
                PenikVoicePlayer.progressMs
            } else {
                0
            }
    val durationMs =
            if (PenikVoicePlayer.currentUuid == uuid && PenikVoicePlayer.durationMs > 0) {
                PenikVoicePlayer.durationMs
            } else {
                runtimeMs
            }
    val progressFraction =
            if (durationMs > 0) {
                (progressMs.toFloat() / durationMs.toFloat()).coerceIn(0f, 1f)
            } else {
                0f
            }
    val waveform = remember(message.uuid) { generateVoiceWaveform(message.uuid, 45) }
    val fileSizeStr = remember(file) {
        try {
            UIHelper.filesizeToString(file.length())
        } catch (e: Exception) {
            ""
        }
    }

    LaunchedEffect(playingThis, uuid) {
        while (PenikVoicePlayer.currentUuid == uuid && PenikVoicePlayer.isPlaying) {
            delay(100)
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
    Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp)
    ) {
        Box(
                modifier =
                        Modifier.size(42.dp)
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
            PenikWaveform(
                    progress = progressFraction,
                    amplitudes = waveform,
                    activeColor = accent,
                    inactiveColor = accent.copy(alpha = 0.35f),
                    onSeek = { fraction ->
                        if (durationMs > 0) {
                            val seekMs = (fraction * durationMs).toInt()
                            PenikVoicePlayer.seekTo(seekMs)
                        }
                    },
                    modifier = Modifier.fillMaxWidth().height(26.dp)
            )
            Spacer(modifier = Modifier.height(3.dp))
            val displayTimeMs = if (playingThis || progressMs > 0) progressMs else durationMs
            val timeAndSizeText = buildString {
                append(penikFormatVoiceTime(displayTimeMs))
                if (fileSizeStr.isNotEmpty()) {
                    append(", ")
                    append(fileSizeStr)
                }
            }
            Text(
                    text = timeAndSizeText,
                    color = textMuted,
                    fontSize = 11.sp,
                    maxLines = 1
            )
        }
    }
}

@Composable
fun PenikImageViewer(
        model: Any?,
        message: Message? = null,
        listener: PenikChatListener? = null,
        onDismiss: () -> Unit
) {
    if (model == null) return
    var scale by remember(model) { mutableStateOf(1f) }
    var offsetX by remember(model) { mutableStateOf(0f) }
    var offsetY by remember(model) { mutableStateOf(0f) }
    var showControls by remember(model) { mutableStateOf(true) }

    val context = LocalContext.current
    val senderName = remember(message) {
        if (message != null) {
            UIHelper.getMessageDisplayName(message)
        } else {
            ""
        }
    }
    val timeFormat = remember { android.text.format.DateFormat.getTimeFormat(context) }
    val dateFormat = remember { android.text.format.DateFormat.getMediumDateFormat(context) }
    val timeText = remember(message) {
        if (message != null && message.timeSent > 0) {
            val date = java.util.Date(message.timeSent)
            "${dateFormat.format(date)}, ${timeFormat.format(date)}"
        } else {
            ""
        }
    }
    val hasUrl = message?.fileParams?.url != null || (message?.body != null && (message.body.contains("http://") || message.body.contains("https://")))

    androidx.compose.ui.window.Dialog(
            onDismissRequest = onDismiss,
            properties = androidx.compose.ui.window.DialogProperties(
                    usePlatformDefaultWidth = false,
                    decorFitsSystemWindows = false
            )
    ) {
        Box(
                modifier =
                        Modifier.fillMaxSize()
                                .background(Color.Black.copy(alpha = 0.96f))
                                .pointerInput(model) {
                                    detectTapGestures(
                                            onDoubleTap = {
                                                if (scale > 1f) {
                                                    scale = 1f
                                                    offsetX = 0f
                                                    offsetY = 0f
                                                } else {
                                                    scale = 2.5f
                                                }
                                            },
                                            onTap = {
                                                showControls = !showControls
                                            }
                                    )
                                },
                contentAlignment = Alignment.Center
        ) {
            coil.compose.AsyncImage(
                    model = model,
                    contentDescription = null,
                    modifier =
                            Modifier.fillMaxSize()
                                    .pointerInput(model) {
                                        detectTransformGestures { _, pan, zoom, _ ->
                                            scale = (scale * zoom).coerceIn(1f, 5f)
                                            if (scale <= 1f) {
                                                offsetX = 0f
                                                offsetY = 0f
                                            } else {
                                                offsetX += pan.x
                                                offsetY += pan.y
                                            }
                                        }
                                    }
                                    .offset {
                                        IntOffset(
                                                offsetX.toInt(),
                                                offsetY.toInt()
                                        )
                                    }
                                    .scale(scale),
                    contentScale = ContentScale.Fit
            )

            AnimatedVisibility(
                    visible = showControls,
                    enter = fadeIn(),
                    exit = fadeOut(),
                    modifier = Modifier.align(Alignment.TopCenter).fillMaxWidth()
            ) {
                Box(
                        modifier =
                                Modifier.fillMaxWidth()
                                        .background(
                                                Brush.verticalGradient(
                                                        colors = listOf(Color.Black.copy(alpha = 0.85f), Color.Transparent)
                                                )
                                        )
                                        .statusBarsPadding()
                                        .padding(horizontal = 8.dp, vertical = 6.dp)
                ) {
                    Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically
                    ) {
                        IconButton(onClick = onDismiss) {
                            Icon(
                                    imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                                    contentDescription = "Назад",
                                    tint = Color.White
                            )
                        }
                        Spacer(modifier = Modifier.width(4.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            if (senderName.isNotEmpty()) {
                                Text(
                                        text = senderName,
                                        color = Color.White,
                                        fontSize = 15.sp,
                                        fontWeight = FontWeight.Bold,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis
                                )
                            }
                            if (timeText.isNotEmpty()) {
                                Text(
                                        text = timeText,
                                        color = Color.White.copy(alpha = 0.7f),
                                        fontSize = 12.sp,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis
                                )
                            }
                        }
                        if (message != null && listener != null) {
                            if (hasUrl) {
                                IconButton(
                                        onClick = {
                                            listener.onMessageAction(PenikChatActions.COPY_URL, message)
                                        }
                                ) {
                                    Icon(
                                            imageVector = Icons.Default.Link,
                                            contentDescription = "Копировать ссылку",
                                            tint = Color.White
                                    )
                                }
                            }
                            IconButton(
                                    onClick = {
                                        listener.onMessageAction(PenikChatActions.SAVE_FILE, message)
                                    }
                            ) {
                                Icon(
                                        imageVector = Icons.Default.Download,
                                        contentDescription = "Сохранить",
                                        tint = Color.White
                                )
                            }
                            IconButton(
                                    onClick = {
                                        listener.onMessageAction(PenikChatActions.SHARE, message)
                                    }
                            ) {
                                Icon(
                                        imageVector = Icons.Default.Share,
                                        contentDescription = "Поделиться",
                                        tint = Color.White
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun PenikVideoViewer(
        message: Message,
        activity: XmppActivity,
        listener: PenikChatListener? = null,
        onDismiss: () -> Unit
) {
    val context = LocalContext.current
    val service = activity.xmppConnectionService
    val localFile = remember(message.uuid) {
        service?.fileBackend?.getFile(message, false)?.takeIf { it.exists() }
    }
    val rawUrl = message.fileParams?.url ?: message.body?.trim()
    val videoUri = remember(message.uuid, localFile) {
        if (localFile != null) {
            Uri.fromFile(localFile)
        } else if (rawUrl != null && (rawUrl.startsWith("http://") || rawUrl.startsWith("https://"))) {
            Uri.parse(rawUrl)
        } else {
            null
        }
    }

    var isPlaying by remember { mutableStateOf(false) }
    var currentPositionMs by remember { mutableStateOf(0) }
    var durationMs by remember { mutableStateOf(0) }
    var showControls by remember { mutableStateOf(true) }
    var isError by remember { mutableStateOf(false) }
    var videoViewRef by remember { mutableStateOf<android.widget.VideoView?>(null) }

    val senderName = remember(message) { UIHelper.getMessageDisplayName(message) }
    val timeFormat = remember { android.text.format.DateFormat.getTimeFormat(context) }
    val dateFormat = remember { android.text.format.DateFormat.getMediumDateFormat(context) }
    val timeText = remember(message) {
        if (message.timeSent > 0) {
            val date = java.util.Date(message.timeSent)
            "${dateFormat.format(date)}, ${timeFormat.format(date)}"
        } else {
            ""
        }
    }
    val hasUrl = message.fileParams?.url != null || (message.body != null && (message.body.contains("http://") || message.body.contains("https://")))

    DisposableEffect(Unit) {
        onDispose {
            videoViewRef?.stopPlayback()
        }
    }

    LaunchedEffect(isPlaying) {
        while (isPlaying) {
            videoViewRef?.let { vv ->
                if (vv.isPlaying) {
                    currentPositionMs = vv.currentPosition
                    val dur = vv.duration
                    if (dur > 0) durationMs = dur
                }
            }
            delay(250)
        }
    }

    androidx.compose.ui.window.Dialog(
            onDismissRequest = {
                videoViewRef?.stopPlayback()
                onDismiss()
            },
            properties = androidx.compose.ui.window.DialogProperties(
                    usePlatformDefaultWidth = false,
                    decorFitsSystemWindows = false
            )
    ) {
        Box(
                modifier = Modifier
                        .fillMaxSize()
                        .background(Color.Black),
                contentAlignment = Alignment.Center
        ) {
            if (videoUri != null && !isError) {
                AndroidView(
                        factory = { ctx ->
                            android.widget.VideoView(ctx).apply {
                                setVideoURI(videoUri)
                                setOnPreparedListener { mp ->
                                    mp.isLooping = false
                                    durationMs = mp.duration
                                    start()
                                    isPlaying = true
                                }
                                setOnCompletionListener {
                                    isPlaying = false
                                    currentPositionMs = durationMs
                                }
                                setOnErrorListener { _, _, _ ->
                                    isError = true
                                    false
                                }
                                videoViewRef = this
                            }
                        },
                        modifier = Modifier
                                .fillMaxSize()
                                .clickable { showControls = !showControls }
                )
            } else {
                Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        modifier = Modifier.padding(24.dp)
                ) {
                    Text(
                            text = if (isError) "Не удалось воспроизвести видео" else "Видео не скачано",
                            color = Color.White,
                            fontSize = 16.sp,
                            fontWeight = FontWeight.Medium
                    )
                    Spacer(modifier = Modifier.height(14.dp))
                    Button(
                            onClick = {
                                listener?.onMessageAction(PenikChatActions.OPEN, message)
                                onDismiss()
                            },
                            colors = ButtonDefaults.buttonColors(
                                    containerColor = colorResource(R.color.penik_accent)
                            )
                    ) {
                        Text(if (isError) "Открыть через внешнее приложение" else "Скачать видео")
                    }
                }
            }

            // Top Bar
            AnimatedVisibility(
                    visible = showControls,
                    enter = fadeIn(),
                    exit = fadeOut(),
                    modifier = Modifier.align(Alignment.TopCenter).fillMaxWidth()
            ) {
                Box(
                        modifier = Modifier
                                .fillMaxWidth()
                                .background(
                                        Brush.verticalGradient(
                                                colors = listOf(Color.Black.copy(alpha = 0.85f), Color.Transparent)
                                        )
                                )
                                .statusBarsPadding()
                                .padding(horizontal = 8.dp, vertical = 6.dp)
                ) {
                    Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically
                    ) {
                        IconButton(onClick = {
                            videoViewRef?.stopPlayback()
                            onDismiss()
                        }) {
                            Icon(
                                    imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                                    contentDescription = "Назад",
                                    tint = Color.White
                            )
                        }
                        Spacer(modifier = Modifier.width(4.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            if (senderName.isNotEmpty()) {
                                Text(
                                        text = senderName,
                                        color = Color.White,
                                        fontSize = 15.sp,
                                        fontWeight = FontWeight.Bold,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis
                                )
                            }
                            if (timeText.isNotEmpty()) {
                                Text(
                                        text = timeText,
                                        color = Color.White.copy(alpha = 0.7f),
                                        fontSize = 12.sp,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis
                                )
                            }
                        }
                        if (listener != null) {
                            if (hasUrl) {
                                IconButton(
                                        onClick = {
                                            listener.onMessageAction(PenikChatActions.COPY_URL, message)
                                        }
                                ) {
                                    Icon(
                                            imageVector = Icons.Default.Link,
                                            contentDescription = "Копировать ссылку",
                                            tint = Color.White
                                    )
                                }
                            }
                            IconButton(
                                    onClick = {
                                        listener.onMessageAction(PenikChatActions.SAVE_FILE, message)
                                    }
                            ) {
                                Icon(
                                        imageVector = Icons.Default.Download,
                                        contentDescription = "Сохранить",
                                        tint = Color.White
                                )
                            }
                            IconButton(
                                    onClick = {
                                        listener.onMessageAction(PenikChatActions.SHARE, message)
                                    }
                            ) {
                                Icon(
                                        imageVector = Icons.Default.Share,
                                        contentDescription = "Поделиться",
                                        tint = Color.White
                                )
                            }
                        }
                    }
                }
            }

            // Bottom Controls Bar
            AnimatedVisibility(
                    visible = showControls && videoUri != null && !isError,
                    enter = fadeIn(),
                    exit = fadeOut(),
                    modifier = Modifier.align(Alignment.BottomCenter).fillMaxWidth()
            ) {
                Box(
                        modifier = Modifier
                                .fillMaxWidth()
                                .background(
                                        Brush.verticalGradient(
                                                colors = listOf(Color.Transparent, Color.Black.copy(alpha = 0.85f))
                                        )
                                )
                                .navigationBarsPadding()
                                .padding(horizontal = 16.dp, vertical = 12.dp)
                ) {
                    Column {
                        val progress = if (durationMs > 0) (currentPositionMs.toFloat() / durationMs.toFloat()).coerceIn(0f, 1f) else 0f
                        Slider(
                                value = progress,
                                onValueChange = { fraction ->
                                    if (durationMs > 0) {
                                        val newPos = (fraction * durationMs).toInt()
                                        currentPositionMs = newPos
                                        videoViewRef?.seekTo(newPos)
                                    }
                                },
                                colors = SliderDefaults.colors(
                                        thumbColor = colorResource(R.color.penik_accent),
                                        activeTrackColor = colorResource(R.color.penik_accent),
                                        inactiveTrackColor = Color.White.copy(alpha = 0.3f)
                                ),
                                modifier = Modifier.fillMaxWidth()
                        )
                        Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                        ) {
                            IconButton(
                                    onClick = {
                                        videoViewRef?.let { vv ->
                                            if (vv.isPlaying) {
                                                vv.pause()
                                                isPlaying = false
                                            } else {
                                                if (currentPositionMs >= durationMs && durationMs > 0) {
                                                    vv.seekTo(0)
                                                }
                                                vv.start()
                                                isPlaying = true
                                            }
                                        }
                                    }
                            ) {
                                Icon(
                                        imageVector = if (isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow,
                                        contentDescription = if (isPlaying) "Пауза" else "Воспроизведение",
                                        tint = Color.White,
                                        modifier = Modifier.size(32.dp)
                                )
                            }
                            val curSec = (currentPositionMs / 1000).coerceAtLeast(0)
                            val durSec = (durationMs / 1000).coerceAtLeast(0)
                            val timeStr = "%02d:%02d / %02d:%02d".format(curSec / 60, curSec % 60, durSec / 60, durSec % 60)
                            Text(
                                    text = timeStr,
                                    color = Color.White,
                                    fontSize = 13.sp,
                                    fontWeight = FontWeight.Medium
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun PenikAttachmentRow(
        message: Message,
        activity: XmppActivity,
        isSentByMe: Boolean,
        listener: PenikChatListener,
        revision: Long = 0L
) {
    val context = LocalContext.current
    val haptic = LocalHapticFeedback.current
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
    val boxAlignment = if (isSentByMe) Alignment.CenterEnd else Alignment.CenterStart
    var showMenu by remember(message.uuid) { mutableStateOf(false) }
    var showImageViewer by remember(message.uuid) { mutableStateOf(false) }
    var showVideoViewer by remember(message.uuid) { mutableStateOf(false) }
    val mime = message.mimeType ?: ""
    val isImage = (message.type == Message.TYPE_IMAGE || mime.startsWith("image/")) && !message.isGeoUri
    val isVideo = penikIsVideo(message)

    val service = activity.xmppConnectionService
    val resolvedModel = remember(message.uuid) {
        val file = service?.fileBackend?.getFile(message, false)?.takeIf { it.exists() }
        file ?: message.fileParams?.url
    }

    Box(
            modifier = Modifier.fillMaxWidth().padding(vertical = 1.dp),
            contentAlignment = boxAlignment
    ) {
        if (isImage || isVideo) {
            Box(
                    modifier =
                            Modifier.padding(horizontal = 12.dp)
                                    .widthIn(max = 280.dp)
                                    .clip(RoundedCornerShape(12.dp))
                                    .background(Color(0x15FFFFFF))
                                    .combinedClickable(
                                            onClick = {
                                                if (isVideo) {
                                                    showVideoViewer = true
                                                } else {
                                                    showImageViewer = true
                                                }
                                            },
                                            onLongClick = {
                                                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                                showMenu = true
                                            }
                                    )
            ) {
                if (isVideo) {
                    PenikVideoThumb(message = message, activity = activity, fgColor = fgColor)
                } else {
                    PenikImageThumb(message = message, activity = activity, fgColor = fgColor)
                }
                if (timeText.isNotEmpty()) {
                    Box(
                            modifier =
                                    Modifier.align(Alignment.BottomEnd)
                                            .padding(6.dp)
                                            .clip(RoundedCornerShape(10.dp))
                                            .background(Color.Black.copy(alpha = 0.55f))
                                            .padding(horizontal = 6.dp, vertical = 2.dp)
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(text = timeText, fontSize = 10.sp, color = Color.White)
                            if (isSentByMe) {
                                if (message.status == Message.STATUS_SEND_FAILED) {
                                    Spacer(modifier = Modifier.width(4.dp))
                                    Text(
                                            text = "!",
                                            color = danger,
                                            fontSize = 10.sp,
                                            fontWeight = FontWeight.Bold
                                    )
                                } else {
                                    Spacer(modifier = Modifier.width(4.dp))
                                    val isDouble =
                                            message.status == Message.STATUS_SEND_RECEIVED ||
                                                    message.status == Message.STATUS_SEND_DISPLAYED
                                    PenikTicksIcon(
                                            double = isDouble,
                                            read = message.status == Message.STATUS_SEND_DISPLAYED,
                                            tint = Color.White.copy(alpha = 0.8f),
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
        } else {
            val bubbleShape = PenikBubbleShape(isSentByMe = isSentByMe)
            Box(
                    modifier =
                            Modifier.padding(horizontal = 12.dp)
                                    .widthIn(max = 300.dp)
                                    .clip(bubbleShape)
                                    .background(bgColor)
                                    .combinedClickable(
                                            onClick = { listener.onMessageAction(PenikChatActions.OPEN, message) },
                                            onLongClick = {
                                                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                                showMenu = true
                                            }
                                    )
                                    .padding(10.dp)
            ) {
                Column {
                    if (mime.startsWith("audio/")) {
                        PenikVoiceRow(
                                message = message,
                                activity = activity,
                                fgColor = fgColor,
                                textMuted = textMuted
                        )
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
                            } else {
                                Spacer(modifier = Modifier.width(4.dp))
                                val isDouble =
                                        message.status == Message.STATUS_SEND_RECEIVED ||
                                                message.status == Message.STATUS_SEND_DISPLAYED
                                PenikTicksIcon(
                                        double = isDouble,
                                        read = message.status == Message.STATUS_SEND_DISPLAYED,
                                        tint = textMuted,
                                        accent = accent
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
    }

    if (showImageViewer) {
        val fallbackModel = resolvedModel ?: runCatching { service?.fileBackend?.getThumbnail(message, 1280, false) }.getOrNull()
        PenikImageViewer(
                model = fallbackModel,
                message = message,
                listener = listener,
                onDismiss = { showImageViewer = false }
        )
    }

    if (showVideoViewer) {
        PenikVideoViewer(
                message = message,
                activity = activity,
                listener = listener,
                onDismiss = { showVideoViewer = false }
        )
    }
}

@Composable
fun PenikUrlImageRow(
        url: String,
        message: Message,
        isSentByMe: Boolean,
        listener: PenikChatListener,
        revision: Long = 0L
) {
    val context = LocalContext.current
    val haptic = LocalHapticFeedback.current
    val boxAlignment = if (isSentByMe) Alignment.CenterEnd else Alignment.CenterStart
    val accent = colorResource(R.color.penik_accent)
    val danger = colorResource(R.color.penik_danger)
    val timeFormat = remember { android.text.format.DateFormat.getTimeFormat(context) }
    val timeText =
            if (message.timeSent > 0) {
                timeFormat.format(java.util.Date(message.timeSent))
            } else {
                ""
            }
    var showViewer by remember(message.uuid) { mutableStateOf(false) }
    var showMenu by remember(message.uuid) { mutableStateOf(false) }

    Box(
            modifier = Modifier.fillMaxWidth().padding(vertical = 1.dp),
            contentAlignment = boxAlignment
    ) {
        Box(
                modifier =
                        Modifier.padding(horizontal = 12.dp)
                                .widthIn(max = 280.dp)
                                .clip(RoundedCornerShape(12.dp))
                                .background(Color(0x15FFFFFF))
                                .combinedClickable(
                                        onClick = { showViewer = true },
                                        onLongClick = {
                                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                            showMenu = true
                                        }
                                )
        ) {
            coil.compose.AsyncImage(
                    model = url,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.width(280.dp).heightIn(min = 120.dp, max = 360.dp)
            )
            if (timeText.isNotEmpty()) {
                Box(
                        modifier =
                                Modifier.align(Alignment.BottomEnd)
                                        .padding(6.dp)
                                        .clip(RoundedCornerShape(10.dp))
                                        .background(Color.Black.copy(alpha = 0.55f))
                                        .padding(horizontal = 6.dp, vertical = 2.dp)
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(text = timeText, fontSize = 10.sp, color = Color.White)
                        if (isSentByMe) {
                            if (message.status == Message.STATUS_SEND_FAILED) {
                                Spacer(modifier = Modifier.width(4.dp))
                                Text(
                                        text = "!",
                                        color = danger,
                                        fontSize = 10.sp,
                                        fontWeight = FontWeight.Bold
                                )
                            } else {
                                Spacer(modifier = Modifier.width(4.dp))
                                val isDouble =
                                        message.status == Message.STATUS_SEND_RECEIVED ||
                                                message.status == Message.STATUS_SEND_DISPLAYED
                                PenikTicksIcon(
                                        double = isDouble,
                                        read = message.status == Message.STATUS_SEND_DISPLAYED,
                                        tint = Color.White.copy(alpha = 0.8f),
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

    if (showViewer) {
        PenikImageViewer(
                model = url,
                message = message,
                listener = listener,
                onDismiss = { showViewer = false }
        )
    }
}

@Composable
fun PenikImageThumb(message: Message, activity: XmppActivity, fgColor: Color) {
    val service = activity.xmppConnectionService
    var bitmap by remember(message.uuid) { mutableStateOf<Bitmap?>(null) }
    val localFile = remember(message.uuid) {
        service?.fileBackend?.getFile(message, false)?.takeIf { it.exists() }
    }
    LaunchedEffect(message.uuid) {
        if (service == null || localFile != null) {
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
    val modifier =
            if (aspect > 0f) {
                Modifier.width(280.dp).aspectRatio(aspect)
            } else {
                Modifier.widthIn(max = 280.dp).heightIn(min = 120.dp, max = 360.dp)
            }

    if (localFile != null) {
        coil.compose.AsyncImage(
                model = localFile,
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = modifier
        )
    } else if (loaded != null) {
        Image(
                bitmap = loaded.asImageBitmap(),
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = modifier
        )
    } else if (params?.url != null) {
        coil.compose.AsyncImage(
                model = params.url,
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = modifier
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
fun PenikVideoThumb(message: Message, activity: XmppActivity, fgColor: Color) {
    val service = activity.xmppConnectionService
    var bitmap by remember(message.uuid) { mutableStateOf<Bitmap?>(null) }
    val localFile = remember(message.uuid) {
        service?.fileBackend?.getFile(message, false)?.takeIf { it.exists() }
    }
    LaunchedEffect(message.uuid) {
        if (service == null) return@LaunchedEffect
        bitmap = withContext(Dispatchers.IO) {
            try {
                service.fileBackend.getThumbnail(message, 640, false)
            } catch (e: Exception) {
                null
            }
        }
    }
    val loaded = bitmap
    val params = message.fileParams
    val aspect = if (params != null && params.width > 0 && params.height > 0) {
        (params.width.toFloat() / params.height.toFloat()).coerceIn(0.4f, 2.5f)
    } else {
        0f
    }
    val modifier = if (aspect > 0f) {
        Modifier.width(280.dp).aspectRatio(aspect)
    } else {
        Modifier.widthIn(max = 280.dp).heightIn(min = 140.dp, max = 360.dp)
    }

    Box(contentAlignment = Alignment.Center) {
        if (loaded != null) {
            Image(
                    bitmap = loaded.asImageBitmap(),
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = modifier
            )
        } else if (localFile != null) {
            coil.compose.AsyncImage(
                    model = localFile,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = modifier
            )
        } else {
            Box(
                    modifier = modifier
                            .background(Color(0xFF1E232B)),
                    contentAlignment = Alignment.Center
            ) {
                Icon(
                        imageVector = Icons.Default.PlayCircle,
                        contentDescription = null,
                        tint = Color.White.copy(alpha = 0.5f),
                        modifier = Modifier.size(54.dp)
                )
            }
        }

        // Center play circle
        Box(
                modifier = Modifier
                        .size(48.dp)
                        .clip(CircleShape)
                        .background(Color.Black.copy(alpha = 0.55f)),
                contentAlignment = Alignment.Center
        ) {
            Icon(
                    imageVector = Icons.Default.PlayArrow,
                    contentDescription = "Воспроизвести",
                    tint = Color.White,
                    modifier = Modifier.size(28.dp)
            )
        }

        // Duration badge (bottom-left)
        if (params != null && params.runtime > 0) {
            val runtimeSec = if (params.runtime >= 1000) params.runtime / 1000 else params.runtime
            val durText = "%02d:%02d".format(runtimeSec / 60, runtimeSec % 60)
            Box(
                    modifier = Modifier
                            .align(Alignment.BottomStart)
                            .padding(6.dp)
                            .clip(RoundedCornerShape(6.dp))
                            .background(Color.Black.copy(alpha = 0.6f))
                            .padding(horizontal = 6.dp, vertical = 2.dp)
            ) {
                Text(
                        text = durText,
                        color = Color.White,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Medium
                )
            }
        }
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
                val runtimeSec = if (params.runtime >= 1000) params.runtime / 1000 else params.runtime
                " · %02d:%02d".format(runtimeSec / 60, runtimeSec % 60)
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
