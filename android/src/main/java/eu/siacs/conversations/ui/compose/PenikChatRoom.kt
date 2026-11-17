package eu.siacs.conversations.ui.compose

import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import android.content.Context
import android.graphics.Bitmap
import android.util.Log
import android.util.Patterns
import eu.siacs.conversations.ui.util.PenikAudioWaveformExtractor
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
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.ClickableText
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.automirrored.filled.Reply
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Done
import androidx.compose.material.icons.filled.DoneAll
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.snapshotFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.neverEqualPolicy
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
import androidx.compose.ui.platform.LocalDensity
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
import eu.siacs.conversations.entities.Sticker
import eu.siacs.conversations.entities.Transferable
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
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
import androidx.compose.material.icons.filled.Repeat
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.unit.IntOffset
import kotlin.math.roundToInt
import androidx.compose.ui.viewinterop.AndroidView
import android.net.Uri
import java.io.File
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import eu.siacs.conversations.ui.XmppActivity
import eu.siacs.conversations.ui.YuriLauncherActivity
import eu.siacs.conversations.ui.adapter.MessageAdapter
import eu.siacs.conversations.utils.UIHelper
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import androidx.compose.ui.res.stringResource
import coil.compose.AsyncImage
import coil.decode.VideoFrameDecoder
import coil.request.ImageRequest

fun penikHandleUrlClick(activity: XmppActivity, rawUrl: String, fallbackUriHandler: androidx.compose.ui.platform.UriHandler? = null) {
    val trimmed = rawUrl.trim()
    val lower = trimmed.lowercase()
    if (lower.startsWith("xmpp:") || trimmed.contains("/invite/") || lower.startsWith("https://snikket.penik.ru") || lower.startsWith("http://snikket.penik.ru") || lower.startsWith("https://penik.ru") || lower.startsWith("http://penik.ru")) {
        try {
            val intent = android.content.Intent(activity, YuriLauncherActivity::class.java).apply {
                data = Uri.parse(trimmed)
            }
            activity.startActivity(intent)
            return
        } catch (ignored: Exception) {}
    }
    try {
        if (fallbackUriHandler != null) {
            fallbackUriHandler.openUri(trimmed)
        } else {
            val intent = android.content.Intent(android.content.Intent.ACTION_VIEW, Uri.parse(trimmed))
            activity.startActivity(intent)
        }
    } catch (e: Exception) {
        try {
            val intent = android.content.Intent(android.content.Intent.ACTION_VIEW, Uri.parse(trimmed))
            activity.startActivity(intent)
        } catch (ignored: Exception) {}
    }
}

interface PenikChatListener {
    fun onMessageAction(action: String, message: Message)
    fun onLoadMore()
    fun onBottomVisible(uuid: String)
    fun onAvatarClick(message: Message) {}
    fun onPickPhotoOrVideo() {}
    fun onPickDocument() {}
    fun onTakePhoto() {}
    fun onSendRecentMedias(uris: @JvmSuppressWildcards List<Uri>) {}
    fun onSendSticker(sticker: eu.siacs.conversations.entities.Sticker) {}
    fun onQuoteTargetNotFound(quote: String, currentMsg: Message) {}
    fun onBotButtonClick(message: Message, button: eu.siacs.conversations.entities.BotMarkup.Button) {}
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
    var messages by mutableStateOf<ImmutableList<ChatMessageUi>>(persistentListOf())
    var isMuc by mutableStateOf(false)
    var showAvatars11 by mutableStateOf(true)
    var showAttachmentPicker by mutableStateOf(false)
    var showStickerPicker by mutableStateOf(false)
    var stickerServerUrl by mutableStateOf("")
    var stickerAuthToken by mutableStateOf("")
    var pendingScrollTargetUuid by mutableStateOf<String?>(null)

