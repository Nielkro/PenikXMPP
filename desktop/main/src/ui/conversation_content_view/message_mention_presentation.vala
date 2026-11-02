using Dino.Entities;
using Gtk;

namespace Dino.Ui.ConversationSummary {

// Keep the presentation bound to the displayed revision rather than to the
// message that happened to exist when a timeline row was constructed.
public class MessageMentionPresentation : Object {
    public bool mentioned { get; private set; default = false; }
    public signal void changed();

    private StreamInteractor? stream_interactor;
    private Conversation? conversation;
    private ContentItem? content_item;
    private Message? observed_message;
    private Grid? grid;
    private Label? marker;
    private bool closed = false;
    private bool deleted = false;
    private bool hidden = false;
    private ulong nickname_handler = 0;
    private ulong body_handler = 0;
    private ulong mention_handler = 0;
    private ulong correction_handler = 0;
    private ulong deletion_handler = 0;
    private ulong visibility_handler = 0;

    public MessageMentionPresentation(StreamInteractor stream_interactor,
            Conversation conversation, ContentItem content_item,
            Grid grid, Label marker) {
        this.stream_interactor = stream_interactor;
        this.conversation = conversation;
        this.content_item = content_item;
        this.grid = grid;
        this.marker = marker;
        marker.update_property(AccessibleProperty.LABEL,
            _("You have been mentioned"), -1);
        nickname_handler = connect_nickname(conversation, this);
        correction_handler = connect_correction(stream_interactor
            .get_module<MessageCorrection>(MessageCorrection.IDENTITY), this);
        deletion_handler = connect_deletion(stream_interactor
            .get_module<MessageDeletion>(MessageDeletion.IDENTITY), this);
        visibility_handler = connect_visibility(stream_interactor
            .get_module<ContentItemStore>(ContentItemStore.IDENTITY), this);
        bind_message();
        refresh();
    }

    public static bool is_item_mentioned(StreamInteractor stream_interactor,
            Conversation conversation, ContentItem content_item) {
        if (!belongs_to_conversation(content_item, conversation)) return false;
        Message? message = stream_interactor.get_module<ContentItemStore>(
            ContentItemStore.IDENTITY).get_message_for_content_item(
                conversation, content_item);
        return message != null && Dino.MessageMentions.is_mentioned(
            stream_interactor, conversation, (!) message);
    }

    private static bool belongs_to_conversation(ContentItem item,
            Conversation conversation) {
        Conversation? owner = null;
        if (item is MessageItem) owner = ((MessageItem) item).conversation;
        else if (item is FileItem) owner = ((FileItem) item).conversation;
        return owner != null && ((!) owner).id == conversation.id &&
            ((!) owner).account.id == conversation.account.id &&
            ((!) owner).equals(conversation);
    }

    // Signal closures own only a WeakRef, never the controller or its row.
    private static ulong connect_nickname(Conversation conversation,
            MessageMentionPresentation presentation) {
        WeakRef owner = WeakRef(presentation);
        return conversation.notify["nickname"].connect(() => {
            var current = owner.get() as MessageMentionPresentation;
            if (current != null) current.refresh();
        });
    }

    private static ulong connect_correction(MessageCorrection service,
            MessageMentionPresentation presentation) {
        WeakRef owner = WeakRef(presentation);
        return service.received_correction.connect((item) => {
            var current = owner.get() as MessageMentionPresentation;
            if (current != null) current.on_updated_item(item, false);
        });
    }

    private static ulong connect_deletion(MessageDeletion service,
            MessageMentionPresentation presentation) {
        WeakRef owner = WeakRef(presentation);
        return service.item_deleted.connect((item) => {
            var current = owner.get() as MessageMentionPresentation;
            if (current != null) current.on_updated_item(item, true);
        });
    }

    private static ulong connect_visibility(ContentItemStore service,
            MessageMentionPresentation presentation) {
        WeakRef owner = WeakRef(presentation);
        return service.item_visibility_changed.connect((item, conversation, hidden) => {
            var current = owner.get() as MessageMentionPresentation;
            if (current != null && current.matches(item) &&
                    current.conversation != null &&
                    ((!) current.conversation).equals(conversation)) {
                current.hidden = hidden;
                current.refresh();
            }
        });
    }

    private static ulong connect_message_notify(Message message,
            string property, MessageMentionPresentation presentation) {
        WeakRef owner = WeakRef(presentation);
        return message.notify[property].connect(() => {
            var current = owner.get() as MessageMentionPresentation;
            if (current != null) current.refresh();
        });
    }

    private bool matches(ContentItem item) {
        return !closed && conversation != null && content_item != null &&
            ((item.id > 0 && item.id == ((!) content_item).id) ||
                item == content_item) &&
            item.type_ == ((!) content_item).type_ &&
            belongs_to_conversation(item, (!) conversation);
    }

    private void on_updated_item(ContentItem item, bool removed) {
        if (!matches(item)) return;
        if (removed) deleted = true;
        if (deleted) {
            refresh();
            return;
        }
        content_item = item;
        bind_message();
        refresh();
    }

    private void bind_message() {
        unbind_message();
        if (closed || stream_interactor == null || conversation == null ||
                content_item == null ||
                !belongs_to_conversation((!) content_item, (!) conversation)) return;
        observed_message = ((!) stream_interactor).get_module<ContentItemStore>(
            ContentItemStore.IDENTITY).get_message_for_content_item(
                (!) conversation, (!) content_item);
        if (observed_message == null) return;
        body_handler = connect_message_notify((!) observed_message, "body", this);
        mention_handler = connect_message_notify((!) observed_message,
            "mention-state", this);
    }

    private void unbind_message() {
        if (observed_message != null) {
            if (body_handler != 0) ((!) observed_message).disconnect(body_handler);
            if (mention_handler != 0) ((!) observed_message).disconnect(mention_handler);
        }
        body_handler = 0;
        mention_handler = 0;
        observed_message = null;
    }

    private void refresh() {
        if (closed || grid == null || marker == null) return;
        bool next = !deleted && !hidden && stream_interactor != null &&
            conversation != null && content_item != null &&
            is_item_mentioned((!) stream_interactor, (!) conversation,
                (!) content_item);
        if (next) ((!) grid).add_css_class("mentioned");
        else ((!) grid).remove_css_class("mentioned");
        ((!) marker).visible = next;
        if (next == mentioned) return;
        mentioned = next;
        changed();
    }

    public void clear() {
        if (closed) return;
        closed = true;
        unbind_message();
        if (conversation != null && nickname_handler != 0)
            ((!) conversation).disconnect(nickname_handler);
        if (stream_interactor != null) {
            if (correction_handler != 0) ((!) stream_interactor)
                .get_module<MessageCorrection>(MessageCorrection.IDENTITY)
                .disconnect(correction_handler);
            if (deletion_handler != 0) ((!) stream_interactor)
                .get_module<MessageDeletion>(MessageDeletion.IDENTITY)
                .disconnect(deletion_handler);
            if (visibility_handler != 0) ((!) stream_interactor)
                .get_module<ContentItemStore>(ContentItemStore.IDENTITY)
                .disconnect(visibility_handler);
        }
        nickname_handler = correction_handler = deletion_handler =
            visibility_handler = 0;
        if (grid != null) ((!) grid).remove_css_class("mentioned");
        if (marker != null) ((!) marker).visible = false;
        mentioned = false;
        grid = null;
        marker = null;
        content_item = null;
        conversation = null;
        stream_interactor = null;
    }

    public override void dispose() {
        clear();
        base.dispose();
    }
}

}
