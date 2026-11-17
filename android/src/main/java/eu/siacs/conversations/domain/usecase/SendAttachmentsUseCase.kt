package eu.siacs.conversations.domain.usecase

import android.content.Context
import android.net.Uri
import eu.siacs.conversations.entities.Conversation
import eu.siacs.conversations.services.XmppConnectionService
import eu.siacs.conversations.ui.util.Attachment
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class SendAttachmentsUseCase(
    private val serviceProvider: () -> XmppConnectionService?
) {
    suspend operator fun invoke(
        conversation: Conversation,
        uris: List<Uri>,
        context: Context
    ): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val service = serviceProvider() ?: throw IllegalStateException("XmppConnectionService is not available")
            if (uris.isEmpty()) return@runCatching

            val attachments = Attachment.of(context, uris, null)
            for (attachment in attachments) {
                if (attachment.type == Attachment.Type.IMAGE) {
                    service.attachImageToConversation(
                        conversation,
                        attachment.uri,
                        attachment.mime
                    )
                } else {
                    service.attachFileToConversation(
                        conversation,
                        attachment.uri,
                        attachment.mime
                    )
                }
            }
        }
    }
}
