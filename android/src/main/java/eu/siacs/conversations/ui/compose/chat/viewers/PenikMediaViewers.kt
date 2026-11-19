package eu.siacs.conversations.ui.compose

import android.content.Context
import android.media.MediaPlayer
import android.net.Uri
import android.widget.VideoView
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Done
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Repeat
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.colorResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import coil.compose.AsyncImage
import eu.siacs.conversations.R
import eu.siacs.conversations.entities.Message
import eu.siacs.conversations.ui.XmppActivity
import eu.siacs.conversations.utils.UIHelper
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

@Composable
fun PenikMediaOverflowMenu(
        message: Message,
        listener: PenikChatListener,
        hasUrl: Boolean
) {
    var expanded by remember { mutableStateOf(false) }
    val panel = colorResource(R.color.penik_panel)
    val textPrimary = colorResource(R.color.penik_text_primary)
    val textMuted = colorResource(R.color.penik_text_muted)

    Box {
        IconButton(onClick = { expanded = true }) {
            Icon(
                    imageVector = Icons.Default.MoreVert,
                    contentDescription = stringResource(R.string.more_options),
                    tint = Color.White
            )
        }
        DropdownMenu(
                expanded = expanded,
                onDismissRequest = { expanded = false },
                modifier = Modifier.background(panel)
        ) {
            if (hasUrl) {
                DropdownMenuItem(
                        text = { Text(stringResource(R.string.copy_link), color = textPrimary) },
                        leadingIcon = {
                            Icon(
                                    imageVector = Icons.Default.Link,
                                    contentDescription = null,
                                    tint = textMuted,
                                    modifier = Modifier.size(20.dp)
                            )
                        },
                        onClick = {
                            expanded = false
                            listener.onMessageAction(PenikChatActions.COPY_URL, message)
                        }
                )
            }
            DropdownMenuItem(
                    text = { Text(stringResource(R.string.save), color = textPrimary) },
                    leadingIcon = {
                        Icon(
                                imageVector = Icons.Default.Download,
                                contentDescription = null,
                                tint = textMuted,
                                modifier = Modifier.size(20.dp)
                        )
                    },
                    onClick = {
                        expanded = false
                        listener.onMessageAction(PenikChatActions.SAVE_FILE, message)
                    }
            )
            DropdownMenuItem(
                    text = { Text(stringResource(R.string.share), color = textPrimary) },
                    leadingIcon = {
                        Icon(
                                imageVector = Icons.Default.Share,
                                contentDescription = null,
                                tint = textMuted,
                                modifier = Modifier.size(20.dp)
                        )
                    },
                    onClick = {
                        expanded = false
                        listener.onMessageAction(PenikChatActions.SHARE, message)
                    }
            )
        }
    }
}

