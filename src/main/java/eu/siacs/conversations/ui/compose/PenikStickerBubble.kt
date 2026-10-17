package eu.siacs.conversations.ui.compose

import android.os.Build
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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import coil.decode.ImageDecoderDecoder
import coil.request.ImageRequest
import com.airbnb.lottie.compose.LottieAnimation
import com.airbnb.lottie.compose.LottieCompositionSpec
import com.airbnb.lottie.compose.LottieConstants
import com.airbnb.lottie.compose.animateLottieCompositionAsState
import com.airbnb.lottie.compose.rememberLottieComposition
import eu.siacs.conversations.entities.Message
import eu.siacs.conversations.entities.Sticker
import eu.siacs.conversations.stickers.StickerManager
import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileInputStream
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
    val sticker = message.sticker ?: return
    val stickerManager = remember { StickerManager.getInstance(context) }

    val extension = if (sticker.format() == Sticker.FORMAT_ANIMATED) "tgs" else "webp"
    val localFile = remember(sticker.packId(), sticker.stickerId()) {
        stickerManager.getStickerFile(sticker.packId(), "${sticker.stickerId()}.$extension")
    }

    val model = localFile ?: sticker.url()

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
        if (sticker.format() == Sticker.FORMAT_ANIMATED && localFile != null && localFile.exists()) {
            val lottieJson = remember(localFile.absolutePath) {
                try {
                    GZIPInputStream(FileInputStream(localFile)).bufferedReader().use { it.readText() }
                } catch (e: Exception) {
                    null
                }
            }

            if (lottieJson != null) {
                val composition by rememberLottieComposition(LottieCompositionSpec.JsonString(lottieJson))
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
                FallbackStickerImage(model = model)
            }
        } else {
            FallbackStickerImage(model = model)
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
                        val status = message.status
                        if (status == Message.STATUS_SEND_DISPLAYED || status == Message.STATUS_SEND_RECEIVED) {
                            Icon(
                                imageVector = Icons.Default.DoneAll,
                                contentDescription = null,
                                tint = if (status == Message.STATUS_SEND_DISPLAYED) Color(0xFF64B5F6) else Color.White.copy(alpha = 0.9f),
                                modifier = Modifier.padding(start = 3.dp).size(13.dp)
                            )
                        } else if (status == Message.STATUS_SEND) {
                            Icon(
                                imageVector = Icons.Default.Done,
                                contentDescription = null,
                                tint = Color.White.copy(alpha = 0.9f),
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
        modifier = Modifier.fillMaxSize()
    )
}
