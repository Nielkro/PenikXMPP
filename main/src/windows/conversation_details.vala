/*
 * Copyright (C) 2025 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Dino.Entities;
using Xmpp;
using Xmpp.Xep;
using Gee;
using Gtk;

namespace Dino.Ui.ConversationDetails {

    [GtkTemplate (ui = "/im/dinox/dinox/conversation_details.ui")]
    public class Dialog : Adw.Dialog {
        public signal void room_configuration_visible();

        [GtkChild] public unowned Stack stack;
        [GtkChild] public unowned Box about_box;
        [GtkChild] public unowned Box primary_actions;
        [GtkChild] public unowned Box contact_actions;
        [GtkChild] public unowned StackSwitcher tabs_switcher;
        [GtkChild] public unowned ScrolledWindow tabs_scroller;
        [GtkChild] public unowned Scrollbar tabs_scrollbar;
        [GtkChild] public unowned Button pin_button;
        [GtkChild] public unowned Adw.ButtonContent pin_button_content;
        [GtkChild] public unowned MenuButton block_button;
        [GtkChild] public unowned Adw.ButtonContent block_button_content;
        [GtkChild] public unowned Button remove_contact_button;
        [GtkChild] public unowned Button notification_button_toggle;
        [GtkChild] public unowned Adw.ButtonContent notification_button_toggle_content;
        [GtkChild] public unowned MenuButton notification_button_menu;
        [GtkChild] public unowned Adw.ButtonContent notification_button_menu_content;
        [GtkChild] public unowned Adw.SplitButton notification_button_split;
        [GtkChild] public unowned Adw.ButtonContent notification_button_split_content;

        [GtkChild] public unowned ViewModel.ConversationDetails model { get; }

        public StackPage? encryption_stack_page = null;
        public Widget? encryption_widget = null;
        public Box? encryption_box = null;

        public StackPage? settings_stack_page = null;
        public Widget? settings_widget = null;
        public Box? settings_box = null;

        public StackPage? room_config_stack_page = null;
        public Widget? room_config_widget = null;
        public Box? room_config_box = null;

        public StackPage? room_administration_stack_page = null;
        public Widget? room_administration_widget = null;
        public Box? room_administration_box = null;

        public StackPage? member_stack_page = null;
        public Box? member_box = null;

        private bool dialog_closed = false;
        private uint about_tab_idle_id = 0;
        private uint preferences_idle_id = 0;
        private bool settings_dirty = false;
        private bool administration_dirty = false;
        private ulong selected_tab_after_paint_id = 0;
        private Gdk.FrameClock? selected_tab_frame_clock = null;
        private bool selected_tab_reveal_pending = false;
        private bool selected_tab_reveal_explicit = false;
        private ulong tabs_adjustment_handler_id = 0;

        private SimpleAction block_action = new SimpleAction.stateful("block", VariantType.INT32, new Variant.int32(ViewModel.ConversationDetails.BlockState.UNBLOCK));

        class construct {
            install_action("notification.on", null, (widget, action_name) => { ((Dialog) widget).model.notification_changed(ViewModel.ConversationDetails.NotificationSetting.ON); } );
            install_action("notification.off", null, (widget, action_name) => { ((Dialog) widget).model.notification_changed(ViewModel.ConversationDetails.NotificationSetting.OFF); } );
            install_action("notification.highlight", null, (widget, action_name) => { ((Dialog) widget).model.notification_changed(ViewModel.ConversationDetails.NotificationSetting.HIGHLIGHT); } );
            install_action("notification.default", null, (widget, action_name) => { ((Dialog) widget).model.notification_changed(ViewModel.ConversationDetails.NotificationSetting.DEFAULT); } );
            install_action("contact.remove", null, (widget, action_name) => { ((Dialog) widget).on_remove_contact(); } );
        }

        public override void unmap() {
            // Release any embedded GtkText before GTK unmaps the dialog
            // subtree. GTK 4.14 otherwise keeps its focus state alive too
            // long and reports a missing focus-out event.
            Util.clear_focus_before_detach(this);
            base.unmap();
        }

        public override void map() {
            flush_preference_pages();
            base.map();
            schedule_selected_tab_reveal();
        }

        public override void dispose() {
            cleanup_layout_sources();
            base.dispose();
        }

        private void cleanup_layout_sources() {
            dialog_closed = true;
            if (tabs_adjustment_handler_id != 0) {
                SignalHandler.disconnect(tabs_scroller.hadjustment,
                    tabs_adjustment_handler_id);
                tabs_adjustment_handler_id = 0;
            }
            if (about_tab_idle_id != 0) {
                Source.remove(about_tab_idle_id);
                about_tab_idle_id = 0;
            }
            if (preferences_idle_id != 0) {
                Source.remove(preferences_idle_id);
                preferences_idle_id = 0;
            }
            cancel_selected_tab_reveal();
            selected_tab_reveal_pending = false;
            selected_tab_reveal_explicit = false;
        }

        public void select_page(string name) {
            if (dialog_closed) return;
            flush_preference_pages();
            var child = stack.get_child_by_name(name);
            if (child == null || !stack.get_page(child).visible) return;
            stack.visible_child_name = name;
            selected_tab_reveal_pending = true;
            selected_tab_reveal_explicit = true;
            schedule_selected_tab_reveal();
        }

        private void schedule_selected_tab_reveal() {
            if (dialog_closed || !selected_tab_reveal_pending ||
                    !get_mapped() || selected_tab_after_paint_id != 0) return;
            var clock = get_frame_clock();
            if (clock == null) return;
            selected_tab_frame_clock = clock;
            selected_tab_after_paint_id = add_selected_tab_after_paint(this, clock);
            clock.request_phase(Gdk.FrameClockPhase.AFTER_PAINT);
        }

        private void cancel_selected_tab_reveal() {
            if (selected_tab_frame_clock != null && selected_tab_after_paint_id != 0) {
                SignalHandler.disconnect(selected_tab_frame_clock, selected_tab_after_paint_id);
            }
            selected_tab_after_paint_id = 0;
            selected_tab_frame_clock = null;
        }

        private static ulong add_selected_tab_after_paint(Dialog target, Gdk.FrameClock clock) {
            WeakRef dialog_weak = WeakRef(target);
            return clock.after_paint.connect(() => {
                var dialog = dialog_weak.get() as Dialog;
                if (dialog == null) return;
                // Run once after GTK has allocated the current switcher, and
                // disconnect before native scrolling requests another frame.
                dialog.cancel_selected_tab_reveal();
                if (dialog.dialog_closed || !dialog.get_mapped()) return;
                Widget? focus = dialog.focus_widget;
                if (!dialog.selected_tab_reveal_explicit && focus != null &&
                        focus != dialog.tabs_switcher && !focus.is_ancestor(dialog.tabs_switcher)) {
                    // A later input focus wins over a tab-reorder refresh.
                    dialog.selected_tab_reveal_pending = false;
                    return;
                }
                for (Widget? child = dialog.tabs_switcher.get_first_child();
                        child != null; child = child.get_next_sibling()) {
                    var button = child as ToggleButton;
                    if (button != null && button.active) {
                        // GtkViewport's native focus scrolling reveals the
                        // complete selected tab, independently of its label.
                        if (button.grab_focus()) {
#if GTK_4_12
                            var viewport = dialog.tabs_scroller.child as Viewport;
                            if (viewport != null) viewport.scroll_to(button, null);
#endif
                            dialog.selected_tab_reveal_pending = false;
                            dialog.selected_tab_reveal_explicit = false;
                        }
                        break;
                    }
                }
            });
        }
        
        private void on_remove_contact() {
            if (model.removing_contact) return;
            var dialog = new Adw.AlertDialog(
                _("Remove contact?"),
                _("This contact will be removed from your contact list and all conversation history will be permanently deleted.")
            );
            dialog.add_response("cancel", _("Cancel"));
            dialog.add_response("remove", _("Remove"));
            dialog.set_response_appearance("remove", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.default_response = "cancel";
            dialog.close_response = "cancel";
            
            dialog.response.connect((response) => {
                if (response == "remove") {
                    model.remove_contact();
                }
            });
            
            dialog.present(this);
        }

        construct {
            // Keep tab identity and rooting stable. Reordering by removing and
            // readding pages tears down plugin lifecycle bindings, even when
            // only an unrelated settings row has changed.
            settings_stack_page = create_dynamic_page("settings", _("Settings"), out settings_box, out settings_widget);
            room_administration_stack_page = create_dynamic_page("room_administration", _("Administration"), out room_administration_box, out room_administration_widget);
            room_config_stack_page = create_dynamic_page("room_config", _("Room Configuration"), out room_config_box, out room_config_widget);
            encryption_stack_page = create_dynamic_page("encryption", _("Encryption"), out encryption_box, out encryption_widget);
            // GTK 4.14 does not reserve an automatic horizontal scrollbar's
            // height with a NEVER vertical policy. An external native bar
            // keeps the complete tab text visible without fixing font sizes.
            tabs_scrollbar.adjustment = tabs_scroller.hadjustment;
            WeakRef dialog_weak = WeakRef(this);
            model.bind_property("removing-contact", remove_contact_button, "sensitive",
                BindingFlags.SYNC_CREATE | BindingFlags.INVERT_BOOLEAN);
            model.remove_contact_finished.connect((jid, result) => {
                var current = dialog_weak.get() as Dialog;
                if (current == null || current.dialog_closed || current.get_root() == null) return;
                if (result == RosterRemoveResult.SUCCESS) current.close();
                else Util.show_remove_contact_failure(current, jid, result);
            });
            tabs_adjustment_handler_id = tabs_scroller.hadjustment.changed.connect(() => {
                var dialog = dialog_weak.get() as Dialog;
                if (dialog != null) dialog.update_tabs_scrollbar();
            });
            pin_button.clicked.connect(() => { model.pin_changed(); });
            notification_button_toggle.clicked.connect(() => { model.notification_flipped(); });
            notification_button_split.clicked.connect(() => { model.notification_flipped(); });

            model.notify["pinned"].connect(update_pinned_button);
            model.notify["blocked"].connect(update_blocked_button);
            model.notify["notification"].connect(update_notification_button);
            model.notify["notification"].connect(update_notification_button_state);
            model.notify["notification-options"].connect(update_notification_button_visibility);
            model.notify["notification-is-default"].connect(update_notification_button_visibility);

            model.about_rows.items_changed.connect(schedule_populate_about_tab);
            model.vcard_rows.items_changed.connect(schedule_populate_about_tab);
            model.settings_rows.items_changed.connect(() => {
                if (dialog_closed) return;
                if (model.settings_in_separate_tab) {
                    settings_dirty = true;
                    settings_stack_page.visible = model.settings_rows.get_n_items() > 0;
                    schedule_preference_pages();
                } else {
                    schedule_populate_about_tab();
                }
            });
            model.room_administration_rows.items_changed.connect(() => {
                if (dialog_closed) return;
                administration_dirty = true;
                room_administration_stack_page.visible = model.room_administration_rows.get_n_items() > 0;
                schedule_preference_pages();
            });
            model.notify["room-configuration-rows"].connect(add_room_configuration_tab_element);
            stack.notify["visible-child"].connect(() => {
                if (!dialog_closed && room_config_widget != null && stack.visible_child == room_config_widget) {
                    room_configuration_visible();
                }
            });
            closed.connect(() => {
                cleanup_layout_sources();
            });

            model.members.items_changed.connect(() => {
                create_members();
            });
            create_members();

            // Create block action
            SimpleActionGroup block_action_group = new SimpleActionGroup();
            block_action = new SimpleAction.stateful("block", VariantType.INT32, new Variant.int32(0));
            block_action.activate.connect((parameter) => {
                block_action.set_state(parameter);
                model.block_changed((ViewModel.ConversationDetails.BlockState) parameter.get_int32());
            });
            block_action_group.add_action(block_action);
            this.insert_action_group("block", block_action_group);

            // Create contact action group
            SimpleActionGroup contact_action_group = new SimpleActionGroup();
            SimpleAction remove_action = new SimpleAction("remove", null);
            remove_action.activate.connect(() => {
                on_remove_contact();
            });
            contact_action_group.add_action(remove_action);
            this.insert_action_group("contact", contact_action_group);

            // Create block menu model
            Menu block_menu_model = new Menu();
            string[] menu_labels = new string[] { _("Block user"), _("Block entire domain"), _("Unblock") };
            ViewModel.ConversationDetails.BlockState[] menu_states = new ViewModel.ConversationDetails.BlockState[] { ViewModel.ConversationDetails.BlockState.USER, ViewModel.ConversationDetails.BlockState.DOMAIN, ViewModel.ConversationDetails.BlockState.UNBLOCK };
            for (int i = 0; i < menu_labels.length; i++) {
                MenuItem item = new MenuItem(menu_labels[i], null);
                item.set_action_and_target_value("block.block", new Variant.int32(menu_states[i]));
                block_menu_model.append_item(item);
            }
            block_button.menu_model = block_menu_model;

            update_pinned_button();
            update_blocked_button();
            update_notification_button();
            update_notification_button_state();
            update_notification_button_visibility();
        }

        private void update_tabs_scrollbar() {
            if (dialog_closed) return;
            var adjustment = tabs_scroller.hadjustment;
            tabs_scrollbar.visible = adjustment.upper > adjustment.page_size + 0.5;
        }

        private void update_pinned_button() {
            pin_button_content.icon_name = "view-pin-symbolic";
            pin_button_content.label = model.pinned ? _("Pinned") : _("Pin");
            if (model.pinned) {
                pin_button.add_css_class("accent");
            } else {
                pin_button.remove_css_class("accent");
            }
        }

        private void update_blocked_button() {
            switch (model.blocked) {
                case USER:
                    block_button_content.label = _("Blocked");
                    block_button.add_css_class("error");
                    break;
                case DOMAIN:
                    block_button_content.label = _("Domain blocked");
                    block_button.add_css_class("error");
                    break;
                case UNBLOCK:
                    block_button_content.label = _("Block");
                    block_button.remove_css_class("error");
                    break;
            }

            block_action.set_state(new Variant.int32(model.blocked));
        }

        private void update_notification_button() {
            string icon_name = model.notification == OFF ?
                    "dino-bell-large-none-symbolic" : "dino-bell-large-symbolic";
            notification_button_toggle_content.icon_name = icon_name;
            notification_button_split_content.icon_name = icon_name;
            notification_button_menu_content.icon_name = icon_name;
        }

        private void update_notification_button_state() {
            switch (model.notification) {
                case ON:
                    notification_button_toggle_content.label = _("Mute");
                    notification_button_split_content.label = _("Mute");
                    notification_button_menu_content.label = _("Notifications enabled");
                    break;
                case HIGHLIGHT:
                    notification_button_menu_content.label = _("Notifications for mentions");
                    break;
                case OFF:
                    notification_button_toggle_content.label = _("Muted");
                    notification_button_split_content.label = _("Muted");
                    notification_button_menu_content.label = _("Notifications disabled");
                    break;
                case DEFAULT:
                    // Should not happen in this context or handled elsewhere
                    break;
            }
        }

        private void update_notification_button_visibility() {
            notification_button_toggle.visible = notification_button_menu.visible = notification_button_split.visible = false;

            if (model.notification_options == ON_OFF) {
                if (model.notification_is_default) {
                    notification_button_toggle.visible = true;
                } else {
                    notification_button_split.visible = true;
                }
            } else {
                notification_button_menu.visible = true;
            }
        }

        private void create_members() {
#if GTK_4_8 && (VALA_0_56_GREATER_5 || VALA_0_58)
            if (model.members_sorted.n_items == 0) return;
#else
            if (model.members_sorted.model.get_n_items() == 0) return;
#endif
            if (member_box != null && member_box.get_first_child() != null) return;

            var selection_model = new NoSelection(model.members_sorted);
            var item_factory = new BuilderListItemFactory.from_resource(null, "/im/dinox/dinox/muc_member_list_row.ui");
            var list_view = new ListView(selection_model, item_factory) { single_click_activate = true };
            list_view.add_css_class("card");
            list_view.activate.connect((position) => {
//                var widget = (Gtk.Widget) list_view.observe_children().get_item(position);
//                var name_label = widget.get_template_child(Type.OBJECT, "name-label");
//                print(widget.get_type().name());

//                var popover = new Popover();
//                popover.parent = widget;
//                popover.popup();


            });

            add_members_tab_element(list_view);
        }

        private void schedule_populate_about_tab() {
            if (dialog_closed || about_tab_idle_id != 0) return;
            about_tab_idle_id = Idle.add(() => {
                about_tab_idle_id = 0;
                populate_about_tab();
                return Source.REMOVE;
            });
        }

        private void populate_about_tab() {
            var widget = about_box.get_first_child();
            while (widget != null) {
                about_box.remove(widget);
                widget = about_box.get_first_child();
            }

            if (model.about_rows.get_n_items() > 0) {
                about_box.append(Util.rows_to_preference_group(model.about_rows, _("About")));
            }
            if (model.vcard_rows.get_n_items() > 0) {
                about_box.append(Util.rows_to_preference_group(model.vcard_rows, _("Profile")));
            }
            if (!model.settings_in_separate_tab && model.settings_rows.get_n_items() > 0) {
                about_box.append(Util.rows_to_preference_group(model.settings_rows, _("Settings")));
            }
            if (model.account_jid != null) {
                var account_label = new Label(_("via %s").printf(model.account_jid)) {
                    halign = Align.FILL, xalign = 0, hexpand = true,
                    ellipsize = Pango.EllipsizeMode.END, max_width_chars = 40,
                    tooltip_text = model.account_jid, margin_start = 14,
                    margin_top = 4
                };
                account_label.add_css_class("dim-label");
                about_box.append(account_label);
            }
        }

        private ScrolledWindow create_page_scroller(Widget content) {
            // Pages keep their controls and wrap at the available dialog width.
            // The separate tab scroller handles navigation overflow only.
            var scrolled = new ScrolledWindow() {
                vexpand = true, hscrollbar_policy = PolicyType.NEVER
            };
            var clamp = new Adw.Clamp();
            clamp.set_child(content);
            scrolled.set_child(clamp);
            return scrolled;
        }

        private StackPage create_dynamic_page(string name, string title,
                out Box box, out Widget widget) {
            box = new Box(Orientation.VERTICAL, 12) {
                margin_end = 12, margin_start = 12, margin_top = 18, margin_bottom = 40
            };
            widget = create_page_scroller(box);
            var page = stack.add_titled(widget, name, title);
            page.visible = false;
            return page;
        }

        private void schedule_preference_pages() {
            if (dialog_closed || preferences_idle_id != 0) return;
            preferences_idle_id = Idle.add(() => {
                preferences_idle_id = 0;
                flush_preference_pages();
                return Source.REMOVE;
            });
        }

        private void flush_preference_pages() {
            if (preferences_idle_id != 0) {
                Source.remove(preferences_idle_id);
                preferences_idle_id = 0;
            }
            if (dialog_closed) return;
            // Providers append rows separately. Build each page once per batch,
            // rather than recreating all preceding controls after every append.
            if (settings_dirty) {
                settings_dirty = false;
                add_settings_tab_element();
            }
            if (administration_dirty) {
                administration_dirty = false;
                add_room_administration_tab_element();
            }
        }

        private void clear_page(Box box) {
            var child = box.get_first_child();
            while (child != null) {
                Util.clear_focus_before_detach(child);
                box.remove(child);
                child = box.get_first_child();
            }
        }

        public void add_room_configuration_tab_element() {
            if (dialog_closed) return;
            clear_page(room_config_box);
            room_config_stack_page.visible = model.room_configuration_rows != null &&
                model.room_configuration_rows.get_n_items() > 0;
            if (!room_config_stack_page.visible) return;
            foreach (Adw.PreferencesGroup group in Util.rows_to_preference_window_split_at_text(model.room_configuration_rows)) {
                room_config_box.append(group);
            }
            if (stack.visible_child == room_config_widget) {
                room_configuration_visible();
            }
        }

        public void add_settings_tab_element() {
            if (dialog_closed) return;
            if (settings_box.get_first_child() != null) {
                Util.commit_preference_rows(model.settings_rows);
            }
            clear_page(settings_box);
            settings_stack_page.visible = model.settings_rows.get_n_items() > 0;
            if (!settings_stack_page.visible) return;
            foreach (var group in Util.rows_to_preference_groups_with_sections(
                    model.settings_rows, _("Settings"))) {
                settings_box.append(group);
            }
        }

        public void add_room_administration_tab_element() {
            if (dialog_closed) return;
            clear_page(room_administration_box);
            room_administration_stack_page.visible = model.room_administration_rows.get_n_items() > 0;
            if (!room_administration_stack_page.visible) return;
            room_administration_box.append(Util.rows_to_preference_group(model.room_administration_rows, _("Administration")));
        }

        public void add_encryption_tab_element(Adw.PreferencesGroup preferences_group) {
            if (dialog_closed) return;
            encryption_box.append(preferences_group);
            encryption_stack_page.visible = true;
        }

        public void add_members_tab_element(Widget widget) {
            if (member_stack_page == null) {
                member_box = new Box(Orientation.VERTICAL, 12) { margin_end = 12, margin_start = 12, margin_top = 18 };
                member_stack_page = stack.add_child(create_page_scroller(member_box));
                member_stack_page.title = _("Members");
                member_stack_page.name = "member";
            }
            member_box.append(widget);
        }
    }

    [GtkTemplate (ui = "/im/dinox/dinox/muc_member_list_row.ui")]
    public class Dino.Ui.ConversationDetails.MemberListItem : Gtk.Widget {

    }
}
