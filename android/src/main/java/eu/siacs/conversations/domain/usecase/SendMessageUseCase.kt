package eu.siacs.conversations.domain.usecase

import com.google.common.base.Strings
import eu.siacs.conversations.entities.Conversation
import eu.siacs.conversations.entities.Conversational
import eu.siacs.conversations.entities.Message
import eu.siacs.conversations.services.XmppConnectionService
import eu.siacs.conversations.utils.MessageUtils
import eu.siacs.conversations.utils.UIHelper
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class SendMessageUseCase(
    private val serviceProvider: () -> XmppConnectionService?
) {
    suspend operator fun invoke(
        conversation: Conversation,
        rawText: String,
        replyMessage: Message? = null
    ): Result<Message> = withContext(Dispatchers.IO) {
        runCatching {
            var body = rawText.trim()
            if (body.isEmpty()) {
                throw IllegalArgumentException("Message body cannot be empty")
            }

            val service = serviceProvider() ?: throw IllegalStateException("XmppConnectionService is not available")

            if (replyMessage != null) {
                val author = if (replyMessage.status == Message.STATUS_RECEIVED) {
                    if (replyMessage.conversation.mode == Conversational.MODE_MULTI) {
                        Strings.nullToEmpty(replyMessage.counterpart?.resource)
                    } else {
                        replyMessage.contact?.publicDisplayName ?: ""
                    }
                } else {
                    UIHelper.getMessageDisplayName(replyMessage)
                }

                val quoteBody = when {
                    replyMessage.isSticker || replyMessage.type == Message.TYPE_STICKER -> "Стикер"
                    replyMessage.isFileOrImage -> when {
                        replyMessage.type == Message.TYPE_IMAGE || replyMessage.mimeType?.startsWith("image/") == true -> "📷 Фото"
                        replyMessage.mimeType?.startsWith("audio/") == true -> "🎙 Голосовое сообщение"
                        replyMessage.mimeType?.startsWith("video/") == true -> "🎬 Видео"
                        replyMessage.isGeoUri -> "📍 Местоположение"
                        else -> "📎 Файл"
                    }
                    replyMessage.isGeoUri -> "📍 Местоположение"
                    else -> MessageUtils.prepareQuote(replyMessage)
                }

                if (quoteBody.isNotEmpty()) {
                    val replyUuid = replyMessage.uuid
                    val ref = if (!Strings.isNullOrEmpty(replyUuid)) "[\u200B](penik:msg:$replyUuid)" else ""
                    body = "> $ref" + (if (author.isEmpty()) "" else "$author: ") + quoteBody.replace("\n", "\n> ") + "\n\n" + body
                }
            }

            if (conversation.nextEncryption == Message.ENCRYPTION_AXOLOTL) {
                conversation.account?.axolotlService?.let { axolotlService ->
                    conversation.setAcceptedCryptoTargets(axolotlService.getCryptoTargets(conversation))
                    axolotlService.createSessionsIfNeeded(conversation)
                }
            }

            val message: Message
            if (conversation.correctingMessage == null) {
                message = Message(conversation, body, conversation.nextEncryption)
                Message.configurePrivateMessage(message)
            } else {
                message = conversation.correctingMessage
                val uuid = message.uuid
                message.putEdited(Message.BodyVersion(body, conversation.nextEncryption, null))
                service.databaseBackend.updateMessage(message, uuid)
            }

            service.sendMessage(message)
            message
        }
    }
}
