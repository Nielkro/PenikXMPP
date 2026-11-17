package eu.siacs.conversations.ui.compose

import android.media.MediaPlayer
import android.media.MediaMetadataRetriever
import android.view.Surface
import android.view.TextureView
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
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
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.colorResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import coil.compose.AsyncImage
import coil.decode.VideoFrameDecoder
import coil.request.ImageRequest
import eu.siacs.conversations.R
import eu.siacs.conversations.entities.Message
import eu.siacs.conversations.ui.XmppActivity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import java.io.File

object PenikVideoNotePlayer {
    var activeUuid by mutableStateOf<String?>(null)
    private var player: MediaPlayer? = null
    var isPlaying by mutableStateOf(false)
    var currentPosMs by mutableStateOf(0)
    var durationMs by mutableStateOf(0)

    fun position(): Int {
        return try {
            player?.currentPosition ?: currentPosMs
        } catch (e: Exception) {
            currentPosMs
        }
    }

    fun stop() {
        try {
            player?.stop()
        } catch (ignored: Exception) {}
        try {
            player?.release()
        } catch (ignored: Exception) {}
        player = null
        activeUuid = null
        isPlaying = false
        currentPosMs = 0
        durationMs = 0
    }

    fun toggle(file: File, uuid: String, surface: Surface) {
        if (activeUuid == uuid && player != null) {
            try {
                if (isPlaying) {
                    player?.pause()
                    isPlaying = false
                    currentPosMs = position()
                } else {
                    player?.start()
                    isPlaying = true
                }
            } catch (e: Exception) {
                stop()
            }
            return
        }
        PenikVoicePlayer.stop()
        stop()

        try {
            val p = MediaPlayer()
            p.setDataSource(file.absolutePath)
            p.setSurface(surface)
            p.isLooping = true
            p.setOnPreparedListener { mp ->
                durationMs = mp.duration
                mp.start()
                isPlaying = true
            }
            p.setOnCompletionListener {
                stop()
            }
            player = p
            activeUuid = uuid
            p.prepareAsync()
        } catch (e: Exception) {
            stop()
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun PenikVideoNoteBubble(
        message: Message,
        activity: XmppActivity,
        isSentByMe: Boolean,
        timeText: String,
        status: Int,
        readCount: Int,
        onLongClick: () -> Unit
) {
    val context = LocalContext.current
    val service = activity.xmppConnectionService
    val rawLocalFile = remember(message.uuid, status, message.relativeFilePath) {
        service?.fileBackend?.getFile(message, false)
    }
    var localFileValid by remember(message.uuid, status, message.relativeFilePath) { mutableStateOf(false) }
    LaunchedEffect(rawLocalFile?.absolutePath) {
        val f = rawLocalFile
        localFileValid = if (f != null) {
            withContext(Dispatchers.IO) {
                try { f.exists() && f.length() > 0L } catch (e: Exception) { false }
            }
        } else {
            false
        }
    }
    val localFile = if (localFileValid) rawLocalFile else null
    val isActive = PenikVideoNotePlayer.activeUuid == message.uuid
    val isPlaying = isActive && PenikVideoNotePlayer.isPlaying
    val currentPosMs = if (isActive) PenikVideoNotePlayer.currentPosMs else 0
    val durationMs = if (isActive) PenikVideoNotePlayer.durationMs else 0
    val staticDurationMs = remember(localFile?.absolutePath) {
        val path = localFile?.absolutePath
        if (path != null) {
            val mmr = MediaMetadataRetriever()
            try {
                mmr.setDataSource(path)
                val durStr = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                durStr?.toIntOrNull() ?: 0
            } catch (e: Exception) {
                0
            } finally {
                try {
                    mmr.release()
                } catch (ignored: Exception) {}
            }
        } else {
            0
        }
    }
    val accent = colorResource(R.color.penik_accent)
    val danger = colorResource(R.color.penik_danger)
    var surfaceRef by remember(message.uuid) { mutableStateOf<Surface?>(null) }

    // Progress updater loop only for the ONE active player
    LaunchedEffect(isActive, isPlaying) {
        while (isActive && isPlaying) {
            PenikVideoNotePlayer.currentPosMs = PenikVideoNotePlayer.position()
            delay(100)
        }
    }

    val isTranscodingOrUploading = status == Message.STATUS_WAITING || message.transferable != null
    val previewModel = remember(message.uuid, status, localFile?.absolutePath) {
        service?.bitmapCache?.get(message.uuid) ?: localFile
    }

    Box(
            modifier = Modifier
                    .padding(horizontal = 12.dp, vertical = 2.dp)
                    .size(220.dp)
                    .combinedClickable(
                            onClick = {
                                if (!isTranscodingOrUploading && localFile != null) {
                                    surfaceRef?.let { s ->
                                        PenikVideoNotePlayer.toggle(localFile, message.uuid, s)
                                    }
                                }
                            },
                            onLongClick = onLongClick
                    ),
            contentAlignment = Alignment.Center
    ) {
        if (localFile != null && localFile.length() > 0L && !isTranscodingOrUploading) {
            // Live circular video view
            AndroidView(
                    factory = { ctx ->
                        TextureView(ctx).apply {
                            surfaceTextureListener = object : TextureView.SurfaceTextureListener {
                                override fun onSurfaceTextureAvailable(st: android.graphics.SurfaceTexture, width: Int, height: Int) {
                                    val s = Surface(st)
                                    surfaceRef = s
                                }

                                override fun onSurfaceTextureSizeChanged(st: android.graphics.SurfaceTexture, width: Int, height: Int) {}
                                override fun onSurfaceTextureDestroyed(st: android.graphics.SurfaceTexture): Boolean {
                                    if (PenikVideoNotePlayer.activeUuid == message.uuid) {
                                        PenikVideoNotePlayer.stop()
                                    }
                                    surfaceRef = null
                                    return true
                                }
                                override fun onSurfaceTextureUpdated(st: android.graphics.SurfaceTexture) {}
                            }
                        }
                    },
                    modifier = Modifier
                            .size(212.dp)
                            .clip(CircleShape)
            )

            // Preview thumbnail overlay when not playing
            if (!isPlaying) {
                AsyncImage(
                        model = ImageRequest.Builder(context)
                                .data(previewModel)
                                .decoderFactory(VideoFrameDecoder.Factory())
                                .crossfade(true)
                                .build(),
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier
                                .size(212.dp)
                                .clip(CircleShape)
                )

                // Center play button overlay when not playing
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
            }

            // Circular progress indicator around perimeter
            if (isActive && durationMs > 0) {
                androidx.compose.foundation.Canvas(modifier = Modifier.size(220.dp)) {
                    val strokeWidth = 3.dp.toPx()
                    val sweep = (currentPosMs.toFloat() / durationMs.toFloat()) * 360f

                    drawCircle(
                            color = Color.White.copy(alpha = 0.15f),
                            style = Stroke(width = strokeWidth)
                    )
                    if (sweep > 0f) {
                        drawArc(
                                color = accent,
                                startAngle = -90f,
                                sweepAngle = sweep,
                                useCenter = false,
                                style = Stroke(width = strokeWidth, cap = StrokeCap.Round)
                        )
                    }
                }
            } else {
                // Subtle border when idle
                Box(
                        modifier = Modifier
                                .size(216.dp)
                                .clip(CircleShape)
                                .border(1.5.dp, Color.White.copy(alpha = 0.25f), CircleShape)
                )
            }
        } else {
            // Optimistic instant preview thumbnail with progress spinner if transcoding/uploading
            Box(
                    modifier = Modifier
                            .size(212.dp)
                            .clip(CircleShape)
                            .background(Color(0xFF1E232B)),
                    contentAlignment = Alignment.Center
            ) {
                AsyncImage(
                        model = ImageRequest.Builder(context)
                                .data(previewModel)
                                .decoderFactory(VideoFrameDecoder.Factory())
                                .crossfade(true)
                                .build(),
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.fillMaxSize()
                )

                if (isTranscodingOrUploading) {
                    Box(
                            modifier = Modifier
                                    .size(48.dp)
                                    .clip(CircleShape)
                                    .background(Color.Black.copy(alpha = 0.55f)),
                            contentAlignment = Alignment.Center
                    ) {
                        CircularProgressIndicator(
                                modifier = Modifier.size(28.dp),
                                color = Color.White,
                                strokeWidth = 2.5.dp
                        )
                    }
                } else {
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
                }
            }

            Box(
                    modifier = Modifier
                            .size(216.dp)
                            .clip(CircleShape)
                            .border(1.5.dp, Color.White.copy(alpha = 0.25f), CircleShape)
            )
        }

        // Left badge: video note duration
        val displayDurationMs = if (isPlaying && durationMs > 0) {
            (durationMs - currentPosMs).coerceAtLeast(0)
        } else if (staticDurationMs > 0) {
            staticDurationMs
        } else {
            0
        }
        if (displayDurationMs > 0) {
            Box(
                    modifier = Modifier
                            .align(Alignment.BottomStart)
                            .padding(start = 14.dp, bottom = 10.dp)
                            .clip(RoundedCornerShape(10.dp))
                            .background(Color.Black.copy(alpha = 0.55f))
                            .padding(horizontal = 7.dp, vertical = 2.dp)
            ) {
                Text(
                        text = penikFormatVoiceTime(displayDurationMs),
                        fontSize = 11.sp,
                        color = Color.White
                )
            }
        }

        // Right badge: time sent and status ticks
        Box(
                modifier = Modifier
                        .align(Alignment.BottomEnd)
                        .padding(end = 14.dp, bottom = 10.dp)
                        .clip(RoundedCornerShape(10.dp))
                        .background(Color.Black.copy(alpha = 0.55f))
                        .padding(horizontal = 7.dp, vertical = 2.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                        text = timeText,
                        fontSize = 11.sp,
                        color = Color.White
                )
                if (isSentByMe) {
                    Spacer(modifier = Modifier.width(3.dp))
                    if (status == Message.STATUS_SEND_FAILED) {
                        Text(text = "!", color = danger, fontSize = 10.sp, fontWeight = FontWeight.Bold)
                    } else {
                        val isDouble = status >= Message.STATUS_SEND_RECEIVED || readCount > 0
                        val checkColor = if (readCount > 0) accent else Color.White.copy(alpha = 0.85f)
                        Text(
                                text = if (isDouble) "✓✓" else "✓",
                                color = checkColor,
                                fontSize = 10.sp,
                                fontWeight = FontWeight.Bold
                        )
                    }
                }
            }
        }
    }
}
