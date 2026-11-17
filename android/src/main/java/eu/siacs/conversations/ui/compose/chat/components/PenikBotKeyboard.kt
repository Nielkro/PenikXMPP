package eu.siacs.conversations.ui.compose

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.colorResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import eu.siacs.conversations.R
import eu.siacs.conversations.entities.BotMarkup
import eu.siacs.conversations.entities.Message

@Composable
fun PenikBotKeyboard(
        markup: BotMarkup,
        onButtonClick: (BotMarkup.Button) -> Unit,
        modifier: Modifier = Modifier
) {
    val rows = markup.rows
    if (rows.isEmpty()) return

    Column(
            modifier = modifier.padding(top = 4.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp)
    ) {
        for (row in rows) {
            Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                for (btn in row) {
                    var lastClickTime by remember { mutableStateOf(0L) }
                    Box(
                            modifier = Modifier
                                    .weight(1f)
                                    .clip(RoundedCornerShape(8.dp))
                                    .background(Color(0xFF2A85FF).copy(alpha = 0.16f))
                                    .clickable {
                                        val now = System.currentTimeMillis()
                                        if (now - lastClickTime > 350) {
                                            lastClickTime = now
                                            onButtonClick(btn)
                                        }
                                    }
                                    .padding(vertical = 8.dp, horizontal = 8.dp),
                            contentAlignment = Alignment.Center
                    ) {
                        Text(
                                text = btn.text,
                                color = Color(0xFF2A85FF),
                                fontSize = 13.sp,
                                fontWeight = FontWeight.SemiBold,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                        )
                    }
                }
            }
        }
    }
}

@Composable
fun PenikBotKeyboard(
        markup: BotMarkup,
        message: Message,
        listener: PenikChatListener,
        modifier: Modifier = Modifier
) {
    PenikBotKeyboard(
        markup = markup,
        onButtonClick = { btn -> listener.onBotButtonClick(message, btn) },
        modifier = modifier
    )
}

@Composable
fun PenikBotReplyKeyboard(
        markup: BotMarkup,
        onButtonClick: (BotMarkup.Button) -> Unit,
        modifier: Modifier = Modifier
) {
    val rows = markup.rows
    if (rows.isEmpty()) return

    val panelBackground = colorResource(R.color.penik_background)
    val buttonBackground = colorResource(R.color.penik_panel_secondary)
    val textColor = colorResource(R.color.penik_text_primary)

    Column(
            modifier = modifier
                    .fillMaxWidth()
                    .background(panelBackground)
                    .padding(horizontal = 8.dp, vertical = 6.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        for (row in rows) {
            Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                for (btn in row) {
                    Box(
                            modifier = Modifier
                                    .weight(1f)
                                    .height(44.dp)
                                    .clip(RoundedCornerShape(10.dp))
                                    .background(buttonBackground)
                                    .clickable {
                                        onButtonClick(btn)
                                    }
                                    .padding(horizontal = 8.dp),
                            contentAlignment = Alignment.Center
                    ) {
                        Text(
                                text = btn.text,
                                color = textColor,
                                fontSize = 14.sp,
                                fontWeight = FontWeight.Medium,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                        )
                    }
                }
            }
        }
    }
}

@Preview(showBackground = true, backgroundColor = 0xFF1E293B)
@Composable
private fun PenikBotReplyKeyboardPreview() {
    val rows = listOf(
        listOf(BotMarkup.Button("Option 1"), BotMarkup.Button("Option 2")),
        listOf(BotMarkup.Button("Cancel"))
    )
    val markup = BotMarkup(BotMarkup.Type.REPLY, rows, true, false)

    PenikBotReplyKeyboard(
        markup = markup,
        onButtonClick = {}
    )
}
