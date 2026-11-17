package eu.siacs.conversations.ui.compose

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Done
import androidx.compose.material.icons.filled.DoneAll
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.res.colorResource
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import eu.siacs.conversations.R
import eu.siacs.conversations.entities.Message

@Composable
fun PenikDateHeader(label: String) {
    val panelSecondary = colorResource(R.color.penik_panel_secondary)
    val textPrimary = colorResource(R.color.penik_text_primary)
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
            Text(
                    text = label,
                    color = textPrimary,
                    fontSize = 12.5.sp,
                    fontWeight = FontWeight.SemiBold
            )
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
    val color = if (read) accent else tint
    Icon(
            imageVector = if (double) Icons.Default.DoneAll else Icons.Default.Done,
            contentDescription = null,
            tint = color,
            modifier = modifier.size(if (double) 16.dp else 14.dp)
    )
}

@Composable
fun PenikMessageStatusIcon(
        status: Int,
        tint: Color,
        accent: Color,
        danger: Color,
        modifier: Modifier = Modifier
) {
    when (status) {
        Message.STATUS_WAITING, Message.STATUS_UNSEND -> {
            Icon(
                    painter = painterResource(R.drawable.ic_schedule_24dp),
                    contentDescription = "Ожидание отправки",
                    tint = tint,
                    modifier = modifier.size(12.dp)
            )
        }
        Message.STATUS_SEND_FAILED -> {
            Icon(
                    painter = painterResource(R.drawable.ic_error_24dp),
                    contentDescription = "Не удалось отправить",
                    tint = danger,
                    modifier = modifier.size(13.dp)
            )
        }
        Message.STATUS_SEND -> {
            Icon(
                    imageVector = Icons.Default.Done,
                    contentDescription = "Отправлено",
                    tint = tint,
                    modifier = modifier.size(14.dp)
            )
        }
        Message.STATUS_SEND_RECEIVED -> {
            Icon(
                    imageVector = Icons.Default.DoneAll,
                    contentDescription = "Доставлено",
                    tint = tint,
                    modifier = modifier.size(16.dp)
            )
        }
        Message.STATUS_SEND_DISPLAYED -> {
            Icon(
                    imageVector = Icons.Default.DoneAll,
                    contentDescription = "Прочитано",
                    tint = accent,
                    modifier = modifier.size(16.dp)
            )
        }
        else -> {
            Icon(
                    imageVector = Icons.Default.Done,
                    contentDescription = null,
                    tint = tint,
                    modifier = modifier.size(14.dp)
            )
        }
    }
}

@Composable
fun PenikMetaRow(
        timeText: String,
        isEncrypted: Boolean,
        edited: Boolean,
        overlayDark: Boolean,
        baseColor: Color,
        status: Int = Message.STATUS_RECEIVED,
        isSentByMe: Boolean = false,
        accent: Color = Color.Unspecified
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
        if (isSentByMe && status != Message.STATUS_RECEIVED) {
            Spacer(modifier = Modifier.width(4.dp))
            PenikMessageStatusIcon(
                    status = status,
                    tint = if (overlayDark) Color.White.copy(alpha = 0.85f) else baseColor,
                    accent = if (accent != Color.Unspecified) accent else Color(0xFF64B5F6),
                    danger = Color(0xFFF05A5A)
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

@Preview(showBackground = true, backgroundColor = 0xFF0F172A)
@Composable
private fun PenikChatPrimitivesPreview() {
    Column(modifier = Modifier.padding(16.dp)) {
        PenikDateHeader(label = "Сегодня")
        Spacer(modifier = Modifier.size(8.dp))
        PenikMetaRow(
            timeText = "14:45",
            isEncrypted = true,
            edited = true,
            overlayDark = false,
            baseColor = Color.LightGray,
            status = Message.STATUS_SEND_DISPLAYED,
            isSentByMe = true,
            accent = Color(0xFF38BDF8)
        )
        Spacer(modifier = Modifier.size(8.dp))
        PenikStatusRow(text = "Чат зашифрован с помощью OMEMO")
    }
}
