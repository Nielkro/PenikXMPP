package eu.siacs.conversations.ui.compose

import android.content.Context
import eu.siacs.conversations.entities.Conversation
import eu.siacs.conversations.entities.Conversational
import eu.siacs.conversations.entities.Message
import eu.siacs.conversations.services.XmppConnectionService
import eu.siacs.conversations.ui.adapter.MessageAdapter
import eu.siacs.conversations.utils.UIHelper
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.toPersistentList
import java.time.Instant
import java.util.concurrent.ConcurrentHashMap

object PenikConversationMapper {
    private val cachedConversations = ConcurrentHashMap<String, ConversationUi>()

    @JvmStatic
    fun map(conversations: List<Conversation>, context: Context): ImmutableList<ConversationUi> {
        val result = ArrayList<ConversationUi>(conversations.size)
        for (c in conversations) {
            val uuid = c.uuid ?: continue
            val ui = mapSingle(c, context, cachedConversations[uuid])
            cachedConversations[uuid] = ui
            result.add(ui)
        }
        return result.toPersistentList()
    }

    @JvmStatic
    fun mapSingle(c: Conversation, context: Context, prev: ConversationUi? = null): ConversationUi {
        val uuid = c.uuid ?: ""
        val accountUuid = c.account?.uuid ?: ""
        val isSelfChat = c.isSelf
        val displayName = if (isSelfChat) "Избранное" else (c.name?.toString() ?: "")
        val isRead = c.isRead
        val isPinned = c.isPinnedOnTop
        val isMuted = c.mutedTill?.let { it == Instant.MAX || it.isAfter(Instant.now()) } ?: false
        val isEncrypted = c.nextEncryption != Message.ENCRYPTION_NONE
        val unreadCount = c.unreadCount()
        val avatarBackgroundColor = c.avatarBackgroundColor
        val contactAvatar = runCatching { c.contact?.avatar }.getOrNull()
        val contactPhoto = runCatching { c.contact?.profilePhoto }.getOrNull()
        val mucAvatar = runCatching { c.mucOptions?.avatar }.getOrNull()
        val avatarKey = "${uuid}_${contactAvatar ?: contactPhoto ?: mucAvatar ?: ""}"

        val latest = if (c.hasMessages()) c.latestMessage else null
        val hasRealMessages = latest != null && latest.type != Message.TYPE_STATUS
        val draft = if (c.isRead) c.draft else null
        val timestamp = when {
            draft != null -> draft.instant().toEpochMilli()
            hasRealMessages -> latest.timeSent
            else -> 0L
        }

        val preview = when {
            draft != null -> PenikPreviewData(text = "Черновик: ${draft.message()}")
            hasRealMessages -> {
                val sender = if (latest.status == Message.STATUS_RECEIVED && c.mode == Conversational.MODE_MULTI) {
                    UIHelper.getMessageDisplayName(latest).split("\\s+".toRegex()).firstOrNull()?.plus(": ") ?: ""
                } else if (latest.status != Message.STATUS_RECEIVED && latest.type != Message.TYPE_STATUS && !isSelfChat) {
                    "Вы: "
                } else {
                    ""
                }
                penikMessagePreviewData(context, latest, sender)
            }
            isSelfChat -> PenikPreviewData(text = "Сообщения, заметки")
            else -> null
        }

        val previewSender = preview?.sender ?: ""
        val previewText = preview?.text ?: ""
        val previewIconRes = preview?.iconRes
        val isArchive = c.status == Conversation.STATUS_ARCHIVED

        if (prev != null &&
            prev.uuid == uuid &&
            prev.accountUuid == accountUuid &&
            prev.displayName == displayName &&
            prev.isSelfChat == isSelfChat &&
            prev.isRead == isRead &&
            prev.isPinned == isPinned &&
            prev.isMuted == isMuted &&
            prev.isEncrypted == isEncrypted &&
            prev.unreadCount == unreadCount &&
            prev.avatarBackgroundColor == avatarBackgroundColor &&
            prev.avatarKey == avatarKey &&
            prev.timestamp == timestamp &&
            prev.previewSender == previewSender &&
            prev.previewText == previewText &&
            prev.previewIconRes == previewIconRes &&
            prev.isArchive == isArchive
        ) {
            return prev
        }

        return ConversationUi(
            uuid = uuid,
            accountUuid = accountUuid,
            displayName = displayName,
            isSelfChat = isSelfChat,
            isRead = isRead,
            isPinned = isPinned,
            isMuted = isMuted,
            isEncrypted = isEncrypted,
            unreadCount = unreadCount,
            avatarBackgroundColor = avatarBackgroundColor,
            avatarKey = avatarKey,
            timestamp = timestamp,
            previewSender = previewSender,
            previewText = previewText,
            previewIconRes = previewIconRes,
            isArchive = isArchive
        )
    }

    @JvmStatic
    fun clearCache() {
        cachedConversations.clear()
    }
}

object PenikMessageMapper {
    private val cachedMessages = ConcurrentHashMap<String, ChatMessageUi>()

