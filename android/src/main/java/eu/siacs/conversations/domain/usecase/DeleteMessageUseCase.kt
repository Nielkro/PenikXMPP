package eu.siacs.conversations.domain.usecase

import eu.siacs.conversations.entities.Conversation
import eu.siacs.conversations.entities.Message
import eu.siacs.conversations.services.XmppConnectionService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class DeleteMessageUseCase(
    private val serviceProvider: () -> XmppConnectionService?
) {
    suspend operator fun invoke(message: Message): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val service = serviceProvider() ?: throw IllegalStateException("XmppConnectionService is not available")
            if (message.isFileOrImage) {
                try {
                    service.fileBackend.deleteFile(message)
                    service.evictPreview(message.uuid)
                } catch (ignored: Exception) {}
            }
            service.databaseBackend.deleteMessage(message.uuid)
            (message.conversation as? Conversation)?.remove(message)
            service.notificationService?.clear(message)
            service.updateConversationUi()
        }
    }
}
