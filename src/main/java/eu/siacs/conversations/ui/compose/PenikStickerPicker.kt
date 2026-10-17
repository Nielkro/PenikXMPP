package eu.siacs.conversations.ui.compose

import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.History
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.ui.text.TextStyle
import androidx.compose.material3.ScrollableTabRow
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
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
import coil.request.ImageRequest
import eu.siacs.conversations.R
import eu.siacs.conversations.entities.Sticker
import eu.siacs.conversations.stickers.StickerItem
import eu.siacs.conversations.stickers.StickerManager
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PenikStickerPickerBottomSheet(
    serverBaseUrl: String,
    authToken: String,
    onDismiss: () -> Unit,
    onStickerPicked: (Sticker) -> Unit
) {
    val context = LocalContext.current
    val stickerManager = remember { StickerManager.getInstance(context) }
    val installedPacks by stickerManager.installedPacks.collectAsState()
    val recentStickers by stickerManager.recentStickers.collectAsState()
    val scope = rememberCoroutineScope()

    var selectedTabIndex by remember { mutableIntStateOf(0) }
    var showImportDialog by remember { mutableStateOf(false) }
    var importUrlInput by remember { mutableStateOf("") }
    var isImporting by remember { mutableStateOf(false) }

    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    val panelBg = colorResource(R.color.penik_panel)
    val panelSecondary = colorResource(R.color.penik_panel_secondary)
    val accentColor = colorResource(R.color.penik_accent)
    val textPrimary = colorResource(R.color.penik_text_primary)
    val textMuted = colorResource(R.color.penik_text_muted)

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = panelBg,
        dragHandle = null
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .fillMaxHeight(0.6f)
                .navigationBarsPadding()
        ) {
            // Header / Tabs
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(panelSecondary)
                    .padding(horizontal = 8.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                // Tab items: 0 = Recent, 1..N = Packs
                LazyRow(
                    modifier = Modifier.weight(1f),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    // Recent Tab
                    item {
                        val isSelected = selectedTabIndex == 0
                        Box(
                            modifier = Modifier
                                .size(40.dp)
                                .clip(RoundedCornerShape(8.dp))
                                .background(if (isSelected) accentColor.copy(alpha = 0.2f) else Color.Transparent)
                                .clickable { selectedTabIndex = 0 },
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(
                                imageVector = Icons.Default.History,
                                contentDescription = "Recent",
                                tint = if (isSelected) accentColor else textMuted,
                                modifier = Modifier.size(24.dp)
                            )
                        }
                    }

                    // Pack Tabs
                    itemsIndexed(installedPacks) { index, pack ->
                        val tabIndex = index + 1
                        val isSelected = selectedTabIndex == tabIndex
                        val coverThumb = remember(pack.header.id, pack.header.coverStickerId) {
                            stickerManager.getStickerThumbFile(pack.header.id, pack.header.coverStickerId)
                        }

                        Box(
                            modifier = Modifier
                                .size(40.dp)
                                .clip(RoundedCornerShape(8.dp))
                                .background(if (isSelected) accentColor.copy(alpha = 0.2f) else Color.Transparent)
                                .clickable { selectedTabIndex = tabIndex },
                            contentAlignment = Alignment.Center
                        ) {
                            if (coverThumb != null && coverThumb.exists()) {
                                AsyncImage(
                                    model = coverThumb,
                                    contentDescription = pack.header.title,
                                    contentScale = ContentScale.Fit,
                                    modifier = Modifier.size(32.dp)
                                )
                            } else {
                                Text(
                                    text = pack.header.title.take(1).uppercase(),
                                    color = if (isSelected) accentColor else textMuted,
                                    fontSize = 14.sp
                                )
                            }
                        }
                    }
                }

                // Add button (+)
                IconButton(
                    onClick = { showImportDialog = true },
                    modifier = Modifier.size(36.dp)
                ) {
                    Icon(
                        imageVector = Icons.Default.Add,
                        contentDescription = "Add Sticker Pack",
                        tint = accentColor
                    )
                }
            }

            // Stickers Grid
            val currentStickers: List<StickerItem> = if (selectedTabIndex == 0) {
                recentStickers
            } else {
                val packIdx = selectedTabIndex - 1
                if (packIdx in installedPacks.indices) installedPacks[packIdx].stickers else emptyList()
            }

            if (currentStickers.isEmpty()) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(24.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = if (selectedTabIndex == 0) "Нет недавних стикеров" else "В этом наборе нет стикеров",
                        color = textMuted,
                        fontSize = 14.sp
                    )
                }
            } else {
                LazyVerticalGrid(
                    columns = GridCells.Fixed(4),
                    contentPadding = PaddingValues(8.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.fillMaxSize()
                ) {
                    items(currentStickers, key = { it.id }) { stickerItem ->
                        val thumbFile = remember(stickerItem.packId, stickerItem.id) {
                            stickerManager.getStickerThumbFile(stickerItem.packId, stickerItem.id)
                        }
                        val model = thumbFile ?: stickerItem.url

                        Box(
                            modifier = Modifier
                                .aspectRatio(1f)
                                .clip(RoundedCornerShape(8.dp))
                                .clickable {
                                    val sticker = Sticker(
                                        stickerItem.packId,
                                        stickerItem.id,
                                        stickerItem.emoji,
                                        stickerItem.width,
                                        stickerItem.height,
                                        stickerItem.format,
                                        stickerItem.url
                                    )
                                    stickerManager.addRecentSticker(sticker)
                                    onStickerPicked(sticker)
                                    onDismiss()
                                }
                                .padding(4.dp),
                            contentAlignment = Alignment.Center
                        ) {
                            AsyncImage(
                                model = ImageRequest.Builder(context)
                                    .data(model)
                                    .crossfade(true)
                                    .build(),
                                contentDescription = stickerItem.emoji,
                                contentScale = ContentScale.Fit,
                                modifier = Modifier.fillMaxSize()
                            )
                        }
                    }
                }
            }
        }
    }

    // Import Dialog
    if (showImportDialog) {
        AlertDialog(
            onDismissRequest = { if (!isImporting) showImportDialog = false },
            title = { Text(text = "Добавить стикерпак", color = textPrimary) },
            text = {
                Column {
                    Text(
                        text = "Вставьте ссылку Telegram вида t.me/addstickers/...",
                        color = textMuted,
                        fontSize = 13.sp
                    )
                    Spacer(modifier = Modifier.height(12.dp))
                    OutlinedTextField(
                        value = importUrlInput,
                        onValueChange = { importUrlInput = it },
                        placeholder = { Text("t.me/addstickers/name", color = textMuted) },
                        textStyle = TextStyle(color = textPrimary, fontSize = 14.sp),
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedTextColor = textPrimary,
                            unfocusedTextColor = textPrimary,
                            focusedContainerColor = panelSecondary,
                            unfocusedContainerColor = panelSecondary,
                            focusedBorderColor = accentColor,
                            unfocusedBorderColor = Color.Transparent,
                            cursorColor = accentColor
                        ),
                        shape = RoundedCornerShape(12.dp),
                        singleLine = true,
                        enabled = !isImporting,
                        modifier = Modifier.fillMaxWidth()
                    )
                    if (isImporting) {
                        Spacer(modifier = Modifier.height(16.dp))
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(24.dp),
                                color = accentColor,
                                strokeWidth = 2.dp
                            )
                            Spacer(modifier = Modifier.width(12.dp))
                            Text(
                                text = "Импорт и загрузка стикеров...",
                                color = textMuted,
                                fontSize = 13.sp
                            )
                        }
                    }
                }
            },
            confirmButton = {
                Button(
                    onClick = {
                        val input = importUrlInput.trim()
                        if (input.isNotEmpty()) {
                            isImporting = true
                            scope.launch {
                                val result = stickerManager.importTelegramPack(serverBaseUrl, authToken, input)
                                isImporting = false
                                if (result.isSuccess) {
                                    showImportDialog = false
                                    importUrlInput = ""
                                    Toast.makeText(context, "Стикерпак успешно добавлен!", Toast.LENGTH_SHORT).show()
                                } else {
                                    val err = result.exceptionOrNull()?.message ?: "Ошибка"
                                    Toast.makeText(context, "Не удалось добавить: $err", Toast.LENGTH_LONG).show()
                                }
                            }
                        }
                    },
                    enabled = !isImporting && importUrlInput.isNotBlank()
                ) {
                    Text("Импортировать")
                }
            },
            dismissButton = {
                if (!isImporting) {
                    TextButton(onClick = { showImportDialog = false }) {
                        Text("Отмена", color = textMuted)
                    }
                }
            },
            containerColor = panelBg
        )
    }
}
