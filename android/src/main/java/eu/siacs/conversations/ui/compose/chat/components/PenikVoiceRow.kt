package eu.siacs.conversations.ui.compose

import android.content.Context
import android.media.MediaPlayer
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.colorResource
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import eu.siacs.conversations.R
import eu.siacs.conversations.entities.Message
import eu.siacs.conversations.ui.XmppActivity
import eu.siacs.conversations.ui.util.PenikAudioWaveformExtractor
import eu.siacs.conversations.utils.UIHelper
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import java.io.File

object PenikVoicePlayer {
    private var player: MediaPlayer? = null
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

    fun toggle(context: Context, file: File, uuid: String, fallbackDurationMs: Int) {
        PenikVideoNotePlayer.stop()
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
            val p = MediaPlayer()
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
fun PenikVoiceRow(
        message: Message,
        activity: XmppActivity,
        isSentByMe: Boolean = false,
        fgColor: Color,
        textMuted: Color
) {
    val context = LocalContext.current
    val accent = colorResource(R.color.penik_accent)
    val fileBackend = PenikRepository.getInstance().fileBackend
    val file =
            remember(message.uuid) {
                try {
                    fileBackend?.getFile(message)
                } catch (e: Exception) {
                    null
                }
            }
    var fileExists by remember(message.uuid) { mutableStateOf(false) }
    LaunchedEffect(file?.absolutePath) {
        val f = file
        fileExists = if (f != null) {
            withContext(Dispatchers.IO) {
                try { f.exists() } catch (e: Exception) { false }
            }
        } else {
            false
        }
    }
    if (file == null || !fileExists) {
        Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp)
        ) {
            Box(
                    modifier =
                            Modifier.size(42.dp)
                                    .clip(CircleShape)
                                    .background(if (isSentByMe) fgColor.copy(alpha = 0.2f) else accent),
                    contentAlignment = Alignment.Center
            ) {
                Icon(
                        painter = painterResource(R.drawable.ic_play_arrow_24dp),
                        contentDescription = null,
                        tint = if (isSentByMe) fgColor else Color.White,
                        modifier = Modifier.size(24.dp)
                )
            }
            Spacer(modifier = Modifier.width(10.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                        text = "Голосовое сообщение",
                        color = fgColor,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.Medium
                )
                Spacer(modifier = Modifier.height(2.dp))
                Text(
                        text = "Нажмите, чтобы загрузить",
                        color = if (isSentByMe) Color.White.copy(alpha = 0.75f) else textMuted,
                        fontSize = 11.sp
                )
            }
        }
        return
    }
    val uuid = message.uuid
    val initialRuntime = message.fileParams?.runtime ?: 0
    var runtimeMs by remember(message.uuid) { mutableStateOf(initialRuntime) }
    LaunchedEffect(message.uuid, file.absolutePath) {
        if (runtimeMs <= 0) {
            val extracted = withContext(Dispatchers.IO) {
                try {
                    val mmr = android.media.MediaMetadataRetriever()
                    try {
                        mmr.setDataSource(file.absolutePath)
                        val durStr =
                                mmr.extractMetadata(
                                        android.media.MediaMetadataRetriever.METADATA_KEY_DURATION
                                )
                        durStr?.toIntOrNull() ?: 0
                    } finally {
                        try {
                            mmr.release()
                        } catch (ignored: Exception) {
                        }
                    }
                } catch (e: Exception) {
                    0
                }
            }
            if (extracted > 0) {
                runtimeMs = extracted
            }
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
    val cachedWave = remember(uuid) { PenikAudioWaveformExtractor.getCached(uuid) }
    var waveform by remember(uuid) {
        mutableStateOf(cachedWave ?: generateVoiceWaveform(uuid, 45))
    }

    LaunchedEffect(file.absolutePath, uuid) {
        val realWave = withContext(Dispatchers.IO) {
            try {
                if (file.exists()) {
                    PenikAudioWaveformExtractor.getWaveform(file, uuid, 45)
                } else {
                    emptyList()
                }
            } catch (e: Exception) {
                emptyList()
            }
        }
        if (realWave.isNotEmpty()) {
            waveform = realWave
        }
    }
    var fileSizeStr by remember(file.absolutePath) { mutableStateOf("") }
    LaunchedEffect(file.absolutePath) {
        val str = withContext(Dispatchers.IO) {
            try {
                UIHelper.filesizeToString(file.length())
            } catch (e: Exception) {
                ""
            }
        }
        fileSizeStr = str
    }

    LaunchedEffect(playingThis, uuid) {
        while (PenikVoicePlayer.currentUuid == uuid && PenikVoicePlayer.isPlaying) {
            delay(100)
            PenikVoicePlayer.progressMs = PenikVoicePlayer.position()
        }
    }
    val btnBg = if (isSentByMe) fgColor.copy(alpha = 0.2f) else accent
    val waveActive = if (isSentByMe) fgColor else accent
    val waveInactive = if (isSentByMe) fgColor.copy(alpha = 0.35f) else accent.copy(alpha = 0.35f)
    Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp)
    ) {
        Box(
                modifier =
                        Modifier.size(42.dp)
                                .clip(CircleShape)
                                .background(btnBg)
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
                    tint = if (isSentByMe) fgColor else Color.White,
                    modifier = Modifier.size(24.dp)
            )
        }
        Spacer(modifier = Modifier.width(10.dp))
        Column(modifier = Modifier.weight(1f)) {
            PenikWaveform(
                    progress = progressFraction,
                    amplitudes = waveform,
                    activeColor = waveActive,
                    inactiveColor = waveInactive,
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
                    color = if (isSentByMe) Color.White.copy(alpha = 0.8f) else textMuted,
                    fontSize = 11.sp,
                    maxLines = 1
            )
        }
    }
}

@Preview(showBackground = true, backgroundColor = 0xFF1E293B)
@Composable
private fun PenikWaveformPreview() {
    Column(modifier = Modifier.padding(16.dp)) {
        PenikWaveform(
            progress = 0.45f,
            amplitudes = generateVoiceWaveform("preview-seed", 45),
            activeColor = Color(0xFF38BDF8),
            inactiveColor = Color(0xFF38BDF8).copy(alpha = 0.35f),
            onSeek = {},
            modifier = Modifier.fillMaxWidth().height(32.dp)
        )
    }
}