    @JvmStatic
    fun map(
        messages: List<Message>,
        isMuc: Boolean,
        showAvatars11: Boolean,
        service: XmppConnectionService?
    ): ImmutableList<ChatMessageUi> {
        val result = ArrayList<ChatMessageUi>(messages.size)
        val seenUuids = HashSet<String>()

        for (m in messages) {
            val uid = m.uuid ?: continue
            val body = m.body ?: ""
            if (m.type == Message.TYPE_STATUS) {
                if (body.isBlank() ||
                    body == MessageAdapter.BODY_DATE_SEPARATOR ||
                    body == MessageAdapter.BODY_LOAD_MORE ||
                    body == MessageAdapter.BODY_LOCAL_TIME ||
                    body == MessageAdapter.BODY_DND
                ) {
                    continue
                }
            }
            if (!seenUuids.add(uid)) {
                continue
            }
            val ui = mapSingle(m, isMuc, showAvatars11, service, cachedMessages[uid])
            cachedMessages[uid] = ui
            result.add(ui)
        }
        return result.toPersistentList()
    }

    @JvmStatic
    fun mapSingle(
        m: Message,
        isMuc: Boolean,
        showAvatars11: Boolean,
        service: XmppConnectionService?,
        prev: ChatMessageUi? = null
    ): ChatMessageUi {
        val uuid = m.uuid ?: ""
        val convUuid = m.conversation?.uuid ?: ""
        val timeSent = m.timeSent
        val status = m.status
        val type = m.type
        val body = m.body ?: ""
        val isSentByMe = status != Message.STATUS_RECEIVED
        val isEdited = m.edited()
        val senderName = UIHelper.getMessageDisplayName(m)
        val avatarBg = m.avatarBackgroundColor
        val avatarKey = "${convUuid}_${m.counterpart?.toString() ?: ""}"
        val readCount = m.readByMarkers?.size ?: 0
        val reactionsCount = m.reactions?.size ?: 0
        val showAvatar = isMuc || showAvatars11
        val isDeleted = m.isDeleted
        val isEncrypted = m.encryption != Message.ENCRYPTION_NONE
        val isGeoUri = m.isGeoUri
        val isSticker = m.isSticker || (body.startsWith("{\"pack_id\":") && body.contains("\"sticker_id\":"))
        val mimeType = m.mimeType ?: ""

        val fp = m.fileParams
        val fileUrl = fp?.url
        val rawFile = try {
            service?.fileBackend?.getFile(m, false)
        } catch (e: Exception) {
            null
        }
        val localFilePath = rawFile?.absolutePath
        val fileLength = fp?.size ?: 0L
        val lastModified = rawFile?.lastModified() ?: 0L
        val runtimeMs = fp?.runtime ?: 0
        val fileWidth = fp?.width ?: 0
        val fileHeight = fp?.height ?: 0

        val t = m.transferable
        val transferStatus = t?.status
        val transferProgress = t?.progress ?: 0

        val quote = body.startsWith(">")
        val hasBotMarkup = m.botMarkup != null
        val rowKey = "msg-$uuid"

        if (prev != null &&
            prev.uuid == uuid &&
            prev.conversationUuid == convUuid &&
            prev.timeSent == timeSent &&
            prev.status == status &&
            prev.type == type &&
            prev.body == body &&
            prev.isSentByMe == isSentByMe &&
            prev.isEdited == isEdited &&
            prev.senderName == senderName &&
            prev.avatarBackgroundColor == avatarBg &&
            prev.avatarKey == avatarKey &&
            prev.readCount == readCount &&
            prev.reactionsCount == reactionsCount &&
            prev.isMuc == isMuc &&
            prev.showAvatar == showAvatar &&
            prev.isDeleted == isDeleted &&
            prev.isEncrypted == isEncrypted &&
            prev.isGeoUri == isGeoUri &&
            prev.isSticker == isSticker &&
            prev.mimeType == mimeType &&
            prev.fileUrl == fileUrl &&
            prev.localFilePath == localFilePath &&
            prev.fileLength == fileLength &&
            prev.lastModified == lastModified &&
            prev.runtimeMs == runtimeMs &&
            prev.fileWidth == fileWidth &&
            prev.fileHeight == fileHeight &&
            prev.transferStatus == transferStatus &&
            prev.transferProgress == transferProgress &&
            prev.hasQuote == quote &&
            prev.hasBotMarkup == hasBotMarkup
        ) {
            return prev
        }

        return ChatMessageUi(
            uuid = uuid,
            conversationUuid = convUuid,
            timeSent = timeSent,
            status = status,
            type = type,
            body = body,
            isSentByMe = isSentByMe,
            isEdited = isEdited,
            senderName = senderName,
            avatarBackgroundColor = avatarBg,
            avatarKey = avatarKey,
            readCount = readCount,
            reactionsCount = reactionsCount,
            isMuc = isMuc,
            showAvatar = showAvatar,
            isDeleted = isDeleted,
            isEncrypted = isEncrypted,
            isGeoUri = isGeoUri,
            isSticker = isSticker,
            mimeType = mimeType,
            fileUrl = fileUrl,
            localFilePath = localFilePath,
            fileLength = fileLength,
            lastModified = lastModified,
            runtimeMs = runtimeMs,
            fileWidth = fileWidth,
            fileHeight = fileHeight,
            transferStatus = transferStatus,
            transferProgress = transferProgress,
            hasQuote = quote,
            hasBotMarkup = hasBotMarkup,
            rowKey = rowKey
        )
    }

    @JvmStatic
    fun clearCache() {
        cachedMessages.clear()
    }
}
