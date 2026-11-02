/*
 * Copyright (C) 2025 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Dino.Entities;
using Gtk;
using Xmpp;

namespace Dino.Ui {
    private string get_deletion_content_preview(ContentItem content_item) {
        MessageItem? message_item = content_item as MessageItem;
        if (message_item != null) {
            return Dino.message_body_without_reply_fallback(
                ((!) message_item).message);
        }

        FileItem? file_item = content_item as FileItem;
        if (file_item != null) {
            return _("File") + ": " + ((!) file_item).file_transfer.file_name;
        }
        return "";
    }

    private bool replies_can_delete_for_everyone(MessageDeletion deletion,
            Conversation conversation, Gee.Iterable<ContentItem> replies) {
        foreach (ContentItem reply in replies) {
            if (!deletion.can_delete_for_everyone(conversation, reply)) {
                return false;
            }
        }
        return true;
    }

    private string get_incomplete_reply_batch_detail(int reply_count,
            bool is_moderation) {
        if (is_moderation) {
            return ngettext(
                "The selected message and its known reply cannot both be removed from the group. Leave this option off if you want to remove only the selected message.",
                "The selected message and its known replies cannot all be removed from the group. Leave this option off if you want to remove only the selected message.",
                reply_count);
        }
        return ngettext(
            "The selected message and its known reply cannot both be deleted for everyone. The reply can still be included in a local deletion. Leave this option off if you want to delete only the selected message for everyone.",
            "The selected message and its known replies cannot all be deleted for everyone. The replies can still be included in a local deletion. Leave this option off if you want to delete only the selected message for everyone.",
            reply_count);
    }

    private void show_incomplete_reply_batch_dialog(Gtk.Widget? parent,
            int reply_count, bool is_moderation) {
        var dialog = new Adw.AlertDialog(
            _("Replies cannot be included"),
            _("No message was deleted.") + "\n\n" +
                get_incomplete_reply_batch_detail(reply_count,
                    is_moderation));
        dialog.add_response("close", _("Close"));
        dialog.set_default_response("close");
        dialog.set_close_response("close");
        dialog.present(parent);
    }

    private void show_changed_reply_batch_dialog(Gtk.Widget? parent) {
        var dialog = new Adw.AlertDialog(
            _("Replies changed"),
            _("No message was deleted. The known replies changed while the delete dialog was open. Open the delete dialog again to review the current selection."));
        dialog.add_response("close", _("Close"));
        dialog.set_default_response("close");
        dialog.set_close_response("close");
        dialog.present(parent);
    }

    private void show_global_reply_batch_result(Gtk.Widget? parent,
            MessageDeletionBatchResult result, int reply_count) {
        string heading;
        string detail;
        bool root_locally_hidden = result.item_results.size > 0 &&
            result.item_results[result.item_results.size - 1].locally_hidden;
        bool has_partial_dispatch = false;
        foreach (MessageDeletionItemResult item_result in
                result.item_results) {
            if (item_result.partial_dispatch) {
                has_partial_dispatch = true;
                break;
            }
        }
        ConversationSummary.MessageDeletionBatchPresentation presentation =
            ConversationSummary.MessageActionTarget.classify_batch_result(
                result.success, result.partial_success);

        switch (presentation) {
            case ConversationSummary.MessageDeletionBatchPresentation.SUCCESS:
                heading = _("Messages deleted");
                detail = ngettext(
                    "The selected message and %d known reply were removed from this device. Their deletion requests were sent or confirmed successfully.",
                    "The selected message and %d known replies were removed from this device. Their deletion requests were sent or confirmed successfully.",
                    reply_count).printf(reply_count);
                break;
            case ConversationSummary.MessageDeletionBatchPresentation.PARTIAL:
                heading = _("Some messages could not be deleted");
                detail = _("Known replies with completed deletion: %d of %d. At least one deletion request had already been sent or confirmed when the operation stopped.").printf(
                    result.succeeded_count, reply_count);
                detail += "\n\n" + (root_locally_hidden
                    ? _("The selected message is no longer visible on this device.")
                    : _("The selected message remains visible on this device."));
                if (has_partial_dispatch) {
                    detail += "\n\n" + _("Only some deletion requests for one message were sent before the failure. Other clients may therefore show an incomplete result.");
                }
                break;
            case ConversationSummary.MessageDeletionBatchPresentation.FAILURE:
            default:
                heading = _("Messages could not be deleted");
                detail = _("No item completed deletion.") + "\n\n" +
                    (root_locally_hidden
                        ? _("The selected message is no longer visible on this device.")
                        : _("The selected message remains visible on this device."));
                break;
        }

        var dialog = new Adw.AlertDialog(heading, detail);
        dialog.add_response("close", _("Close"));
        dialog.set_default_response("close");
        dialog.set_close_response("close");
        dialog.present(parent);
    }

    private void show_global_single_failure(Gtk.Widget? parent,
            MessageDeletionItemResult result) {
        string detail = result.locally_hidden
            ? _("The selected message is no longer visible on this device.")
            : _("The selected message remains visible on this device.");
        if (result.partial_dispatch) {
            detail += "\n\n" + _("Only some deletion requests for one message were sent before the failure. Other clients may therefore show an incomplete result.");
        } else if (result.accepted_request_count > 0) {
            detail += "\n\n" + _("All planned deletion requests were sent or confirmed, but the local result could not be completed. Other clients may already show the message as deleted.");
        }

        var dialog = new Adw.AlertDialog(
            _("Message could not be deleted"), detail);
        dialog.add_response("close", _("Close"));
        dialog.set_default_response("close");
        dialog.set_close_response("close");
        dialog.present(parent);
    }

    private async void show_delete_dialog(ContentItem content_item,
            Conversation conversation, StreamInteractor stream_interactor,
            bool is_moderation) {
        MessageDeletion deletion = stream_interactor
            .get_module<MessageDeletion>(MessageDeletion.IDENTITY);
        Replies replies_module = stream_interactor
            .get_module<Replies>(Replies.IDENTITY);
        Gee.List<ContentItem> direct_replies = replies_module
            .get_direct_replies(conversation, content_item);
        bool root_can_delete_for_everyone =
            deletion.can_delete_for_everyone(conversation, content_item);
        bool all_items_can_delete_for_everyone =
            root_can_delete_for_everyone && replies_can_delete_for_everyone(
                deletion, conversation, direct_replies);

        var app = (Dino.Ui.Application) GLib.Application.get_default();
        var window = app.window;
        var dialog = new Adw.AlertDialog(
            is_moderation ? _("Moderate message") : _("Delete message"),
            null);

        string display_name = Util.get_participant_display_name(
            stream_interactor, conversation, content_item.jid, true);
        string content_preview = get_deletion_content_preview(content_item);
        if (is_moderation) {
            dialog.body = ConversationSummary.MessageActionTarget
                .format_confirmation_detail(
                    _("Do you want to remove this message from the group?"),
                    display_name, content_preview);
        } else {
            dialog.body = ConversationSummary.MessageActionTarget
                .format_confirmation_detail(
                    _("Do you want to delete this message just for yourself or for everyone?"),
                    display_name, content_preview);
        }

        Gtk.CheckButton? include_replies_check = null;
        ulong toggled_handler_id = 0;
        if (!direct_replies.is_empty) {
            var options_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
            options_box.margin_top = 6;
            options_box.margin_bottom = 6;
            options_box.margin_start = 6;
            options_box.margin_end = 6;

            var check = new Gtk.CheckButton.with_label(
                ConversationSummary.MessageActionTarget
                    .format_reply_inclusion_label(direct_replies.size));
            check.active = false;
            check.halign = Gtk.Align.FILL;
            check.hexpand = true;
            for (Gtk.Widget? child = check.get_first_child(); child != null;
                    child = ((!) child).get_next_sibling()) {
                Gtk.Label? check_label = child as Gtk.Label;
                if (check_label != null) {
                    ((!) check_label).wrap = true;
                    ((!) check_label).xalign = 0;
                }
            }
            options_box.append(check);
            include_replies_check = check;

            if (!all_items_can_delete_for_everyone) {
                var explanation = new Gtk.Label(
                    get_incomplete_reply_batch_detail(direct_replies.size,
                        is_moderation));
                explanation.wrap = true;
                explanation.xalign = 0;
                explanation.add_css_class("dim-label");
                options_box.append(explanation);
            }
            dialog.set_extra_child(options_box);
        }

        dialog.add_response("cancel", _("Cancel"));
        if (!is_moderation) {
            dialog.add_response("local", _("Delete locally"));
        }
        dialog.add_response("global",
            is_moderation ? _("Remove") : _("Delete for everyone"));
        dialog.set_response_appearance("global",
            Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.set_default_response("cancel");
        dialog.set_close_response("cancel");
        dialog.set_response_enabled("global",
            ConversationSummary.MessageActionTarget
                .global_delete_response_enabled(false,
                    root_can_delete_for_everyone,
                    all_items_can_delete_for_everyone));

        if (include_replies_check != null) {
            Gtk.CheckButton check = (!) include_replies_check;
            unowned Gtk.CheckButton check_ref = check;
            unowned Adw.AlertDialog dialog_ref = dialog;
            toggled_handler_id = check.toggled.connect(() => {
                dialog_ref.set_response_enabled("global",
                    ConversationSummary.MessageActionTarget
                        .global_delete_response_enabled(check_ref.active,
                            root_can_delete_for_everyone,
                            all_items_can_delete_for_everyone));
            });
        }

        string response = yield dialog.choose(window, null);
        if (include_replies_check != null && toggled_handler_id != 0) {
            SignalHandler.disconnect((!) include_replies_check,
                toggled_handler_id);
        }
        bool include_replies = include_replies_check != null &&
            ((!) include_replies_check).active;

        if (response == "local") {
            if (include_replies) {
                if (!replies_module.direct_reply_snapshot_matches(
                        conversation, content_item, direct_replies)) {
                    show_changed_reply_batch_dialog(window);
                    return;
                }
                foreach (ContentItem reply in direct_replies) {
                    deletion.delete_locally(conversation, reply,
                        conversation.account.bare_jid);
                }
            }
            deletion.delete_locally(conversation, content_item,
                conversation.account.bare_jid);
            return;
        }
        if (response != "global") return;

        if (!include_replies) {
            MessageDeletionItemResult result =
                yield deletion.delete_globally_detailed(conversation,
                    content_item);
            if (!result.success) {
                show_global_single_failure(window, result);
            }
            return;
        }

        bool root_still_deletable = deletion.can_delete_for_everyone(
            conversation, content_item);
        bool complete_snapshot_still_deletable = root_still_deletable &&
            replies_can_delete_for_everyone(deletion, conversation,
                direct_replies);
        if (!ConversationSummary.MessageActionTarget
                .global_delete_response_enabled(true, root_still_deletable,
                    complete_snapshot_still_deletable)) {
            show_incomplete_reply_batch_dialog(window, direct_replies.size,
                is_moderation);
            return;
        }

        MessageDeletionBatchResult result =
            yield deletion.delete_globally_with_replies_detailed(
                conversation, direct_replies, content_item);
        show_global_reply_batch_result(window, result, direct_replies.size);
    }

    public Plugins.MessageAction? get_kick_action(ContentItem content_item, Conversation conversation, StreamInteractor stream_interactor) {
        if (conversation.type_ != Conversation.Type.GROUPCHAT) return null;

        // Don't kick yourself
        if (ContentItem.is_own(content_item)) return null;

        Jid? occupant_jid = content_item.jid;
        if (occupant_jid == null) return null;

        MucManager muc_manager = stream_interactor.get_module<MucManager>(
            MucManager.IDENTITY);
        Message? source_message = stream_interactor.get_module<ContentItemStore>(
            ContentItemStore.IDENTITY).get_message_for_content_item(
                conversation, content_item);
        if (source_message == null ||
                !muc_manager.current_occupant_matches_message_identity(
                    conversation.account, conversation.counterpart,
                    (!) occupant_jid, (!) source_message) ||
                !muc_manager.kick_possible(conversation.account,
                    (!) occupant_jid)) return null;

        Plugins.MessageAction action = new Plugins.MessageAction();
        action.name = "kick";
        action.icon_name = "system-log-out-symbolic";
        action.tooltip = _("Kick user");

        action.callback = () => {
            if (!muc_manager.current_occupant_matches_message_identity(
                    conversation.account, conversation.counterpart,
                    (!) occupant_jid, (!) source_message) ||
                    !muc_manager.kick_possible(conversation.account,
                        (!) occupant_jid)) {
                show_message_muc_action_error(_("The selected user is no longer in the room."));
                return;
            }
            muc_manager.kick_checked.begin(conversation.account,
                conversation.counterpart, occupant_jid.resourcepart, null,
                (obj, res) => {
                    try {
                        muc_manager.kick_checked.end(res);
                    } catch (GLib.Error e) {
                        show_message_muc_action_error(e.message);
                    }
                });
        };

        return action;
    }

    public Plugins.MessageAction? get_ban_action(ContentItem content_item, Conversation conversation, StreamInteractor stream_interactor) {
        if (conversation.type_ != Conversation.Type.GROUPCHAT) return null;

        // Don't ban yourself
        if (ContentItem.is_own(content_item)) return null;

        Jid? occupant_jid = content_item.jid;
        if (occupant_jid == null) return null;

        MucManager muc_manager = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
        Message? source_message = stream_interactor.get_module<ContentItemStore>(
            ContentItemStore.IDENTITY).get_message_for_content_item(
                conversation, content_item);
        if (source_message == null ||
                !muc_manager.current_occupant_matches_message_identity(
                    conversation.account, conversation.counterpart,
                    (!) occupant_jid, (!) source_message) ||
                !muc_manager.ban_possible(conversation.account,
                    (!) occupant_jid)) return null;

        Plugins.MessageAction action = new Plugins.MessageAction();
        action.name = "ban";
        action.icon_name = "dialog-error-symbolic";
        action.tooltip = _("Ban user");

        action.callback = () => {
            if (!muc_manager.current_occupant_matches_message_identity(
                    conversation.account, conversation.counterpart,
                    (!) occupant_jid, (!) source_message) ||
                    !muc_manager.ban_possible(conversation.account,
                        (!) occupant_jid)) {
                show_message_muc_action_error(_("The selected user is no longer in the room."));
                return;
            }
            Jid? target = muc_manager.get_affiliation_target(conversation.account,
                conversation.counterpart, occupant_jid);
            if (target == null) {
                show_message_muc_action_error(_("The server did not disclose a JID for this room user."));
                return;
            }
            muc_manager.ban_checked.begin(conversation.account,
                conversation.counterpart, (!) target, null, (obj, res) => {
                    try {
                        muc_manager.ban_checked.end(res);
                    } catch (GLib.Error e) {
                        show_message_muc_action_error(e.message);
                    }
                });
        };

        return action;
    }

    private void show_message_muc_action_error(string detail) {
        var dialog = new Adw.AlertDialog(_("Room action failed"), detail);
        dialog.add_response("close", _("Close"));
        Application? app = GLib.Application.get_default() as Application;
        dialog.present(app != null ? ((!) app).window : null);
    }

    public Plugins.MessageAction get_reaction_action(ContentItem content_item, Conversation conversation, StreamInteractor stream_interactor) {
        Plugins.MessageAction action = new Plugins.MessageAction();
        action.name = "reaction";
        action.icon_name = "dino-emoticon-add-symbolic";
        action.tooltip = _("Add reaction");

        action.callback = (variant) => {
            string emoji = variant.get_string();
            stream_interactor.get_module<Reactions>(Reactions.IDENTITY).add_reaction(conversation, content_item, emoji);
        };

        // Disable the button if reaction aren't possible.
        bool supports_reactions = stream_interactor.get_module<Reactions>(Reactions.IDENTITY).conversation_supports_reactions(conversation);
        string? message_id = stream_interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY).get_message_id_for_content_item(conversation, content_item);

        if (!supports_reactions) {
            action.tooltip = _("This conversation does not support reactions.");
            action.sensitive = false;
        } else if (message_id == null) {
            action.tooltip = "This message does not support reactions.";
            action.sensitive = false;
        }
        return action;
    }

    public Plugins.MessageAction get_reply_action(ContentItem content_item, Conversation conversation, StreamInteractor stream_interactor) {
        Plugins.MessageAction action = new Plugins.MessageAction();
        action.name = "reply";
        action.icon_name = "mail-reply-sender-symbolic";
        action.tooltip = _("Reply");
        action.callback = () => {
            GLib.Application.get_default().activate_action("quote", new GLib.Variant.tuple(new GLib.Variant[] { new GLib.Variant.int32(conversation.id), new GLib.Variant.int32(content_item.id) }));
        };

        // Disable the button if replies aren't possible.
        string? message_id = stream_interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY).get_message_id_for_content_item(conversation, content_item);
        if (message_id == null) {
            action.sensitive = false;
            if (conversation.type_.is_muc_semantic()) {
                action.tooltip = _("This conversation does not support replies.");
            } else {
                action.tooltip = "This message does not support replies.";
            }
        }
        return action;
    }

    public Plugins.MessageAction? get_delete_action(ContentItem content_item, Conversation conversation, StreamInteractor stream_interactor) {
        bool is_deletable = stream_interactor.get_module<MessageDeletion>(MessageDeletion.IDENTITY).is_deletable(conversation, content_item);
        if (!is_deletable) return null;

        bool can_delete_for_everyone = stream_interactor.get_module<MessageDeletion>(MessageDeletion.IDENTITY).can_delete_for_everyone(conversation, content_item);

        // Check if it is own message to distinguish between Retraction and Moderation
        bool is_own_message = ContentItem.is_own(content_item);

        bool is_moderation = can_delete_for_everyone && !is_own_message;

        Plugins.MessageAction action = new Plugins.MessageAction();
        action.name = "delete";
        action.icon_name = "user-trash-symbolic";
        
        if (is_moderation) {
            action.tooltip = _("Moderate message...");
        } else if (can_delete_for_everyone) {
            action.tooltip = _("Delete...");
        } else {
            action.tooltip = _("Delete locally");
        }

        action.callback = () => {
            // If we can delete for everyone (own message or moderation), offer choice
            if (can_delete_for_everyone) {
                show_delete_dialog.begin(content_item, conversation,
                    stream_interactor, is_moderation);
            } else {
                stream_interactor.get_module<MessageDeletion>(MessageDeletion.IDENTITY).delete_locally(conversation, content_item, conversation.account.bare_jid);
            }
        };
        return action;
    }
}
