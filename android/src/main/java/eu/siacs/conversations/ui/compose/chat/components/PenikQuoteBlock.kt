package eu.siacs.conversations.ui.compose

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

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
    val cleanRaw = raw.replace("\\[[^\\]]*\\]\\(penik:msg:[^)]+\\)".toRegex(), "").trim()
    val trimmed = cleanRaw.trim()
    if (trimmed.startsWith("{") && trimmed.contains("\"pack_id\"") && trimmed.contains("\"sticker_id\"")) {
        val emojiRegex = "\"emoji\"\\s*:\\s*\"([^\"]+)\"".toRegex()
        val emoji = emojiRegex.find(trimmed)?.groupValues?.get(1)?.trim()?.let { "$it " } ?: ""
        return "${emoji}Стикер"
    }
    if (trimmed.startsWith("🎨")) {
        val rest = trimmed.removePrefix("🎨").trim()
        val emoji = rest.removePrefix("Стикер").trim()
        return if (emoji.isNotEmpty()) "$emoji Стикер" else "Стикер"
    }
    if (trimmed.startsWith("geo:")) {
        return "📍 Местоположение"
    }
    if (trimmed.startsWith("aesgcm://", ignoreCase = true)) {
        val cleanUrl = trimmed.substring("aesgcm://".length).substringBefore("|").trim()
        val lower = cleanUrl.lowercase().substringBefore("?").substringBefore("#")
        val ext = lower.substringAfterLast(".", "")
        return when {
            ext in listOf("jpg", "jpeg", "png", "webp", "gif", "bmp") -> "📷 Фото"
            ext in listOf("ogg", "mp3", "m4a", "opus", "wav", "aac") -> "🎙 Голосовое сообщение"
            ext in listOf("mp4", "webm", "mov", "mkv", "3gp", "avi") -> "🎬 Видео"
            else -> {
                val fileName = try {
                    java.net.URI("https://$cleanUrl").path?.substringAfterLast("/")?.takeIf { it.isNotBlank() }
                } catch (e: Exception) {
                    null
                }
                if (fileName != null) "📎 $fileName" else "📎 Файл"
            }
        }
    }
    return cleanRaw
}

@Composable
fun PenikQuoteBlock(
        quote: String,
        barColor: Color,
        textColor: Color,
        isSentByMe: Boolean = false,
        onClick: (() -> Unit)? = null
) {
    val cleanQuote = quote.replace("\\[[^\\]]*\\]\\(penik:msg:[^)]+\\)".toRegex(), "").trim()
    val lines = cleanQuote.lines()
    val firstLine = lines.firstOrNull() ?: ""
    val isRawJson = firstLine.trim().startsWith("{")
    val hasColon = !isRawJson && firstLine.contains(": ") &&
            !firstLine.startsWith("http://", ignoreCase = true) &&
            !firstLine.startsWith("https://", ignoreCase = true) &&
            !firstLine.startsWith("aesgcm://", ignoreCase = true) &&
            !firstLine.startsWith("geo:", ignoreCase = true) &&
            !firstLine.startsWith("xmpp:", ignoreCase = true)

    val author = if (hasColon) firstLine.substringBefore(": ").trim().takeIf { it.isNotBlank() } else null
    val rawContent = if (hasColon) {
        val remainder = firstLine.substringAfter(": ").trim()
        (listOf(remainder) + lines.drop(1)).joinToString("\n").trim()
    } else {
        cleanQuote
    }
    val content = if (rawContent.startsWith(">") || rawContent.startsWith("»")) {
        rawContent.lines().dropWhile { it.trimStart().startsWith(">") || it.trimStart().startsWith("»") }.joinToString("\n").trim().ifEmpty { rawContent }
    } else {
        rawContent
    }

    Row(
            modifier =
                    Modifier.fillMaxWidth()
                            .padding(bottom = 6.dp)
                            .clip(RoundedCornerShape(6.dp))
                            .background(Color(0x12FFFFFF))
                            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
                            .height(IntrinsicSize.Max),
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

@Preview(showBackground = true, backgroundColor = 0xFF1E293B)
@Composable
private fun PenikQuoteBlockPreview() {
    Column(modifier = Modifier.padding(16.dp)) {
        PenikQuoteBlock(
            quote = "Alice: Hey, are you ready for the release?",
            barColor = Color(0xFF38BDF8),
            textColor = Color.White
        )
    }
}
