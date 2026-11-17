package eu.siacs.conversations.domain.usecase

import eu.siacs.conversations.entities.Message
import eu.siacs.conversations.services.XmppConnectionService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class ResendMessageUseCase(
    private val serviceProvider: () -> XmppConnectionService?
) {
    suspend operator fun invoke(message: Message, forceP2P: Boolean = false): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val service = serviceProvider() ?: throw IllegalStateException("XmppConnectionService is not available")
            service.resendFailedMessages(message, forceP2P)
        }
    }
}
