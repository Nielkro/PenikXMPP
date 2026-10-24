package eu.siacs.conversations.ui.compose

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.res.colorResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import eu.siacs.conversations.R
import eu.siacs.conversations.entities.BotCommand

object PenikBotCommandsBridge {
    @JvmStatic
    fun renderBotCommandsPopup(
            view: ComposeView,
            commands: List<BotCommand>,
            onCommandClick: java.util.function.Consumer<BotCommand>,
            onClose: Runnable
    ) {
        view.setContent {
            PenikBotCommandsPopup(
                    commands = commands,
                    onCommandClick = { onCommandClick.accept(it) },
                    onClose = { onClose.run() }
            )
        }
    }
}

@Composable
fun PenikBotCommandsPopup(
        commands: List<BotCommand>,
        onCommandClick: (BotCommand) -> Unit,
        onClose: () -> Unit,
        modifier: Modifier = Modifier
) {
    if (commands.isEmpty()) return

    val panelBackground = colorResource(R.color.penik_panel)
    val textColor = colorResource(R.color.penik_text_primary)
    val mutedColor = colorResource(R.color.penik_text_muted)
    val accentColor = colorResource(R.color.penik_accent)
    val dividerColor = colorResource(R.color.penik_divider)

    Column(
            modifier = modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(topStart = 16.dp, topEnd = 16.dp))
                    .background(panelBackground)
                    .border(
                            width = 1.dp,
                            color = dividerColor.copy(alpha = 0.5f),
                            shape = RoundedCornerShape(topStart = 16.dp, topEnd = 16.dp)
                    )
                    .padding(top = 10.dp, bottom = 4.dp)
    ) {
        // Header
        Row(
                modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 14.dp, vertical = 2.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                        modifier = Modifier
                                .size(24.dp)
                                .clip(CircleShape)
                                .background(accentColor.copy(alpha = 0.16f)),
                        contentAlignment = Alignment.Center
                ) {
                    Text(
                            text = "/",
                            color = accentColor,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.Bold
                    )
                }
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                        text = "Команды бота",
                        color = textColor,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold
                )
            }
            Box(
                    modifier = Modifier
                            .size(24.dp)
                            .clip(CircleShape)
                            .clickable { onClose() },
                    contentAlignment = Alignment.Center
            ) {
                Text(
                        text = "✕",
                        color = mutedColor,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Bold
                )
            }
        }

        Spacer(modifier = Modifier.height(6.dp))

        // Commands List
        LazyColumn(
                modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(max = 200.dp)
        ) {
            items(commands) { cmd ->
                Row(
                        modifier = Modifier
                                .fillMaxWidth()
                                .clickable { onCommandClick(cmd) }
                                .padding(horizontal = 14.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                            text = "/" + cmd.command,
                            color = accentColor,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.Bold
                    )
                    Spacer(modifier = Modifier.width(12.dp))
                    Text(
                            text = cmd.description,
                            color = mutedColor,
                            fontSize = 13.sp,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                    )
                }
            }
        }
    }
}
