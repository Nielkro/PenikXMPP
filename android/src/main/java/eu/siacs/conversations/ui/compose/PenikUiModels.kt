package eu.siacs.conversations.ui.compose

import androidx.compose.runtime.Immutable
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf

@Immutable
data class ConversationUi(
    val uuid: String,
    val accountUuid: String,
    val displayName: String,
    val isSelfChat: Boolean,
    val isRead: Boolean,
    val isPinned: Boolean,
    val isMuted: Boolean,
    val isEncrypted: Boolean,
    val unreadCount: Int,
    val avatarBackgroundColor: Int,
    val avatarKey: String,
    val timestamp: Long,
    val previewSender: String = "",
    val previewText: String = "",
    val previewIconRes: Int? = null,
    val isArchive: Boolean = false
)

@Immutable
data class ChatMessageUi(
    val uuid: String,
    val conversationUuid: String,
    val timeSent: Long,
    val status: Int,
    val type: Int,
    val body: String,
    val isSentByMe: Boolean,
    val isEdited: Boolean,
    val senderName: String,
    val avatarBackgroundColor: Int,
    val avatarKey: String,
    val readCount: Int = 0,
    val reactionsCount: Int = 0,
    val isMuc: Boolean = false,
    val showAvatar: Boolean = false,
    val isDeleted: Boolean = false,
    val isEncrypted: Boolean = false,
    val isGeoUri: Boolean = false,
    val isSticker: Boolean = false,
    val mimeType: String = "",
    val fileUrl: String? = null,
    val localFilePath: String? = null,
    val fileLength: Long = 0L,
    val lastModified: Long = 0L,
    val runtimeMs: Int = 0,
    val fileWidth: Int = 0,
    val fileHeight: Int = 0,
    val transferStatus: Int? = null,
    val transferProgress: Int = 0,
    val hasQuote: Boolean = false,
    val quoteAuthor: String? = null,
    val quoteText: String? = null,
    val quoteTargetUuid: String? = null,
    val hasBotMarkup: Boolean = false,
    val rowKey: String = "msg-$uuid"
)

@Immutable
class PenikChatCallbacks(
    val onAction: (String, String) -> Unit = { _, _ -> }, // (action, uuid)
    val onAvatarClick: (String) -> Unit = {},
    val onQuoteClick: (String, String) -> Unit = { _, _ -> },
    val onUrlClick: (String) -> Unit = {},
    val onStickerClick: (String) -> Unit = {},
    val onBotButtonClick: (String, eu.siacs.conversations.entities.BotMarkup.Button) -> Unit = { _, _ -> }
)

@Immutable
class PenikChatsCallbacks(
    val onConversationClick: (String) -> Unit = {},
    val onConversationLongClick: (String) -> Unit = {},
    val onArchiveClick: () -> Unit = {}
)
