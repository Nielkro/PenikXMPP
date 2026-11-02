using Gee;

using Dino.Entities;
using Xmpp;

namespace Dino {

    internal void set_outgoing_reply_reference(
            ContentItemStore content_item_store, Conversation conversation,
            Message out_message, ContentItem reply_to) {
        string? reply_reference_id;
        Jid? reply_reference_sender;
        if (content_item_store.try_get_message_reference_for_content_item(
                conversation, reply_to, out reply_reference_id,
                out reply_reference_sender)) {
            out_message.set_quoted_item(reply_to.id, reply_reference_id,
                reply_reference_sender);
        } else {
            out_message.set_quoted_item(reply_to.id);
        }
    }

    public void send_message(Conversation conversation, string text, int reply_to_id, Message? correction_to, Gee.List<Xep.MessageMarkup.Span> markups) {
        StreamInteractor stream_interactor = Application.get_default().stream_interactor;
        ContentItemStore content_item_store = stream_interactor
            .get_module<ContentItemStore>(ContentItemStore.IDENTITY);
        ContentItem? reply_to = null;
        if (reply_to_id != 0) {
            reply_to = content_item_store.get_item_by_id(conversation,
                reply_to_id);
        }

        Message out_message = stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY).create_out_message(text, conversation);

        if (reply_to_id != 0 && reply_to == null) {
            out_message.delivery_error_text =
                "The replied-to message is no longer available in this conversation.";
            out_message.marked = Message.Marked.ERROR;
            content_item_store.insert_message(out_message, conversation);
            stream_interactor.get_module<MessageProcessor>(
                MessageProcessor.IDENTITY).message_sent(out_message,
                    conversation);
            return;
        }

        if (correction_to != null) {
            string correction_to_stanza_id = correction_to.edit_to ?? correction_to.stanza_id;
            out_message.edit_to = correction_to_stanza_id;
            stream_interactor.get_module<MessageCorrection>(MessageCorrection.IDENTITY).set_correction(conversation, out_message, correction_to);
        }

        if (reply_to_id != 0) {
            set_outgoing_reply_reference(content_item_store, conversation,
                out_message, (!) reply_to);

            // Store body with fallback
            string fallback = FallbackBody.get_quoted_fallback_body(
                (!) reply_to);
            out_message.body = fallback + out_message.body;

            // Store fallback location
            var fallback_locations = new ArrayList<Xep.FallbackIndication.FallbackLocation>();
            fallback_locations.add(new Xep.FallbackIndication.FallbackLocation.partial_body(0, (int)fallback.char_count()));
            var fallback_list = new ArrayList<Xep.FallbackIndication.Fallback>();
            fallback_list.add(new Xep.FallbackIndication.Fallback(Xep.Replies.NS_URI, fallback_locations));
            out_message.set_fallbacks(fallback_list);

            // Adjust markups to new prefix (use char_count, not byte length)
            int fallback_chars = (int) fallback.char_count();
            foreach (var span in markups) {
                span.start_char += fallback_chars;
                span.end_char += fallback_chars;
            }
        }

        if (!markups.is_empty) {
            out_message.persist_markups(markups, out_message.id);
        }


        if (correction_to != null) {
            stream_interactor.get_module<MessageCorrection>(MessageCorrection.IDENTITY).on_received_correction(conversation, out_message.id);
            stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY).send_xmpp_message(out_message, conversation);
            return;
        }

        stream_interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY).insert_message(out_message, conversation);
        stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY).send_xmpp_message(out_message, conversation);
        stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY).message_sent(out_message, conversation);
    }
}
