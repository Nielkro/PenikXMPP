using Dino.Entities;

namespace Dino.Ui.ConversationSummary {

/** Local diagnostics are stored independently of the current UI language. */
public class MessageDiagnostics : Object {
    private const string OMEMO_FAILURE = "[This OMEMO message could not be decrypted]";

    public static bool is_local_decryption_failure(Message message) {
        return message.decryption_failed && message.encryption == Encryption.OMEMO &&
            message.body == OMEMO_FAILURE;
    }

    public static string? body_for_display(Message message) {
        if (is_local_decryption_failure(message)) {
            // Manual archive reloads summarize their failures separately.
            // Live and automatic catch-up failures remain visible per message.
            return _("This message could not be decrypted on this device.");
        }
        return message.body;
    }

    public static string delivery_error_for_display(string? error_text) {
        if (error_text == null || error_text == "" || error_text == "delivery failed") {
            return _("Delivery failed. No reason was provided.");
        }
        if (error_text == "The recipient is using OMEMO. Switch this chat to OMEMO or send unencrypted.") {
            return _("Delivery failed. The recipient is using OMEMO. Switch this chat to OMEMO or send unencrypted.");
        }
        if (error_text == "The recipient is using OpenPGP. Switch this chat to OpenPGP or send unencrypted.") {
            return _("Delivery failed. The recipient is using OpenPGP. Switch this chat to OpenPGP or send unencrypted.");
        }
        if (error_text == "The recipient is using unencrypted messages. Switch this chat to unencrypted.") {
            return _("Delivery failed. The recipient is using unencrypted messages. Switch this chat to unencrypted.");
        }
        if (error_text == "OMEMO is selected, but this message was not encrypted with OMEMO. Switch the chat encryption mode or send unencrypted.") {
            return _("Delivery failed. OMEMO is selected, but this message was not encrypted with OMEMO. Switch the chat encryption mode or send unencrypted.");
        }
        if (error_text == "OpenPGP is selected, but this message was not encrypted with OpenPGP. Switch the chat encryption mode or send unencrypted.") {
            return _("Delivery failed. OpenPGP is selected, but this message was not encrypted with OpenPGP. Switch the chat encryption mode or send unencrypted.");
        }
        if (error_text == "Unencrypted messages are selected, but this message still contains encrypted data. Switch the chat encryption mode before sending.") {
            return _("Delivery failed. Unencrypted messages are selected, but this message still contains encrypted data. Switch the chat encryption mode before sending.");
        }
        if (error_text == "The replied-to message is no longer available in this conversation." ||
                error_text == "The replied-to message is no longer available.") {
            return _("Delivery failed. The replied-to message is no longer available in this conversation.");
        }
        if (error_text == "The replied-to groupchat message has no room-assigned stanza ID yet.") {
            return _("Delivery failed. The replied-to group message is not ready to be referenced yet. Try again shortly.");
        }
        if (error_text == "The replied-to message cannot be referenced safely.") {
            return _("Delivery failed. The replied-to message cannot be referenced safely.");
        }
        if (error_text == "OMEMO groupchat encryption requires live private members-only non-anonymous room features") {
            return _("OMEMO requires a members-only room that exposes participants' XMPP addresses.");
        }
        if (error_text == "OMEMO private-MUC encryption requires completed member, admin and owner affiliation queries" ||
                error_text == "OMEMO private-MUC encryption requires a known member list") {
            return _("Cannot verify the room members. Check room permissions and try again.");
        }
        if (error_text == "OMEMO private-MUC encryption requires at least one other known member") {
            return _("Invite another member before sending an OMEMO message.");
        }
        if (error_text == "OMEMO private-MUC encryption requires a trusted device of another member") {
            return _("No trusted device of another room member is available. Review the room members' OMEMO keys.");
        }
        return _("Delivery failed. Reason: %s").printf(error_text);
    }
}

}
