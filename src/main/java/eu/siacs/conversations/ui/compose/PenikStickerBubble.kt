package eu.siacs.conversations.ui.compose

import android.graphics.drawable.Animatable
import android.graphics.drawable.AnimatedImageDrawable
import android.os.Build
import android.util.Log
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Done
import androidx.compose.material.icons.filled.DoneAll
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
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.colorResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import eu.siacs.conversations.R
import coil.decode.ImageDecoderDecoder
import coil.request.ImageRequest
import com.airbnb.lottie.compose.LottieAnimation
import com.airbnb.lottie.compose.LottieCompositionSpec
import com.airbnb.lottie.compose.LottieConstants
import com.airbnb.lottie.compose.animateLottieCompositionAsState
import com.airbnb.lottie.compose.rememberLottieComposition
import eu.siacs.conversations.Config
import eu.siacs.conversations.entities.Message
import eu.siacs.conversations.entities.Sticker
import eu.siacs.conversations.stickers.StickerManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.zip.GZIPInputStream

@Composable
fun PenikStickerBubble(
    message: Message,
    isSentByMe: Boolean,
    timeText: String,
    onLongClick: () -> Unit = {},
    onClick: () -> Unit = {}
) {
    val context = LocalContext.current
    val sticker = message.sticker ?: Sticker.fromJson(message.body) ?: return
    val stickerManager = remember { StickerManager.getInstance(context) }

    val extension = if (sticker.format() == Sticker.FORMAT_ANIMATED) "tgs" else "webp"
    val fileName = "${sticker.stickerId()}.$extension"
    val localFile = remember(sticker.packId(), sticker.stickerId(), extension) {
        val f = stickerManager.getStickerFile(sticker.packId(), fileName)
        if (f != null && f.exists() && f.name.endsWith(".webp")) {
            // Validate that the file is not a raw WebM video mistakenly saved as webp
            try {
                FileInputStream(f).use { input ->
                    val header = ByteArray(4)
                    val read = input.read(header)
                    if (read == 4 && header[0] == 0x1A.toByte() && header[1] == 0x45.toByte() && header[2] == 0xDF.toByte() && header[3] == 0xA3.toByte()) {
                        f.delete()
                        return@remember null
                    }
                }
            } catch (ignored: Exception) {}
        }
        f?.takeIf { it.exists() }
    }

    val defaultBaseUrl = "https://stickers.snikket.penik.ru"
    val fileUrl = remember(sticker.url(), sticker.packId(), fileName) {
        if (!sticker.url().isNullOrBlank()) {
            sticker.url()
        } else {
            "$defaultBaseUrl/api/v1/stickers/file/${sticker.packId()}/$fileName"
        }
    }

    var lottieJson by remember(sticker.packId(), sticker.stickerId()) { mutableStateOf<String?>(null) }

    LaunchedEffect(sticker.packId(), sticker.stickerId(), localFile) {
        if (sticker.format() == Sticker.FORMAT_ANIMATED) {
            withContext(Dispatchers.IO) {
                try {
                    val fileToRead = if (localFile != null && localFile.exists()) {
                        localFile
                    } else {
                        val targetDir = File(context.filesDir, "stickers/${sticker.packId()}")
                        if (!targetDir.exists()) targetDir.mkdirs()
                        val cachedFile = File(targetDir, fileName)
                        if (!cachedFile.exists() || cachedFile.length() == 0L) {
                            val conn = URL(fileUrl).openConnection() as HttpURLConnection
                            conn.connectTimeout = 10000
                            conn.readTimeout = 10000
                            if (conn.responseCode in 200..299) {
                                conn.inputStream.use { input ->
                                    FileOutputStream(cachedFile).use { output ->
                                        input.copyTo(output)
                                    }
                                }
                            }
                        }
                        if (cachedFile.exists() && cachedFile.length() > 0L) cachedFile else null
                    }

                    if (fileToRead != null && fileToRead.exists()) {
                        val json = GZIPInputStream(FileInputStream(fileToRead)).bufferedReader().use { it.readText() }
                        withContext(Dispatchers.Main) {
                            lottieJson = json
                        }
                    }
                } catch (e: Exception) {
                    Log.e(Config.LOGTAG, "Failed to load/download animated sticker", e)
                }
            }
        }
    }

    val width = if (sticker.width() > 0) sticker.width() else 512
    val height = if (sticker.height() > 0) sticker.height() else 512
    val aspectRatio = (width.toFloat() / height.toFloat()).coerceIn(0.5f, 2.0f)

    Box(
        modifier = Modifier
            .padding(horizontal = 12.dp, vertical = 2.dp)
            .widthIn(min = 120.dp, max = 200.dp)
            .heightIn(min = 120.dp, max = 200.dp)
            .aspectRatio(aspectRatio)
            .combinedClickable(
                onClick = onClick,
                onLongClick = onLongClick
            )
    ) {
        if (sticker.format() == Sticker.FORMAT_ANIMATED) {
            if (lottieJson != null) {
                val composition by rememberLottieComposition(LottieCompositionSpec.JsonString(lottieJson!!))
                val progress by animateLottieCompositionAsState(
                    composition = composition,
                    iterations = LottieConstants.IterateForever
                )
                LottieAnimation(
                    composition = composition,
                    progress = { progress },
                    modifier = Modifier.matchParentSize()
                )
            } else {
                val thumbFile = stickerManager.getStickerThumbFile(sticker.packId(), sticker.stickerId())
                val thumbUrl = "$defaultBaseUrl/api/v1/stickers/file/${sticker.packId()}/thumb_${sticker.stickerId()}.webp"
                FallbackStickerImage(model = thumbFile ?: thumbUrl)
            }
        } else {
            val imageModel = if (localFile != null && localFile.exists()) localFile else fileUrl
            FallbackStickerImage(model = imageModel)
        }

        // Delivery ticks & time badge on semi-transparent background
        if (timeText.isNotEmpty()) {
            Box(
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(4.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .background(Color(0x66000000))
                    .padding(horizontal = 6.dp, vertical = 2.dp)
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = timeText,
                        color = Color.White.copy(alpha = 0.9f),
                        fontSize = 11.sp
                    )
                    if (isSentByMe) {
                        val accent = colorResource(R.color.penik_accent)
                        val status = message.status
                        if (status == Message.STATUS_SEND_DISPLAYED || status == Message.STATUS_SEND_RECEIVED) {
                            Icon(
                                imageVector = Icons.Default.DoneAll,
                                contentDescription = null,
                                tint = if (status == Message.STATUS_SEND_DISPLAYED) accent else Color.White.copy(alpha = 0.85f),
                                modifier = Modifier.padding(start = 3.dp).size(15.dp)
                            )
                        } else if (status == Message.STATUS_SEND) {
                            Icon(
                                imageVector = Icons.Default.Done,
                                contentDescription = null,
                                tint = Color.White.copy(alpha = 0.85f),
                                modifier = Modifier.padding(start = 3.dp).size(13.dp)
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun FallbackStickerImage(model: Any) {
    val context = LocalContext.current
    val imageRequest = remember(model) {
        val builder = ImageRequest.Builder(context)
            .data(model)
            .crossfade(true)
        if (Build.VERSION.SDK_INT >= 28) {
            builder.decoderFactory(ImageDecoderDecoder.Factory())
        }
        builder.build()
    }

    AsyncImage(
        model = imageRequest,
        contentDescription = "Sticker",
        contentScale = ContentScale.Fit,
        onSuccess = { state ->
            if (Build.VERSION.SDK_INT >= 28) {
                (state.result.drawable as? AnimatedImageDrawable)?.let { anim ->
                    anim.repeatCount = AnimatedImageDrawable.REPEAT_INFINITE
                    anim.start()
                }
            }
            (state.result.drawable as? Animatable)?.start()
        },
        onError = { state ->
            Log.e(Config.LOGTAG, "Sticker load failed for model $model: ${state.result.throwable.message}")
        },
        modifier = Modifier.fillMaxSize()
    )
}
