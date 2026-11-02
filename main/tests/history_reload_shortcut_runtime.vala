using Gtk;
using Dino.Entities;
using Xmpp;

namespace Dino.Ui.Test {

class HistoryReloadShortcutRuntimeTest : Gee.TestCase {
    public HistoryReloadShortcutRuntimeTest() {
        base("HistoryReloadShortcutRuntime");
        add_test("native_help_overlay_has_one_localized_CtrlShiftH_for_current_conversation", test_overlay);
        add_test("native_header_menu_exposes_current_scope_reload_for_only_CHAT_and_GROUPCHAT", test_menu);
    }

    private void test_overlay() {
        Window? overlay = null;
        try {
            var builder = new Builder();
            builder.translation_domain = "dino";
            builder.add_from_resource("/im/dinox/dinox/gtk/help-overlay.ui");
            overlay = builder.get_object("help_overlay") as Window;
            fail_if(overlay == null, "the production shortcuts resource must create a native window");
            if (overlay == null) return;
            int matches = 0;
            foreach (var object in builder.get_objects()) {
                // Use base GObject properties: the existing GTK shortcuts UI
                // also works with newer Windows GTK without newly compiling
                // against its deprecated shortcuts widget C API.
                if (object.get_type().name() != "GtkShortcutsShortcut") continue;
                string title, accelerator;
                object.get("title", out title, "accelerator", out accelerator);
                uint keyval;
                Gdk.ModifierType modifiers;
                bool parsed = accelerator_parse(accelerator, out keyval, out modifiers);
                if (!parsed || Gdk.keyval_to_lower(keyval) != Gdk.Key.h ||
                        modifiers != (Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.SHIFT_MASK)) continue;
                matches++;
                fail_if_not_eq_str(_("Load messages now"), title);
                string subtitle;
                object.get("subtitle", out subtitle);
                fail_if_not_eq_str(_("In the current chat or group"), subtitle);
                var widget = object as Widget;
                fail_if(widget == null, "the documented action must render a native shortcut widget");
                string? language = Environment.get_variable("LANGUAGE");
                if (Environment.get_variable("DINOX_UI_TEST_LOCALE_DIR") != null &&
                        language != null && language.has_prefix("de")) {
                    fail_if_not_eq_str("Nachrichten jetzt nachladen", title);
                    fail_if_not_eq_str("Im aktuellen Chat oder in der aktuellen Gruppe", subtitle);
                }
            }
            fail_if_not_eq_int(1, matches, "the current-conversation shortcut must be documented exactly once without collision");
            overlay.present();
            iterate_for(40);
            fail_if_not(overlay.get_mapped(), "native translated shortcuts window must map with accessibility enabled too");
        } catch (Error error) { fail_if_reached(error.message); }
        finally {
            if (overlay != null) { overlay.destroy(); overlay.dispose(); iterate_for(20); }
        }
    }

    private void test_menu() {
        Database? database = null;
        var window = new Adw.Window();
        try {
            string path = Path.build_filename(Environment.get_user_data_dir(), "history-menu-" + Uuid.string_random() + ".db");
            DirUtils.create_with_parents(Environment.get_user_data_dir(), 0700);
            database = new Database(path, "isolated history header menu");
            var interactor = new StreamInteractor.for_tests(database);
            var entry = new MenuEntry(interactor);
            var button = entry.get_widget(Plugins.WidgetType.GTK4) as MenuButton;
            fail_if(button == null);
            if (button == null) return;
            var action_group = new SimpleActionGroup();
            var reload = new SimpleAction("load-current-conversation-history", null);
            int requests = 0;
            reload.activate.connect(() => requests++);
            action_group.add_action(reload);
            window.insert_action_group("app", action_group);
            window.content = button;
            window.set_default_size(340, 200);
            window.present();
            var account = new Account(new Jid("first@example.test"), "fixture");
            foreach (var type in new Conversation.Type[] { Conversation.Type.CHAT, Conversation.Type.GROUPCHAT }) {
                entry.set_conversation(new Conversation(new Jid("same@conference.example.test"), account, type));
                iterate_for(30);
                var popover = button.popover as PopoverMenu;
                fail_if(popover == null, "production header must retain a native PopoverMenu");
                if (popover == null) continue;
                fail_if_not_eq_int(1, reload_items(popover.menu_model), "header action must appear once for1:1 and rooms");
                button.popup();
                iterate_for(30);
                fail_if_not(popover.get_mapped(), "native menu must be usable with the registered current-scope action");
                fail_if_not(button.activate_action("app.load-current-conversation-history", null));
                button.popdown(); iterate_for(30);
            }
            fail_if_not_eq_int(2, requests);
            entry.set_conversation(new Conversation(new Jid("same@conference.example.test/nick"), account, Conversation.Type.GROUPCHAT_PM));
            fail_if_not_eq_int(0, reload_items(((PopoverMenu) button.popover).menu_model), "MUC private-message sessions must not be routed to a room archive");
            entry.set_conversation(new Conversation(new Jid("device@mqtt.local"), account, Conversation.Type.CHAT));
            fail_if_not_eq_int(0, reload_items(((PopoverMenu) button.popover).menu_model), "synthetic MQTT chat has no XMPP archive action");
            entry.unset_conversation();
            fail_if(button.visible, "cleared conversation must hide the native header controls");
        } catch (Error error) { fail_if_reached(error.message); }
        finally {
            Util.clear_focus_before_detach(window); window.destroy(); iterate_for(30);
            if (database != null) database.close();
        }
    }

    private static int reload_items(MenuModel model) {
        int matches = 0;
        for (int index = 0; index < model.get_n_items(); index++) {
            // The chat menu groups feed sharing separately. Walk native
            // sections/submenus instead of assuming a flat menu model.
            foreach (string link in new string[] { Menu.LINK_SECTION, Menu.LINK_SUBMENU }) {
                MenuModel? child = model.get_item_link(index, link);
                if (child != null) matches += reload_items(child);
            }
            Variant? action = model.get_item_attribute_value(index, Menu.ATTRIBUTE_ACTION, VariantType.STRING);
            if (action != null && action.get_string() == "app.load-current-conversation-history") {
                matches++;
                Variant? label = model.get_item_attribute_value(index, Menu.ATTRIBUTE_LABEL, VariantType.STRING);
                fail_if(label == null);
                if (label != null) fail_if_not_eq_str(_("Load messages now"), label.get_string());
            }
        }
        return matches;
    }

    private static void iterate_for(uint milliseconds) {
        var context = MainContext.default();
        int64 deadline = get_monotonic_time() + milliseconds * 1000;
        while (get_monotonic_time() < deadline) {
            while (context.pending()) context.iteration(false);
            Thread.usleep(1000);
        }
        while (context.pending()) context.iteration(false);
    }
}

}
