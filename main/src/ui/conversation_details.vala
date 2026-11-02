/*
 * Copyright (C) 2025 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Dino;
using Dino.Entities;
using Xmpp;
using Xmpp.Xep;
using Gee;
using Gtk;

namespace Dino.Ui.ConversationDetails {

    private HistoryLoadPreferences create_history_preferences(
            Model.ConversationDetails model, MucManager manager) {
        WeakRef model_weak = WeakRef(model);
        return new HistoryLoadPreferences(model.conversation, manager, model, () => {
            var current_model = model_weak.get() as Model.ConversationDetails;
            return current_model != null ? current_model.conversation : null;
        });
    }

    private const int HATS_DIALOG_CONTENT_WIDTH = 700;
    private const int HATS_DIALOG_CONTENT_HEIGHT = 600;

    public void populate_dialog(Model.ConversationDetails model, Conversation conversation, StreamInteractor stream_interactor) {
        model.conversation = conversation;
        model.display_name = stream_interactor.get_module<ContactModels>(ContactModels.IDENTITY).get_display_name_model(conversation);
        model.blocked = stream_interactor.get_module<BlockingManager>(BlockingManager.IDENTITY).is_blocked(model.conversation.account, model.conversation.counterpart);
        model.domain_blocked = stream_interactor.get_module<BlockingManager>(BlockingManager.IDENTITY).is_blocked(model.conversation.account, model.conversation.counterpart.domain_jid);

        if (conversation.type_ == Conversation.Type.CHAT || conversation.type_ == Conversation.Type.GROUPCHAT_PM || conversation.type_ == Conversation.Type.GROUPCHAT) {
            fetch_vcard.begin(model, conversation, stream_interactor);
        }
    }

    public void bind_dialog(Model.ConversationDetails model, ViewModel.ConversationDetails view_model, StreamInteractor stream_interactor) {
        // Set some data once
        view_model.avatar = new ViewModel.CompatAvatarPictureModel(stream_interactor).set_conversation(model.conversation);
        bool is_synthetic_bot = (model.conversation.counterpart.domainpart == "mqtt.local");
        view_model.show_blocked = !is_synthetic_bot && model.conversation.type_ == Conversation.Type.CHAT && stream_interactor.get_module<BlockingManager>(BlockingManager.IDENTITY).is_supported(model.conversation.account);
        view_model.show_remove_contact = !is_synthetic_bot && model.conversation.type_ == Conversation.Type.CHAT;  // Only show for 1:1 chats
        view_model.settings_in_separate_tab = model.conversation.type_ == Conversation.Type.GROUPCHAT;
        for (uint i = 0; i < model.members.get_n_items(); i++) {
            var conference_member = (Ui.Model.ConferenceMember) model.members.get_item(i);
            Jid? nick_jid = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_occupant_jid(model.conversation.account, model.conversation.counterpart, conference_member.jid);
            view_model.members.append(new Ui.ViewModel.ConferenceMemberListRow() {
                avatar = new ViewModel.CompatAvatarPictureModel(stream_interactor).add_participant(model.conversation, conference_member.jid, true),
                name = nick_jid != null ? nick_jid.resourcepart : conference_member.jid.localpart,
                jid = conference_member.jid.to_string(),
                affiliation = conference_member.affiliation
            });
        }
        view_model.account_jid = stream_interactor.get_accounts().size > 1 ? model.conversation.account.bare_jid.to_string() : null;

        if (model.domain_blocked) {
            view_model.blocked = DOMAIN;
        } else if (model.blocked) {
            view_model.blocked = USER;
        } else {
            view_model.blocked = UNBLOCK;
        }

        // Bind properties
        model.display_name.bind_property("display-name", view_model, "name", BindingFlags.SYNC_CREATE);
        model.conversation.bind_property("notify-setting", view_model, "notification", BindingFlags.SYNC_CREATE, (_, from, ref to) => {
            switch (model.conversation.get_notification_setting(stream_interactor)) {
                case ON:
                    to = ViewModel.ConversationDetails.NotificationSetting.ON;
                    break;
                case OFF:
                    to = ViewModel.ConversationDetails.NotificationSetting.OFF;
                    break;
                case HIGHLIGHT:
                    to = ViewModel.ConversationDetails.NotificationSetting.HIGHLIGHT;
                    break;
                case DEFAULT:
                    // A "default" setting should have been resolved to the actual default value
                    assert_not_reached();
            }
            return true;
        });
        model.conversation.bind_property("notify-setting", view_model, "notification-is-default", BindingFlags.SYNC_CREATE, (_, from, ref to) => {
            var notify_setting = (Conversation.NotifySetting) from;
            to = notify_setting == Conversation.NotifySetting.DEFAULT;
            return true;
        });
        model.conversation.bind_property("pinned", view_model, "pinned", BindingFlags.SYNC_CREATE, (_, from, ref to) => {
            var from_int = (int) from;
            to = from_int > 0;
            return true;
        });
        model.conversation.bind_property("type-", view_model, "notification-options", BindingFlags.SYNC_CREATE, (_, from, ref to) => {
            var ty = (Conversation.Type) from;
            to = ty == Conversation.Type.GROUPCHAT ? ViewModel.ConversationDetails.NotificationOptions.ON_HIGHLIGHT_OFF : ViewModel.ConversationDetails.NotificationOptions.ON_OFF;
            return true;
        });
        model.bind_property("data-form", view_model, "room-configuration-rows", BindingFlags.SYNC_CREATE, (binding, from, ref to) => {
            var data_form = (DataForms.DataForm) from;
            if (data_form == null) return true;
            var list_store = new GLib.ListStore(typeof(ViewModel.PreferencesRow.Any));

            foreach (var field in data_form.fields) {
                var field_view_model = Util.get_data_form_field_view_model(field);
                if (field_view_model != null) {
                    list_store.append(field_view_model);
                }
            }

            var save_button = new ViewModel.PreferencesRow.Button();
            save_button.title = _("Room Configuration");
            save_button.button_text = _("Apply Changes");
            save_button.clicked.connect(() => {
                view_model.room_configuration_save();
            });
            list_store.append(save_button);

            to = list_store;
            return true;
        });

        view_model.pin_changed.connect(() => {
            model.conversation.pinned = model.conversation.pinned == 1 ? 0 : 1;
        });
        view_model.block_changed.connect((action) => {
            switch (action) {
                case USER:
                    stream_interactor.get_module<BlockingManager>(BlockingManager.IDENTITY).block(model.conversation.account, model.conversation.counterpart);
                    stream_interactor.get_module<BlockingManager>(BlockingManager.IDENTITY).unblock(model.conversation.account, model.conversation.counterpart.domain_jid);
                    break;
                case DOMAIN:
                    stream_interactor.get_module<BlockingManager>(BlockingManager.IDENTITY).block(model.conversation.account, model.conversation.counterpart.domain_jid);
                    break;
                case UNBLOCK:
                    stream_interactor.get_module<BlockingManager>(BlockingManager.IDENTITY).unblock(model.conversation.account, model.conversation.counterpart);
                    stream_interactor.get_module<BlockingManager>(BlockingManager.IDENTITY).unblock(model.conversation.account, model.conversation.counterpart.domain_jid);
                    break;
            }
            view_model.blocked = action;
        });
        view_model.remove_contact.connect(() => {
            if (view_model.removing_contact) return;
            view_model.removing_contact = true;
            Conversation target = model.conversation;
            var manager = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY);
            manager.remove_contact_and_history.begin(target.account, target.counterpart, (obj, res) => {
                RosterRemoveResult result = manager.remove_contact_and_history.end(res);
                view_model.removing_contact = false;
                view_model.remove_contact_finished(target.counterpart, result);
            });
        });
        view_model.notification_changed.connect((setting) => {
            switch (setting) {
                case ON:
                    model.conversation.notify_setting = ON;
                    break;
                case OFF:
                    model.conversation.notify_setting = OFF;
                    break;
                case HIGHLIGHT:
                    model.conversation.notify_setting = HIGHLIGHT;
                    break;
                case DEFAULT:
                    model.conversation.notify_setting = DEFAULT;
                    break;
            }
        });

        view_model.notification_flipped.connect(() => {
            model.conversation.notify_setting = view_model.notification == ON ? Conversation.NotifySetting.OFF : Conversation.NotifySetting.ON;
        });

        model.notify["vcard4"].connect(() => { update_vcard_rows(model, view_model); });
        model.notify["vcard-temp"].connect(() => { update_vcard_rows(model, view_model); });
        model.notify["pep-nickname"].connect(() => { update_vcard_rows(model, view_model); });
    }

    private void set_room_configuration_status(ViewModel.ConversationDetails view_model, string title, string? button_text) {
        var list_store = new GLib.ListStore(typeof(ViewModel.PreferencesRow.Any));
        list_store.append(new ViewModel.PreferencesRow.Text() {
            title = title,
            text = ""
        });
        if (button_text != null) {
            var button = new ViewModel.PreferencesRow.Button() {
                title = "",
                button_text = (!) button_text
            };
            button.clicked.connect(() => {
                view_model.room_configuration_retry();
            });
            list_store.append(button);
        }
        view_model.room_configuration_rows = list_store;
    }

    private Xep.Muc.Affiliation? get_current_own_affiliation(
            Conversation conversation, StreamInteractor stream_interactor) {
        if (conversation.type_ != Conversation.Type.GROUPCHAT) return null;

        return get_current_own_affiliation_for_room(conversation.account,
            conversation.counterpart, stream_interactor);
    }

    private Xep.Muc.Affiliation? get_current_own_affiliation_for_room(
            Account account, Jid room_jid, StreamInteractor stream_interactor) {

        MucManager muc_manager = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
        Jid? own_jid = muc_manager.get_own_jid(room_jid.bare_jid, account);
        if (own_jid == null) return null;
        return muc_manager.get_affiliation(room_jid.bare_jid, (!) own_jid, account);
    }

    private bool can_configure_current_room(
            Conversation conversation, StreamInteractor stream_interactor) {
        return MucManager.can_configure_room_affiliation(
            get_current_own_affiliation(conversation, stream_interactor));
    }

    private bool can_administer_current_room(
            Conversation conversation, StreamInteractor stream_interactor) {
        return MucManager.can_administer_room_affiliations(
            get_current_own_affiliation(conversation, stream_interactor));
    }

    private void request_room_configuration(Model.ConversationDetails model, ViewModel.ConversationDetails view_model, StreamInteractor stream_interactor, bool force = false) {
        if (model.conversation.type_ != Conversation.Type.GROUPCHAT) return;
        if (!can_configure_current_room(model.conversation, stream_interactor)) {
            set_room_configuration_status(view_model,
                _("Room configuration could not be loaded"), null);
            return;
        }
        if (model.room_configuration_loading || model.data_form != null) return;
        if (!force && model.room_configuration_requested) return;

        model.room_configuration_requested = true;
        model.room_configuration_loading = true;
        set_room_configuration_status(view_model, _("Loading room configuration..."), null);
        MucManager muc_manager = stream_interactor.get_module<MucManager>(
            MucManager.IDENTITY);
        MucManager.MucOwnerMutationContext? room_context =
            muc_manager.capture_current_owner_context(
                model.conversation.account, model.conversation.counterpart);
        if (room_context == null) {
            model.room_configuration_loading = false;
            set_room_configuration_status(view_model,
                _("Room configuration could not be loaded"), _("Retry"));
            return;
        }
        muc_manager.get_config_form_in_context.begin(model.conversation.account,
                (!) room_context, (obj, res) => {
            DataForms.DataForm? data_form =
                muc_manager.get_config_form_in_context.end(res);
            if (!model.room_configuration_loading) return;

            model.room_configuration_loading = false;
            if (data_form == null) {
                set_room_configuration_status(view_model, _("Room configuration could not be loaded"), _("Retry"));
                return;
            }
            if (!can_configure_current_room(model.conversation, stream_interactor)) {
                set_room_configuration_status(view_model,
                    _("Room configuration could not be loaded"), null);
                return;
            }

            model.room_configuration_context = room_context;
            model.original_members_only = MucManager.get_members_only_config_value(data_form);
            model.data_form = data_form;
            model.data_form_bak = data_form.stanza_node.to_string();
            if (model.conversation.message_expiry_seconds > 0) {
                stream_interactor.get_module<MucManager>(MucManager.IDENTITY).set_mam_archiving_enabled(model.data_form, true);
            }
        });
    }

    private void show_room_configuration_save_error(Gtk.Widget? parent = null) {
        var error_dialog = new Adw.AlertDialog(
            _("Room configuration could not be saved"),
            _("The server rejected the room configuration. Check your room permissions and try again.")
        );
        error_dialog.add_response("close", _("Close"));
        if (parent != null) {
            error_dialog.present(parent);
        } else {
            var app = GLib.Application.get_default() as Gtk.Application;
            error_dialog.present(app != null ? app.active_window : null);
        }
    }

    private void show_room_configuration_sync_warning(Gtk.Widget? parent = null) {
        var warning_dialog = new Adw.AlertDialog(
            _("Room configuration was applied"),
            _("The server accepted the room configuration, but DinoX could not synchronize all local room or bookmark state. The server change will not be sent again."));
        warning_dialog.add_response("close", _("Close"));
        if (parent != null) {
            warning_dialog.present(parent);
        } else {
            var app = GLib.Application.get_default() as Gtk.Application;
            warning_dialog.present(app != null ? app.active_window : null);
        }
    }

    private void show_room_configuration_unverified_warning(
            Gtk.Widget? parent = null) {
        var warning_dialog = new Adw.AlertDialog(
            _("Room configuration could not be confirmed"),
            _("The server acknowledged the request, but DinoX could not confirm the effective room settings. Reopen the configuration before trying again."));
        warning_dialog.add_response("close", _("Close"));
        if (parent != null) {
            warning_dialog.present(parent);
        } else {
            var app = GLib.Application.get_default() as Gtk.Application;
            warning_dialog.present(app != null ? app.active_window : null);
        }
    }

    private void show_room_configuration_preflight_warning(
            Gtk.Widget? parent = null) {
        var warning_dialog = new Adw.AlertDialog(
            _("Room configuration was not applied"),
            _("The room configuration was not applied. Some memberships granted during the safety preflight were kept to avoid overwriting newer server-side affiliation changes. Review them in Room Administration."));
        warning_dialog.add_response("close", _("Close"));
        if (parent != null) {
            warning_dialog.present(parent);
        } else {
            var app = GLib.Application.get_default() as Gtk.Application;
            warning_dialog.present(app != null ? app.active_window : null);
        }
    }

    private void show_room_destroy_sync_warning(Gtk.Widget? parent = null) {
        var warning_dialog = new Adw.AlertDialog(
            _("Room was destroyed"),
            _("The server destroyed the room, but DinoX could not confirm bookmark cleanup. If the bookmark remains after reconnecting, remove it manually."));
        warning_dialog.add_response("close", _("Close"));
        if (parent != null) {
            warning_dialog.present(parent);
        } else {
            var app = GLib.Application.get_default() as Gtk.Application;
            warning_dialog.present(app != null ? app.active_window : null);
        }
    }

    private void close_details_discarding_room_configuration(
            Model.ConversationDetails model, Gtk.Widget? parent) {
        // A confirmed destroy/leave supersedes any unsaved owner form. Mark
        // the current form as deliberately discarded before closing so the
        // generic close guard can never submit stale configuration against a
        // room that has just been left or destroyed.
        if (model.data_form != null) {
            model.data_form_bak = ((!) model.data_form).stanza_node.to_string();
        }
        Dialog? dialog = parent as Dialog;
        if (dialog != null) {
            ((!) dialog).can_close = true;
            ((!) dialog).close();
        }
    }

    private bool has_unsaved_room_configuration(
            Model.ConversationDetails model) {
        return model.data_form != null && model.data_form_bak != null &&
            !((!) model.data_form).get_changed_field_vars().is_empty;
    }

    private void confirm_discard_before_leaving(
            Model.ConversationDetails model, Gtk.Widget? parent,
            owned SourceFunc leave_action) {
        if (!has_unsaved_room_configuration(model)) {
            leave_action();
            return;
        }

        var confirm_dialog = new Adw.AlertDialog(
            _("Leave Conversation"),
            _("The room configuration contains unsaved changes."));
        confirm_dialog.add_response("cancel", _("Cancel"));
        confirm_dialog.add_response("discard", _("Discard"));
        confirm_dialog.set_response_appearance("discard",
            Adw.ResponseAppearance.DESTRUCTIVE);
        confirm_dialog.default_response = "cancel";
        confirm_dialog.close_response = "cancel";
        confirm_dialog.choose.begin(parent, null, (obj, res) => {
            if (confirm_dialog.choose.end(res) == "discard") {
                leave_action();
            }
        });
    }

    private void rebuild_confirmed_room_configuration(
            Model.ConversationDetails model) {
        if (model.data_form == null) return;
        // MucManager replaces the form contents with the authoritative GET
        // response. Recreate every row so server-side changes to field type,
        // required markers, choices or values cannot leave stale bindings in
        // the still-open configuration page.
        DataForms.DataForm confirmed_form = (!) model.data_form;
        model.data_form = null;
        model.data_form = confirmed_form;
    }

    private async void save_room_configuration(Model.ConversationDetails model,
            Dialog dialog, StreamInteractor stream_interactor,
            bool close_after_success) {
        if (model.room_configuration_saving || model.data_form == null ||
                model.data_form_bak == null ||
                model.room_configuration_context == null) {
            return;
        }

        if (((!) model.data_form).get_changed_field_vars().is_empty) {
            if (close_after_success) {
                dialog.can_close = true;
                dialog.close();
            }
            return;
        }
        if (!can_configure_current_room(model.conversation,
                stream_interactor)) {
            show_room_configuration_save_error(dialog);
            return;
        }

        model.room_configuration_saving = true;
        dialog.can_close = false;
        // GTK 4.14 warns if a focused GtkText becomes insensitive before its
        // focus controller can process focus-out.
        Util.clear_focus_before_detach(dialog.stack);
        dialog.stack.sensitive = false;
        int64 started_us = UiTiming.enabled() ? UiTiming.now_us() : 0;
        MucConfigSaveResult save_result = yield stream_interactor.get_module<
            MucManager>(MucManager.IDENTITY).set_config_form_detailed_in_context(
                model.conversation.account,
                (!) model.room_configuration_context,
                (!) model.data_form, model.original_members_only);
        model.room_configuration_saving = false;
        dialog.stack.sensitive = true;
        if (UiTiming.enabled()) {
            GLib.message("UI-TIMING ConversationDetails.room_config_submit: result=%s elapsed=%.2f ms",
                save_result.to_string(),
                (UiTiming.now_us() - started_us) / 1000.0);
        }
        if (save_result == MucConfigSaveResult.REJECTED) {
            show_room_configuration_save_error(dialog);
            return;
        }
        if (save_result ==
                MucConfigSaveResult.REJECTED_PREFLIGHT_MEMBERS_PRESERVED) {
            show_room_configuration_preflight_warning(dialog);
            return;
        }
        if (save_result ==
                MucConfigSaveResult.APPLIED_SERVER_STATE_UNVERIFIED) {
            if (close_after_success) {
                dialog.can_close = true;
                dialog.close();
                show_room_configuration_unverified_warning();
            } else {
                show_room_configuration_unverified_warning(dialog);
                // The acknowledged SET must never be retried blindly. Replace
                // the edited model with a fresh authoritative owner form.
                model.data_form = null;
                model.data_form_bak = null;
                model.original_members_only = null;
                model.room_configuration_context = null;
                request_room_configuration(model, dialog.model,
                    stream_interactor, true);
            }
            return;
        }

        // Both remaining applied results have passed the authoritative owner
        // form readback. Adopt that exact form as the next UI/save baseline.
        model.data_form_bak = ((!) model.data_form).stanza_node.to_string();
        model.original_members_only =
            MucManager.get_members_only_config_value((!) model.data_form);
        if (save_result ==
                MucConfigSaveResult.APPLIED_LOCAL_SYNC_WARNING) {
            if (close_after_success) {
                dialog.can_close = true;
                dialog.close();
                show_room_configuration_sync_warning();
            } else {
                rebuild_confirmed_room_configuration(model);
                show_room_configuration_sync_warning(dialog);
            }
            return;
        }
        if (close_after_success) {
            dialog.can_close = true;
            dialog.close();
        } else {
            rebuild_confirmed_room_configuration(model);
        }
    }

    private void save_muc_mam_archiving_for_expiry(Model.ConversationDetails model, StreamInteractor stream_interactor) {
        if (model.conversation.type_ != Conversation.Type.GROUPCHAT || model.conversation.message_expiry_seconds <= 0) return;
        if (!can_configure_current_room(model.conversation, stream_interactor)) return;

        MucManager muc_manager = stream_interactor.get_module<MucManager>(
            MucManager.IDENTITY);
        MucManager.MucOwnerMutationContext? room_context =
            muc_manager.capture_current_owner_context(
                model.conversation.account, model.conversation.counterpart);
        if (room_context == null) return;
        muc_manager.get_config_form_in_context.begin(model.conversation.account,
                (!) room_context, (obj, res) => {
            DataForms.DataForm? data_form =
                muc_manager.get_config_form_in_context.end(res);
            if (data_form == null) {
                show_room_configuration_save_error();
                return;
            }
            if (model.conversation.message_expiry_seconds <= 0) return;
            if (!can_configure_current_room(model.conversation, stream_interactor)) {
                show_room_configuration_save_error();
                return;
            }

            bool? original_members_only = MucManager.get_members_only_config_value(data_form);
            muc_manager.set_mam_archiving_enabled(data_form, true);
            muc_manager.set_config_form_detailed_in_context.begin(
                    model.conversation.account, (!) room_context, data_form,
                    original_members_only, (obj, res) => {
                MucConfigSaveResult result = stream_interactor.get_module<
                    MucManager>(MucManager.IDENTITY)
                    .set_config_form_detailed_in_context.end(res);
                if (result == MucConfigSaveResult.REJECTED) {
                    show_room_configuration_save_error();
                } else if (result == MucConfigSaveResult.REJECTED_PREFLIGHT_MEMBERS_PRESERVED) {
                    show_room_configuration_preflight_warning();
                } else if (result ==
                        MucConfigSaveResult.APPLIED_SERVER_STATE_UNVERIFIED) {
                    show_room_configuration_unverified_warning();
                } else if (result ==
                        MucConfigSaveResult.APPLIED_LOCAL_SYNC_WARNING) {
                    show_room_configuration_sync_warning();
                }
            });
        });
    }

    public void set_about_rows(Model.ConversationDetails model, ViewModel.ConversationDetails view_model, StreamInteractor stream_interactor, Gtk.Widget? parent) {
        bool is_synthetic_bot = (model.conversation.counterpart.domainpart == "mqtt.local");

        var xmpp_addr_row = new ViewModel.PreferencesRow.Text();
        xmpp_addr_row.title = _("XMPP Address");
        xmpp_addr_row.text = model.conversation.counterpart.to_string();
        view_model.about_rows.append(xmpp_addr_row);

        // Show own Role/Affiliation in MUC rooms
        var muc_module = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
        var room_jid = model.conversation.counterpart.bare_jid;
        if (model.conversation.type_ == Conversation.Type.GROUPCHAT && muc_module.is_joined(room_jid, model.conversation.account)) {
            // Get own MUC JID (room@conf/nickname) to query own role
            var own_muc_jid = muc_module.get_own_jid(room_jid, model.conversation.account);
            if (own_muc_jid != null) {
                var role = muc_module.get_role(own_muc_jid, model.conversation.account);
                if (role != null && role != Xmpp.Xep.Muc.Role.NONE) {
                    var role_row = new ViewModel.PreferencesRow.Text();
                    role_row.title = _("Your Role");
                    switch (role) {
                        case Xmpp.Xep.Muc.Role.MODERATOR: role_row.text = _("Moderator"); break;
                        case Xmpp.Xep.Muc.Role.PARTICIPANT: role_row.text = _("Participant"); break;
                        case Xmpp.Xep.Muc.Role.VISITOR: role_row.text = _("Visitor"); break;
                        default: role_row.text = _("None"); break;
                    }
                    view_model.about_rows.append(role_row);
                }

                var affiliation = muc_module.get_affiliation(room_jid, own_muc_jid, model.conversation.account);
                if (affiliation != null && affiliation != Xmpp.Xep.Muc.Affiliation.NONE) {
                    var affiliation_row = new ViewModel.PreferencesRow.Text();
                    affiliation_row.title = _("Your Affiliation");
                    switch (affiliation) {
                        case Xmpp.Xep.Muc.Affiliation.OWNER: affiliation_row.text = _("Owner"); break;
                        case Xmpp.Xep.Muc.Affiliation.ADMIN: affiliation_row.text = _("Admin"); break;
                        case Xmpp.Xep.Muc.Affiliation.MEMBER: affiliation_row.text = _("Member"); break;
                        case Xmpp.Xep.Muc.Affiliation.OUTCAST: affiliation_row.text = _("Outcast"); break;
                        default: affiliation_row.text = _("None"); break;
                    }
                    view_model.about_rows.append(affiliation_row);
                }
            }
        }

        if (model.conversation.type_ == Conversation.Type.CHAT && !is_synthetic_bot) {
            var about_row = new ViewModel.PreferencesRow.Entry() {
                title = _("Display name"),
                text = model.display_name.display_name
            };
            about_row.changed.connect(() => {
                if (about_row.text != model.display_name.display_name) {
                    stream_interactor.get_module<RosterManager>(RosterManager.IDENTITY).set_jid_handle(model.conversation.account, model.conversation.counterpart, about_row.text);
                }
            });
            view_model.about_rows.append(about_row);

            var client_row = new ViewModel.PreferencesRow.Text() {
                title = _("Clients"),
                text = _("No active clients")
            };
            view_model.about_rows.append(client_row);
            update_client_row.begin(model, stream_interactor, client_row);

            var permissions = new ViewModel.ContactSubscriptionModel(stream_interactor,
                model.conversation.account, model.conversation.counterpart);
            var permission_row = new ViewModel.PreferencesRow.Text() {
                title = _("Contact permissions"), text = permissions.describe()
            };
            view_model.about_rows.append(permission_row);
            if (parent != null) {
                var weak_row = WeakRef(permission_row);
                var weak_permissions = WeakRef(permissions);
                ulong permissions_handler = permissions.changed.connect(() => {
                    var row = weak_row.get() as ViewModel.PreferencesRow.Text;
                    var current = weak_permissions.get() as ViewModel.ContactSubscriptionModel;
                    if (row != null && current != null) row.text = current.describe();
                });
                parent.unmap.connect(() => {
                    permissions.disconnect(permissions_handler);
                    permissions.deactivate();
                });
            } else {
                permissions.deactivate();
            }
        }
        if (model.conversation.type_ == Conversation.Type.GROUPCHAT) {
            var topic = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_groupchat_subject(model.conversation.counterpart, model.conversation.account);
            string accepted_topic = topic ?? "";

            Ui.ViewModel.PreferencesRow.Any preferences_row = null;
            Jid? own_muc_jid = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_own_jid(model.conversation.counterpart, model.conversation.account);
            if (own_muc_jid != null) {
                MucManager muc_manager = stream_interactor.get_module<
                    MucManager>(MucManager.IDENTITY);
                MucManager.MucOwnerMutationContext? subject_context =
                    muc_manager.capture_current_muc_context(
                        model.conversation.account,
                        model.conversation.counterpart);
                Xep.Muc.Role? own_role = muc_manager.get_role(own_muc_jid,
                    model.conversation.account);
                if (own_role != null) {
                    if (subject_context != null &&
                            muc_manager.can_change_subject(
                                model.conversation.account,
                                model.conversation.counterpart)) {
                        var preferences_row_entry = new ViewModel.PreferencesRow.Entry() {
                            title = _("Topic"),
                            text = topic
                        };
                        bool subject_pending = false;
                        string pending_topic = "";
                        uint subject_timeout_id = 0;
                        ulong subject_handler = muc_manager.subject_set.connect(
                            (event_account, event_room, subject) => {
                                if (event_account != model.conversation.account ||
                                        !event_room.equals_bare(
                                            model.conversation.counterpart))
                                    return;
                                accepted_topic = subject ?? "";
                                subject_pending = false;
                                if (subject_timeout_id != 0) {
                                    Source.remove(subject_timeout_id);
                                    subject_timeout_id = 0;
                                }
                                preferences_row_entry.text = accepted_topic;
                            });
                        if (parent != null) {
                            parent.unmap.connect(() => {
                                if (subject_handler != 0) {
                                    SignalHandler.disconnect(muc_manager,
                                        subject_handler);
                                    subject_handler = 0;
                                }
                                if (subject_timeout_id != 0) {
                                    Source.remove(subject_timeout_id);
                                    subject_timeout_id = 0;
                                }
                            });
                        }
                        preferences_row_entry.changed.connect(() => {
                            if (preferences_row_entry.text == accepted_topic)
                                return;
                            if (subject_pending) {
                                preferences_row_entry.text = pending_topic;
                                return;
                            }
                            pending_topic = preferences_row_entry.text;
                            subject_pending = true;
                            try {
                                muc_manager.change_subject_checked_in_context(
                                    model.conversation.account,
                                    (!) subject_context,
                                    pending_topic);
                                if (subject_pending) {
                                    subject_timeout_id = Timeout.add_seconds(5,
                                        () => {
                                            subject_timeout_id = 0;
                                            if (!subject_pending)
                                                return Source.REMOVE;
                                            subject_pending = false;
                                            // XEP-0045 requires the service to
                                            // broadcast the new subject to the
                                            // other occupants, but does not
                                            // require a self-reflection to the
                                            // sender. Absence of that echo is
                                            // therefore not a rejection.
                                            accepted_topic = pending_topic;
                                            preferences_row_entry.text =
                                                accepted_topic;
                                            return Source.REMOVE;
                                        });
                                }
                            } catch (GLib.Error e) {
                                subject_pending = false;
                                preferences_row_entry.text = accepted_topic;
                                show_room_action_error(parent,
                                    _("The room action is not permitted for the current user state."));
                            }
                        });
                        preferences_row = preferences_row_entry;
                    }
                }
            }
            if (preferences_row == null && topic != null && topic != "") {
                preferences_row = new ViewModel.PreferencesRow.Text() {
                    title = _("Topic"),
                    text = Util.parse_add_markup(topic, null, true, true)
                };
            }
            if (preferences_row != null) {
                view_model.about_rows.append(preferences_row);
            }

            // Administration Button
            if (own_muc_jid != null) {
                Xep.Muc.Affiliation? own_affiliation = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_affiliation(model.conversation.counterpart, own_muc_jid, model.conversation.account);
                if (MucManager.can_configure_room_affiliation(own_affiliation)) {
                    var change_avatar_button = new ViewModel.PreferencesRow.Button() {
                        title = _("Avatar"),
                        button_text = _("Change Avatar")
                    };
                    change_avatar_button.clicked.connect(() => {
                        if (!can_configure_current_room(model.conversation, stream_interactor)) {
                            show_room_action_error(parent,
                                _("The room action is not permitted for the current user state."));
                            return;
                        }
                        change_muc_avatar.begin(stream_interactor, model.conversation.account, model.conversation.counterpart, parent);
                    });
                    view_model.room_administration_rows.append(change_avatar_button);

                    var remove_avatar_button = new ViewModel.PreferencesRow.Button() {
                        title = _("Avatar"),
                        button_text = _("Remove Avatar")
                    };
                    remove_avatar_button.clicked.connect(() => {
                        if (!can_configure_current_room(model.conversation, stream_interactor)) {
                            show_room_action_error(parent,
                                _("The room action is not permitted for the current user state."));
                            return;
                        }
                        remove_muc_avatar.begin(stream_interactor, model.conversation.account, model.conversation.counterpart, parent);
                    });
                    view_model.room_administration_rows.append(remove_avatar_button);
                }

                if (MucManager.can_administer_room_affiliations(own_affiliation)) {
                    var admin_button = new ViewModel.PreferencesRow.Button() {
                        title = _("Permissions"),
                        button_text = _("Manage Affiliations")
                    };
                    admin_button.clicked.connect(() => {
                        if (!can_administer_current_room(model.conversation, stream_interactor)) {
                            show_room_action_error(parent,
                                _("The room action is not permitted for the current user state."));
                            return;
                        }
                        var admin_dialog = new MucAdminDialog(stream_interactor, model.conversation.account, model.conversation.counterpart);
                        // Try to find a window to be transient for
                        if (parent != null) {
                            var window = parent.get_root() as Gtk.Window;
                            admin_dialog.present(window);
                        } else {
                            var app = GLib.Application.get_default() as Gtk.Application;
                            if (app != null) {
                                admin_dialog.present(app.active_window);
                            }
                        }
                    });
                    view_model.room_administration_rows.append(admin_button);

                    var hats_button = new ViewModel.PreferencesRow.Button() {
                        title = _("Hats"),
                        button_text = _("Manage Hats")
                    };
                    hats_button.clicked.connect(() => {
                        if (!can_administer_current_room(model.conversation, stream_interactor)) {
                            show_room_action_error(parent,
                                _("The room action is not permitted for the current user state."));
                            return;
                        }
                        show_hats_management_dialog(stream_interactor, model.conversation.account, model.conversation.counterpart, get_parent_window(parent));
                    });
                    view_model.room_administration_rows.append(hats_button);
                }

                if (own_affiliation == OWNER) {
                    bool destroy_in_progress = false;
                    var destroy_button = new ViewModel.PreferencesRow.Button() {
                        title = _("Danger Zone"),
                        button_text = _("Destroy Room")
                    };
                    // TODO: Style this button red if possible, but PreferencesRow.Button doesn't expose style classes easily yet
                    
                    destroy_button.clicked.connect(() => {
                        if (destroy_in_progress) return;
                        if (!can_configure_current_room(model.conversation, stream_interactor)) {
                            show_room_action_error(parent,
                                _("The room action is not permitted for the current user state."));
                            return;
                        }
                        MucManager muc_manager = stream_interactor.get_module<
                            MucManager>(MucManager.IDENTITY);
                        MucManager.MucOwnerMutationContext? destroy_context =
                            muc_manager.capture_current_owner_context(
                                model.conversation.account,
                                model.conversation.counterpart);
                        if (destroy_context == null) {
                            show_room_action_error(parent,
                                _("The room action is not permitted for the current user state."));
                            return;
                        }
                        var confirm_dialog = new Adw.AlertDialog(
                            _("Destroy Room?"),
                            _("This permanently destroys the room on the server. Its message archive may also be deleted, depending on the server settings. Messages already stored on participants' devices are kept.")
                        );
                        confirm_dialog.add_response("cancel", _("Cancel"));
                        confirm_dialog.add_response("destroy", _("Destroy"));
                        confirm_dialog.set_response_appearance("destroy", Adw.ResponseAppearance.DESTRUCTIVE);
                        confirm_dialog.default_response = "cancel";
                        confirm_dialog.close_response = "cancel";
                        
                        confirm_dialog.choose.begin(parent, null, (obj, res) => {
                            string response = confirm_dialog.choose.end(res);
                            if (response == "destroy") {
                                if (destroy_in_progress) return;
                                if (!can_configure_current_room(model.conversation, stream_interactor)) {
                                    show_room_action_error(parent,
                                        _("The room action is not permitted for the current user state."));
                                    return;
                                }
                                destroy_in_progress = true;
                                muc_manager.destroy_room_detailed_in_context.begin(
                                        model.conversation.account,
                                        (!) destroy_context, null,
                                        (obj2, res2) => {
                                    try {
                                        MucDestroyResult destroy_result =
                                            muc_manager
                                                .destroy_room_detailed_in_context.end(res2);
                                        close_details_discarding_room_configuration(
                                            model, parent);
                                        if (destroy_result == MucDestroyResult.APPLIED_LOCAL_SYNC_WARNING) {
                                            show_room_destroy_sync_warning();
                                        }
                                    } catch (GLib.Error e) {
                                        destroy_in_progress = false;
                                        Gtk.Window? window = null;
                                        if (parent != null) window = parent.get_root() as Gtk.Window;
                                        var error_dialog = new Adw.AlertDialog(_("Failed to destroy room"), e.message);
                                        error_dialog.add_response("close", _("Close"));
                                        error_dialog.present(window);
                                    }
                                });
                            }
                        });
                    });
                    view_model.room_administration_rows.append(destroy_button);
                }

                var leave_button = new ViewModel.PreferencesRow.Button() {
                    title = _("Danger Zone"),
                    button_text = _("Leave Conversation")
                };
                leave_button.clicked.connect(() => {
                    confirm_discard_before_leaving(model, parent, () => {
                        close_details_discarding_room_configuration(model,
                            parent);
                        GLib.Application.get_default().activate_action(
                            "leave-conversation", new GLib.Variant.int32(
                                model.conversation.id));
                        return Source.REMOVE;
                    });
                });
                view_model.room_administration_rows.append(leave_button);

                var leave_permanently_button = new ViewModel.PreferencesRow.Button() {
                    title = _("Danger Zone"),
                    button_text = _("Leave Permanently")
                };
                leave_permanently_button.clicked.connect(() => {
                    var confirm_dialog = new Adw.AlertDialog(
                        _("Leave Group Permanently?"),
                        _("This leaves the group, removes its bookmark, and stops DinoX from joining it automatically. The group is not destroyed and your local message history is kept.")
                    );
                    confirm_dialog.add_response("cancel", _("Cancel"));
                    confirm_dialog.add_response("leave", _("Leave Permanently"));
                    confirm_dialog.set_response_appearance("leave", Adw.ResponseAppearance.DESTRUCTIVE);
                    confirm_dialog.default_response = "cancel";
                    confirm_dialog.close_response = "cancel";

                    confirm_dialog.choose.begin(parent, null, (obj, res) => {
                        string response = confirm_dialog.choose.end(res);
                        if (response == "leave") {
                            stream_interactor.get_module<MucManager>(MucManager.IDENTITY).leave_permanently.begin(model.conversation.account, model.conversation.counterpart, (obj2, res2) => {
                                try {
                                    stream_interactor.get_module<MucManager>(MucManager.IDENTITY).leave_permanently.end(res2);
                                    close_details_discarding_room_configuration(
                                        model, parent);
                                } catch (GLib.Error e) {
                                    Gtk.Window? window = null;
                                    if (parent != null) window = parent.get_root() as Gtk.Window;
                                    var error_dialog = new Adw.AlertDialog(_("Failed to leave group"), e.message);
                                    error_dialog.add_response("close", _("Close"));
                                    error_dialog.present(window);
                                }
                            });
                        }
                    });
                });
                view_model.room_administration_rows.append(leave_permanently_button);
            }
        }
        
        // Disappearing Messages - available for all conversation types
        var expiry_row = new ViewModel.PreferencesRow.ComboBox();
        expiry_row.title = _("Auto-delete messages");
        expiry_row.items.add(_("Never"));
        expiry_row.items.add(_("After 15 minutes"));
        expiry_row.items.add(_("After 30 minutes"));
        expiry_row.items.add(_("After 1 hour"));
        expiry_row.items.add(_("After 24 hours"));
        expiry_row.items.add(_("After 7 days"));
        expiry_row.items.add(_("After 30 days"));

        // Set current value
        switch (model.conversation.message_expiry_seconds) {
            case 900: expiry_row.active_item = 1; break;    // 15 min
            case 1800: expiry_row.active_item = 2; break;   // 30 min
            case 3600: expiry_row.active_item = 3; break;   // 1 hour
            case 86400: expiry_row.active_item = 4; break;  // 24 hours
            case 604800: expiry_row.active_item = 5; break; // 7 days
            case 2592000: expiry_row.active_item = 6; break; // 30 days
            default: expiry_row.active_item = 0; break;
        }

        // Save on change
        expiry_row.notify["active-item"].connect(() => {
            int expiry_seconds = 0;
            switch (expiry_row.active_item) {
                case 1: expiry_seconds = 900; break;    // 15 min
                case 2: expiry_seconds = 1800; break;   // 30 min
                case 3: expiry_seconds = 3600; break;   // 1 hour
                case 4: expiry_seconds = 86400; break;  // 24 hours
                case 5: expiry_seconds = 604800; break; // 7 days
                case 6: expiry_seconds = 2592000; break; // 30 days
                default: expiry_seconds = 0; break;
            }

            model.conversation.message_expiry_seconds = expiry_seconds;
            if (expiry_seconds > 0 && model.conversation.type_ == Conversation.Type.GROUPCHAT) {
                if (model.data_form != null) {
                    stream_interactor.get_module<MucManager>(MucManager.IDENTITY).set_mam_archiving_enabled(model.data_form, true);
                } else {
                    save_muc_mam_archiving_for_expiry(model, stream_interactor);
                }
            }
        });

        view_model.settings_rows.append(expiry_row);
    }

    private async void update_client_row(Model.ConversationDetails model, StreamInteractor stream_interactor, ViewModel.PreferencesRow.Text client_row) {
        Gee.List<Jid>? full_jids = stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY).get_full_jids(model.conversation.counterpart, model.conversation.account);
        if (full_jids == null || full_jids.size == 0) return;

        var client_names = new ArrayList<string>();
        foreach (Jid full_jid in full_jids) {
            string? label = null;
            Xep.ServiceDiscovery.Identity? identity = yield stream_interactor.get_module<EntityInfo>(EntityInfo.IDENTITY).get_identity(model.conversation.account, full_jid);

            if (identity != null && identity.name != null && identity.name.strip() != "") {
                label = identity.name.strip();
            } else if (full_jid.resourcepart != null && Regex.match_simple("^dino\\.[a-f0-9]{8}$", full_jid.resourcepart)) {
                label = "Dino";
            } else if (full_jid.resourcepart != null && full_jid.resourcepart.strip() != "") {
                label = full_jid.resourcepart.strip();
            }

            if (label != null && !client_names.contains(label)) {
                client_names.add(label);
            }
        }

        if (client_names.size > 0) {
            client_row.text = global::Dino.Ui.Util.join_strings(", ", client_names);
        }
    }

    public Dialog setup_dialog(Conversation conversation, StreamInteractor stream_interactor) {
        var dialog = new Dialog();
        var model = new Model.ConversationDetails();
        model.populate(stream_interactor, conversation);
        bind_dialog(model, dialog.model, stream_interactor);

        if (conversation.type_ == Conversation.Type.GROUPCHAT &&
                can_configure_current_room(conversation, stream_interactor)) {
            set_room_configuration_status(dialog.model, _("Room configuration is not loaded yet"), _("Load"));
            dialog.room_configuration_visible.connect(() => {
                request_room_configuration(model, dialog.model, stream_interactor);
            });
            dialog.model.room_configuration_retry.connect(() => {
                model.data_form = null;
                model.data_form_bak = null;
                model.original_members_only = null;
                model.room_configuration_context = null;
                request_room_configuration(model, dialog.model, stream_interactor, true);
            });
        }

        set_about_rows(model, dialog.model, stream_interactor, dialog);

        dialog.model.room_configuration_save.connect(() => {
            save_room_configuration.begin(model, dialog, stream_interactor,
                false);
        });
        model.notify["data-form"].connect(() => {
            if (model.data_form != null) dialog.can_close = false;
        });

        bool room_configuration_close_prompt_active = false;
        dialog.close_attempt.connect(() => {
            if (model.room_configuration_saving ||
                    room_configuration_close_prompt_active) {
                return;
            }
            if (model.data_form == null || model.data_form_bak == null ||
                    ((!) model.data_form).get_changed_field_vars().is_empty) {
                dialog.can_close = true;
                dialog.close();
                return;
            }

            room_configuration_close_prompt_active = true;
            var confirm_dialog = new Adw.AlertDialog(
                _("Save Room Configuration?"),
                _("The room configuration contains unsaved changes."));
            confirm_dialog.add_response("cancel", _("Cancel"));
            confirm_dialog.add_response("discard", _("Discard"));
            confirm_dialog.add_response("save", _("Save"));
            confirm_dialog.set_response_appearance("discard",
                Adw.ResponseAppearance.DESTRUCTIVE);
            confirm_dialog.set_response_appearance("save",
                Adw.ResponseAppearance.SUGGESTED);
            confirm_dialog.default_response = "save";
            confirm_dialog.close_response = "cancel";
            confirm_dialog.choose.begin(dialog, null, (obj, res) => {
                string response = confirm_dialog.choose.end(res);
                room_configuration_close_prompt_active = false;
                if (response == "discard") {
                    dialog.can_close = true;
                    dialog.close();
                } else if (response == "save") {
                    save_room_configuration.begin(model, dialog,
                        stream_interactor, true);
                }
            });
        });

        dialog.closed.connect(() => {
            model.room_configuration_loading = false;
        });

        Plugins.ContactDetails contact_details = new Plugins.ContactDetails();
        contact_details.add_settings_action_row.connect((entry_row_model) => {
            dialog.model.settings_rows.append((Ui.ViewModel.PreferencesRow.Any) entry_row_model);
        });
        Application app = GLib.Application.get_default() as Application;
        app.plugin_registry.register_contact_details_entry(new ContactDetails.SettingsProvider(stream_interactor));

        foreach (Plugins.ContactDetailsProvider provider in app.plugin_registry.contact_details_entries) {
            var preferences_group = (Adw.PreferencesGroup) provider.get_widget(conversation);
            if (preferences_group != null) {
                dialog.add_encryption_tab_element(preferences_group);
            }
            provider.populate(conversation, contact_details, Plugins.WidgetType.GTK4);
        }

        if (conversation.type_ == Conversation.Type.GROUPCHAT) {
            var history_preferences = create_history_preferences(model,
                stream_interactor.get_module<MucManager>(MucManager.IDENTITY));
            history_preferences.append_to(dialog.model.settings_rows);
            history_preferences.attach_to_dialog(dialog);
        }

        return dialog;
    }

    private async void fetch_vcard(Model.ConversationDetails model, Conversation conversation, StreamInteractor stream_interactor) {
        Jid target_jid = conversation.counterpart;
        bool is_muc_occupant = (conversation.type_ == Conversation.Type.GROUPCHAT_PM);

        if (is_muc_occupant) {
            var real_jid = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_real_jid(conversation.counterpart, conversation.account);
            if (real_jid != null) {
                target_jid = real_jid;
                is_muc_occupant = false; // It's now a real user JID
            }
        }

        // For normal users (not MUC occupants), always use the bare JID for vCard requests
        if (!is_muc_occupant) {
            target_jid = target_jid.bare_jid;
        }

        var stream = stream_interactor.get_stream(conversation.account);
        if (stream == null) {
            return;
        }

        // Try XEP-0292
        var vcard4_module = stream.get_module<Xmpp.Xep.VCard4.Module>(Xmpp.Xep.VCard4.Module.IDENTITY);
        if (vcard4_module != null) {
            var vcard4 = yield vcard4_module.request(stream, target_jid);
            if (vcard4 != null) {
                model.vcard4 = vcard4;
                // If we have vCard4, we might still want to check PEP nickname if vCard4 nickname is missing?
                // But usually vCard4 is authoritative.
            }
        }

        // Try PEP Nickname (XEP-0172)
        var pubsub_module = stream.get_module<Xmpp.Xep.Pubsub.Module>(Xmpp.Xep.Pubsub.Module.IDENTITY);
        if (pubsub_module != null) {
            var items = yield pubsub_module.request_all(stream, target_jid, "http://jabber.org/protocol/nick", 1, Xmpp.Xep.Pubsub.RequestPurpose.OPPORTUNISTIC_METADATA);
            if (items != null && items.size > 0) {
                var item = items[0];
                var nick_node = item.get_subnode("nick", "http://jabber.org/protocol/nick");
                if (nick_node != null) {
                    var nick = nick_node.get_string_content();
                    if (nick != null) {
                        model.pep_nickname = nick;
                    }
                }
            }
        }
        
        // Try XEP-0054
        var vcard_temp = yield Xmpp.Xep.VCard.fetch_vcard(stream, target_jid);
        if (vcard_temp != null) {
            model.vcard_temp = vcard_temp;
        }
    }

    private void update_vcard_rows(Model.ConversationDetails model, ViewModel.ConversationDetails view_model) {
        view_model.vcard_rows.remove_all();
        
        string? fn = null;
        string? nickname = null;
        string? note = null;
        string? bday = null;
        string? address = null;
        
        Gee.List<string> emails = new Gee.ArrayList<string>();
        Gee.List<string> phones = new Gee.ArrayList<string>();
        Gee.List<string> urls = new Gee.ArrayList<string>();
        Gee.List<string> roles = new Gee.ArrayList<string>();
        Gee.List<string> titles = new Gee.ArrayList<string>();
        Gee.List<string> orgs = new Gee.ArrayList<string>();

        string? tz = null;
        string? gender = null;

        Gee.List<string> impps = new Gee.ArrayList<string>();

        // 1. Try vCard4 first
        if (model.vcard4 != null) {
            fn = model.vcard4.full_name;
            nickname = model.vcard4.nickname;
            note = model.vcard4.note;
            bday = model.vcard4.bday;
            tz = model.vcard4.tz;
            gender = model.vcard4.gender;
            
            emails.add_all(model.vcard4.emails);
            phones.add_all(model.vcard4.tels);
            urls.add_all(model.vcard4.urls);
            roles.add_all(model.vcard4.roles);
            titles.add_all(model.vcard4.titles);
            orgs.add_all(model.vcard4.orgs);
            
            foreach (var impp in model.vcard4.impps) {
                impps.add(impp);
            }
            
            // Construct address string for vCard4
            var parts = new ArrayList<string>();
            if (model.vcard4.adr_street != null) parts.add(model.vcard4.adr_street);
            
            // Handle PCode and POBox
            string? pcode = model.vcard4.adr_pcode;
            if (pcode == null) pcode = model.vcard4.adr_pobox; // Fallback if Gajim puts zip in pobox
            
            if (pcode != null && model.vcard4.adr_locality != null) {
                parts.add(pcode + " " + model.vcard4.adr_locality);
            } else {
                if (pcode != null) parts.add(pcode);
                if (model.vcard4.adr_locality != null) parts.add(model.vcard4.adr_locality);
            }
            if (model.vcard4.adr_region != null) parts.add(model.vcard4.adr_region);
            if (model.vcard4.adr_country != null) parts.add(model.vcard4.adr_country);
            
            if (parts.size > 0) {
                address = global::Dino.Ui.Util.join_strings(", ", parts);
            }
        }

        // 2. Fallback / Merge with vCard-temp
        if (model.vcard_temp != null) {
            if (fn == null || fn == "") fn = model.vcard_temp.full_name;
            if (nickname == null || nickname == "") nickname = model.vcard_temp.nickname;
            if (note == null || note == "") note = model.vcard_temp.description;
            if (bday == null || bday == "") bday = model.vcard_temp.birthday;
            
            foreach (var email in model.vcard_temp.emails) {
                if (!emails.contains(email)) emails.add(email);
            }
            foreach (var phone in model.vcard_temp.phones) {
                if (!phones.contains(phone)) phones.add(phone);
            }
            foreach (var url in model.vcard_temp.urls) {
                if (!urls.contains(url)) urls.add(url);
            }
            foreach (var role in model.vcard_temp.roles) {
                if (!roles.contains(role)) roles.add(role);
            }
            foreach (var title in model.vcard_temp.titles) {
                if (!titles.contains(title)) titles.add(title);
            }
            foreach (var org in model.vcard_temp.organizations) {
                if (!orgs.contains(org)) orgs.add(org);
            }

            // If address is still missing, try vCard-temp
            if (address == null || address == "") {
                var parts = new ArrayList<string>();
                if (model.vcard_temp.adr_street != null) parts.add(model.vcard_temp.adr_street);
                if (model.vcard_temp.adr_pcode != null && model.vcard_temp.adr_locality != null) {
                    parts.add(model.vcard_temp.adr_pcode + " " + model.vcard_temp.adr_locality);
                } else {
                    if (model.vcard_temp.adr_pcode != null) parts.add(model.vcard_temp.adr_pcode);
                    if (model.vcard_temp.adr_locality != null) parts.add(model.vcard_temp.adr_locality);
                }
                if (model.vcard_temp.adr_region != null) parts.add(model.vcard_temp.adr_region);
                if (model.vcard_temp.adr_country != null) parts.add(model.vcard_temp.adr_country);
                
                if (parts.size > 0) {
                    address = global::Dino.Ui.Util.join_strings(", ", parts);
                }
            }
        }

        if (model.pep_nickname != null) {
            nickname = model.pep_nickname;
        }

        if (fn != null && fn != "") view_model.vcard_rows.append(new ViewModel.PreferencesRow.Text() { title = _("Full Name"), text = fn });
        if (nickname != null && nickname != "") view_model.vcard_rows.append(new ViewModel.PreferencesRow.Text() { title = _("Nickname"), text = nickname });
        
        // Requested Sort Order:
        // Gender, Birthday, Address, Email, IM Address, Phone, Organization, Title, Role, Timezone, URL, Note

        if (gender != null && gender != "") {
            string display_gender = gender;
            if (gender == "M") display_gender = _("Male");
            else if (gender == "F") display_gender = _("Female");
            else if (gender == "O") display_gender = _("Other");
            else if (gender == "N") display_gender = _("None");
            else if (gender == "U") display_gender = _("Unknown");
            
            view_model.vcard_rows.append(new ViewModel.PreferencesRow.Text() { title = _("Gender"), text = display_gender });
        }

        if (bday != null && bday != "") view_model.vcard_rows.append(new ViewModel.PreferencesRow.Text() { title = _("Birthday"), text = bday });
        
        if (address != null && address != "") view_model.vcard_rows.append(new ViewModel.PreferencesRow.Text() { title = _("Address"), text = address });
        
        foreach (var email in emails) if (email != "") view_model.vcard_rows.append(new ViewModel.PreferencesRow.Text() { title = _("Email"), text = email });
        
        foreach (var impp in impps) if (impp != "") view_model.vcard_rows.append(new ViewModel.PreferencesRow.Text() { title = _("IM Address"), text = impp });
        
        foreach (var phone in phones) if (phone != "") view_model.vcard_rows.append(new ViewModel.PreferencesRow.Text() { title = _("Phone"), text = phone });
        
        foreach (var org in orgs) if (org != "") view_model.vcard_rows.append(new ViewModel.PreferencesRow.Text() { title = _("Organization"), text = org });
        
        foreach (var title in titles) if (title != "") view_model.vcard_rows.append(new ViewModel.PreferencesRow.Text() { title = _("Title"), text = title });
        
        foreach (var role in roles) if (role != "") view_model.vcard_rows.append(new ViewModel.PreferencesRow.Text() { title = _("Role"), text = role });
        
        if (tz != null && tz != "") view_model.vcard_rows.append(new ViewModel.PreferencesRow.Text() { title = _("Timezone"), text = tz });
        
        foreach (var url in urls) if (url != "") view_model.vcard_rows.append(new ViewModel.PreferencesRow.Text() { title = _("URL"), text = url });
        
        if (note != null && note != "") view_model.vcard_rows.append(new ViewModel.PreferencesRow.Text() { title = _("Note"), text = note });
    }

    private void show_room_action_error(Gtk.Widget? parent, string detail) {
        var error_dialog = new Adw.AlertDialog(_("Room action failed"), detail);
        error_dialog.add_response("close", _("Close"));
        error_dialog.present(get_parent_window(parent));
    }

    private void require_current_muc_avatar_context(MucManager muc_manager,
            Account account, MucManager.MucOwnerMutationContext context)
            throws GLib.Error {
        if (!muc_manager.is_current_owner_context(account, context)) {
            throw new GLib.IOError.PERMISSION_DENIED(
                "Room owner permission is no longer available");
        }
    }

    private async void change_muc_avatar(StreamInteractor stream_interactor, Account account, Jid room_jid, Gtk.Widget? parent) {
        MucManager muc_manager = stream_interactor.get_module<MucManager>(
            MucManager.IDENTITY);
        MucManager.MucOwnerMutationContext? maybe_context =
            muc_manager.capture_current_owner_context(account, room_jid);
        if (maybe_context == null) {
            show_room_action_error(parent,
                _("The room action is not permitted for the current user state."));
            return;
        }
        MucManager.MucOwnerMutationContext context = (!) maybe_context;
        if (!muc_manager.try_begin_muc_avatar_mutation(account,
                context.room)) {
            show_room_action_error(parent,
                _("Please wait, this may take a moment…"));
            return;
        }

        var dialog = new Gtk.FileDialog();
        dialog.title = _("Select Avatar");
        var filter = new Gtk.FileFilter();
        filter.add_mime_type("image/png");
        filter.add_mime_type("image/jpeg");
        filter.add_mime_type("image/gif");
        filter.add_mime_type("image/webp");
        filter.name = _("Images");
        
        var filters = new GLib.ListStore(typeof(Gtk.FileFilter));
        filters.append(filter);
        dialog.filters = filters;
        dialog.default_filter = filter;

        Gtk.Window? window = null;
        if (parent != null) {
            window = parent.get_root() as Gtk.Window;
        }

        try {
            File file = yield dialog.open(window, null);
            require_current_muc_avatar_context(muc_manager, account, context);
            if (file == null) return;
            
            // Resize image if necessary (limit to 192px)
            const int MAX_PIXEL = 192;
            var file_stream = yield file.read_async();
            require_current_muc_avatar_context(muc_manager, account, context);
            var pixbuf = yield new Gdk.Pixbuf.from_stream_async(file_stream);
            require_current_muc_avatar_context(muc_manager, account, context);
            yield file_stream.close_async();
            require_current_muc_avatar_context(muc_manager, account, context);

            if (pixbuf.width >= pixbuf.height && pixbuf.width > MAX_PIXEL) {
                int dest_height = int.max(1, (int) ((float) MAX_PIXEL / pixbuf.width * pixbuf.height));
                pixbuf = pixbuf.scale_simple(MAX_PIXEL, dest_height, Gdk.InterpType.BILINEAR);
            } else if (pixbuf.height > pixbuf.width && pixbuf.height > MAX_PIXEL) {
                int dest_width = int.max(1, (int) ((float) MAX_PIXEL / pixbuf.height * pixbuf.width));
                pixbuf = pixbuf.scale_simple(dest_width, MAX_PIXEL, Gdk.InterpType.BILINEAR);
            }

            uint8[] buffer;
            buffer = global::Dino.Ui.Util.pixbuf_to_png_bytes(pixbuf);
            Bytes bytes = new Bytes(buffer);

            require_current_muc_avatar_context(muc_manager, account, context);

            debug("Updating MUC avatar for %s...", context.room.to_string());
            // A checked fetch is required: an IQ error must never be treated as an empty vCard.
            var vcard = yield muc_manager.fetch_muc_vcard_in_owner_context(
                account, context);
            require_current_muc_avatar_context(muc_manager, account, context);
            if (vcard == null) vcard = new Xmpp.Xep.VCard.VCardInfo();
            vcard.photo = bytes;
            vcard.photo_type = "image/png";
            yield muc_manager.publish_muc_vcard_in_owner_context(account,
                context, (!) vcard);
            require_current_muc_avatar_context(muc_manager, account, context);
            debug("MUC vCard published.");

            // Mutate local UI/cache only after the server confirmed the IQ.
            string hash = Checksum.compute_for_bytes(ChecksumType.SHA1, bytes);
            var avatar_manager = stream_interactor.get_module<AvatarManager>(AvatarManager.IDENTITY);
            yield avatar_manager.store_image(hash, bytes);
            require_current_muc_avatar_context(muc_manager, account, context);
            avatar_manager.on_vcard_avatar_received(account, context.room, hash);
            debug("MUC avatar updated locally.");
        } catch (Gtk.DialogError e) {
            return;
        } catch (Error e) {
            warning("Failed to select or upload avatar: %s", e.message);
            show_room_action_error(parent, e.message);
        } finally {
            muc_manager.finish_muc_avatar_mutation(account, context.room);
        }
    }

    private async void remove_muc_avatar(StreamInteractor stream_interactor, Account account, Jid room_jid, Gtk.Widget? parent) {
        MucManager muc_manager = stream_interactor.get_module<MucManager>(
            MucManager.IDENTITY);
        MucManager.MucOwnerMutationContext? maybe_context =
            muc_manager.capture_current_owner_context(account, room_jid);
        if (maybe_context == null) {
            show_room_action_error(parent,
                _("The room action is not permitted for the current user state."));
            return;
        }
        MucManager.MucOwnerMutationContext context = (!) maybe_context;
        if (!muc_manager.try_begin_muc_avatar_mutation(account,
                context.room)) {
            show_room_action_error(parent,
                _("Please wait, this may take a moment…"));
            return;
        }

        try {
            // Fetch existing vCard to preserve other fields (description, etc.)
            var vcard = yield muc_manager.fetch_muc_vcard_in_owner_context(
                account, context);
            require_current_muc_avatar_context(muc_manager, account, context);
            if (vcard == null) vcard = new Xmpp.Xep.VCard.VCardInfo();

            // Clear the photo — to_node() will omit the PHOTO element entirely
            vcard.photo = null;
            vcard.photo_type = null;

            yield muc_manager.publish_muc_vcard_in_owner_context(account,
                context, (!) vcard);
            require_current_muc_avatar_context(muc_manager, account, context);
            debug("MUC avatar removed for %s", context.room.to_string());

            // Clear local avatar cache
            var avatar_manager = stream_interactor.get_module<AvatarManager>(AvatarManager.IDENTITY);
            avatar_manager.remove_vcard_avatar(account, context.room);
        } catch (Error e) {
            warning("Failed to remove MUC avatar: %s", e.message);
            show_room_action_error(parent, e.message);
        } finally {
            muc_manager.finish_muc_avatar_mutation(account, context.room);
        }
    }

    private static void show_hats_management_dialog(StreamInteractor stream_interactor, Account account, Jid room_jid, Gtk.Window? parent_window) {
        MucManager muc_manager = stream_interactor.get_module<MucManager>(
            MucManager.IDENTITY);
        MucManager.MucOwnerMutationContext? room_context =
            muc_manager.capture_current_muc_context(account, room_jid);
        if (room_context == null ||
                !can_manage_hats_now(stream_interactor, account, room_jid,
                    (!) room_context)) {
            show_hats_result(parent_window, _("Hat command failed"),
                _("The room action is not permitted for the current user state."));
            return;
        }
        var dialog = new Adw.Dialog();
        var management_state = new HatsManagementDialogState(
            (!) room_context);
        dialog.closed.connect(() => {
            management_state.closed = true;
        });
        dialog.title = _("Manage Hats");
        dialog.content_width = HATS_DIALOG_CONTENT_WIDTH;
        dialog.content_height = HATS_DIALOG_CONTENT_HEIGHT;

        var toolbar_view = new Adw.ToolbarView();
        toolbar_view.add_top_bar(new Adw.HeaderBar());

        var page = new HatsManagementPage(room_jid.bare_jid.to_string(),
            account.bare_jid.to_string());
        toolbar_view.content = page;
        var feedback = new Adw.ToastOverlay() { child = toolbar_view };
        dialog.child = feedback;
        management_state.page = WeakRef(page);
        management_state.feedback = WeakRef(feedback);
        HatsDialogSignals.track(dialog, page, page.requested.connect((node, uri, jid) => {
            if (management_state.closed || management_state.loading ||
                    management_state.command_started ||
                    management_state.action_dialog.get() != null ||
                    !management_state.available_nodes.contains(node)) return;
            management_state.command_started = true;
            // Keep the overview in the native dialog stack. Closing an action
            // must reveal this exact overview, not the room administration.
            run_hats_command.begin(stream_interactor, account, room_jid,
                parent_window, node, management_state.available_nodes,
                management_state.context, management_state, uri, jid, (obj, result) => {
                    run_hats_command.end(result);
                    management_state.command_started = false;
                });
        }));
        dialog.present(parent_window);
        populate_hats_management.begin(stream_interactor, account, room_jid,
            management_state);
    }

    private static bool can_manage_hats_now(StreamInteractor stream_interactor,
            Account account, Jid room_jid,
            MucManager.MucOwnerMutationContext? expected_context = null) {
        MucManager muc_manager = stream_interactor.get_module<MucManager>(
            MucManager.IDENTITY);
        if (expected_context != null &&
                (!((!) expected_context).room.equals_bare(room_jid) ||
                 !muc_manager.is_current_muc_context(account,
                    (!) expected_context))) return false;
        Jid? own_jid = muc_manager.get_own_jid(room_jid.bare_jid, account);
        if (own_jid == null) return false;
        return MucManager.can_administer_room_affiliations(
            muc_manager.get_affiliation(room_jid.bare_jid, (!) own_jid,
                account));
    }

    private static async void populate_hats_management(
            StreamInteractor stream_interactor, Account account, Jid room_jid,
            HatsManagementDialogState management_state) {
        var page = management_state.page.get() as HatsManagementPage;
        if (management_state.closed || management_state.loading || page == null) return;
        management_state.loading = true;
        page.sensitive = false;
        try {
            XmppStream stream = management_state.context.stream;
            if (!can_manage_hats_now(stream_interactor, account, room_jid,
                    management_state.context)) {
                page.show_failure();
                return;
            }
            var module = stream.get_module<Xep.AdHocCommands.Module>(
                Xep.AdHocCommands.Module.IDENTITY);
            var commands = yield module.list_commands(stream, room_jid.bare_jid);
            if (management_state.closed) return;
            if (stream_interactor.get_stream(account) != stream ||
                    !can_manage_hats_now(stream_interactor, account, room_jid,
                        management_state.context) || commands == null) {
                page.show_failure();
                return;
            }
            var available_nodes = new HashSet<string>();
            foreach (var command in commands) {
                if (command.jid.equals(room_jid.bare_jid) &&
                        command.node.has_prefix("urn:xmpp:hats:commands:")) {
                    available_nodes.add(command.node);
                }
            }
            Gee.List<HatChoice>? hats = null;
            if (available_nodes.contains("urn:xmpp:hats:commands:list")) {
                hats = yield get_room_hats(stream_interactor, account, room_jid,
                    stream, management_state.context);
            }
            if (management_state.closed) return;
            if (stream_interactor.get_stream(account) != stream ||
                    !can_manage_hats_now(stream_interactor, account, room_jid,
                        management_state.context)) {
                page.show_failure();
                return;
            }
            Gee.List<AssignedHatChoice>? assigned = null;
            if (available_nodes.contains("urn:xmpp:hats:commands:list-assigned")) {
                assigned = yield get_assigned_room_hats(stream_interactor, account,
                    room_jid, stream, management_state.context);
            }
            if (management_state.closed) return;
            if (stream_interactor.get_stream(account) != stream ||
                    !can_manage_hats_now(stream_interactor, account, room_jid,
                        management_state.context)) {
                page.show_failure();
                return;
            }
            management_state.available_nodes = available_nodes;
            page.show_content(available_nodes, hats, assigned);
        } finally {
            management_state.loading = false;
            page.sensitive = true;
        }
    }

    private static async void run_hats_command(StreamInteractor stream_interactor, Account account, Jid room_jid, Gtk.Window? parent_window, string node, Gee.Set<string> available_nodes, MucManager.MucOwnerMutationContext room_context, HatsManagementDialogState management_state, string? preset_uri = null, string? preset_jid = null) {
        if (management_state.closed) return;
        XmppStream? stream = room_context.stream;
        if (!can_manage_hats_now(stream_interactor, account, room_jid,
                room_context)) {
            show_hats_result(parent_window, _("Hat command failed"),
                _("The room action is not permitted for the current user state."));
            return;
        }
        Xep.AdHocCommands.Module module = ((!) stream).get_module<
            Xep.AdHocCommands.Module>(Xep.AdHocCommands.Module.IDENTITY);
        Xep.AdHocCommands.Command? command = yield module.execute((!) stream,
            room_jid.bare_jid, node);
        if (management_state.closed) {
            if (command != null) cancel_hats_session.begin(stream_interactor,
                account, room_jid, command, stream);
            return;
        }
        if (stream_interactor.get_stream(account) != stream ||
                !can_manage_hats_now(stream_interactor, account, room_jid,
                    room_context)) {
            if (command != null && ((!) command).status ==
                    Xep.AdHocCommands.Command.Status.EXECUTING &&
                    ((!) command).node != null &&
                    ((!) command).sessionid != null) {
                module.cancel.begin((!) stream, room_jid.bare_jid,
                    (!) ((!) command).node, (!) ((!) command).sessionid);
            }
            show_hats_result(parent_window, _("Hat command failed"),
                _("The room action is not permitted for the current user state."));
            return;
        }
        if (command == null) {
            show_hats_result(parent_window, _("Hat command failed"),
                _("The server did not accept the hats command."));
            return;
        }
        ((!) command).set_data<MucManager.MucOwnerMutationContext>(
            "dinox-hats-room-context", room_context);
        command.set_data<HatsManagementDialogState>("dinox-hats-management", management_state);
        if (((!) command).status == Xep.AdHocCommands.Command.Status.CANCELED ||
                ((!) command).has_error_note()) {
            if (((!) command).status ==
                    Xep.AdHocCommands.Command.Status.EXECUTING) {
                cancel_hats_session.begin(stream_interactor, account,
                    room_jid, (!) command, (!) stream);
            }
            show_hats_result(parent_window, _("Hat command failed"),
                ((!) command).get_error_note_text() ??
                    _("The server did not accept the hats command."));
            return;
        }
        if (((!) command).status == Xep.AdHocCommands.Command.Status.COMPLETED) {
            if (is_hats_mutation_node(command.node)) {
                refresh_hats_after_mutation(stream_interactor, account, room_jid, command);
            } else {
                show_hats_result(parent_window, _("Hat command completed"), _("The hats command completed successfully."));
            }
            return;
        }
        if (((!) command).form == null) {
            if (((!) command).status ==
                    Xep.AdHocCommands.Command.Status.EXECUTING) {
                cancel_hats_session.begin(stream_interactor, account,
                    room_jid, (!) command, (!) stream);
            }
            show_hats_result(parent_window, _("Hat command failed"),
                _("The server returned an invalid command state."));
            return;
        }

        Gee.List<HatChoice>? hats = null;
        Gee.List<AssignedHatChoice>? assigned_hats = null;
        if (((node == "urn:xmpp:hats:commands:create" && preset_uri != null) ||
                node == "urn:xmpp:hats:commands:assign" ||
                node == "urn:xmpp:hats:commands:unassign" ||
                node == "urn:xmpp:hats:commands:destroy") &&
                available_nodes.contains("urn:xmpp:hats:commands:list")) {
            hats = yield get_room_hats(stream_interactor, account, room_jid,
                stream, room_context);
            if (management_state.closed) {
                cancel_hats_session.begin(stream_interactor, account, room_jid, command, stream);
                return;
            }
            if (hats == null) {
                cancel_hats_session.begin(stream_interactor, account,
                    room_jid, (!) command, (!) stream);
                show_hats_result(parent_window, _("Hat command failed"),
                    _("Available hats could not be loaded."));
                return;
            }
        }
        if ((node == "urn:xmpp:hats:commands:assign" ||
                node == "urn:xmpp:hats:commands:unassign") &&
                available_nodes.contains(
                    "urn:xmpp:hats:commands:list-assigned")) {
            assigned_hats = yield get_assigned_room_hats(stream_interactor,
                account, room_jid, stream, room_context);
            if (management_state.closed) {
                cancel_hats_session.begin(stream_interactor, account, room_jid, command, stream);
                return;
            }
            if (assigned_hats == null) {
                cancel_hats_session.begin(stream_interactor, account,
                    room_jid, (!) command, (!) stream);
                show_hats_result(parent_window, _("Hat command failed"),
                    _("Assigned hats could not be loaded."));
                return;
            }
        }

        if (stream_interactor.get_stream(account) != stream ||
                !can_manage_hats_now(stream_interactor, account, room_jid,
                    room_context)) {
            cancel_hats_session.begin(stream_interactor, account, room_jid,
                (!) command, (!) stream);
            show_hats_result(parent_window, _("Hat command failed"),
                _("The room action is not permitted for the current user state."));
            return;
        }

        // Shortcuts never silently target the first remaining hat/person when
        // their selected definition or assignment disappeared meanwhile.
        Gee.List<HatChoice>? preset_hats = hats;
        if (preset_hats == null && assigned_hats != null) {
            preset_hats = get_hats_from_assignments(assigned_hats);
        }
        bool preset_valid = HatFormChoices.permits_preset(command.form,
            get_available_hats(command.form, preset_hats), assigned_hats,
            preset_uri, preset_jid, node == "urn:xmpp:hats:commands:unassign");
        if (!preset_valid) {
            cancel_hats_session.begin(stream_interactor, account, room_jid, command, stream);
            show_hats_result(parent_window, _("Hat command failed"),
                _("The selected hat or assignment is no longer available. Reopen Manage Hats to refresh the list."));
            return;
        }
        if (preset_uri != null) set_hat_uri_form_value(command.form, preset_uri);
        if (preset_jid != null) set_hat_jid_form_value(command.form, preset_jid);
        if (node == "urn:xmpp:hats:commands:create" && preset_uri != null && hats != null) {
            foreach (var hat in hats) {
                if (hat.uri != preset_uri) continue;
                command.set_data<HatChoice>("dinox-hats-edit", hat);
                foreach (var field in command.form.fields) {
                    if (field.type_ != DataForms.DataForm.Type.TEXT_SINGLE) continue;
                    if (field.var == "hats#title") field.set_value_string(hat.title);
                    if (field.var == "hats#hue") field.set_value_string(hat.hue ?? "");
                }
                break;
            }
        }
        show_hats_form_dialog(stream_interactor, account, room_jid,
            parent_window, (!) command, hats, assigned_hats);
    }

    private static void show_hats_form_dialog(StreamInteractor stream_interactor, Account account, Jid room_jid, Gtk.Window? parent_window, Xep.AdHocCommands.Command command, Gee.List<HatChoice>? hats = null, Gee.List<AssignedHatChoice>? assigned_hats = null, bool use_specialized_renderer = true) {
        MucManager.MucOwnerMutationContext? room_context =
            command.get_data<MucManager.MucOwnerMutationContext>(
                "dinox-hats-room-context");
        if (room_context == null ||
                !can_manage_hats_now(stream_interactor, account, room_jid,
                    (!) room_context)) {
            cancel_hats_session.begin(stream_interactor, account, room_jid,
                command, room_context != null
                    ? ((!) room_context).stream : null);
            show_hats_result(parent_window, _("Hat command failed"),
                _("The room action is not permitted for the current user state."));
            return;
        }
        if (use_specialized_renderer &&
                !has_unhandled_required_hats_field(command.form) &&
                HatFormChoices.can_render_specialized(command.form,
                    command.node == "urn:xmpp:hats:commands:create")) {
            switch (command.node) {
                case "urn:xmpp:hats:commands:create":
                    show_create_hat_dialog(stream_interactor, account, room_jid, parent_window, command);
                    return;
                case "urn:xmpp:hats:commands:assign":
                    show_assign_hat_dialog(stream_interactor, account, room_jid, parent_window, command, hats, assigned_hats, false);
                    return;
                case "urn:xmpp:hats:commands:unassign":
                    if (assigned_hats == null) break;
                    if (assigned_hats.size == 0) {
                        cancel_hats_session.begin(stream_interactor, account, room_jid, command);
                        show_hats_result(parent_window, _("Remove Hat Assignment"),
                            _("No hats are assigned in this room."));
                    } else {
                        // Keep the command's restricted hat choices authoritative.
                        var allowed = get_available_hats(command.form, hats);
                        var filtered = new ArrayList<AssignedHatChoice>();
                        foreach (var assignment in assigned_hats) {
                            foreach (var hat in allowed) {
                                if (hat.uri == assignment.uri) { filtered.add(assignment); break; }
                            }
                        }
                        if (filtered.size == 0) break;
                        show_remove_assigned_hat_dialog(stream_interactor, account, room_jid,
                            parent_window, command, filtered);
                    }
                    return;
                case "urn:xmpp:hats:commands:destroy":
                    show_delete_hat_dialog(stream_interactor, account, room_jid, parent_window, command, hats);
                    return;
            }
        }

        string? submit_action = get_hats_submit_action(command);
        if (submit_action == null) {
            cancel_hats_session.begin(stream_interactor, account, room_jid,
                command);
            show_hats_result(parent_window, _("Hat command failed"),
                _("The server returned an invalid command state."));
            return;
        }

        var dialog = new Adw.Dialog();
        HatChoice? edit = command.get_data<HatChoice>("dinox-hats-edit");
        dialog.title = edit != null ? _("Edit Hat") : get_hats_command_title(command.node);
        if (edit != null && command.form != null) foreach (var field in command.form.fields) {
            // The generic server-form fallback must not turn an edit into a new hat.
            if (is_hat_uri_field(field.var)) field.type_ = DataForms.DataForm.Type.HIDDEN;
        }
        dialog.content_width = HATS_DIALOG_CONTENT_WIDTH;
        dialog.content_height = HATS_DIALOG_CONTENT_HEIGHT;

        var toolbar_view = new Adw.ToolbarView();
        var header_bar = new Adw.HeaderBar();
        toolbar_view.add_top_bar(header_bar);

        var submit_button = new Gtk.Button.with_label(
            submit_action == "next" ? _("Next") : _("Complete"));
        submit_button.add_css_class("suggested-action");
        header_bar.pack_end(submit_button);
        add_hats_previous_button(header_bar, stream_interactor, account,
            room_jid, parent_window, dialog, command);

        var page = new Adw.PreferencesPage();
        page.margin_top = 12;
        page.margin_bottom = 12;
        page.margin_start = 12;
        page.margin_end = 12;
        page.add(HatsManagementPage.create_scope(room_jid.bare_jid.to_string(),
            account.bare_jid.to_string()));
        page.add(Util.rows_to_preference_group(Util.get_data_form_view_model(command.form), ""));

        toolbar_view.content = page;
        dialog.child = toolbar_view;
        arm_hats_session_cancel(stream_interactor, account, room_jid, dialog,
            command);

        HatsDialogSignals.track(dialog, submit_button, submit_button.clicked.connect(() => {
            submit_hats_form.begin(stream_interactor, account, room_jid, parent_window, dialog, command);
        }));

        dialog.present(parent_window);
    }

    private static bool has_unhandled_required_hats_field(
            DataForms.DataForm? form) {
        if (form == null) return false;
        foreach (DataForms.DataForm.Field field in form.fields) {
            if (!field.required) continue;
            string? field_var = field.var;
            if (field_var == "hats#title" || field_var == "hats#hue" ||
                    is_hat_uri_field(field_var) ||
                    is_hat_jid_field(field_var)) {
                continue;
            }
            return true;
        }
        return false;
    }

    private static void show_create_hat_dialog(StreamInteractor stream_interactor, Account account, Jid room_jid, Gtk.Window? parent_window, Xep.AdHocCommands.Command command) {
        HatChoice? edit = command.get_data<HatChoice>("dinox-hats-edit");
        var dialog = new Adw.Dialog();
        dialog.title = edit != null ? _("Edit Hat") : _("Create Hat");
        dialog.content_width = 440;

        var toolbar_view = new Adw.ToolbarView();
        var header_bar = new Adw.HeaderBar();
        toolbar_view.add_top_bar(header_bar);

        var submit_button = new Gtk.Button.with_label(edit != null ? _("Save") : _("Create"));
        submit_button.add_css_class("suggested-action");
        header_bar.pack_end(submit_button);
        add_hats_previous_button(header_bar, stream_interactor, account,
            room_jid, parent_window, dialog, command);

        var page = new Adw.PreferencesPage();
        page.margin_top = 12;
        page.margin_bottom = 12;
        page.margin_start = 12;
        page.margin_end = 12;
        page.add(HatsManagementPage.create_scope(room_jid.bare_jid.to_string(),
            account.bare_jid.to_string()));

        var group = new Adw.PreferencesGroup() {
            description = edit != null
                ? _("Changes apply to everyone wearing this hat. Existing assignments are kept.")
                : _("Choose a short name for the badge. Create it first, then assign it to people.")
        };
        var title_row = new Adw.EntryRow() { title = _("Hat title"), show_apply_button = false };
        var color_row = new Adw.ComboRow() { use_markup = false, use_subtitle = true, title_lines = 1, subtitle_lines = 1, title = _("Hat color") };
        var color_model = new Gtk.StringList(null);
        string[] color_names = { _("Blue"), _("Green"), _("Purple"), _("Red"), _("Orange"), _("Default color") };
        double[] hues = { 225.0, 145.0, 285.0, 5.0, 35.0, 0.0 };
        bool hue_required = false;
        bool has_hue = false;
        if (command.form != null) foreach (var field in command.form.fields) {
            if (field.var == "hats#hue") { has_hue = true; hue_required = field.required; }
        }
        for (int i = 0; i < color_names.length; i++) {
            if (i == 5 && hue_required) continue;
            color_model.append(color_names[i]);
        }
        uint custom_index = color_model.get_n_items();
        color_model.append(_("Custom color"));
        color_row.model = color_model;
        color_row.selected = 0;
        color_row.visible = has_hue;
        string current_hue = edit != null ? (edit.hue ?? "") : "225";
        double? initial_hue = HatFormChoices.parse_hue(current_hue);
        if (initial_hue == null && hue_required) current_hue = "225";
        if (edit != null) {
            title_row.text = edit.title;
            color_row.selected = initial_hue == null && !hue_required ? 5 : custom_index;
            if (initial_hue != null) for (uint i = 0; i < 5; i++) {
                if (initial_hue == hues[i]) { color_row.selected = i; break; }
            }
        }
        var picker = new Gtk.ColorDialogButton(new Gtk.ColorDialog() {
            title = _("Hat color"), with_alpha = false
        }) { valign = Align.CENTER, tooltip_text = _("Choose a color") };
        picker.update_property(AccessibleProperty.LABEL, _("Hat color"), -1);
        picker.rgba = HatFormChoices.hue_color(initial_hue ?? 225);
        var picker_row = new Adw.ActionRow() {
            title = _("Custom color"), use_markup = false,
            subtitle = _("The hue is saved. Brightness and contrast are adjusted for readability."),
            visible = has_hue && color_row.selected == custom_index
        };
        picker_row.add_suffix(picker);
        picker_row.activatable_widget = picker;
        var preview = new OccupantMenu.OccupantHatBadges() { valign = Align.CENTER, hexpand = false };
        var preview_row = new Adw.ActionRow() { title = _("Preview"), use_markup = false };
        preview_row.add_suffix(preview);
        group.add(title_row);
        group.add(color_row);
        group.add(picker_row);
        group.add(preview_row);
        page.add(group);

        toolbar_view.content = page;
        dialog.child = toolbar_view;
        arm_hats_session_cancel(stream_interactor, account, room_jid, dialog,
            command);

        update_hat_preview(preview, title_row.text, current_hue);
        submit_button.sensitive = title_row.text.strip() != "";
        HatsDialogSignals.track(dialog, title_row, title_row.notify["text"].connect(() => {
            submit_button.sensitive = title_row.text.strip() != "";
            update_hat_preview(preview, title_row.text, current_hue);
        }));
        HatsDialogSignals.track(dialog, color_row, color_row.notify["selected"].connect(() => {
            picker_row.visible = color_row.selected == custom_index;
            if (color_row.selected < 5) current_hue = hues[color_row.selected].to_string();
            else if (color_row.selected == custom_index) {
                current_hue = HatFormChoices.picker_hue(picker, "225");
            } else current_hue = "";
            update_hat_preview(preview, title_row.text, current_hue);
        }));
        HatsDialogSignals.track(dialog, picker, picker.notify["rgba"].connect(() => {
            current_hue = HatFormChoices.picker_hue(picker,
                HatFormChoices.parse_hue(current_hue) != null ? current_hue : "225");
            update_hat_preview(preview, title_row.text, current_hue);
        }));
        HatsDialogSignals.track(dialog, title_row, title_row.entry_activated.connect(() => {
            if (submit_button.sensitive) submit_button.activate();
        }));
        // Retrying after an uncertain response must not create another definition.
        string new_hat_uri = edit != null ? edit.uri : HatFormChoices.new_uri();
        HatsDialogSignals.track(dialog, submit_button, submit_button.clicked.connect(() => {
            string title = title_row.text.strip();
            if (title == "") {
                show_hats_result(parent_window, _("Hat command failed"), _("Enter a hat title."));
                return;
            }
            set_hats_form_value(command.form, "hats#title", title);
            set_hat_uri_form_value(command.form, new_hat_uri);
            // Preserve a custom server hue exactly when only the title changes.
            if (has_hue) set_hats_form_value(command.form, "hats#hue", current_hue);
            submit_hats_form.begin(stream_interactor, account, room_jid, parent_window, dialog, command);
        }));

        dialog.present(parent_window);
    }

    private static void update_hat_preview(OccupantMenu.OccupantHatBadges preview,
            string title, string? hue) {
        var hats = new ArrayList<Muc.Hat>();
        hats.add(new Muc.Hat() { uri = "urn:dinox:hat-preview",
            title = title.strip() != "" ? title.strip() : _("Hat"), hue = hue });
        preview.set_hats(hats);
    }

    private static void show_assign_hat_dialog(StreamInteractor stream_interactor, Account account, Jid room_jid, Gtk.Window? parent_window, Xep.AdHocCommands.Command command, Gee.List<HatChoice>? hats, Gee.List<AssignedHatChoice>? assigned_hats, bool remove) {
        if (remove && assigned_hats != null && assigned_hats.size > 0) {
            show_remove_assigned_hat_dialog(stream_interactor, account, room_jid, parent_window, command, assigned_hats);
            return;
        }

        Gee.List<HatChoice> available_hats = get_available_hats(command.form, hats);
        if (available_hats.size == 0) {
            cancel_hats_session.begin(stream_interactor, account, room_jid,
                command);
            show_hats_result(parent_window, _("Hat command failed"), _("No hats are available in this room."));
            return;
        }

        Gee.List<Jid> occupants = stream_interactor.get_module<MucManager>(MucManager.IDENTITY)
            .get_occupants(room_jid, account) ?? new ArrayList<Jid>();

        var dialog = new Adw.Dialog();
        dialog.title = remove ? _("Remove Hat Assignment") : _("Assign Hat");
        dialog.content_width = 440;

        var toolbar_view = new Adw.ToolbarView();
        var header_bar = new Adw.HeaderBar();
        toolbar_view.add_top_bar(header_bar);

        var submit_button = new Gtk.Button.with_label(remove ? _("Remove Assignment") : _("Assign"));
        submit_button.add_css_class("suggested-action");
        header_bar.pack_end(submit_button);
        add_hats_previous_button(header_bar, stream_interactor, account,
            room_jid, parent_window, dialog, command);

        var page = new Adw.PreferencesPage();
        page.margin_top = 12;
        page.margin_bottom = 12;
        page.margin_start = 12;
        page.margin_end = 12;
        page.add(HatsManagementPage.create_scope(room_jid.bare_jid.to_string(),
            account.bare_jid.to_string()));

        var group = new Adw.PreferencesGroup() {
            description = _("Choose a participant or enter an XMPP address, including someone who is offline.")
        };
        var hat_row = new Adw.ComboRow() { use_markup = false, use_subtitle = true, title_lines = 1, subtitle_lines = 1, title = _("Hat") };
        var hat_model = new Gtk.StringList(null);
        foreach (HatChoice hat in available_hats) hat_model.append(hat.title);
        hat_row.model = hat_model;
        hat_row.selected = get_initial_hat_selection(command.form, available_hats);

        group.add(hat_row);

        var user_row = new Adw.ComboRow() { use_markup = false, use_subtitle = true, title_lines = 1, subtitle_lines = 1, title = _("Participant") };
        var real_jids = new ArrayList<string>();
        update_assign_user_choices(stream_interactor, account, occupants, assigned_hats, available_hats[(int) hat_row.selected].uri, user_row, real_jids);
        group.add(user_row);
        var address_row = new Adw.EntryRow() {
            title = _("XMPP address (optional)"), use_markup = false,
            text = get_hat_jid_form_value(command.form) ?? ""
        };
        group.add(address_row);
        page.add(group);

        toolbar_view.content = page;
        dialog.child = toolbar_view;
        arm_hats_session_cancel(stream_interactor, account, room_jid, dialog,
            command);

        HatsDialogSignals.track(dialog, hat_row, hat_row.notify["selected"].connect(() => {
            if (hat_row.selected >= available_hats.size) return;
            update_assign_user_choices(stream_interactor, account, occupants, assigned_hats, available_hats[(int) hat_row.selected].uri, user_row, real_jids);
        }));

        HatsDialogSignals.track(dialog, submit_button, submit_button.clicked.connect(() => {
            if (hat_row.selected >= available_hats.size) return;
            string address = address_row.text.strip();
            if (address == "" && user_row.selected < real_jids.size) {
                address = real_jids[(int) user_row.selected];
            }
            Jid jid;
            try {
                jid = new Jid(address);
            } catch (InvalidJidError error) {
                show_hats_result(parent_window, _("Hat command failed"), _("Enter a valid XMPP address."));
                return;
            }
            if (jid.resourcepart != null || jid.localpart == null) {
                show_hats_result(parent_window, _("Hat command failed"), _("Enter a valid XMPP address."));
                return;
            }
            set_hat_jid_form_value(command.form, jid.bare_jid.to_string());
            set_hat_uri_form_value(command.form, available_hats[(int) hat_row.selected].uri);
            submit_hats_form.begin(stream_interactor, account, room_jid, parent_window, dialog, command);
        }));

        dialog.present(parent_window);
    }

    private static void show_remove_assigned_hat_dialog(StreamInteractor stream_interactor, Account account, Jid room_jid, Gtk.Window? parent_window, Xep.AdHocCommands.Command command, Gee.List<AssignedHatChoice> assigned_hats) {
        var dialog = new Adw.Dialog();
        dialog.title = _("Remove Hat Assignment");
        dialog.content_width = 500;

        var toolbar_view = new Adw.ToolbarView();
        var header_bar = new Adw.HeaderBar();
        toolbar_view.add_top_bar(header_bar);

        var submit_button = new Gtk.Button.with_label(_("Remove Assignment"));
        submit_button.add_css_class("suggested-action");
        header_bar.pack_end(submit_button);
        add_hats_previous_button(header_bar, stream_interactor, account,
            room_jid, parent_window, dialog, command);

        var page = new Adw.PreferencesPage();
        page.margin_top = 12;
        page.margin_bottom = 12;
        page.margin_start = 12;
        page.margin_end = 12;
        page.add(HatsManagementPage.create_scope(room_jid.bare_jid.to_string(),
            account.bare_jid.to_string()));

        var group = new Adw.PreferencesGroup() {
            description = _("Only this person's assignment will be removed. The hat stays available in the room.")
        };
        Gee.List<HatChoice> available_hats = get_hats_from_assignments(assigned_hats);
        var hat_row = new Adw.ComboRow() { use_markup = false, use_subtitle = true, title_lines = 1, subtitle_lines = 1, title = _("Hat") };
        var hat_model = new Gtk.StringList(null);
        foreach (HatChoice hat in available_hats) hat_model.append(hat.title);
        hat_row.model = hat_model;
        hat_row.selected = get_initial_hat_selection(command.form, available_hats);
        group.add(hat_row);

        var assignment_row = new Adw.ComboRow() { use_markup = false, use_subtitle = true, title_lines = 1, subtitle_lines = 1, title = _("XMPP Address") };
        var visible_assignments = new ArrayList<AssignedHatChoice>();
        update_remove_assignment_choices(assigned_hats, available_hats[(int) hat_row.selected].uri, assignment_row, visible_assignments);
        string? initial_jid = get_hat_jid_form_value(command.form);
        for (int i = 0; i < visible_assignments.size; i++) {
            if (visible_assignments[i].jid == initial_jid) assignment_row.selected = i;
        }
        group.add(assignment_row);
        page.add(group);

        toolbar_view.content = page;
        dialog.child = toolbar_view;
        arm_hats_session_cancel(stream_interactor, account, room_jid, dialog,
            command);

        HatsDialogSignals.track(dialog, hat_row, hat_row.notify["selected"].connect(() => {
            if (hat_row.selected >= available_hats.size) return;
            update_remove_assignment_choices(assigned_hats, available_hats[(int) hat_row.selected].uri, assignment_row, visible_assignments);
        }));

        HatsDialogSignals.track(dialog, submit_button, submit_button.clicked.connect(() => {
            if (assignment_row.selected >= visible_assignments.size) {
                show_hats_result(parent_window, _("Hat command failed"), _("No user has this hat assigned."));
                return;
            }
            AssignedHatChoice assignment = visible_assignments[(int) assignment_row.selected];
            set_hat_jid_form_value(command.form, assignment.jid);
            set_hat_uri_form_value(command.form, assignment.uri);
            submit_hats_form.begin(stream_interactor, account, room_jid, parent_window, dialog, command);
        }));

        dialog.present(parent_window);
    }

    private static void show_delete_hat_dialog(StreamInteractor stream_interactor, Account account, Jid room_jid, Gtk.Window? parent_window, Xep.AdHocCommands.Command command, Gee.List<HatChoice>? hats) {
        Gee.List<HatChoice> available_hats = get_available_hats(command.form, hats);
        if (available_hats.size == 0) {
            cancel_hats_session.begin(stream_interactor, account, room_jid,
                command);
            show_hats_result(parent_window, _("Hat command failed"), _("No hats are available in this room."));
            return;
        }

        var dialog = new Adw.Dialog();
        dialog.title = _("Delete Hat from Room");
        dialog.content_width = 420;

        var toolbar_view = new Adw.ToolbarView();
        var header_bar = new Adw.HeaderBar();
        toolbar_view.add_top_bar(header_bar);

        var submit_button = new Gtk.Button.with_label(_("Delete"));
        submit_button.add_css_class("destructive-action");
        header_bar.pack_end(submit_button);
        add_hats_previous_button(header_bar, stream_interactor, account,
            room_jid, parent_window, dialog, command);

        var page = new Adw.PreferencesPage();
        page.margin_top = 12;
        page.margin_bottom = 12;
        page.margin_start = 12;
        page.margin_end = 12;
        page.add(HatsManagementPage.create_scope(room_jid.bare_jid.to_string(),
            account.bare_jid.to_string()));

        var group = new Adw.PreferencesGroup() {
            description = _("Deleting a hat removes it from the room and from everyone it is assigned to.")
        };
        var hat_row = new Adw.ComboRow() { use_markup = false, use_subtitle = true, title_lines = 1, subtitle_lines = 1, title = _("Hat") };
        var hat_model = new Gtk.StringList(null);
        foreach (HatChoice hat in available_hats) hat_model.append(hat.title);
        hat_row.model = hat_model;
        hat_row.selected = get_initial_hat_selection(command.form, available_hats);
        group.add(hat_row);
        page.add(group);

        toolbar_view.content = page;
        dialog.child = toolbar_view;
        arm_hats_session_cancel(stream_interactor, account, room_jid, dialog,
            command);

        HatsDialogSignals.track(dialog, submit_button, submit_button.clicked.connect(() => {
            if (hat_row.selected >= available_hats.size) return;
            HatChoice selected = available_hats[(int) hat_row.selected];
            var confirmation = new Adw.AlertDialog(_("Delete Hat from Room"),
                _("Delete “%s” and all of its assignments in this room?").printf(selected.title));
            confirmation.add_response("cancel", _("Cancel"));
            confirmation.add_response("delete", _("Delete"));
            confirmation.set_response_appearance("delete", Adw.ResponseAppearance.DESTRUCTIVE);
            confirmation.default_response = "cancel";
            confirmation.close_response = "cancel";
            submit_button.sensitive = false;
            HatsDialogSignals.track(dialog, confirmation, confirmation.response.connect((response) => {
                submit_button.sensitive = true;
                if (response != "delete") return;
                set_hat_uri_form_value(command.form, selected.uri);
                submit_hats_form.begin(stream_interactor, account, room_jid, parent_window, dialog, command);
            }));
            confirmation.present(dialog);
        }));

        dialog.present(parent_window);
    }

    private static void add_hats_previous_button(Adw.HeaderBar header_bar,
            StreamInteractor stream_interactor, Account account, Jid room_jid,
            Gtk.Window? parent_window, Adw.Dialog dialog,
            Xep.AdHocCommands.Command command) {
        if (!command.actions.contains("prev")) return;

        var previous_button = new Gtk.Button.with_label(_("Back"));
        header_bar.pack_start(previous_button);
        HatsDialogSignals.track(dialog, previous_button, previous_button.clicked.connect(() => {
            proceed_hats_form.begin(stream_interactor, account, room_jid,
                parent_window, dialog, command, "prev", null);
        }));
    }

    private static async void submit_hats_form(StreamInteractor stream_interactor, Account account, Jid room_jid, Gtk.Window? parent_window, Adw.Dialog dialog, Xep.AdHocCommands.Command command) {
        HatChoice? edit = command.get_data<HatChoice>("dinox-hats-edit");
        if (edit != null && !HatFormChoices.permits_value(command.form, edit.uri, true)) {
            abort_hats_dialog_session(stream_interactor, account, room_jid, dialog, command);
            show_hats_result(parent_window, _("Hat command failed"),
                _("The selected hat or assignment is no longer available. Reopen Manage Hats to refresh the list."));
            return;
        }
        if (edit != null && command.form != null) foreach (var field in command.form.fields) {
            if (is_hat_uri_field(field.var)) field.set_value_string(edit.uri);
        }
        string? action = get_hats_submit_action(command);
        if (action == null) {
            abort_hats_dialog_session(stream_interactor, account,
                room_jid, dialog, command);
            show_hats_result(parent_window, _("Hat command failed"),
                _("The server returned an invalid command state."));
            return;
        }
        if (action != "prev" && command.form != null &&
                ((!) command.form).get_missing_required_fields().size > 0) {
            show_hats_result(parent_window, _("Hat command failed"),
                _("The required fields marked with * must be completed."));
            return;
        }
        DataForms.DataForm? submit_form = action == "prev" ? null :
            create_hats_submit_form(command.form);
        yield proceed_hats_form(stream_interactor, account, room_jid,
            parent_window, dialog, command, (!) action, submit_form);
    }

    private static async void proceed_hats_form(
            StreamInteractor stream_interactor, Account account, Jid room_jid,
            Gtk.Window? parent_window, Adw.Dialog dialog,
            Xep.AdHocCommands.Command command, string action,
            DataForms.DataForm? submit_form) {
        HatsCommandDialogState? dialog_state =
            dialog.get_data<HatsCommandDialogState>("dinox-hats-session");
        if (dialog_state == null || ((!) dialog_state).finished) {
            return;
        }
        var management_state = command.get_data<HatsManagementDialogState>("dinox-hats-management");
        if (management_state != null && management_state.closed) {
            abort_hats_dialog_session(stream_interactor, account, room_jid, dialog, command);
            return;
        }
        if (!can_manage_hats_now(stream_interactor, account, room_jid,
                ((!) dialog_state).context)) {
            abort_hats_dialog_session(stream_interactor, account,
                room_jid, dialog, command);
            show_hats_result(parent_window, _("Hat command failed"),
                _("The room action is not permitted for the current user state."));
            return;
        }
        XmppStream? stream = ((!) dialog_state).stream;
        if (stream == null || command.node == null ||
                command.sessionid == null ||
                (action != "next" && action != "prev" &&
                    action != "complete") ||
                (command.actions.size > 0 &&
                    !command.actions.contains(action))) {
            abort_hats_dialog_session(stream_interactor, account,
                room_jid, dialog, command);
            show_hats_result(parent_window, _("Hat command failed"),
                _("The server returned an invalid command state."));
            return;
        }

        if (((!) dialog_state).busy) return;
        if (((!) dialog_state).command != command) {
            abort_hats_dialog_session(stream_interactor, account, room_jid,
                dialog, command);
            show_hats_result(parent_window, _("Hat command failed"),
                _("The server returned an invalid command state."));
            return;
        }
        if (((!) dialog_state).stream != stream) {
            abort_hats_dialog_session(stream_interactor, account, room_jid,
                dialog, command);
            show_hats_result(parent_window, _("Hat command failed"),
                _("The room action is not permitted for the current user state."));
            return;
        }
        ((!) dialog_state).busy = true;
        if (dialog.child != null) ((!) dialog.child).sensitive = false;
        dialog.can_close = false;
        Xep.AdHocCommands.Module module = ((!) stream).get_module<
            Xep.AdHocCommands.Module>(Xep.AdHocCommands.Module.IDENTITY);
        Xep.AdHocCommands.Command? result = yield module.proceed((!) stream,
            room_jid.bare_jid, (!) command.node, (!) command.sessionid,
            action, submit_form);
        if (management_state != null && management_state.closed) {
            if (result != null && result.status == Xep.AdHocCommands.Command.Status.EXECUTING) {
                cancel_hats_session.begin(stream_interactor, account, room_jid, result, stream);
            }
            finish_hats_dialog_session(dialog);
            dialog.can_close = true;
            dialog.close();
            return;
        }
        if (result == null) {
            if (stream_interactor.get_stream(account) != stream ||
                    !can_manage_hats_now(stream_interactor, account,
                        room_jid, ((!) dialog_state).context)) {
                cancel_hats_session.begin(stream_interactor, account,
                    room_jid, command, (!) stream);
                finish_hats_dialog_session(dialog);
                dialog.can_close = true;
                dialog.close();
                show_hats_result(parent_window, _("Hat command failed"),
                    _("The room action is not permitted for the current user state."));
                return;
            }
            ((!) dialog_state).busy = false;
            if (dialog.child != null) ((!) dialog.child).sensitive = true;
            dialog.can_close = true;
            show_hats_result(parent_window, _("Hat command failed"),
                _("The server rejected the hats command."));
            return;
        }

        if (stream_interactor.get_stream(account) != stream ||
                !can_manage_hats_now(stream_interactor, account, room_jid,
                    ((!) dialog_state).context)) {
            if (((!) result).status ==
                    Xep.AdHocCommands.Command.Status.EXECUTING) {
                cancel_hats_session.begin(stream_interactor, account,
                    room_jid, (!) result, (!) stream);
            }
            finish_hats_dialog_session(dialog);
            dialog.can_close = true;
            dialog.close();
            show_hats_result(parent_window, _("Hat command failed"),
                _("The room action is not permitted for the current user state."));
            return;
        }

        if (((!) result).has_error_note()) {
            if (((!) result).status ==
                    Xep.AdHocCommands.Command.Status.EXECUTING) {
                cancel_hats_session.begin(stream_interactor, account,
                    room_jid, (!) result, (!) stream);
            }
            finish_hats_dialog_session(dialog);
            dialog.can_close = true;
            dialog.close();
            show_hats_result(parent_window, _("Hat command failed"),
                ((!) result).get_error_note_text() ??
                    _("The server rejected the hats command."));
            return;
        }
        if (((!) result).status ==
                Xep.AdHocCommands.Command.Status.CANCELED) {
            finish_hats_dialog_session(dialog);
            dialog.can_close = true;
            dialog.close();
            show_hats_result(parent_window, _("Hat command failed"),
                _("The hats command was canceled."));
            return;
        }
        if (((!) result).status ==
                Xep.AdHocCommands.Command.Status.EXECUTING) {
            if (((!) result).form == null) {
                cancel_hats_session.begin(stream_interactor, account,
                    room_jid, (!) result, (!) stream);
                finish_hats_dialog_session(dialog);
                dialog.can_close = true;
                dialog.close();
                show_hats_result(parent_window, _("Hat command failed"),
                    _("The server returned an invalid command state."));
                return;
            }
            ((!) result).set_data<MucManager.MucOwnerMutationContext>(
                "dinox-hats-room-context", ((!) dialog_state).context);
            HatChoice? edit = command.get_data<HatChoice>("dinox-hats-edit");
            if (edit != null) ((!) result).set_data<HatChoice>("dinox-hats-edit", edit);
            if (management_state != null) result.set_data<HatsManagementDialogState>(
                "dinox-hats-management", management_state);
            finish_hats_dialog_session(dialog);
            dialog.can_close = true;
            dialog.close();
            show_hats_form_dialog(stream_interactor, account, room_jid,
                parent_window, (!) result, null, null, false);
            return;
        }

        finish_hats_dialog_session(dialog);
        dialog.can_close = true;
        dialog.close();
        if (is_hats_mutation_node(command.node)) {
            refresh_hats_after_mutation(stream_interactor, account, room_jid, command);
        } else {
            show_hats_result(parent_window, _("Hat command completed"),
                _("The hats command completed successfully."));
        }
    }

    private static void refresh_hats_after_mutation(StreamInteractor stream_interactor,
            Account account, Jid room_jid, Xep.AdHocCommands.Command command) {
        stream_interactor.get_module<MucManager>(MucManager.IDENTITY)
            .request_room_occupant_presence_resync(account, room_jid);
        var management_state = command.get_data<HatsManagementDialogState>("dinox-hats-management");
        if (management_state == null || management_state.closed) return;
        populate_hats_management.begin(stream_interactor, account, room_jid, management_state);
        var feedback = management_state.feedback.get() as Adw.ToastOverlay;
        if (feedback != null && command.get_data<HatChoice>("dinox-hats-edit") != null) {
            feedback.add_toast(new Adw.Toast(_("Hat updated.")));
        }
    }

    private static bool is_hats_mutation_node(string? node) {
        return node == "urn:xmpp:hats:commands:create" ||
            node == "urn:xmpp:hats:commands:assign" ||
            node == "urn:xmpp:hats:commands:unassign" ||
            node == "urn:xmpp:hats:commands:destroy";
    }

    private static string? get_hats_submit_action(
            Xep.AdHocCommands.Command command) {
        if (command.actions.size == 0) return "complete";
        string action = command.execute_action ?? "next";
        if (action != "next" && action != "prev" &&
                action != "complete") return null;
        return command.actions.contains(action) ? action : null;
    }

    private static void arm_hats_session_cancel(
            StreamInteractor stream_interactor, Account account, Jid room_jid,
            Adw.Dialog dialog, Xep.AdHocCommands.Command command) {
        MucManager.MucOwnerMutationContext? context =
            command.get_data<MucManager.MucOwnerMutationContext>(
                "dinox-hats-room-context");
        if (context == null) return;
        var state = new HatsCommandDialogState(command, (!) context);
        dialog.set_data<HatsCommandDialogState>("dinox-hats-session", state);
        var management_state = command.get_data<HatsManagementDialogState>("dinox-hats-management");
        WeakRef dialog_ref = WeakRef(dialog);
        if (management_state != null) management_state.action_dialog = WeakRef(dialog);
        dialog.closed.connect(() => {
            // A continuation may already have opened the next form while the
            // previous dialog finishes its close animation.
            if (management_state != null && management_state.action_dialog.get() == dialog_ref.get()) {
                management_state.action_dialog = WeakRef(null);
            }
            if (state.finished) return;
            state.finished = true;
            cancel_hats_session.begin(stream_interactor, account, room_jid,
                state.command, state.stream);
        });
    }

    private static void finish_hats_dialog_session(Adw.Dialog dialog) {
        HatsCommandDialogState? state =
            dialog.get_data<HatsCommandDialogState>("dinox-hats-session");
        if (state != null) {
            ((!) state).finished = true;
            ((!) state).busy = false;
        }
    }

    private static void abort_hats_dialog_session(
            StreamInteractor stream_interactor, Account account, Jid room_jid,
            Adw.Dialog dialog, Xep.AdHocCommands.Command command) {
        HatsCommandDialogState? state =
            dialog.get_data<HatsCommandDialogState>("dinox-hats-session");
        if (state != null && !((!) state).finished) {
            ((!) state).finished = true;
            ((!) state).busy = false;
            cancel_hats_session.begin(stream_interactor, account, room_jid,
                command, ((!) state).stream);
        }
        finish_hats_dialog_session(dialog);
        dialog.can_close = true;
        dialog.close();
    }

    private static async bool cancel_hats_session(
            StreamInteractor stream_interactor, Account account, Jid room_jid,
            Xep.AdHocCommands.Command command,
            XmppStream? expected_stream = null) {
        if (command.node == null || command.sessionid == null ||
                command.status != Xep.AdHocCommands.Command.Status.EXECUTING) {
            return true;
        }
        XmppStream? stream = expected_stream ??
            stream_interactor.get_stream(account);
        if (stream == null) return false;
        Xep.AdHocCommands.Module module = ((!) stream).get_module<
            Xep.AdHocCommands.Module>(Xep.AdHocCommands.Module.IDENTITY);
        return yield module.cancel((!) stream, room_jid.bare_jid,
            (!) command.node, (!) command.sessionid);
    }

    private static void show_hats_result(Gtk.Window? parent_window, string title, string body) {
        var alert = new Adw.AlertDialog(title, body);
        alert.add_response("ok", _("OK"));
        alert.default_response = "ok";
        alert.close_response = "ok";
        alert.present(parent_window);
    }

    private static string get_hats_command_title(string? node) {
        switch (node) {
            case "urn:xmpp:hats:commands:create":
                return _("Create Hat");
            case "urn:xmpp:hats:commands:assign":
                return _("Assign Hat");
            case "urn:xmpp:hats:commands:unassign":
                return _("Remove Hat Assignment");
            case "urn:xmpp:hats:commands:destroy":
                return _("Delete Hat from Room");
            default:
                return _("Manage Hats");
        }
    }

    private class HatsCommandDialogState : Object {
        public Xep.AdHocCommands.Command command { get; private set; }
        public XmppStream? stream { get; private set; }
        public MucManager.MucOwnerMutationContext context { get; private set; }
        public bool finished { get; set; default = false; }
        public bool busy { get; set; default = false; }

        public HatsCommandDialogState(Xep.AdHocCommands.Command command,
                MucManager.MucOwnerMutationContext context) {
            this.command = command;
            this.context = context;
            this.stream = context.stream;
        }
    }

    private class HatsManagementDialogState : Object {
        public MucManager.MucOwnerMutationContext context { get; private set; }
        public bool closed { get; set; default = false; }
        public bool command_started { get; set; default = false; }
        public bool loading { get; set; default = false; }
        public Gee.Set<string> available_nodes = new HashSet<string>();
        public WeakRef page = WeakRef(null);
        public WeakRef feedback = WeakRef(null);
        public WeakRef action_dialog = WeakRef(null);

        public HatsManagementDialogState(
                MucManager.MucOwnerMutationContext context) {
            this.context = context;
        }
    }

    private static void update_assign_user_choices(StreamInteractor stream_interactor, Account account, Gee.List<Jid> occupants, Gee.List<AssignedHatChoice>? assigned_hats, string selected_hat_uri, Adw.ComboRow user_row, Gee.List<string> real_jids) {
        real_jids.clear();
        var user_model = new Gtk.StringList(null);
        var seen = new HashSet<string>();

        foreach (Jid occupant in occupants) {
            Jid? real_jid = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_real_jid(occupant, account);
            if (real_jid == null) continue;
            string bare_jid = real_jid.bare_jid.to_string();
            if (!seen.add(bare_jid) || has_hat_assignment(assigned_hats, bare_jid, selected_hat_uri)) continue;

            real_jids.add(bare_jid);
            user_model.append("%s (%s)".printf(occupant.resourcepart ?? real_jid.localpart, bare_jid));
        }

        if (real_jids.size == 0) {
            user_model.append(_("No eligible participants. Enter an XMPP address below."));
        }
        user_row.model = user_model;
        user_row.selected = 0;
        user_row.sensitive = real_jids.size > 0;
    }

    private static void update_remove_assignment_choices(Gee.List<AssignedHatChoice> assigned_hats, string selected_hat_uri, Adw.ComboRow assignment_row, Gee.List<AssignedHatChoice> visible_assignments) {
        visible_assignments.clear();
        var assignment_model = new Gtk.StringList(null);

        foreach (AssignedHatChoice assignment in assigned_hats) {
            if (assignment.uri != selected_hat_uri) continue;
            visible_assignments.add(assignment);
            assignment_model.append(assignment.jid);
        }

        if (visible_assignments.size == 0) {
            assignment_model.append(_("No user has this hat assigned."));
        }
        assignment_row.model = assignment_model;
        assignment_row.selected = 0;
    }

    private static Gee.List<HatChoice> get_hats_from_assignments(Gee.List<AssignedHatChoice> assigned_hats) {
        var hats = new ArrayList<HatChoice>();
        foreach (AssignedHatChoice assignment in assigned_hats) {
            add_hat_choice(hats, assignment.uri, assignment.title, assignment.hue);
        }
        return hats;
    }

    private static bool has_hat_assignment(Gee.List<AssignedHatChoice>? assigned_hats, string jid, string hat_uri) {
        if (assigned_hats == null) return false;
        foreach (AssignedHatChoice assignment in assigned_hats) {
            if (assignment.jid == jid && assignment.uri == hat_uri) return true;
        }
        return false;
    }

    private static Gee.List<HatChoice> get_available_hats(DataForms.DataForm? command_form, Gee.List<HatChoice>? listed_hats) {
        return HatFormChoices.available(command_form,
            get_hats_from_form(command_form), listed_hats);
    }

    private static async Gee.List<HatChoice>? get_room_hats(
            StreamInteractor stream_interactor, Account account, Jid room_jid,
            XmppStream? expected_stream = null,
            MucManager.MucOwnerMutationContext? expected_context = null) {
        XmppStream? stream = expected_stream ??
            stream_interactor.get_stream(account);
        if (stream == null || stream_interactor.get_stream(account) != stream ||
                !can_manage_hats_now(stream_interactor, account, room_jid,
                    expected_context)) {
            return null;
        }
        Xep.AdHocCommands.Module module = ((!) stream).get_module<
            Xep.AdHocCommands.Module>(Xep.AdHocCommands.Module.IDENTITY);
        Xep.AdHocCommands.Command? command = yield module.execute((!) stream,
            room_jid.bare_jid, "urn:xmpp:hats:commands:list");
        if (command == null) return null;
        if (stream_interactor.get_stream(account) != stream ||
                !can_manage_hats_now(stream_interactor, account, room_jid,
                    expected_context) ||
                !((!) command).completed_successfully() ||
                ((!) command).form == null) {
            if (((!) command).status ==
                    Xep.AdHocCommands.Command.Status.EXECUTING) {
                yield cancel_hats_session(stream_interactor, account,
                    room_jid, (!) command, (!) stream);
            }
            return null;
        }
        return get_hats_from_form(((!) command).form);
    }

    private static async Gee.List<AssignedHatChoice>?
            get_assigned_room_hats(StreamInteractor stream_interactor,
            Account account, Jid room_jid,
            XmppStream? expected_stream = null,
            MucManager.MucOwnerMutationContext? expected_context = null) {
        XmppStream? stream = expected_stream ??
            stream_interactor.get_stream(account);
        if (stream == null || stream_interactor.get_stream(account) != stream ||
                !can_manage_hats_now(stream_interactor, account, room_jid,
                    expected_context)) {
            return null;
        }
        Xep.AdHocCommands.Module module = ((!) stream).get_module<
            Xep.AdHocCommands.Module>(Xep.AdHocCommands.Module.IDENTITY);
        Xep.AdHocCommands.Command? command = yield module.execute((!) stream,
            room_jid.bare_jid,
            "urn:xmpp:hats:commands:list-assigned");
        if (command == null) return null;
        if (stream_interactor.get_stream(account) != stream ||
                !can_manage_hats_now(stream_interactor, account, room_jid,
                    expected_context) ||
                !((!) command).completed_successfully() ||
                ((!) command).form == null) {
            if (((!) command).status ==
                    Xep.AdHocCommands.Command.Status.EXECUTING) {
                yield cancel_hats_session(stream_interactor, account,
                    room_jid, (!) command, (!) stream);
            }
            return null;
        }
        return get_assigned_hats_from_form(((!) command).form);
    }

    private static Gee.List<AssignedHatChoice> get_assigned_hats_from_form(DataForms.DataForm? form) {
        var assignments = new ArrayList<AssignedHatChoice>();
        if (form == null) return assignments;

        foreach (Gee.List<DataForms.DataForm.Field> item in form.items) {
            string? jid = null;
            string? uri = null;
            string? title = null;
            string? hue = null;
            foreach (DataForms.DataForm.Field field in item) {
                if (is_hat_jid_field(field.var)) {
                    jid = field.get_value_string();
                } else if (is_hat_uri_field(field.var)) {
                    uri = field.get_value_string();
                } else if (field.var == "hats#title" || field.var == "hat_title") {
                    title = field.get_value_string();
                } else if (field.var == "hats#hue") {
                    hue = field.get_value_string();
                }
            }
            add_assigned_hat_choice(assignments, jid, uri, title, hue);
        }

        return assignments;
    }

    private static Gee.List<HatChoice> get_hats_from_form(DataForms.DataForm? form) {
        var hats = new ArrayList<HatChoice>();
        if (form == null) return hats;

        foreach (Gee.List<DataForms.DataForm.Field> item in form.items) {
            string? uri = null;
            string? title = null;
            string? hue = null;
            foreach (DataForms.DataForm.Field field in item) {
                if (is_hat_uri_field(field.var)) {
                    uri = field.get_value_string();
                } else if (field.var == "hats#title") {
                    title = field.get_value_string();
                } else if (field.var == "hats#hue") {
                    hue = field.get_value_string();
                }
            }
            add_hat_choice(hats, uri, title, hue);
        }
        if (hats.size > 0) return hats;

        foreach (DataForms.DataForm.Field field in form.fields) {
            if (!is_hat_uri_field(field.var)) continue;
            var list_field = field as DataForms.DataForm.ListSingleField;
            if (list_field == null) continue;

            foreach (DataForms.DataForm.Option option in list_field.options) {
                add_hat_choice(hats, option.value, option.label);
            }
        }
        return hats;
    }

    private static bool is_hat_uri_field(string? field_var) {
        return field_var == "hats#uri" || field_var == "hat" || field_var == "hat_uri";
    }

    private static bool is_hat_jid_field(string? field_var) {
        return field_var == "hats#jid" || field_var == "jid";
    }

    private static void add_hat_choice(Gee.List<HatChoice> hats, string? uri, string? title, string? hue = null) {
        if (uri == null || uri == "") return;
        foreach (HatChoice existing in hats) {
            if (existing.uri == uri) return;
        }
        hats.add(new HatChoice() {
            uri = uri,
            title = title != null && title != "" ? title : uri,
            hue = HatFormChoices.parse_hue(hue) != null ? hue : null
        });
    }

    private static void add_assigned_hat_choice(Gee.List<AssignedHatChoice> assignments, string? jid, string? uri, string? title, string? hue = null) {
        if (jid == null || jid == "" || uri == null || uri == "") return;
        foreach (AssignedHatChoice existing in assignments) {
            if (existing.jid == jid && existing.uri == uri) return;
        }
        assignments.add(new AssignedHatChoice() {
            jid = jid,
            uri = uri,
            title = title != null && title != "" ? title : uri,
            hue = HatFormChoices.parse_hue(hue) != null ? hue : null
        });
    }

    private static uint get_initial_hat_selection(DataForms.DataForm? form, Gee.List<HatChoice> hats) {
        if (form != null) foreach (var field in form.fields) {
            if (!is_hat_uri_field(field.var)) continue;
            for (int i = 0; i < hats.size; i++) {
                if (hats[i].uri == field.get_value_string()) return (uint) i;
            }
        }
        return 0;
    }

    private static string? get_hat_jid_form_value(DataForms.DataForm? form) {
        if (form != null) foreach (var field in form.fields) {
            if (is_hat_jid_field(field.var)) return field.get_value_string();
        }
        return null;
    }

    private static void set_hat_jid_form_value(DataForms.DataForm? form, string value) {
        if (set_hats_form_value_if_present(form, "hats#jid", value)) return;
        if (set_hats_form_value_if_present(form, "jid", value)) return;
        add_hats_form_value(form, "hats#jid", value);
    }

    private static void set_hat_uri_form_value(DataForms.DataForm? form, string value) {
        if (set_hats_form_value_if_present(form, "hat", value)) return;
        if (set_hats_form_value_if_present(form, "hats#uri", value)) return;
        if (set_hats_form_value_if_present(form, "hat_uri", value)) return;
        add_hats_form_value(form, "hats#uri", value);
    }

    private static void set_hats_form_value(DataForms.DataForm? form, string field_var, string value) {
        if (set_hats_form_value_if_present(form, field_var, value)) return;
        add_hats_form_value(form, field_var, value);
    }

    private static bool set_hats_form_value_if_present(DataForms.DataForm? form, string field_var, string value) {
        if (form == null) return false;
        foreach (DataForms.DataForm.Field field in form.fields) {
            if (field.var == field_var) {
                field.set_value_string(value);
                return true;
            }
        }
        return false;
    }

    private static DataForms.DataForm? create_hats_submit_form(DataForms.DataForm? form) {
        if (form == null) return null;

        var submit_form = new DataForms.DataForm("submit");
        if (((!) form).form_type != null) {
            add_hats_typed_form_value(submit_form, "FORM_TYPE",
                (!) ((!) form).form_type, "hidden");
        }

        // XEP-0004 command forms are server-defined. Preserve every named
        // field and all values, including opaque hidden continuation tokens
        // and extension fields that DinoX does not render itself.
        foreach (DataForms.DataForm.Field field in form.fields) {
            if (field.var == null || field.var == "FORM_TYPE") continue;
            if (field.var == "hats#hue" && !field.required &&
                    field.get_value_string() == "") continue;
            var submit_field = new DataForms.DataForm.Field();
            submit_field.var = (!) field.var;
            string? field_type = field.node.get_attribute("type",
                DataForms.NS_URI);
            if (field_type != null) {
                submit_field.node.put_attribute("type", (!) field_type);
            }
            submit_field.set_values(field.get_values());
            submit_form.add_field(submit_field);
        }

        return submit_form;
    }

    private static void add_hats_form_value(DataForms.DataForm? form, string field_var, string value) {
        add_hats_typed_form_value(form, field_var, value, null);
    }

    private static void add_hats_typed_form_value(DataForms.DataForm? form, string field_var, string value, string? type) {
        if (form == null) return;
        var field = new DataForms.DataForm.Field();
        field.var = field_var;
        if (type != null) field.node.put_attribute("type", type);
        field.set_value_string(value);
        form.add_field(field);
    }

    private static Gtk.Window? get_parent_window(Gtk.Widget? parent) {
        if (parent != null) {
            Gtk.Window? window = parent.get_root() as Gtk.Window;
            if (window != null) return window;
        }
        var app = GLib.Application.get_default() as Gtk.Application;
        return app != null ? app.active_window : null;
    }
}
