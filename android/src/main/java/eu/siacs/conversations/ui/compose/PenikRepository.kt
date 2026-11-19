package eu.siacs.conversations.ui.compose

import android.content.Context
import eu.siacs.conversations.entities.Conversation
import eu.siacs.conversations.entities.Message
import eu.siacs.conversations.services.XmppConnectionService
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.concurrent.atomic.AtomicInteger

class PenikRepository private constructor() {

    private var serviceRef: XmppConnectionService? = null
    private val refCount = AtomicInteger(0)

    private val _conversations = MutableStateFlow<ImmutableList<ConversationUi>>(persistentListOf())
    val conversations: StateFlow<ImmutableList<ConversationUi>> = _conversations.asStateFlow()

    private val _archivedConversations = MutableStateFlow<ImmutableList<ConversationUi>>(persistentListOf())
    val archivedConversations: StateFlow<ImmutableList<ConversationUi>> = _archivedConversations.asStateFlow()

    private val _chatMessages = MutableStateFlow<ImmutableList<ChatMessageUi>>(persistentListOf())
    val chatMessages: StateFlow<ImmutableList<ChatMessageUi>> = _chatMessages.asStateFlow()

    fun attachService(service: XmppConnectionService) {
        serviceRef = service
        refCount.incrementAndGet()
    }

    fun detachService() {
        if (refCount.decrementAndGet() <= 0) {
            serviceRef = null
            refCount.set(0)
        }
    }

    fun getService(): XmppConnectionService? = serviceRef

    val fileBackend get() = serviceRef?.fileBackend
    val databaseBackend get() = serviceRef?.databaseBackend

    var activeConversation: Conversation? = null

    fun findConversationByUuid(uuid: String): Conversation? {
        val active = activeConversation
        if (active != null && active.uuid == uuid) {
            return active
        }
        return serviceRef?.findConversationByUuid(uuid)
            ?: serviceRef?.findConversationByUuidReliable(uuid)
    }

    fun updateConversations(mainList: List<Conversation>, archivedList: List<Conversation>, context: Context) {
        val mappedMain = PenikConversationMapper.map(mainList, context)
        val mappedArchived = PenikConversationMapper.map(archivedList, context)
        _conversations.value = mappedMain
        _archivedConversations.value = mappedArchived
    }

    fun updateChatMessages(messages: List<Message>, isMuc: Boolean, showAvatars: Boolean) {
        val mapped = PenikMessageMapper.map(messages, isMuc, showAvatars, serviceRef)
        _chatMessages.value = mapped
    }

    companion object {
        @Volatile
        private var INSTANCE: PenikRepository? = null

        @JvmStatic
        fun getInstance(): PenikRepository {
            return INSTANCE ?: synchronized(this) {
                INSTANCE ?: PenikRepository().also { INSTANCE = it }
            }
        }
    }
}
