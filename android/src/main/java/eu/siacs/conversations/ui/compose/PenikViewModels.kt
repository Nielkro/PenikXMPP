package eu.siacs.conversations.ui.compose

import android.content.Context
import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import eu.siacs.conversations.domain.usecase.DeleteMessageUseCase
import eu.siacs.conversations.domain.usecase.ResendMessageUseCase
import eu.siacs.conversations.domain.usecase.SendAttachmentsUseCase
import eu.siacs.conversations.domain.usecase.SendMessageUseCase
import eu.siacs.conversations.domain.usecase.SendStickerUseCase
import eu.siacs.conversations.entities.Conversation
import eu.siacs.conversations.entities.Message
import eu.siacs.conversations.entities.Sticker
import kotlinx.collections.immutable.ImmutableList
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch

sealed interface PenikNavEffect {
    data class OpenChat(val uuid: String) : PenikNavEffect
    data object OpenArchive : PenikNavEffect
    data object OpenSettings : PenikNavEffect
    data class ShowConfirmationDialog(val title: String, val message: String, val action: () -> Unit) : PenikNavEffect
}

sealed interface PenikChatUiEffect {
    data class ScrollToMessage(val uuid: String) : PenikChatUiEffect
    data class ShowError(val error: String) : PenikChatUiEffect
    data class ShowNotice(val notice: String) : PenikChatUiEffect
}

class PenikChatsViewModel(
    private val repository: PenikRepository = PenikRepository.getInstance()
) : ViewModel() {

    val conversations: StateFlow<ImmutableList<ConversationUi>> = repository.conversations
    val archivedConversations: StateFlow<ImmutableList<ConversationUi>> = repository.archivedConversations

    private val _searchQuery = MutableStateFlow("")
    val searchQuery: StateFlow<String> = _searchQuery.asStateFlow()

    // Buffered channel for critical navigation and one-off actions that cannot be dropped
    private val _navigationEffect = Channel<PenikNavEffect>(Channel.BUFFERED)
    val navigationEffect = _navigationEffect.receiveAsFlow()

    // Conflated channel for transient notifications (e.g. snackbar messages)
    private val _transientNotice = Channel<String>(Channel.CONFLATED)
    val transientNotice = _transientNotice.receiveAsFlow()

    fun onSearchQueryChanged(query: String) {
        _searchQuery.value = query
    }

    fun openChat(uuid: String) {
        viewModelScope.launch {
            _navigationEffect.send(PenikNavEffect.OpenChat(uuid))
        }
    }

    fun openArchive() {
        viewModelScope.launch {
            _navigationEffect.send(PenikNavEffect.OpenArchive)
        }
    }

    fun showNotice(message: String) {
        _transientNotice.trySend(message)
    }
}

class PenikChatViewModel(
    private val repository: PenikRepository = PenikRepository.getInstance(),
    private val sendMessageUseCase: SendMessageUseCase = SendMessageUseCase { repository.getService() },
    private val sendStickerUseCase: SendStickerUseCase = SendStickerUseCase { repository.getService() },
    private val sendAttachmentsUseCase: SendAttachmentsUseCase = SendAttachmentsUseCase { repository.getService() },
    private val deleteMessageUseCase: DeleteMessageUseCase = DeleteMessageUseCase { repository.getService() },
    private val resendMessageUseCase: ResendMessageUseCase = ResendMessageUseCase { repository.getService() }
) : ViewModel() {

    val messages: StateFlow<ImmutableList<ChatMessageUi>> = repository.chatMessages

    private val _activeQuote = MutableStateFlow<String?>(null)
    val activeQuote: StateFlow<String?> = _activeQuote.asStateFlow()

    // Buffered channel for action effects
    private val _actionEffect = Channel<PenikChatUiEffect>(Channel.BUFFERED)
    val actionEffect = _actionEffect.receiveAsFlow()

    // Conflated channel for transient notices
    private val _transientNotice = Channel<String>(Channel.CONFLATED)
    val transientNotice = _transientNotice.receiveAsFlow()

    fun setQuote(quote: String?) {
        _activeQuote.value = quote
    }

    fun scrollToMessage(uuid: String) {
        viewModelScope.launch {
            _actionEffect.send(PenikChatUiEffect.ScrollToMessage(uuid))
        }
    }

    fun showError(error: String) {
        _transientNotice.trySend(error)
    }

    fun sendMessage(conversation: Conversation, text: String, replyMessage: Message? = null) {
        viewModelScope.launch {
            val result = sendMessageUseCase(conversation, text, replyMessage)
            result.onFailure { error ->
                _actionEffect.send(PenikChatUiEffect.ShowError(error.localizedMessage ?: "Failed to send message"))
            }
        }
    }

    fun sendSticker(conversation: Conversation, sticker: Sticker, context: Context? = null) {
        viewModelScope.launch {
            val result = sendStickerUseCase(conversation, sticker, context)
            result.onFailure { error ->
                _actionEffect.send(PenikChatUiEffect.ShowError(error.localizedMessage ?: "Failed to send sticker"))
            }
        }
    }

    fun sendAttachments(conversation: Conversation, uris: List<Uri>, context: Context) {
        viewModelScope.launch {
            val result = sendAttachmentsUseCase(conversation, uris, context)
            result.onFailure { error ->
                _actionEffect.send(PenikChatUiEffect.ShowError(error.localizedMessage ?: "Failed to send attachments"))
            }
        }
    }

    fun deleteMessage(message: Message) {
        viewModelScope.launch {
            val result = deleteMessageUseCase(message)
            result.onFailure { error ->
                _actionEffect.send(PenikChatUiEffect.ShowError(error.localizedMessage ?: "Failed to delete message"))
            }
        }
    }

    fun resendMessage(message: Message, forceP2P: Boolean = false) {
        viewModelScope.launch {
            val result = resendMessageUseCase(message, forceP2P)
            result.onFailure { error ->
                _actionEffect.send(PenikChatUiEffect.ShowError(error.localizedMessage ?: "Failed to resend message"))
            }
        }
    }
}
