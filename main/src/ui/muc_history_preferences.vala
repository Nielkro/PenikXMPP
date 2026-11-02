/*
 * Copyright (C) 2025 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Dino.Entities;

namespace Dino.Ui.ConversationDetails {

    internal delegate Conversation? HistoryConversationProvider();

    internal class HistoryLoadPreferences : Object {
        public ViewModel.PreferencesRow.Toggle custom_period { get; private set; }
        public ViewModel.PreferencesRow.Number days { get; private set; }
        public ViewModel.PreferencesRow.Button load_now { get; private set; }

        private WeakRef context_weak;
        private HistoryConversationProvider? current_conversation;
        private Conversation? target;
        private Account? account;
        private MucManager? manager;
        private int conversation_id;
        private int account_id;
        private string account_jid;
        private string room_jid;
        private bool active = true;
        private bool invalidated = false;
        private bool updating = false;
        private ulong custom_handler;
        private ulong days_handler;
        private ulong load_handler;
        private ulong model_handler;
        private ulong target_handler;
        private ulong account_handler;

        public HistoryLoadPreferences(Conversation conversation, MucManager manager,
                Object context, owned HistoryConversationProvider current_conversation) {
            context_weak = WeakRef(context);
            this.current_conversation = (owned) current_conversation;
            this.target = conversation;
            this.account = conversation.account;
            this.manager = manager;
            conversation_id = conversation.id;
            account_id = conversation.account.id;
            account_jid = conversation.account.bare_jid.to_string();
            room_jid = conversation.counterpart.bare_jid.to_string();
            custom_period = new ViewModel.PreferencesRow.Toggle() {
                title = _("Set a custom period"),
                subtitle = _("When off, DinoX chooses the history period automatically for this group and account.")
            };
            days = new ViewModel.PreferencesRow.Number() {
                title = _("Days to load"),
                description = _("The server may retain less history. Cleared and expired messages remain excluded."),
                minimum = 1,
                maximum = 365,
                value = 30
            };
            load_now = new ViewModel.PreferencesRow.Button() {
                title = _("Load message history"),
                button_text = _("Load now")
            };
            refresh_from_target();
            connect_controls(this, context);
        }

        public void append_to(GLib.ListStore rows) {
            rows.append(new ViewModel.PreferencesRow.Section() {
                title = _("Load message history")
            });
            rows.append(custom_period);
            rows.append(days);
            rows.append(load_now);
        }

        public void attach_to_dialog(Adw.Dialog dialog) {
            dialog.set_data<HistoryLoadPreferences>("muc-history-load-preferences", this);
            connect_dialog_closed(dialog, this);
        }

        private static void connect_dialog_closed(Adw.Dialog dialog,
                HistoryLoadPreferences preferences) {
            WeakRef preferences_weak = WeakRef(preferences);
            dialog.closed.connect(() => {
                var current = preferences_weak.get() as HistoryLoadPreferences;
                if (current != null) current.close();
            });
        }

        private static void connect_controls(HistoryLoadPreferences preferences, Object context) {
            WeakRef preferences_weak = WeakRef(preferences);
            preferences.custom_handler = preferences.custom_period.notify["state"].connect(() => {
                var current = preferences_weak.get() as HistoryLoadPreferences;
                if (current != null) current.on_custom_period_changed();
            });
            preferences.days_handler = preferences.days.notify["value"].connect(() => {
                var current = preferences_weak.get() as HistoryLoadPreferences;
                if (current != null) current.on_days_changed();
            });
            preferences.load_handler = preferences.load_now.clicked.connect(() => {
                var current = preferences_weak.get() as HistoryLoadPreferences;
                if (current != null) current.request_load();
            });
            preferences.model_handler = context.notify["conversation"].connect(() => {
                var current = preferences_weak.get() as HistoryLoadPreferences;
                if (current != null && !current.is_current_target()) current.invalidate_controls();
            });
            preferences.target_handler = ((!) preferences.target).notify.connect((property) => {
                var current = preferences_weak.get() as HistoryLoadPreferences;
                if (current == null) return;
                if (!current.is_current_target()) current.invalidate_controls();
                else if (property.name == "muc-history-days") current.refresh_from_target();
            });
            preferences.account_handler = ((!) preferences.account).notify.connect(() => {
                var current = preferences_weak.get() as HistoryLoadPreferences;
                if (current != null && !current.is_current_target()) current.invalidate_controls();
            });
        }

        private bool is_current_target() {
            return active && !invalidated && current_conversation != null && target != null &&
                account != null && manager != null &&
                ((!) current_conversation)() == target &&
                ((!) target).type_ == Conversation.Type.GROUPCHAT &&
                ((!) target).id == conversation_id &&
                ((!) target).account == account &&
                ((!) account).id == account_id &&
                ((!) account).bare_jid.to_string() == account_jid &&
                ((!) target).counterpart.bare_jid.to_string() == room_jid;
        }

        private void refresh_from_target() {
            if (!is_current_target()) {
                invalidate_controls();
                return;
            }
            updating = true;
            int saved = ((!) target).muc_history_days;
            custom_period.state = saved > 0;
            if (saved > 0) days.value = int.max(1, int.min(365, saved));
            days.enabled = custom_period.state;
            load_now.description = _("The saved setting also applies when you next join this group.");
            updating = false;
        }

        private void invalidate_controls() {
            invalidated = true;
            custom_period.enabled = false;
            days.enabled = false;
            load_now.enabled = false;
            load_now.description = _("This group is no longer available for this account.");
        }

        private bool save_current_choice() {
            if (!is_current_target()) {
                invalidate_controls();
                return false;
            }
            int requested_days = custom_period.state ?
                int.max(1, int.min(365, days.value)) : 0;
            if (!((!) manager).set_muc_history_days((!) target, requested_days)) {
                invalidate_controls();
                return false;
            }
            return is_current_target();
        }

        private void on_custom_period_changed() {
            if (updating || !active) return;
            days.enabled = custom_period.state;
            save_current_choice();
        }

        private void on_days_changed() {
            if (updating || !active || !custom_period.state) return;
            save_current_choice();
        }

        private void request_load() {
            if (!is_current_target()) {
                invalidate_controls();
                return;
            }
            // Native update commits any still-edited text before reading the
            // bound integer or dispatching an archive request.
            days.commit();
            if (!save_current_choice()) return;
            switch (((!) manager).request_muc_history_refresh((!) target)) {
                case MucHistoryRefreshResult.QUEUED:
                    load_now.description = _("History load requested. Messages will appear as they are received.");
                    break;
                case MucHistoryRefreshResult.PENDING_JOIN:
                    load_now.description = _("Saved. History will be loaded when you next join this group.");
                    break;
                case MucHistoryRefreshResult.UNAVAILABLE:
                    load_now.description = _("Message history is not available for this group right now.");
                    break;
            }
        }

        public void close() {
            if (!active) return;
            active = false;
            custom_period.enabled = false;
            days.enabled = false;
            load_now.enabled = false;
            custom_period.disconnect(custom_handler);
            days.disconnect(days_handler);
            load_now.disconnect(load_handler);
            var context = context_weak.get();
            if (context != null) context.disconnect(model_handler);
            if (target != null) ((!) target).disconnect(target_handler);
            if (account != null) ((!) account).disconnect(account_handler);
            current_conversation = null;
            target = null;
            account = null;
            manager = null;
        }

        public override void dispose() {
            close();
            base.dispose();
        }
    }

}