fun formatViewerDateTime(context: Context, timestamp: Long): String {
    if (timestamp <= 0L) return ""
    val msgCal = java.util.Calendar.getInstance().apply { timeInMillis = timestamp }
    val nowCal = java.util.Calendar.getInstance()
    val sameYear = msgCal.get(java.util.Calendar.YEAR) == nowCal.get(java.util.Calendar.YEAR)
    val timeFormat = android.text.format.DateFormat.getTimeFormat(context)
    val datePattern = if (sameYear) "d MMMM" else "d MMMM yyyy"
    val dateStr = android.text.format.DateFormat.format(datePattern, msgCal).toString()
    val timeStr = timeFormat.format(java.util.Date(timestamp))
    return "$dateStr, $timeStr"
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
    val timeText = remember(message?.timeSent) {
        val ts = message?.timeSent ?: 0L
        formatViewerDateTime(context, ts)
    }
    val hasUrl = message?.fileParams?.url != null || (message?.body != null && (message.body.contains("http://") || message.body.contains("https://")))

    Dialog(
            onDismissRequest = onDismiss,
            properties = DialogProperties(
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
            AsyncImage(
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
                                                        colors = listOf(
                                                                Color.Black.copy(alpha = 0.95f),
                                                                Color.Black.copy(alpha = 0.75f),
                                                                Color.Black.copy(alpha = 0.35f),
                                                                Color.Transparent
                                                        )
                                                )
                                        )
                                        .statusBarsPadding()
                                        .padding(start = 8.dp, end = 8.dp, top = 6.dp, bottom = 28.dp)
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
                                        color = Color.White.copy(alpha = 0.75f),
                                        fontSize = 12.sp,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis
                                )
                            }
                        }
                        if (message != null && listener != null) {
                            var showOverflowMenu by remember { mutableStateOf(false) }
                            Box {
                                IconButton(onClick = { showOverflowMenu = true }) {
                                    Icon(
                                            imageVector = Icons.Default.MoreVert,
                                            contentDescription = "Ещё",
                                            tint = Color.White
                                    )
                                }
                                DropdownMenu(
                                        expanded = showOverflowMenu,
                                        onDismissRequest = { showOverflowMenu = false },
                                        modifier = Modifier.background(colorResource(R.color.penik_panel_secondary))
                                ) {
                                    if (hasUrl) {
                                        DropdownMenuItem(
                                                text = { Text("Копировать ссылку", color = Color.White) },
                                                leadingIcon = {
                                                    Icon(
                                                            imageVector = Icons.Default.Link,
                                                            contentDescription = null,
                                                            tint = Color.White.copy(alpha = 0.7f),
                                                            modifier = Modifier.size(20.dp)
                                                    )
                                                },
                                                onClick = {
                                                    showOverflowMenu = false
                                                    listener.onMessageAction(PenikChatActions.COPY_URL, message)
                                                }
                                        )
                                    }
                                    DropdownMenuItem(
                                            text = { Text("Сохранить", color = Color.White) },
                                            leadingIcon = {
                                                Icon(
                                                        imageVector = Icons.Default.Download,
                                                        contentDescription = null,
                                                        tint = Color.White.copy(alpha = 0.7f),
                                                        modifier = Modifier.size(20.dp)
                                                )
                                            },
                                            onClick = {
                                                showOverflowMenu = false
                                                listener.onMessageAction(PenikChatActions.SAVE_FILE, message)
                                            }
                                    )
                                }
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
    val fileBackend = eu.siacs.conversations.ui.compose.PenikRepository.getInstance().fileBackend
    val localFile = remember(message.uuid) {
        val f = try { fileBackend?.getFile(message, false) } catch (e: Exception) { null }
        if (f != null && f.exists() && f.length() > 0L) f else null
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

    val initialRuntimeSec = message.fileParams?.runtime ?: 0
    var isPrepared by remember { mutableStateOf(false) }
    var isPlaying by remember { mutableStateOf(false) }
    var currentPositionMs by remember { mutableStateOf(0) }
    var durationMs by remember { mutableStateOf(initialRuntimeSec * 1000) }
    var showControls by remember { mutableStateOf(false) }
    var isError by remember { mutableStateOf(false) }
    var videoViewRef by remember { mutableStateOf<VideoView?>(null) }
    var mediaPlayerRef by remember { mutableStateOf<MediaPlayer?>(null) }
    var isLooping by remember(message.uuid) {
        mutableStateOf(initialRuntimeSec in 1..30)
    }
    var isLoopingExplicit by remember(message.uuid) { mutableStateOf(false) }

    val senderName = remember(message) { UIHelper.getMessageDisplayName(message) }
    val timeText = remember(message.timeSent) {
        formatViewerDateTime(context, message.timeSent)
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

    val togglePlay: () -> Unit = {
        videoViewRef?.let { vv ->
            if (vv.isPlaying) {
                vv.pause()
                isPlaying = false
                showControls = true
            } else {
                if (currentPositionMs >= durationMs - 500 && durationMs > 0) {
                    vv.seekTo(0)
                    currentPositionMs = 0
                }
                vv.start()
                isPlaying = true
            }
        }
    }

    Dialog(
            onDismissRequest = {
                videoViewRef?.stopPlayback()
                onDismiss()
            },
            properties = DialogProperties(
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
                            VideoView(ctx).apply {
                                setVideoURI(videoUri)
                                setOnPreparedListener { mp ->
                                    isPrepared = true
                                    mediaPlayerRef = mp
                                    val dur = mp.duration
                                    if (dur > 0) durationMs = dur
                                    if (!isLoopingExplicit) {
                                        isLooping = durationMs in 1..30_000
                                    }
                                    mp.isLooping = isLooping
                                    start()
                                    isPlaying = true
                                }
                                setOnCompletionListener { mp ->
                                    if (isLooping) {
                                        mp.seekTo(0)
                                        mp.start()
                                        isPlaying = true
                                        currentPositionMs = 0
                                    } else {
                                        isPlaying = false
                                        currentPositionMs = 0
                                        videoViewRef?.seekTo(0)
                                        showControls = true
                                    }
                                }
                                setOnErrorListener { _, _, _ ->
                                    isError = true
                                    isPrepared = true
                                    false
                                }
                                videoViewRef = this
                            }
                        },
                        modifier = Modifier
                                .fillMaxSize()
                                .pointerInput(Unit) {
                                    detectTapGestures {
                                        showControls = !showControls
                                    }
                                }
                )

                if (!isPrepared) {
                    val thumbModel: Any? = localFile ?: rawUrl
                    if (thumbModel != null) {
                        AsyncImage(
                                model = thumbModel,
                                contentDescription = null,
                                contentScale = ContentScale.Fit,
                                modifier = Modifier.fillMaxSize()
                        )
                    }
                    CircularProgressIndicator(
                            color = colorResource(R.color.penik_accent),
                            modifier = Modifier.size(48.dp)
                    )
                }

                AnimatedVisibility(
                        visible = (showControls || !isPlaying) && isPrepared,
                        enter = fadeIn(),
                        exit = fadeOut(),
                        modifier = Modifier.align(Alignment.Center)
                ) {
                    Box(
                            modifier = Modifier
                                    .size(72.dp)
                                    .clip(CircleShape)
                                    .background(Color.Black.copy(alpha = 0.6f))
                                    .clickable { togglePlay() },
                            contentAlignment = Alignment.Center
                    ) {
                        Icon(
                                imageVector = if (isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow,
                                contentDescription = if (isPlaying) "Пауза" else "Воспроизведение",
                                tint = Color.White,
                                modifier = Modifier.size(40.dp)
                        )
                    }
                }
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
                                                colors = listOf(
                                                        Color.Black.copy(alpha = 0.95f),
                                                        Color.Black.copy(alpha = 0.75f),
                                                        Color.Black.copy(alpha = 0.35f),
                                                        Color.Transparent
                                                )
                                        )
                                )
                                .statusBarsPadding()
                                .padding(start = 8.dp, end = 8.dp, top = 6.dp, bottom = 28.dp)
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
                                        color = Color.White.copy(alpha = 0.75f),
                                        fontSize = 12.sp,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis
                                )
                            }
                        }

                        // Video Viewer 3-dots overflow menu: Repeat / Loop, Copy link, Save
                        var showOverflowMenu by remember { mutableStateOf(false) }
                        Box {
                            IconButton(onClick = { showOverflowMenu = true }) {
                                Icon(
                                        imageVector = Icons.Default.MoreVert,
                                        contentDescription = "Ещё",
                                        tint = Color.White
                                )
                            }
                            DropdownMenu(
                                    expanded = showOverflowMenu,
                                    onDismissRequest = { showOverflowMenu = false },
                                    modifier = Modifier.background(colorResource(R.color.penik_panel_secondary))
                            ) {
                                DropdownMenuItem(
                                        text = {
                                            Text(
                                                    text = "Зациклить",
                                                    color = if (isLooping) colorResource(R.color.penik_accent) else Color.White
                                            )
                                        },
                                        leadingIcon = {
                                            Icon(
                                                    imageVector = Icons.Default.Repeat,
                                                    contentDescription = null,
                                                    tint = if (isLooping) colorResource(R.color.penik_accent) else Color.White.copy(alpha = 0.7f),
                                                    modifier = Modifier.size(20.dp)
                                            )
                                        },
                                        trailingIcon = if (isLooping) {
                                            {
                                                Icon(
                                                        imageVector = Icons.Default.Done,
                                                        contentDescription = null,
                                                        tint = colorResource(R.color.penik_accent),
                                                        modifier = Modifier.size(18.dp)
                                                )
                                            }
                                        } else null,
                                        onClick = {
                                            showOverflowMenu = false
                                            val newLoop = !isLooping
                                            isLooping = newLoop
                                            isLoopingExplicit = true
                                            mediaPlayerRef?.isLooping = newLoop
                                        }
                                )
                                if (hasUrl && listener != null) {
                                    DropdownMenuItem(
                                            text = { Text("Копировать ссылку", color = Color.White) },
                                            leadingIcon = {
                                                Icon(
                                                        imageVector = Icons.Default.Link,
                                                        contentDescription = null,
                                                        tint = Color.White.copy(alpha = 0.7f),
                                                        modifier = Modifier.size(20.dp)
                                                )
                                            },
                                            onClick = {
                                                showOverflowMenu = false
                                                listener.onMessageAction(PenikChatActions.COPY_URL, message)
                                            }
                                    )
                                }
                                if (listener != null) {
                                    DropdownMenuItem(
                                            text = { Text("Сохранить", color = Color.White) },
                                            leadingIcon = {
                                                Icon(
                                                        imageVector = Icons.Default.Download,
                                                        contentDescription = null,
                                                        tint = Color.White.copy(alpha = 0.7f),
                                                        modifier = Modifier.size(20.dp)
                                                )
                                            },
                                            onClick = {
                                                showOverflowMenu = false
                                                listener.onMessageAction(PenikChatActions.SAVE_FILE, message)
                                            }
                                    )
                                }
                            }
                        }
                    }
                }
            }

            // Bottom Bar (Progress slider and timestamps)
            AnimatedVisibility(
                    visible = showControls && isPlaying,
                    enter = fadeIn(),
                    exit = fadeOut(),
                    modifier = Modifier.align(Alignment.BottomCenter).fillMaxWidth()
            ) {
                Box(
                        modifier = Modifier
                                .fillMaxWidth()
                                .background(
                                        Brush.verticalGradient(
                                                colors = listOf(
                                                        Color.Transparent,
                                                        Color.Black.copy(alpha = 0.45f),
                                                        Color.Black.copy(alpha = 0.85f),
                                                        Color.Black.copy(alpha = 0.95f)
                                                )
                                        )
                                )
                                .navigationBarsPadding()
                                .padding(horizontal = 16.dp, vertical = 12.dp)
                ) {
                    Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.fillMaxWidth()
                    ) {
                        IconButton(onClick = togglePlay) {
                            Icon(
                                    imageVector = if (isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow,
                                    contentDescription = null,
                                    tint = Color.White,
                                    modifier = Modifier.size(28.dp)
                            )
                        }
                        Spacer(modifier = Modifier.width(6.dp))
                        Slider(
                                value = if (durationMs > 0) currentPositionMs.toFloat() else 0f,
                                onValueChange = { newVal ->
                                    currentPositionMs = newVal.toInt()
                                    videoViewRef?.seekTo(newVal.toInt())
                                },
                                valueRange = 0f..(durationMs.toFloat().coerceAtLeast(1f)),
                                colors = SliderDefaults.colors(
                                        thumbColor = colorResource(R.color.penik_accent),
                                        activeTrackColor = colorResource(R.color.penik_accent),
                                        inactiveTrackColor = Color.White.copy(alpha = 0.35f)
                                ),
                                modifier = Modifier.weight(1f)
                        )
                        Spacer(modifier = Modifier.width(10.dp))
                        val curSec = (currentPositionMs / 1000).coerceAtLeast(0)
                        val durSec = (durationMs / 1000).coerceAtLeast(0)
                        val timeStr = "%02d:%02d / %02d:%02d".format(curSec / 60, curSec % 60, durSec / 60, durSec % 60)
                        Text(
                                text = timeStr,
                                color = Color.White.copy(alpha = 0.9f),
                                fontSize = 11.5.sp,
                                fontWeight = FontWeight.Medium
                        )
                    }
                }
            }
        }
    }
}
