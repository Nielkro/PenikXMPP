package eu.siacs.conversations.domain.usecase

import android.content.Context
import eu.siacs.conversations.Config
import eu.siacs.conversations.entities.Conversation
import eu.siacs.conversations.entities.Message
import eu.siacs.conversations.entities.Sticker
import eu.siacs.conversations.services.XmppConnectionService
import eu.siacs.conversations.stickers.StickerManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class SendStickerUseCase(
    private val serviceProvider: () -> XmppConnectionService?
) {
    suspend operator fun invoke(
        conversation: Conversation,
        sticker: Sticker,
        context: Context? = null
    ): Result<Message> = withContext(Dispatchers.IO) {
        runCatching {
            val service = serviceProvider() ?: throw IllegalStateException("XmppConnectionService is not available")

            if (conversation.nextEncryption == Message.ENCRYPTION_AXOLOTL) {
                conversation.account?.axolotlService?.let { axolotlService ->
                    conversation.setAcceptedCryptoTargets(axolotlService.getCryptoTargets(conversation))
                    axolotlService.createSessionsIfNeeded(conversation)
                }
            }

            val finalSticker = if (sticker.url().isNullOrEmpty()) {
                val ext = if (Sticker.FORMAT_ANIMATED == sticker.format()) "tgs" else "webp"
                val fileName = "${sticker.stickerId()}.$ext"
                val resolvedUrl = "${Config.STICKERS_BASE_URL}/api/v1/stickers/file/${sticker.packId()}/$fileName"
                Sticker(
                    sticker.packId(),
                    sticker.stickerId(),
                    sticker.emoji(),
                    sticker.width(),
                    sticker.height(),
                    sticker.format(),
                    resolvedUrl
                )
            } else {
                sticker
            }

            val message = Message(conversation, finalSticker.toJson(), conversation.nextEncryption)
            message.type = Message.TYPE_STICKER
            Message.configurePrivateMessage(message)

            context?.let { ctx ->
                try {
                    StickerManager.getInstance(ctx).addRecentSticker(finalSticker)
                } catch (ignored: Exception) {}
            }

            service.sendMessage(message)
            message
        }
    }
}