    fun update(newMessages: ImmutableList<ChatMessageUi>, muc: Boolean, avatars11: Boolean = true) {
        messages = newMessages
        isMuc = muc
        showAvatars11 = avatars11
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

    @JvmStatic
    fun renderBotReplyKeyboard(
            view: ComposeView,
            markup: eu.siacs.conversations.entities.BotMarkup,
            onButtonClick: java.util.function.Consumer<eu.siacs.conversations.entities.BotMarkup.Button>
    ) {
        view.setContent {
            PenikBotReplyKeyboard(
                    markup = markup,
                    onButtonClick = { onButtonClick.accept(it) }
            )
        }
    }
}

private sealed interface ChatRow {
    val rowKey: String
    data class DateHeader(val label: String, val key: LocalDate, override val rowKey: String) : ChatRow
    data class Msg(
        val message: ChatMessageUi,
        override val rowKey: String
    ) : ChatRow
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

fun penikLinkified(text: String, linkColor: Color, onLinkClick: ((String) -> Unit)? = null) =
        buildAnnotatedString {
            val xmppPattern = java.util.regex.Pattern.compile("(xmpp:[^\\s\"'<>()]+)", java.util.regex.Pattern.CASE_INSENSITIVE)
            val patterns =
                    listOf(
                            xmppPattern to { m: String -> m },
                            android.util.Patterns.WEB_URL to
                                    { m: String ->
                                        if (m.startsWith("http://", ignoreCase = true) || m.startsWith("https://", ignoreCase = true)) m
                                        else "https://$m"
                                    },
                            android.util.Patterns.EMAIL_ADDRESS to
                                    { m: String ->
                                        if (m.startsWith("mailto:", ignoreCase = true)) m
                                        else "mailto:$m"
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
                pushLink(
                    LinkAnnotation.Url(
                        url = span.url,
                        linkInteractionListener = onLinkClick?.let { listener ->
                            { link ->
                                val clickedUrl = (link as? LinkAnnotation.Url)?.url ?: span.url
                                listener(clickedUrl)
                            }
                        }
                    )
                )
                withStyle(SpanStyle(color = linkColor)) { append(span.display) }
                pop()
                last = span.end
            }
            if (last < text.length) {
                append(text.substring(last))
            }
        }

val LocalPenikChatListener = compositionLocalOf<PenikChatListener> { error("No PenikChatListener provided") }
val LocalQuoteScrollHandler = compositionLocalOf<((String, Message) -> Unit)?> { null }
val LocalHighlightedMessageUuid = compositionLocalOf<String?> { null }

@Composable
fun PenikChatRoom(
        state: PenikChatState,
        activity: XmppActivity,
        listener: PenikChatListener
) {
    DisposableEffect(Unit) {
        onDispose {
            PenikVoicePlayer.stop()
            PenikVideoNotePlayer.stop()
        }
    }
    val background = colorResource(R.color.penik_background)
    val scope = rememberCoroutineScope()
    val listState = rememberLazyListState()
    val rows =
            remember(state.messages) {
                val items = ArrayList<ChatRow>(state.messages.size + 16)
                val seenRowKeys = HashSet<String>()
                var lastDay: LocalDate? = null
                for (m in state.messages) {
                    if (m.timeSent > 0) {
                        val day =
                                Instant.ofEpochMilli(m.timeSent)
                                        .atZone(ZoneId.systemDefault())
                                        .toLocalDate()
                        if (day != lastDay) {
                            lastDay = day
                            var hKey = "date-$day"
                            if (!seenRowKeys.add(hKey)) {
                                hKey = "$hKey-${items.size}"
                                seenRowKeys.add(hKey)
                            }
                            items.add(ChatRow.DateHeader(penikChatDateLabel(day), day, hKey))
                        }
                    }
                    var mKey = m.rowKey
                    if (!seenRowKeys.add(mKey)) {
                        mKey = "$mKey-${m.timeSent}-${items.size}"
                        seenRowKeys.add(mKey)
                    }
                    items.add(ChatRow.Msg(message = m, rowKey = mKey))
                }
                items.asReversed()
            }

    val callbacks = remember(listener, activity) {
        PenikChatCallbacks(
            onAction = { action, uuid ->
                val conv = activity.xmppConnectionService?.findConversationByUuid(state.messages.firstOrNull()?.conversationUuid ?: "")
                val msg = conv?.findMessageWithUuid(uuid)
                if (msg != null) {
                    listener.onMessageAction(action, msg)
                }
            },
            onAvatarClick = { uuid ->
                val conv = activity.xmppConnectionService?.findConversationByUuid(state.messages.firstOrNull()?.conversationUuid ?: "")
                val msg = conv?.findMessageWithUuid(uuid)
                if (msg != null) {
                    listener.onAvatarClick(msg)
                }
            },
            onQuoteClick = { quote, currentUuid ->
                val conv = activity.xmppConnectionService?.findConversationByUuid(state.messages.firstOrNull()?.conversationUuid ?: "")
                val currentMsg = conv?.findMessageWithUuid(currentUuid)
                if (currentMsg != null) {
                    listener.onQuoteTargetNotFound(quote, currentMsg)
                }
            },
            onBotButtonClick = { uuid, button ->
                val conv = activity.xmppConnectionService?.findConversationByUuid(state.messages.firstOrNull()?.conversationUuid ?: "")
                val msg = conv?.findMessageWithUuid(uuid)
                if (msg != null) {
                    listener.onBotButtonClick(msg, button)
                }
            }
        )
    }
    val showScrollDown by remember {
        derivedStateOf {
            listState.firstVisibleItemIndex > 2
        }
    }
    val isAtBottom by remember {
        derivedStateOf {
            listState.firstVisibleItemIndex == 0
        }
    }

    val newestUuid = (rows.firstOrNull() as? ChatRow.Msg)?.message?.uuid
    LaunchedEffect(newestUuid) {
        if (listState.firstVisibleItemIndex <= 2 && rows.isNotEmpty()) {
            listState.scrollToItem(0)
        }
        if (!newestUuid.isNullOrBlank()) {
            listener.onBottomVisible(newestUuid)
        }
    }
    LaunchedEffect(listState, state.messages.size) {
        snapshotFlow {
            val layoutInfo = listState.layoutInfo
            val totalItems = layoutInfo.totalItemsCount
            val lastVisibleIndex = layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0
            totalItems > 0 && lastVisibleIndex >= totalItems - 8
        }
        .distinctUntilChanged()
        .collect { shouldLoad ->
            if (shouldLoad) {
                listener.onLoadMore()
            }
        }
    }
    LaunchedEffect(isAtBottom, newestUuid) {
        if (isAtBottom) {
            val newest = rows.firstOrNull()
            if (newest is ChatRow.Msg) {
                val uuid = newest.message.uuid
                if (!uuid.isNullOrBlank()) {
                    listener.onBottomVisible(uuid)
                }
            }
        }
    }

    var highlightedMessageUuid by remember { mutableStateOf<String?>(null) }
    var highlightJob by remember { mutableStateOf<Job?>(null) }
    val jumpOriginUuids = remember { mutableStateListOf<String>() }

    LaunchedEffect(isAtBottom) {
        if (isAtBottom) {
            jumpOriginUuids.clear()
        }
    }

    suspend fun smoothScrollTo(targetIndex: Int, targetMsg: ChatMessageUi? = null) {
        val maxIdx = (rows.size - 1).coerceAtLeast(0)
        val validTarget = targetIndex.coerceIn(0, maxIdx)
        val currentIndex = listState.firstVisibleItemIndex
        val distance = kotlin.math.abs(validTarget - currentIndex)
        if (distance > 3) {
            val preIndex = if (validTarget > currentIndex) validTarget - 2 else validTarget + 2
            listState.scrollToItem(preIndex.coerceIn(0, maxIdx))
        }
        listState.animateScrollToItem(validTarget)
        if (targetMsg != null) {
            highlightJob?.cancel()
            highlightJob = scope.launch {
                highlightedMessageUuid = targetMsg.uuid
                delay(1400)
                if (highlightedMessageUuid == targetMsg.uuid) {
                    highlightedMessageUuid = null
                }
            }
        }
    }

    LaunchedEffect(rows, state.pendingScrollTargetUuid) {
        val targetUuid = state.pendingScrollTargetUuid
        if (!targetUuid.isNullOrBlank() && rows.isNotEmpty()) {
            val matchedIndex = rows.indexOfFirst { it is ChatRow.Msg && it.message.uuid == targetUuid }
            if (matchedIndex >= 0) {
                state.pendingScrollTargetUuid = null
                val targetMsg = (rows.getOrNull(matchedIndex) as? ChatRow.Msg)?.message
                highlightJob?.cancel()
                highlightJob = scope.launch {
                    smoothScrollTo(matchedIndex, targetMsg)
                }
            }
        }
    }

    val onQuoteClick: (String, Message) -> Unit = remember(rows) {
        { quote, currentMsg ->
            val matchedIndex = findPenikQuotedMessageIndex(rows, currentMsg, quote)
            if (matchedIndex != null) {
                currentMsg.uuid?.let { jumpOriginUuids.add(it) }
                val targetMsg = (rows.getOrNull(matchedIndex) as? ChatRow.Msg)?.message
                highlightJob?.cancel()
                highlightJob = scope.launch {
                    smoothScrollTo(matchedIndex, targetMsg)
                }
            } else {
                listener.onQuoteTargetNotFound(quote, currentMsg)
            }
        }
    }

    val defaultUriHandler = LocalUriHandler.current
    val customUriHandler = remember(activity, defaultUriHandler) {
        object : androidx.compose.ui.platform.UriHandler {
            override fun openUri(uri: String) {
                penikHandleUrlClick(activity, uri, defaultUriHandler)
            }
        }
    }
    val hasReturnOrigin by remember {
        derivedStateOf { jumpOriginUuids.isNotEmpty() }
    }
    CompositionLocalProvider(
            LocalPenikChatListener provides listener,
            LocalUriHandler provides customUriHandler,
            LocalQuoteScrollHandler provides onQuoteClick,
            LocalHighlightedMessageUuid provides highlightedMessageUuid
    ) {
        Scaffold(
                containerColor = background,
                floatingActionButton = {
                    if (showScrollDown) {
                        FloatingActionButton(
                                onClick = {
                                    highlightJob?.cancel()
                                    highlightJob = scope.launch {
                                        val originUuid = if (jumpOriginUuids.isNotEmpty()) jumpOriginUuids.removeLastOrNull() else null
                                        val matchedIndex = if (originUuid != null) {
                                            rows.indexOfFirst { it is ChatRow.Msg && it.message.uuid == originUuid }
                                        } else -1

                                        val targetIndex = if (matchedIndex >= 0) matchedIndex else 0
                                        val targetMsg = if (matchedIndex >= 0) (rows.getOrNull(matchedIndex) as? ChatRow.Msg)?.message else null

                                        smoothScrollTo(targetIndex, targetMsg)
                                    }
                                },
                                containerColor = colorResource(R.color.penik_panel_secondary),
                                contentColor = colorResource(R.color.penik_text_primary),
                                modifier = Modifier.size(44.dp)
                        ) {
                            Icon(
                                    painter =
                                            painterResource(
                                                    if (hasReturnOrigin) {
                                                        R.drawable.ic_reply_24dp
                                                    } else {
                                                        R.drawable.ic_keyboard_double_arrow_down_24dp
                                                    }
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
                items(
                        items = rows,
                        key = { row -> row.rowKey },
                        contentType = { row ->
                            when (row) {
                                is ChatRow.DateHeader -> "date_header"
                                is ChatRow.Msg -> "msg_row"
                            }
                        }
                ) { row ->
                    when (row) {
                        is ChatRow.DateHeader -> PenikDateHeader(label = row.label)
                        is ChatRow.Msg ->
                                PenikMessageRow(
                                        item = row.message,
                                        activity = activity,
                                        isMuc = state.isMuc,
                                        showAvatars11 = state.showAvatars11,
                                        callbacks = callbacks
                                )
                    }
                }
            }
        }
    }

    if (state.showAttachmentPicker) {
        PenikAttachmentPickerBottomSheet(
            onDismiss = { state.showAttachmentPicker = false },
            onPickPhotoOrVideo = {
                state.showAttachmentPicker = false
                listener.onPickPhotoOrVideo()
            },
            onPickDocument = {
                state.showAttachmentPicker = false
                listener.onPickDocument()
            },
            onTakePhoto = {
                state.showAttachmentPicker = false
                listener.onTakePhoto()
            },
            onSendRecentMedias = { uris ->
                state.showAttachmentPicker = false
                listener.onSendRecentMedias(uris)
            }
        )
    }

    if (state.showStickerPicker) {
        PenikStickerPickerBottomSheet(
            serverBaseUrl = state.stickerServerUrl,
            authToken = state.stickerAuthToken,
            onDismiss = { state.showStickerPicker = false },
            onStickerPicked = { sticker ->
                state.showStickerPicker = false
                listener.onSendSticker(sticker)
            }
        )
    }
}



fun penikBareImageUrl(text: String): String? {
    val trimmed = text.trim()
    if (trimmed.isEmpty() || trimmed.contains("\n") || trimmed.contains(" ")) {
        return null
    }
    val cleanUrl = (if (trimmed.startsWith("aesgcm://", ignoreCase = true)) trimmed.substring("aesgcm://".length) else trimmed).substringBefore("|").trim()
    if (!cleanUrl.startsWith("http://", ignoreCase = true) && !cleanUrl.startsWith("https://", ignoreCase = true)) {
        return null
    }
    val lower = cleanUrl.lowercase().substringBefore("?").substringBefore("#")
    return if (lower.endsWith(".jpg") ||
                    lower.endsWith(".jpeg") ||
                    lower.endsWith(".png") ||
                    lower.endsWith(".gif") ||
                    lower.endsWith(".webp")
    ) {
        cleanUrl
    } else {
        null
    }
}

fun penikBareVideoUrl(text: String): String? {
    val trimmed = text.trim()
    if (trimmed.isEmpty() || trimmed.contains("\n") || trimmed.contains(" ")) {
        return null
    }
    val cleanUrl = (if (trimmed.startsWith("aesgcm://", ignoreCase = true)) trimmed.substring("aesgcm://".length) else trimmed).substringBefore("|").trim()
    if (!cleanUrl.startsWith("http://", ignoreCase = true) && !cleanUrl.startsWith("https://", ignoreCase = true)) {
        return null
    }
    val lower = cleanUrl.lowercase().substringBefore("?").substringBefore("#")
    return if (lower.endsWith(".mp4") ||
                    lower.endsWith(".webm") ||
                    lower.endsWith(".mov") ||
                    lower.endsWith(".mkv") ||
                    lower.endsWith(".3gp") ||
                    lower.endsWith(".avi")
    ) {
        cleanUrl
    } else {
        null
    }
}

fun penikBareAudioUrl(text: String): String? {
    val trimmed = text.trim()
    if (trimmed.isEmpty() || trimmed.contains("\n") || trimmed.contains(" ")) {
        return null
    }
    val cleanUrl = (if (trimmed.startsWith("aesgcm://", ignoreCase = true)) trimmed.substring("aesgcm://".length) else trimmed).substringBefore("|").trim()
    if (!cleanUrl.startsWith("http://", ignoreCase = true) && !cleanUrl.startsWith("https://", ignoreCase = true)) {
        return null
    }
    val lower = cleanUrl.lowercase().substringBefore("?").substringBefore("#")
    return if (lower.endsWith(".ogg") ||
                    lower.endsWith(".opus") ||
                    lower.endsWith(".m4a") ||
                    lower.endsWith(".mp3") ||
                    lower.endsWith(".wav") ||
                    lower.endsWith(".aac")
    ) {
        cleanUrl
    } else {
        null
    }
}

fun penikIsAudio(message: Message): Boolean {
    if (message.isGeoUri) return false
    val mime = message.mimeType ?: ""
    if (mime.startsWith("audio/") || mime == "application/ogg") return true
    val body = message.body ?: ""
    val cleanUrl = (if (body.startsWith("aesgcm://", ignoreCase = true)) body.substring("aesgcm://".length) else body).substringBefore("|").trim()
    val lower = cleanUrl.lowercase().substringBefore("?").substringBefore("#")
    return lower.endsWith(".ogg") ||
            lower.endsWith(".opus") ||
            lower.endsWith(".m4a") ||
            lower.endsWith(".mp3") ||
            lower.endsWith(".wav") ||
            lower.endsWith(".aac")
}

fun penikIsVideo(message: Message): Boolean {
    if (message.isGeoUri) return false
    val mime = message.mimeType ?: ""
    if (mime.startsWith("video/")) return true
    val path = (message.relativeFilePath?.file?.name ?: "").lowercase()
    if (path.endsWith(".mp4") || path.endsWith(".webm") || path.endsWith(".mov")) return true
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

fun penikIsVideoNote(message: Message): Boolean {
    if (!penikIsVideo(message)) return false
    val path = (message.relativeFilePath?.file?.name ?: "").lowercase()
    if (path.contains("video_note") || path.contains("videonote") || path.contains("round_video")) {
        return true
    }
    val url = (message.fileParams?.url ?: message.body ?: "").lowercase()
    if (url.contains("video_note") || url.contains("videonote") || url.contains("round_video")) {
        return true
    }
    val params = message.fileParams
    if (params != null && params.width > 0 && params.height > 0) {
        val ratio = params.width.toFloat() / params.height.toFloat()
        if (ratio in 0.92f..1.08f) {
            return true
        }
    }
    return false
}

@Composable
fun PenikSwipeToReplyWrapper(
        uuid: String,
        onSwipeReply: () -> Unit,
        content: @Composable () -> Unit
) {
    val coroutineScope = rememberCoroutineScope()
    val offsetX = remember(uuid) { Animatable(0f) }
    val density = LocalDensity.current
    val triggerThresholdPx = with(density) { 60.dp.toPx() }
    val maxDragPx = with(density) { 92.dp.toPx() }
    val haptic = LocalHapticFeedback.current
    var hasVibrated by remember(uuid) { mutableStateOf(false) }

    Box(
            modifier =
                    Modifier.fillMaxWidth().pointerInput(uuid) {
                        awaitEachGesture {
                            val down = awaitFirstDown(requireUnconsumed = false)
                            val touchSlop = viewConfiguration.touchSlop
                            var totalDx = 0f
                            var totalDy = 0f
                            var isSwipingLeft = false

                            try {
                                while (true) {
                                    val event = awaitPointerEvent()
                                    val change = event.changes.firstOrNull { it.id == down.id } ?: break
                                    if (!change.pressed) {
                                        if (isSwipingLeft) {
                                            val triggered = -offsetX.value >= triggerThresholdPx
                                            coroutineScope.launch {
                                                offsetX.animateTo(
                                                        targetValue = 0f,
                                                        animationSpec =
                                                                spring(
                                                                        dampingRatio = Spring.DampingRatioMediumBouncy,
                                                                        stiffness = Spring.StiffnessLow
                                                                )
                                                )
                                            }
                                            if (triggered) {
                                                onSwipeReply()
                                            }
                                            hasVibrated = false
                                        }
                                        break
                                    }

                                    val dragDelta = change.positionChange()
                                    if (!isSwipingLeft) {
                                        totalDx += dragDelta.x
                                        totalDy += dragDelta.y
                                        if (totalDx < -touchSlop && kotlin.math.abs(totalDx) > kotlin.math.abs(totalDy)) {
                                            isSwipingLeft = true
                                            change.consume()
                                            val initialDelta = totalDx + touchSlop
                                            val newTarget = (offsetX.value + initialDelta).coerceAtMost(0f)
                                            coroutineScope.launch { offsetX.snapTo(newTarget) }
                                        } else if (kotlin.math.abs(totalDy) > touchSlop || totalDx > touchSlop) {
                                            break
                                        }
                                    } else {
                                        change.consume()
                                        val newTarget = offsetX.value + dragDelta.x
                                        val clampedTarget =
                                                if (newTarget > 0f) {
                                                    0f
                                                } else if (-newTarget > triggerThresholdPx) {
                                                    val excess = -newTarget - triggerThresholdPx
                                                    -(triggerThresholdPx + excess * 0.3f).coerceAtMost(maxDragPx)
                                                } else {
                                                    newTarget
                                                }

                                        coroutineScope.launch { offsetX.snapTo(clampedTarget) }

                                        if (-clampedTarget >= triggerThresholdPx && !hasVibrated) {
                                            hasVibrated = true
                                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                        } else if (-clampedTarget < triggerThresholdPx && hasVibrated) {
                                            hasVibrated = false
                                        }
                                    }
                                }
                            } finally {
                                if (isSwipingLeft && offsetX.value != 0f) {
                                    coroutineScope.launch {
                                        offsetX.animateTo(
                                                targetValue = 0f,
                                                animationSpec =
                                                        spring(
                                                                dampingRatio = Spring.DampingRatioMediumBouncy,
                                                                stiffness = Spring.StiffnessLow
                                                        )
                                        )
                                    }
                                    hasVibrated = false
                                }
                            }
                        }
                    }
    ) {
        val currentOffset = offsetX.value
        if (currentOffset < -1f) {
            val progress = (-currentOffset / triggerThresholdPx).coerceIn(0f, 1f)
            val isReady = -currentOffset >= triggerThresholdPx
            val accentColor = colorResource(R.color.penik_accent)
            val defaultBg = colorResource(R.color.penik_panel_secondary)

            Box(
                    modifier =
                            Modifier.align(Alignment.CenterEnd)
                                    .padding(end = 16.dp)
                                    .size(36.dp)
                                    .graphicsLayer {
                                        scaleX = 0.5f + progress * 0.5f
                                        scaleY = 0.5f + progress * 0.5f
                                        alpha = progress
                                        rotationZ = (1f - progress) * -45f
                                    }
                                    .background(
                                            color = if (isReady) accentColor else defaultBg.copy(alpha = 0.85f),
                                            shape = CircleShape
                                    ),
                    contentAlignment = Alignment.Center
            ) {
                Icon(
                        imageVector = Icons.AutoMirrored.Filled.Reply,
                        contentDescription = "Ответить",
                        tint = if (isReady) Color.White else colorResource(R.color.penik_text_primary),
                        modifier = Modifier.size(20.dp)
                )
            }
        }

        Box(
                modifier =
                        Modifier.fillMaxWidth().offset {
                            IntOffset(offsetX.value.roundToInt(), 0)
                        }
        ) {
            content()
        }
    }
}



@OptIn(ExperimentalFoundationApi::class)
@Composable
fun PenikMessageRow(
        item: ChatMessageUi,
        activity: XmppActivity,
        isMuc: Boolean,
        showAvatars11: Boolean,
        callbacks: PenikChatCallbacks
) {
    if (item.type == Message.TYPE_RTP_SESSION) {
        val conv = activity.xmppConnectionService?.findConversationByUuid(item.conversationUuid)
        val message = conv?.findMessageWithUuid(item.uuid)
        if (message != null) {
            PenikCallCard(message = message, activity = activity, listener = LocalPenikChatListener.current)
        }
        return
    }
    if (item.type == Message.TYPE_STATUS) {
        PenikStatusRow(text = item.body)
        return
    }
    val body = item.body
    if (body == MessageAdapter.BODY_DATE_SEPARATOR ||
                    body == MessageAdapter.BODY_LOAD_MORE ||
                    body == MessageAdapter.BODY_LOCAL_TIME ||
                    body == MessageAdapter.BODY_DND
    ) {
        return
    }
    val isSentByMe = item.isSentByMe
    val showAvatar = !isSentByMe && (isMuc || showAvatars11)
    val highlightedUuid = LocalHighlightedMessageUuid.current
    val isHighlighted = highlightedUuid != null && highlightedUuid == item.uuid
    val highlightAlpha by animateFloatAsState(
            targetValue = if (isHighlighted) 0.38f else 0f,
            animationSpec = tween(durationMillis = 280),
            label = "quote_highlight"
    )
    val listener = LocalPenikChatListener.current

    PenikSwipeToReplyWrapper(
            uuid = item.uuid,
            onSwipeReply = { callbacks.onAction(PenikChatActions.QUOTE, item.uuid) }
    ) {
        Row(
                modifier =
                        Modifier.fillMaxWidth()
                                .padding(horizontal = 4.dp, vertical = 1.dp)
                                .drawBehind {
                                    if (highlightAlpha > 0f) {
                                        drawRoundRect(
                                                color = Color(0xFFFFA000).copy(alpha = highlightAlpha),
                                                cornerRadius = CornerRadius(12.dp.toPx())
                                        )
                                    }
                                },
                horizontalArrangement = if (isSentByMe) Arrangement.End else Arrangement.Start,
                verticalAlignment = Alignment.Bottom
        ) {
            val conv = activity.xmppConnectionService?.findConversationByUuid(item.conversationUuid)
            val message = conv?.findMessageWithUuid(item.uuid)

            if (showAvatar) {
                val context = LocalContext.current
                val density = context.resources.displayMetrics.density
                val sizePx = (28 * density).toInt()
                val cachedAvatar = remember(item.uuid) {
                    try {
                        if (message != null) activity.avatarService()?.get(message, sizePx, true) else null
                    } catch (e: Exception) {
                        null
                    }
                }
                var avatarBitmap by remember(item.uuid) { mutableStateOf(cachedAvatar) }
                LaunchedEffect(item.uuid) {
                    val loaded = withContext(Dispatchers.IO) {
                        try {
                            if (message != null) activity.avatarService()?.get(message, sizePx, false) else null
                        } catch (e: Exception) {
                            null
                        }
                    }
                    if (loaded != null) {
                        avatarBitmap = loaded
                    }
                }
                PenikAvatarImage(
                        name = item.senderName,
                        bitmap = avatarBitmap,
                        backgroundColor = Color(item.avatarBackgroundColor),
                        size = 28.dp,
                        modifier = Modifier.clip(CircleShape).clickable { callbacks.onAvatarClick(item.uuid) }
                )
                Spacer(modifier = Modifier.width(4.dp))
            }

            if (message == null) return@Row

            Box(
                    modifier = Modifier.weight(1f, fill = false),
                    contentAlignment = if (isSentByMe) Alignment.CenterEnd else Alignment.CenterStart
            ) {
                Column(
                    modifier = Modifier.width(IntrinsicSize.Max),
                    horizontalAlignment = if (isSentByMe) Alignment.End else Alignment.Start
                ) {
                    val isStickerMsg = item.isSticker || (body.startsWith("{\"pack_id\":") && body.contains("\"sticker_id\":"))
                    if (isStickerMsg) {
                        val timeFormat = remember { android.text.format.DateFormat.getTimeFormat(activity) }
                        val timeText = if (item.timeSent > 0) timeFormat.format(java.util.Date(item.timeSent)) else ""
                        var showMenu by remember(item.uuid) { mutableStateOf(false) }
                        val haptic = LocalHapticFeedback.current
                        Box {
                            PenikStickerBubble(
                                message = message,
                                isSentByMe = isSentByMe,
                                timeText = timeText,
                                onClick = {},
                                onLongClick = {
                                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                    showMenu = true
                                }
                            )
                            if (showMenu) {
                                PenikMessageMenu(
                                    message = message,
                                    isSentByMe = isSentByMe,
                                    onDismiss = { showMenu = false },
                                    onAction = {
                                        showMenu = false
                                        callbacks.onAction(it, item.uuid)
                                    }
                                )
                            }
                        }
                    } else if (item.type == Message.TYPE_TEXT) {
                        val bareUrl = remember(body) { penikBareImageUrl(body) }
                        if (bareUrl != null) {
                            PenikUrlImageRow(
                                    url = bareUrl,
                                    message = message,
                                    status = item.status,
                                    isSentByMe = isSentByMe,
                                    listener = listener
                            )
                        } else {
                            val bareVideoUrl = remember(body) { penikBareVideoUrl(body) }
                            val bareAudioUrl = remember(body) { penikBareAudioUrl(body) }
                            if (bareVideoUrl != null || bareAudioUrl != null) {
                                PenikAttachmentRow(
                                        message = message,
                                        status = item.status,
                                        activity = activity,
                                        isSentByMe = isSentByMe,
                                        listener = listener
                                )
                            } else {
                                PenikTextBubble(
                                        message = message,
                                        status = item.status,
                                        edited = item.isEdited,
                                        activity = activity,
                                        isMuc = isMuc,
                                        listener = listener
                                )
                            }
                        }
                    } else if (message.isFileOrImage || item.isGeoUri || penikIsVideo(message)) {
                        PenikAttachmentRow(
                                message = message,
                                status = item.status,
                                activity = activity,
                                isSentByMe = isSentByMe,
                                listener = listener
                        )
                    } else {
                        PenikTextBubble(
                                message = message,
                                status = item.status,
                                edited = item.isEdited,
                                activity = activity,
                                isMuc = isMuc,
                                listener = listener
                        )
                    }

                    val markup = message.botMarkup
                    if (markup != null && !markup.isEmpty && markup.isInline) {
                        PenikBotKeyboard(
                                markup = markup,
                                message = message,
                                listener = listener,
                                modifier = Modifier.fillMaxWidth()
                        )
                    }
                }
            }
        }
    }
}

private fun findPenikQuotedMessageIndex(
        rows: List<ChatRow>,
        currentMsg: Message,
        quote: String
): Int? {
    // 1. Direct UUID resolution if available
    val msgUuidRegex = "penik:msg:([a-zA-Z0-9_-]+)".toRegex()
    val targetUuid = msgUuidRegex.find(quote)?.groupValues?.get(1)
    if (targetUuid != null) {
        val exactIndex = rows.indexOfFirst { it is ChatRow.Msg && it.message.uuid == targetUuid }
        if (exactIndex >= 0) {
            return exactIndex
        }
    }

    // Strip invisible/markdown UUID links if present
    val cleanQuote = quote.replace("\\[[^\\]]*\\]\\(penik:msg:[^)]+\\)".toRegex(), "").trim()
    val lines = cleanQuote.lines()
    val firstLine = lines.firstOrNull()?.trim() ?: ""
    val isRawJson = firstLine.startsWith("{")
    val hasColon = !isRawJson && firstLine.contains(": ") &&
            !firstLine.startsWith("http://", ignoreCase = true) &&
            !firstLine.startsWith("https://", ignoreCase = true) &&
            !firstLine.startsWith("aesgcm://", ignoreCase = true) &&
            !firstLine.startsWith("geo:", ignoreCase = true) &&
            !firstLine.startsWith("xmpp:", ignoreCase = true)

    val author = if (hasColon) firstLine.substringBefore(": ").trim().takeIf { it.isNotBlank() } else null
    val content = if (hasColon) {
        val remainder = firstLine.substringAfter(": ").trim()
        (listOf(remainder) + lines.drop(1)).joinToString("\n").trim()
    } else {
        cleanQuote.trim()
    }

    if (content.isEmpty()) return null

    // Detect quote type
    val isStickerQuote = (content.startsWith("{") && content.contains("\"pack_id\"")) ||
            content.contains("Стикер") || content.startsWith("🎨")

    val isPhotoQuote = content.startsWith("📷") || content.contains("Фото")
    val isVoiceQuote = content.startsWith("🎙") || content.contains("Голосовое")
    val isVideoQuote = content.startsWith("🎬") || content.contains("Видео")
    val isFileQuote = content.startsWith("📎")
    val isGeoQuote = content.startsWith("📍") || content.startsWith("geo:")

    val isMediaOrUrlQuote = content.startsWith("http://", ignoreCase = true) ||
            content.startsWith("https://", ignoreCase = true) ||
            content.startsWith("aesgcm://", ignoreCase = true) ||
            content.contains("aesgcm://") ||
            (content.contains("http") && content.contains("|"))

    val stickerIdRegex = "\"sticker_id\"\\s*:\\s*\"([^\"]+)\"".toRegex()
    val stickerId = if (content.contains("\"sticker_id\"")) stickerIdRegex.find(content)?.groupValues?.get(1) else null

    val quoteEmoji: String? = when {
        content.contains("\"emoji\"") -> {
            "\"emoji\"\\s*:\\s*\"([^\"]+)\"".toRegex().find(content)?.groupValues?.get(1)?.trim()
        }
        content.contains("Стикер") -> {
            val emojiPart = content.removeSuffix("Стикер").replace("🎨", "").trim()
            emojiPart.takeIf { it.isNotEmpty() }
        }
        else -> null
    }

    // Clean URL base path for media/link matching (e.g. server.com/upload/abc.jpg)
    val urlBase = if (isMediaOrUrlQuote) {
        val s = if (content.contains("://")) content.substringAfter("://") else content
        s.substringBefore("|").substringBefore("?").substringBefore("#").trim().takeIf { it.isNotBlank() }
    } else null

    fun matchesAuthor(m: ChatMessageUi): Boolean {
        if (author.isNullOrBlank()) return true
        val a = author.lowercase()
        val name1 = m.senderName.lowercase()
        return name1 == a || a == name1 || name1.contains(a) || a.contains(name1)
    }

    fun matchesContent(m: ChatMessageUi): Boolean {
        val b = m.body

        if (isStickerQuote) {
            val isSticker = m.type == Message.TYPE_STICKER || m.isSticker || (b.startsWith("{\"pack_id\":") && b.contains("\"sticker_id\":"))
            if (!isSticker) return false
            if (stickerId != null) return b.contains(stickerId)
            if (quoteEmoji != null) {
                val sticker = eu.siacs.conversations.entities.Sticker.fromJson(b)
                val candEmoji = sticker?.emoji()?.trim()
                return if (!candEmoji.isNullOrEmpty()) {
                    candEmoji == quoteEmoji || candEmoji.contains(quoteEmoji) || quoteEmoji.contains(candEmoji)
                } else {
                    b.contains(quoteEmoji)
                }
            }
            return true
        }

        if (isPhotoQuote) {
            val isPhotoMsg = m.type == Message.TYPE_IMAGE || (m.mimeType.startsWith("image/")) || penikBareImageUrl(b) != null
            if (!isPhotoMsg) return false
            val cleanBody = splitPenikQuote(b).second
            return cleanBody.isBlank() || m.mimeType.startsWith("image/") || penikBareImageUrl(cleanBody) != null
        }

        if (isVoiceQuote) {
            return m.mimeType.startsWith("audio/") || b.contains("voice")
        }

        if (isVideoQuote) {
            return m.mimeType.startsWith("video/")
        }

        if (isFileQuote) {
            return m.mimeType.isNotEmpty() || m.type == Message.TYPE_FILE
        }

        if (isGeoQuote) {
            return m.isGeoUri
        }

        if (urlBase != null) {
            val mFileUrl = m.fileUrl ?: ""
            val cleanBody = splitPenikQuote(b).second
            return cleanBody.contains(urlBase) || mFileUrl.contains(urlBase)
        }

        // Regular text quote: candidate MUST be a text message, NOT an attachment, audio, or sticker
        if (m.type != Message.TYPE_TEXT || m.mimeType.isNotEmpty() || m.isSticker || m.isGeoUri) {
            return false
        }

        val targetText = content.trim()
        val cleanBody = splitPenikQuote(b).second.trim()
        return cleanBody == targetText ||
                cleanBody.startsWith(targetText) ||
                (targetText.length >= 10 && cleanBody.contains(targetText))
    }

    val currentIndex = rows.indexOfFirst { it is ChatRow.Msg && it.message.uuid == currentMsg.uuid }
    val priorIndices = if (currentIndex >= 0) (currentIndex + 1 until rows.size) else rows.indices

    // Pass 1: search prior messages matching BOTH content and author
    for (idx in priorIndices) {
        val row = rows[idx]
        if (row is ChatRow.Msg) {
            val m = row.message
            if (matchesContent(m) && matchesAuthor(m)) {
                return idx
            }
        }
    }

    // Pass 2: if author was specified but no combined match was found, search prior messages matching content only
    if (author != null) {
        for (idx in priorIndices) {
            val row = rows[idx]
            if (row is ChatRow.Msg) {
                val m = row.message
                if (matchesContent(m)) {
                    return idx
                }
            }
        }
    }

    // Pass 3: fallback to newer messages (e.g. clock skew) matching both content and author
    if (currentIndex > 0) {
        for (idx in 0 until currentIndex) {
            val row = rows[idx]
            if (row is ChatRow.Msg) {
                val m = row.message
                if (matchesContent(m) && matchesAuthor(m)) {
                    return idx
                }
            }
        }
    }

    // No match found — DO NOT jump to a random message
    return null
}



@OptIn(ExperimentalFoundationApi::class)
@Composable
fun PenikTextBubble(
        message: Message,
        status: Int = message.status,
        edited: Boolean = message.edited(),
        activity: XmppActivity,
        isMuc: Boolean,
        listener: PenikChatListener,
        revision: Long = 0L
) {
    val context = LocalContext.current
    val quoteScrollHandler = LocalQuoteScrollHandler.current
    val haptic = LocalHapticFeedback.current
    val uriHandler = LocalUriHandler.current
    val sentBg = colorResource(R.color.penik_sent_message_bg)
    val sentText = colorResource(R.color.penik_sent_message_text)
    val recvBg = colorResource(R.color.penik_recv_message_bg)
    val textPrimary = colorResource(R.color.penik_text_primary)
    val textMuted = colorResource(R.color.penik_text_muted)
    val accent = colorResource(R.color.penik_accent)
    val danger = colorResource(R.color.penik_danger)
    val isSentByMe = status != Message.STATUS_RECEIVED
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
                    val effectiveMuted = if (isSentByMe) fgColor.copy(alpha = 0.7f) else textMuted
                    val readAccent = if (isSentByMe && bgColor == accent) Color(0xFF80D8FF) else accent
                    PenikMetaRow(
                            timeText = timeText,
                            isEncrypted = message.encryption != Message.ENCRYPTION_NONE,
                            edited = edited,
                            overlayDark = false,
                            baseColor = effectiveMuted,
                            status = status,
                            isSentByMe = isSentByMe,
                            accent = readAccent
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
                                    isSentByMe = isSentByMe,
                                    onClick = quoteScrollHandler?.let { handler ->
                                        { handler(quote, message) }
                                    }
                            )
                        }
                        val mainText = if (quote != null) rest else rawBody
                        if (mainText.isNotEmpty()) {
                            val annotated = remember(mainText, linkColor, activity) {
                                penikLinkified(mainText, linkColor) { url ->
                                    penikHandleUrlClick(activity, url, uriHandler)
                                }
                            }
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
                                                                        penikHandleUrlClick(activity, (annotation.item as LinkAnnotation.Url).url, uriHandler)
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
                        if (edited) {
                            Text(text = "изм. ", color = textMuted, fontSize = 11.sp)
                        }
                        val effectiveMuted = if (isSentByMe) fgColor.copy(alpha = 0.7f) else textMuted
                        val readAccent = if (isSentByMe && bgColor == accent) Color(0xFF80D8FF) else accent
                        if (message.encryption != Message.ENCRYPTION_NONE) {
                            Icon(
                                    imageVector = Icons.Default.Lock,
                                    contentDescription = null,
                                    tint = effectiveMuted,
                                    modifier = Modifier.size(11.dp)
                            )
                            Spacer(modifier = Modifier.width(3.dp))
                        }
                        if (timeText.isNotEmpty()) {
                            Text(text = timeText, color = effectiveMuted, fontSize = 11.sp)
                        }
                        if (isSentByMe) {
                            Spacer(modifier = Modifier.width(4.dp))
                            PenikMessageStatusIcon(
                                    status = status,
                                    tint = effectiveMuted,
                                    accent = readAccent,
                                    danger = danger
                            )
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



@OptIn(ExperimentalFoundationApi::class)
@Composable
fun PenikCallCard(message: Message, activity: XmppActivity, listener: PenikChatListener) {
    val context = LocalContext.current
    var showMenu by remember { mutableStateOf(false) }
    val haptic = LocalHapticFeedback.current
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

    val seconds =
            if (status.duration > 0) {
                if (message.timeSent < 1791010127000L) {
                    status.duration / 1000
                } else {
                    status.duration
                }
            } else {
                0L
            }
    val durationText =
            if (seconds > 0 && seconds <= 7 * 24 * 3600) {
                val h = seconds / 3600
                val m = (seconds % 3600) / 60
                val s = seconds % 60
                if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
            } else {
                ""
            }

    val mediaText =
            when (status.media) {
                "video" -> context.getString(R.string.video).replaceFirstChar { it.uppercase() }
                else -> context.getString(R.string.audio).replaceFirstChar { it.uppercase() }
            }

    val subtitle =
            when {
                durationText.isNotEmpty() -> "$durationText  $mediaText"
                missed && received -> "Без ответа"
                missed && !received -> "Отменен"
                else -> mediaText
            }

    val bgColor = if (isSentByMe) sentBg else recvBg
    val fgColor = if (isSentByMe) sentText else textPrimary
    val boxAlignment = if (isSentByMe) Alignment.CenterEnd else Alignment.CenterStart
    val iconTint = if (missed) danger else fgColor.copy(alpha = 0.95f)

    Box(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 2.dp),
            contentAlignment = boxAlignment
    ) {
        Row(
                modifier =
                        Modifier.widthIn(min = 190.dp, max = 270.dp)
                                .clip(PenikBubbleShape(isSentByMe = isSentByMe))
                                .background(bgColor)
                                .combinedClickable(
                                        onClick = {},
                                        onLongClick = {
                                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                            showMenu = true
                                        }
                                )
                                .padding(horizontal = 10.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                    modifier =
                            Modifier.size(38.dp)
                                    .clip(CircleShape)
                                    .background(Color.White.copy(alpha = 0.12f)),
                    contentAlignment = Alignment.Center
            ) {
                Box(modifier = Modifier.size(24.dp)) {
                    Icon(
                            painter = painterResource(R.drawable.ic_call_24dp),
                            contentDescription = null,
                            tint = iconTint,
                            modifier = Modifier.size(19.dp).align(Alignment.BottomStart)
                    )
                    Icon(
                            painter =
                                    painterResource(
                                            if (received) {
                                                R.drawable.ic_call_received_24dp
                                            } else {
                                                R.drawable.ic_call_made_24dp
                                            }
                                    ),
                            contentDescription = null,
                            tint = iconTint,
                            modifier =
                                    Modifier.size(11.dp)
                                            .align(Alignment.TopEnd)
                                            .offset(x = (-1).dp, y = 1.dp)
                    )
                }
            }
            Spacer(modifier = Modifier.width(10.dp))
            Column(modifier = Modifier.weight(1f, fill = false)) {
                Text(
                        text = title,
                        color = if (missed && received) danger else fgColor,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 15.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                )
                Text(
                        text = subtitle,
                        color = textMuted,
                        fontSize = 13.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                )
            }
            Spacer(modifier = Modifier.width(10.dp))
            Column(
                    horizontalAlignment = Alignment.End,
                    verticalArrangement = Arrangement.Bottom,
                    modifier = Modifier.align(Alignment.Bottom)
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    if (timeText.isNotEmpty()) {
                        Text(
                                text = timeText,
                                color = textMuted,
                                fontSize = 11.sp
                        )
                    }
                    if (isSentByMe) {
                        Spacer(modifier = Modifier.width(3.dp))
                        PenikMessageStatusIcon(
                                status = message.status,
                                tint = textMuted,
                                accent = accent,
                                danger = danger,
                                modifier = Modifier.size(12.dp)
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
                    onAction = { action ->
                        showMenu = false
                        listener.onMessageAction(action, message)
                    }
            )
        }
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













@Composable
fun PenikAttachmentRow(
        message: Message,
        status: Int = message.status,
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
    val isSticker = message.type == Message.TYPE_STICKER || message.isSticker
    val isImage = (message.type == Message.TYPE_IMAGE || mime.startsWith("image/")) && !message.isGeoUri && !isSticker
    val isVideo = penikIsVideo(message)
    val isVideoNote = penikIsVideoNote(message)

    val service = activity.xmppConnectionService
    val rawFile = remember(message.uuid) {
        service?.fileBackend?.getFile(message, false)
    }
    var fileExists by remember(message.uuid) { mutableStateOf(false) }
    LaunchedEffect(rawFile?.absolutePath) {
        val f = rawFile
        fileExists = if (f != null) {
            withContext(Dispatchers.IO) {
                try { f.exists() } catch (e: Exception) { false }
            }
        } else {
            false
        }
    }
    val resolvedModel = remember(message.uuid, fileExists) {
        if (fileExists && rawFile != null) rawFile else message.fileParams?.url
    }

    Box(
            modifier = Modifier.fillMaxWidth().padding(vertical = 1.dp),
            contentAlignment = boxAlignment
    ) {
        if (isSticker) {
            PenikStickerBubble(
                message = message,
                isSentByMe = isSentByMe,
                timeText = timeText,
                onClick = {},
                onLongClick = {
                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                    showMenu = true
                }
            )
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
        } else if (isVideoNote) {
            PenikVideoNoteBubble(
                message = message,
                activity = activity,
                isSentByMe = isSentByMe,
                timeText = timeText,
                status = status,
                readCount = message.readByMarkers?.size ?: 0,
                onLongClick = {
                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                    showMenu = true
                }
            )
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
        } else if (isImage || isVideo) {
            val t = message.transferable
            val transferStatus = t?.status
            val isTranscoding = transferStatus == Transferable.STATUS_TRANSCODING
            val isUploading = isSentByMe && message.fileParams?.url == null && (
                    isTranscoding ||
                    transferStatus == Transferable.STATUS_UPLOADING ||
                    transferStatus == Transferable.STATUS_CHECKING ||
                    message.needsUploading() ||
                    status == Message.STATUS_UNSEND ||
                    status == Message.STATUS_WAITING
            )
            val initialTotal = remember(message.uuid, revision) {
                t?.fileSize?.takeIf { it > 0L }
                    ?: message.fileParams?.getSize()?.takeIf { it > 0L }
                    ?: 0L
            }
            var currentTotal by remember(message.uuid, revision) { mutableStateOf(initialTotal) }
            LaunchedEffect(message.uuid, revision) {
                if (currentTotal <= 0L) {
                    val len = withContext(Dispatchers.IO) {
                        try {
                            activity.xmppConnectionService?.fileBackend?.getFile(message, false)?.takeIf { it.exists() }?.length() ?: 0L
                        } catch (e: Exception) {
                            0L
                        }
                    }
                    if (len > 0L) {
                        currentTotal = len
                    }
                }
            }
            val currentTransferred = remember(message.uuid, revision) {
                t?.transferred ?: ((t?.progress?.toLong() ?: 0L) * currentTotal / 100L)
            }
            val transcodePercent = remember(message.uuid, revision) {
                t?.progress ?: 0
            }
            Box(
                    modifier =
                            Modifier.padding(horizontal = 12.dp)
                                    .widthIn(max = 280.dp)
                                    .clip(RoundedCornerShape(12.dp))
                                    .background(Color(0x15FFFFFF))
                                    .combinedClickable(
                                            onClick = {
                                                if (isUploading) {
                                                    return@combinedClickable
                                                }
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
                if (isUploading) {
                    val badgeText = when {
                        isTranscoding -> "Сжатие $transcodePercent%"
                        currentTotal > 0L -> {
                            val transferredFormatted = android.text.format.Formatter.formatShortFileSize(
                                    context,
                                    currentTransferred.coerceIn(0L, currentTotal)
                            )
                            val totalFormatted = android.text.format.Formatter.formatShortFileSize(context, currentTotal)
                            "$transferredFormatted / $totalFormatted"
                        }
                        else -> "Загрузка..."
                    }
                    val badgeIcon = if (isTranscoding) {
                        painterResource(R.drawable.ic_schedule_24dp)
                    } else {
                        painterResource(R.drawable.ic_upload_24dp)
                    }
                    Box(
                            modifier =
                                    Modifier.align(Alignment.TopStart)
                                            .padding(6.dp)
                                            .clip(RoundedCornerShape(8.dp))
                                            .background(Color.Black.copy(alpha = 0.55f))
                                            .padding(horizontal = 6.dp, vertical = 2.dp)
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(
                                    painter = badgeIcon,
                                    contentDescription = null,
                                    tint = Color.White,
                                    modifier = Modifier.size(10.dp)
                            )
                            Spacer(modifier = Modifier.width(3.dp))
                            Text(
                                    text = badgeText,
                                    fontSize = 10.sp,
                                    color = Color.White,
                                    fontWeight = FontWeight.Medium
                            )
                        }
                    }
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
                                Spacer(modifier = Modifier.width(4.dp))
                                PenikMessageStatusIcon(
                                        status = status,
                                        tint = Color.White.copy(alpha = 0.8f),
                                        accent = accent,
                                        danger = danger
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
        } else {
            val bubbleShape = PenikBubbleShape(isSentByMe = isSentByMe)
            val isVoice = penikIsAudio(message)
            val bubbleBg = bgColor
            val effectiveFgColor = fgColor
            val effectiveMutedColor = if (isSentByMe) fgColor.copy(alpha = 0.7f) else textMuted
            val onBubbleClick: () -> Unit = if (isVoice) {
                {
                    val file = try {
                        activity.xmppConnectionService?.fileBackend?.getFile(message)
                    } catch (e: Exception) {
                        null
                    }
                    if (file != null && file.exists()) {
                        val runtimeMs = message.fileParams?.runtime ?: 0
                        PenikVoicePlayer.toggle(context, file, message.uuid, runtimeMs)
                    } else {
                        listener.onMessageAction(PenikChatActions.OPEN, message)
                    }
                }
            } else {
                { listener.onMessageAction(PenikChatActions.OPEN, message) }
            }
            Box(
                    modifier =
                            Modifier.padding(horizontal = 12.dp)
                                    .widthIn(max = 300.dp)
                                    .clip(bubbleShape)
                                    .background(bubbleBg)
                                    .combinedClickable(
                                            onClick = onBubbleClick,
                                            onLongClick = {
                                                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                                showMenu = true
                                            }
                                    )
                                    .padding(10.dp)
            ) {
                Column {
                    if (isVoice) {
                        PenikVoiceRow(
                                message = message,
                                activity = activity,
                                isSentByMe = isSentByMe,
                                fgColor = effectiveFgColor,
                                textMuted = effectiveMutedColor
                        )
                    } else {
                        PenikFileRow(message = message, fgColor = fgColor, textMuted = textMuted, revision = revision)
                    }
                    Spacer(modifier = Modifier.height(4.dp))
                    Row(
                            modifier = Modifier.align(Alignment.End),
                            verticalAlignment = Alignment.CenterVertically
                    ) {
                        if (timeText.isNotEmpty()) {
                            Text(text = timeText, color = effectiveMutedColor, fontSize = 11.sp)
                        }
                        if (isSentByMe) {
                            Spacer(modifier = Modifier.width(4.dp))
                            val readAccent = if (isSentByMe && bubbleBg == accent) Color(0xFF80D8FF) else accent
                            PenikMessageStatusIcon(
                                    status = status,
                                    tint = effectiveMutedColor,
                                    accent = readAccent,
                                    danger = danger
                            )
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
        status: Int = message.status,
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
                            Spacer(modifier = Modifier.width(4.dp))
                            PenikMessageStatusIcon(
                                    status = status,
                                    tint = Color.White.copy(alpha = 0.8f),
                                    accent = accent,
                                    danger = danger
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
    val rawFile = remember(message.uuid) {
        service?.fileBackend?.getFile(message, false)
    }
    var localFileExists by remember(message.uuid) { mutableStateOf(false) }
    LaunchedEffect(rawFile?.absolutePath) {
        val f = rawFile
        localFileExists = if (f != null) {
            withContext(Dispatchers.IO) {
                try { f.exists() } catch (e: Exception) { false }
            }
        } else {
            false
        }
    }
    val localFile = if (localFileExists) rawFile else null
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
    val rawFile = remember(message.uuid) {
        service?.fileBackend?.getFile(message, false)
    }
    var localFileExists by remember(message.uuid) { mutableStateOf(false) }
    LaunchedEffect(rawFile?.absolutePath) {
        val f = rawFile
        localFileExists = if (f != null) {
            withContext(Dispatchers.IO) {
                try { f.exists() } catch (e: Exception) { false }
            }
        } else {
            false
        }
    }
    val localFile = if (localFileExists) rawFile else null
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
                            .background(Color(0xFF1E232B))
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
fun PenikFileRow(message: Message, fgColor: Color, textMuted: Color, revision: Long = 0L) {
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
    val context = androidx.compose.ui.platform.LocalContext.current
    val t = message.transferable
    val transferStatus = t?.status
    val resolvedSize = remember(message.uuid, params?.size, revision) {
        val s = params?.getSize() ?: 0L
        if (s > 0L) s else t?.fileSize ?: 0L
    }
    val isUploading = message.fileParams?.url == null && (
            message.needsUploading() ||
            message.status == Message.STATUS_UNSEND ||
            message.status == Message.STATUS_WAITING ||
            transferStatus == Transferable.STATUS_UPLOADING ||
            transferStatus == Transferable.STATUS_CHECKING ||
            transferStatus == Transferable.STATUS_TRANSCODING
    )
    val currentTransferred = remember(message.uuid, revision) {
        t?.transferred ?: ((t?.progress?.toLong() ?: 0L) * resolvedSize / 100L)
    }
    val sizeText =
            if (!message.isGeoUri && resolvedSize > 0L) {
                if (isUploading) {
                    val tFormatted = android.text.format.Formatter.formatShortFileSize(context, currentTransferred.coerceIn(0L, resolvedSize))
                    val totFormatted = android.text.format.Formatter.formatShortFileSize(context, resolvedSize)
                    " · $tFormatted / $totFormatted"
                } else {
                    " · " + android.text.format.Formatter.formatShortFileSize(
                            context,
                            resolvedSize
                    )
                }
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
