using Dino.Entities;
using Dino.Ui.ConversationDetails;
using Gtk;
using Xmpp;
using Xmpp.Xep;

namespace Dino.Ui.Test {

// Test-only declarations for the existing generated namespace-function symbols.
// These invoke the real specialized renderers without widening the product API.
[CCode (cname = "dino_ui_conversation_details_show_create_hat_dialog")]
private static extern void render_create_hat_dialog(StreamInteractor interactor,
    Account account, Jid room, Gtk.Window? parent, AdHocCommands.Command command);
[CCode (cname = "dino_ui_conversation_details_show_assign_hat_dialog")]
private static extern void render_assign_hat_dialog(StreamInteractor interactor,
    Account account, Jid room, Gtk.Window? parent, AdHocCommands.Command command,
    Gee.List<HatChoice>? hats, Gee.List<AssignedHatChoice>? assigned, bool remove);
[CCode (cname = "dino_ui_conversation_details_show_remove_assigned_hat_dialog")]
private static extern void render_remove_hat_dialog(StreamInteractor interactor,
    Account account, Jid room, Gtk.Window? parent, AdHocCommands.Command command,
    Gee.List<AssignedHatChoice> assigned);
[CCode (cname = "dino_ui_conversation_details_show_delete_hat_dialog")]
private static extern void render_delete_hat_dialog(StreamInteractor interactor,
    Account account, Jid room, Gtk.Window? parent, AdHocCommands.Command command,
    Gee.List<HatChoice>? hats);
[CCode (cname = "dino_ui_conversation_details_create_hats_submit_form")]
private static extern DataForms.DataForm? hats_submit_form(DataForms.DataForm? form);
[CCode (cname = "dino_ui_conversation_details_show_hats_management_dialog")]
private static extern void open_hats_management(StreamInteractor interactor,
    Account account, Jid room, Gtk.Window? parent);

class HatsCommandDialogRuntimeTest : Gee.TestCase {
    private delegate bool Ready();
    public HatsCommandDialogRuntimeTest() {
        base("HatsCommandDialogRuntime");
        add_test("actual_specialized_forms_fit_small_themed_rtl_parents", test_layout);
        add_test("actual_create_form_explains_optional_color_and_validates_title", test_create);
        add_test("editing_preserves_identity_custom_hue_and_form_fields", test_edit);
        add_test("native_color_picker_opens_and_cancel_preserves_the_hat", test_picker);
        add_test("closing_actual_command_forms_releases_widget_callbacks", test_lifetime);
        add_test("all_actions_close_back_to_the_same_management_dialog", test_navigation_cancel);
        add_test("confirmed_mutations_refresh_the_same_management_dialog", test_navigation_save);
        add_test("errors_and_continuations_preserve_the_dialog_stack", test_navigation_errors);
        add_test("late_replies_cannot_reopen_closed_management", test_navigation_late);
        add_test("lost_room_permissions_block_submission_and_preserve_return_path", test_navigation_permissions);
    }

    // Real controller, IQ module and GTK dialog stack; only the server is local.
    // No product test hooks, network sockets or real user database are involved.
    private class HatServer : Object {
        public OccupantListRuntimeTest.Fixture fixture;
        private AdHocCommands.Module module = new AdHocCommands.Module();
        private ulong handler;
        public string title = "Maintainer";
        public string uri = "urn:example:hat:maintainer";
        public bool exists = true;
        public bool assigned = true;
        public bool reject_submit = false;
        public bool continue_submit = false;
        public bool hold_execute = false;
        public Iq.Stanza? held;
        public int cancels = 0;
        public int starts = 0;
        public int submits = 0;
        public int overviews = 0;
        public HatServer(OccupantListRuntimeTest.Fixture fixture) throws Error {
            this.fixture = fixture;
            fixture.presence("Self", true, "owner", "moderator");
            fixture.first_stream.add_module(module);
            module.attach(fixture.first_stream);
            handler = fixture.first_stream.get_module<Iq.Module>(Iq.Module.IDENTITY)
                .preprocess_outgoing_iq_set_get.connect((stream, iq) => {
                    if (iq.to == null || !iq.to.equals(fixture.room.counterpart)) return;
                    if (iq.stanza.get_subnode("command", AdHocCommands.NS_URI) == null &&
                            iq.stanza.get_subnode("query", "http://jabber.org/protocol/disco#items") == null) return;
                    Idle.add(() => { reply(iq); return Source.REMOVE; });
                });
        }
        public void close() {
            fixture.first_stream.get_module<Iq.Module>(Iq.Module.IDENTITY).disconnect(handler);
            module.detach(fixture.first_stream);
        }
        public void release() {
            hold_execute = false;
            Iq.Stanza? iq = held;
            held = null;
            if (iq != null) reply(iq);
        }
        private StanzaNode field(string name, string value) {
            return new StanzaNode.build("field", DataForms.NS_URI).put_attribute("var", name)
                .put_node(new StanzaNode.build("value", DataForms.NS_URI)
                    .put_node(new StanzaNode.text(value)));
        }
        private void reply(Iq.Stanza iq) {
            var response = new StanzaNode.build("iq", "jabber:client")
                .put_attribute("id", iq.id).put_attribute("type", "result")
                .put_attribute("from", fixture.room.counterpart.to_string())
                .put_attribute("to", fixture.first.full_jid.to_string());
            var request = iq.stanza.get_subnode("command", AdHocCommands.NS_URI);
            if (request == null) {
                overviews++;
                var query = new StanzaNode.build("query", "http://jabber.org/protocol/disco#items")
                    .put_attribute("node", AdHocCommands.NS_URI);
                foreach (string task in new string[] { "create", "assign", "unassign", "destroy", "list", "list-assigned" }) {
                    query.put_node(new StanzaNode.build("item", "http://jabber.org/protocol/disco#items")
                        .put_attribute("jid", fixture.room.counterpart.to_string())
                        .put_attribute("node", "urn:xmpp:hats:commands:" + task));
                }
                response.put_node(query);
            } else {
                string node = request.get_attribute("node");
                string task = node.substring("urn:xmpp:hats:commands:".length);
                string action = request.get_attribute("action") ?? "execute";
                var result = new StanzaNode.build("command", AdHocCommands.NS_URI)
                    .put_attribute("node", node).put_attribute("status", "completed")
                    .put_attribute("sessionid", "local-render-only");
                if (task == "list" || task == "list-assigned") {
                    var form = new StanzaNode.build("x", DataForms.NS_URI).put_attribute("type", "result");
                    if (exists && (task == "list" || assigned)) {
                        var item = new StanzaNode.build("item", DataForms.NS_URI)
                            .put_node(field("hats#uri", uri)).put_node(field("hats#title", title))
                            .put_node(field("hats#hue", "137.125"));
                        if (task == "list-assigned") item.put_node(field("hats#jid", "member@example.test"));
                        form.put_node(item);
                    }
                    result.put_node(form);
                } else if (action == "cancel") {
                    cancels++;
                    result.set_attribute("status", "canceled");
                } else if (action == "execute") {
                    if (hold_execute) { held = iq; return; }
                    starts++;
                    result.set_attribute("status", "executing");
                    result.put_node(command(task).form.stanza_node);
                } else {
                    submits++;
                    if (reject_submit) {
                        response.set_attribute("type", "error");
                        response.put_node(request)
                            .put_node(new StanzaNode.build("error", "jabber:client").put_attribute("type", "cancel")
                                .put_node(new StanzaNode.build("forbidden", "urn:ietf:params:xml:ns:xmpp-stanzas")));
                        fixture.first_stream.received_iq_stanza(fixture.first_stream, response);
                        return;
                    }
                    if (continue_submit) {
                        continue_submit = false;
                        result.set_attribute("status", "executing");
                        result.put_node(command(task).form.stanza_node);
                    } else {
                        if (task == "create") {
                            var form = DataForms.DataForm.create_from_node(request.get_subnode("x", DataForms.NS_URI));
                            foreach (var value in form.fields) {
                                if (value.var == "hats#title") title = value.get_value_string();
                                if (value.var == "hats#uri") uri = value.get_value_string();
                            }
                            exists = true;
                        }
                        if (task == "assign") assigned = true;
                        if (task == "unassign") assigned = false;
                        if (task == "destroy") { exists = false; assigned = false; }
                    }
                }
                response.put_node(result);
            }
            fixture.first_stream.received_iq_stanza(fixture.first_stream, response);
        }
    }

    private static HatsManagementPage? management_page(Adw.Dialog dialog) {
        foreach (var widget in widgets(dialog.child)) {
            if (widget is HatsManagementPage) return (HatsManagementPage) widget;
        }
        return null;
    }

    private static Adw.Dialog overview(OccupantListRuntimeTest.Fixture fixture, Adw.Window window) {
        window.present();
        open_hats_management(fixture.interactor, fixture.first, fixture.room.counterpart, window);
        // Discovery and both list queries finish asynchronously. A fixed delay
        // can click the disabled page before the last response is processed.
        wait_for(() => {
            var current = window.get_visible_dialog();
            var page = current != null ? management_page(current) : null;
            return page != null && page.sensitive;
        }, "the management overview must finish loading before an action");
        var dialog = window.get_visible_dialog();
        assert(dialog != null && management_page(dialog) != null);
        wait_presented(dialog);
        return dialog;
    }

    private static Adw.Dialog action_dialog(Adw.Window window, Adw.Dialog root,
            string task, string? uri = null, string? jid = null) {
        management_page(root).requested("urn:xmpp:hats:commands:" + task, uri, jid);
        wait_for(() => {
            var current = window.get_visible_dialog();
            return current != null && current != root;
        }, "the requested command must receive its form before interaction");
        var dialog = window.get_visible_dialog();
        assert(dialog != null && dialog != root && !(dialog is Adw.AlertDialog));
        wait_presented(dialog);
        return dialog;
    }

    private void test_navigation_cancel() {
        OccupantListRuntimeTest.Fixture? fixture = null;
        HatServer? server = null;
        var window = new Adw.Window() { default_width = 600, default_height = 720 };
        try {
            fixture = new OccupantListRuntimeTest.Fixture();
            server = new HatServer(fixture);
            var room_admin = new Adw.Dialog() { child = new Label("Room administration") };
            window.present(); room_admin.present(window);
            var root = overview(fixture, window);
            int expected_cancels = 0;
            foreach (string task in new string[] { "create", "assign", "unassign", "destroy", "edit" }) {
                var dialog = action_dialog(window, root, task == "edit" ? "create" : task,
                    task == "create" ? null : server.uri, task == "unassign" ? "member@example.test" : null);
                if (task == "destroy") {
                    button(dialog.child, _("Delete")).clicked();
                    if (!wait_for(() => window.get_visible_dialog() is Adw.AlertDialog,
                            "deletion must show its confirmation before cancellation")) return;
                    var confirmation = window.get_visible_dialog();
                    if (!wait_presented(confirmation)) return;
                    confirmation.close();
                    if (!wait_for(() => window.get_visible_dialog() == dialog,
                            "canceling deletion confirmation must return to the delete form")) return;
                }
                dialog.close();
                expected_cancels++;
                if (!wait_for(() => window.get_visible_dialog() == root &&
                        management_page(root).sensitive && server.cancels == expected_cancels,
                        "cancel must return to the same usable management instance and cancel its command")) return;
            }
            fail_if_not_eq_int(5, server.cancels);
            fail_if_not_eq_int(0, server.submits);
            root.close();
            wait_for(() => window.get_visible_dialog() == room_admin,
                "only closing the overview returns to room administration");
            room_admin.close(); settle();
        } catch (Error error) { fail_if_reached(error.message); }
        finally { window.destroy(); settle(); if (server != null) server.close(); if (fixture != null) fixture.close(); }
    }

    private void test_navigation_save() {
        OccupantListRuntimeTest.Fixture? fixture = null;
        HatServer? server = null;
        var window = new Adw.Window() { default_width = 600, default_height = 720 };
        try {
            fixture = new OccupantListRuntimeTest.Fixture();
            server = new HatServer(fixture);
            var root = overview(fixture, window);
            // Enter editing through the actual assigned-row pencil, not the
            // definition shortcut: both must preserve the same definition URI.
            foreach (var widget in widgets(root.child)) {
                var row = widget as Adw.ActionRow;
                if (row == null || row.title != "member@example.test") continue;
                foreach (var child in widgets(row)) {
                    if (child is Button && child.tooltip_text == _("Edit Hat")) ((Button) child).clicked();
                }
            }
            if (!wait_for(() => {
                var current = window.get_visible_dialog();
                return current != null && current != root;
            }, "editing the assigned row must receive its form")) return;
            var dialog = window.get_visible_dialog();
            if (fail_if(dialog == root || dialog is Adw.AlertDialog)) return;
            if (!wait_presented(dialog)) return;
            entry(dialog.child, _("Hat title")).text = "Support";
            button(dialog.child, _("Save")).clicked();
            if (!wait_for(() => window.get_visible_dialog() == root && management_page(root).sensitive &&
                    server.submits == 1 && server.overviews == 2,
                    "saving the assigned hat must finish refreshing the original overview")) return;
            fail_if_not_eq_str("Support", server.title);
            fail_if_not(server.assigned, "editing a definition must retain its assignments");
            bool refreshed = false;
            foreach (var widget in widgets(root.child)) {
                if (widget is Label && ((Label) widget).label == "Support") refreshed = true;
            }
            fail_if_not(refreshed, "the original overview must show confirmed server data");
            capture(window, root, "management-after-assigned-hat-edit");
            int expected_submits = 1;
            foreach (string task in new string[] { "unassign", "assign", "destroy", "create" }) {
                dialog = action_dialog(window, root, task, task == "create" ? null : server.uri,
                    task == "unassign" ? "member@example.test" : null);
                if (task == "create") entry(dialog.child, _("Hat title")).text = "New Hat";
                if (task == "assign") entry(dialog.child, _("XMPP address (optional)")).text = "member@example.test";
                button(dialog.child, task == "unassign" ? _("Remove Assignment") :
                    task == "assign" ? _("Assign") : task == "destroy" ? _("Delete") : _("Create")).clicked();
                if (task == "destroy") {
                    if (!wait_for(() => window.get_visible_dialog() is Adw.AlertDialog,
                            "deletion must show its confirmation before submission")) return;
                    var confirmation = window.get_visible_dialog();
                    if (!wait_presented(confirmation)) return;
                    button(confirmation.child, _("Delete")).clicked();
                }
                expected_submits++;
                if (!wait_for(() => window.get_visible_dialog() == root && management_page(root).sensitive &&
                        server.submits == expected_submits && server.overviews == expected_submits + 1,
                        "save must refresh the original management dialog with the confirmed result")) return;
            }
            fail_if_not_eq_int(5, server.starts, "refreshes cannot duplicate the action handler");
            fail_if_not_eq_int(5, server.submits);
            fail_if_not_eq_int(0, server.cancels, "completed commands must not be canceled on close");
            fail_if_not_eq_int(6, server.overviews);
            root.close(); settle();
        } catch (Error error) { fail_if_reached(error.message); }
        finally { window.destroy(); settle(); if (server != null) server.close(); if (fixture != null) fixture.close(); }
    }

    private void test_navigation_errors() {
        OccupantListRuntimeTest.Fixture? fixture = null;
        HatServer? server = null;
        var window = new Adw.Window() { default_width = 600, default_height = 720 };
        try {
            fixture = new OccupantListRuntimeTest.Fixture();
            server = new HatServer(fixture);
            var root = overview(fixture, window);
            var dialog = action_dialog(window, root, "create", server.uri);
            entry(dialog.child, _("Hat title")).text = "Changed";
            server.reject_submit = true;
            button(dialog.child, _("Save")).clicked();
            if (!wait_for(() => window.get_visible_dialog() is Adw.AlertDialog,
                    "a rejected submission must display its error before dismissal")) return;
            var error = window.get_visible_dialog();
            if (!wait_presented(error)) return;
            error.close();
            if (!wait_for(() => window.get_visible_dialog() == dialog,
                    "dismissed errors must retain the editable form")) return;
            fail_if_not_eq_str("Changed", entry(dialog.child, _("Hat title")).text);
            server.reject_submit = false;
            server.continue_submit = true;
            button(dialog.child, _("Save")).clicked();
            if (!wait_for(() => {
                var current = window.get_visible_dialog();
                return current != null && current != root && current != dialog && !(current is Adw.AlertDialog);
            }, "the continuation response must display the next editable form")) return;
            var next = window.get_visible_dialog();
            if (!wait_presented(next)) return;
            fail_if_not_eq_str(_("Edit Hat"), next.title);
            next.close();
            if (!wait_for(() => window.get_visible_dialog() == root && management_page(root).sensitive,
                    "closing a continuation must also reveal the usable overview")) return;
            // Closing the old continuation must not leave the overview blocked.
            dialog = action_dialog(window, root, "create", server.uri);
            dialog.close();
            wait_for(() => window.get_visible_dialog() == root && server.cancels == 2,
                "both canceled command sessions must finish before checking the overview");
            fail_if_not_eq_int(2, server.cancels);
            root.close(); settle();
        } catch (Error error) { fail_if_reached(error.message); }
        finally { window.destroy(); settle(); if (server != null) server.close(); if (fixture != null) fixture.close(); }
    }

    private void test_navigation_late() {
        OccupantListRuntimeTest.Fixture? fixture = null;
        HatServer? server = null;
        var window = new Adw.Window() { default_width = 600, default_height = 720 };
        try {
            fixture = new OccupantListRuntimeTest.Fixture();
            server = new HatServer(fixture);
            Adw.Dialog? root = overview(fixture, window);
            WeakRef root_ref = WeakRef(root);
            server.hold_execute = true;
            management_page(root).requested("urn:xmpp:hats:commands:create", server.uri, null);
            if (!wait_for(() => server.held != null,
                    "the test server must receive the command before the overview closes")) return;
            root.close(); root = null;
            if (!wait_for(() => window.get_visible_dialog() == null,
                    "the overview must close before the delayed response")) return;
            server.release();
            wait_for(() => server.cancels == 1, "the late executing session must be canceled");
            wait_for(() => root_ref.get() == null,
                "completed async work must release the closed management dialog");
            fail_if(window.get_visible_dialog() != null, "a late command form cannot resurrect the closed overview");
            fail_if(root_ref.get() != null, "completed async work must not retain the closed management dialog");
            fail_if_not_eq_int(1, server.cancels, "the late executing session must be canceled");
            fail_if_not_eq_int(0, server.submits);
        } catch (Error error) { fail_if_reached(error.message); }
        finally { window.destroy(); settle(); if (server != null) server.close(); if (fixture != null) fixture.close(); }
    }

    private void test_navigation_permissions() {
        OccupantListRuntimeTest.Fixture? fixture = null;
        HatServer? server = null;
        var window = new Adw.Window() { default_width = 600, default_height = 720 };
        try {
            fixture = new OccupantListRuntimeTest.Fixture();
            server = new HatServer(fixture);
            var root = overview(fixture, window);
            var dialog = action_dialog(window, root, "create", server.uri);
            fixture.presence("Self", true, "member", "participant");
            button(dialog.child, _("Save")).clicked();
            if (!wait_for(() => window.get_visible_dialog() is Adw.AlertDialog,
                    "lost permissions must show an error before returning to the overview")) return;
            var error = window.get_visible_dialog();
            if (!wait_presented(error)) return;
            error.close();
            wait_for(() => window.get_visible_dialog() == root && server.cancels == 1,
                "the rejected action must close and cancel its session");
            fail_if_not_eq_int(0, server.submits, "stale owner authority must never submit a change");
            fail_if_not_eq_int(1, server.cancels);
            fail_if_not_eq_int(0, fixture.second_stream.writes, "the other account stays untouched");
            root.close(); settle();
        } catch (Error error) { fail_if_reached(error.message); }
        finally { window.destroy(); settle(); if (server != null) server.close(); if (fixture != null) fixture.close(); }
    }

    private static void settle(uint milliseconds = 120) {
        int64 deadline = get_monotonic_time() + milliseconds * 1000;
        while (get_monotonic_time() < deadline) {
            if (MainContext.default().pending()) MainContext.default().iteration(false);
            else Thread.usleep(1000);
        }
    }

    private static bool wait_for(Ready ready, string reason) {
        int64 deadline = get_monotonic_time() + 5 * TimeSpan.SECOND;
        while (!ready() && get_monotonic_time() < deadline) settle(5);
        return !fail_if_not(ready(), reason);
    }

    private static bool wait_presented(Adw.Dialog dialog) {
        // libadwaita 1.5 opens its sheet on the second map tick. A dialog can
        // already be in get_visible_dialog() before that: closing it then
        // closes an unopened sheet which the pending map callback reopens.
        // Simulate interaction only after actual frames, never a fixed delay.
        int frames = 0;
        uint tick = dialog.add_tick_callback(() => {
            frames++;
            return frames < 3;
        });
        bool ready = wait_for(() => frames >= 3, "the dialog must finish its initial presentation before interaction");
        if (!ready) dialog.remove_tick_callback(tick);
        return ready;
    }

    private static void descendants(Widget root, Gee.List<Widget> result) {
        result.add(root);
        for (Widget? child = root.get_first_child(); child != null;
                child = child.get_next_sibling()) descendants(child, result);
    }

    private static Gee.List<Widget> widgets(Widget root) {
        var result = new Gee.ArrayList<Widget>();
        descendants(root, result);
        return result;
    }

    private static Button? button(Widget root, string label) {
        foreach (var widget in widgets(root)) {
            var result = widget as Button;
            if (result != null && result.label == label) return result;
        }
        return null;
    }

    private static Adw.EntryRow? entry(Widget root, string title) {
        foreach (var widget in widgets(root)) {
            var result = widget as Adw.EntryRow;
            if (result != null && result.title == title) return result;
        }
        return null;
    }

    private static Adw.ComboRow? combo(Widget root, string title) {
        foreach (var widget in widgets(root)) {
            var result = widget as Adw.ComboRow;
            if (result != null && result.title == title) return result;
        }
        return null;
    }

    private static AdHocCommands.Command command(string task) {
        var node = new StanzaNode.build("command", AdHocCommands.NS_URI)
            .put_attribute("node", "urn:xmpp:hats:commands:" + task)
            .put_attribute("status", "executing")
            .put_attribute("sessionid", "local-render-only");
        var form = new StanzaNode.build("x", DataForms.NS_URI)
            .put_attribute("type", "form");
        if (task == "create") {
            form.put_node(new StanzaNode.build("field", DataForms.NS_URI)
                .put_attribute("var", "hats#title").put_attribute("type", "text-single")
                .put_node(new StanzaNode.build("required", DataForms.NS_URI)));
            form.put_node(new StanzaNode.build("field", DataForms.NS_URI)
                .put_attribute("var", "hats#uri").put_attribute("type", "text-single")
                .put_node(new StanzaNode.build("required", DataForms.NS_URI)));
            form.put_node(new StanzaNode.build("field", DataForms.NS_URI)
                .put_attribute("var", "hats#hue").put_attribute("type", "text-single"));
        } else {
            form.put_node(new StanzaNode.build("field", DataForms.NS_URI)
                .put_attribute("var", "hat").put_attribute("type", "list-single")
                .put_node(new StanzaNode.build("option", DataForms.NS_URI)
                    .put_attribute("label", "Maintainer")
                    .put_node(new StanzaNode.build("value", DataForms.NS_URI)
                        .put_node(new StanzaNode.text("urn:example:hat:maintainer")))));
            if (task == "assign" || task == "unassign") {
                form.put_node(new StanzaNode.build("field", DataForms.NS_URI)
                    .put_attribute("var", "hats#jid").put_attribute("type", "jid-single")
                    .put_node(new StanzaNode.build("required", DataForms.NS_URI)));
            }
        }
        node.put_node(form);
        // No room-context data is installed: closing/rendering can never send a
        // cancel or complete IQ. The shared local stream counts attempted writes.
        return AdHocCommands.Command.from_node(node);
    }

    private static Adw.Dialog? render(OccupantListRuntimeTest.Fixture fixture,
            Adw.Window parent, string task) {
        var hats = new Gee.ArrayList<HatChoice>();
        hats.add(new HatChoice() { title = "<Maintainer> & Support", uri = "urn:example:hat:maintainer", hue = "225" });
        var assigned = new Gee.ArrayList<AssignedHatChoice>();
        assigned.add(new AssignedHatChoice() {
            title = "<Maintainer> & Support", uri = "urn:example:hat:maintainer", hue = "225",
            jid = "member@example.test"
        });
        var form = command(task == "edit" ? "create" : task);
        if (task == "edit") {
            hats[0].hue = "137.125";
            form.set_data<HatChoice>("dinox-hats-edit", hats[0]);
        }
        switch (task) {
            case "edit":
            case "create":
                render_create_hat_dialog(fixture.interactor, fixture.first,
                    fixture.room.counterpart, parent, form);
                break;
            case "assign":
                render_assign_hat_dialog(fixture.interactor, fixture.first,
                    fixture.room.counterpart, parent, form, hats, assigned, false);
                break;
            case "unassign":
                render_remove_hat_dialog(fixture.interactor, fixture.first,
                    fixture.room.counterpart, parent, form, assigned);
                break;
            case "destroy":
                render_delete_hat_dialog(fixture.interactor, fixture.first,
                    fixture.room.counterpart, parent, form, hats);
                break;
        }
        settle();
        var dialog = parent.get_visible_dialog();
        if (dialog != null) {
            bool found_scope = false;
            foreach (var widget in widgets(dialog.child)) {
                var row = widget as Adw.ActionRow;
                if (row != null && row.title == fixture.room.counterpart.bare_jid.to_string()) {
                    found_scope = true;
                    fail_if(row.use_markup);
                    fail_if_not_eq_str(_("Account: %s").printf(fixture.first.bare_jid.to_string()), row.subtitle);
                }
            }
            fail_if_not(found_scope, "every command form identifies its captured room and account");
        }
        return dialog;
    }

    private static void check_layout(Adw.Dialog dialog, Adw.Window window, int width) {
        int minimum, natural;
        dialog.child.measure(Orientation.HORIZONTAL, -1, out minimum, out natural, null, null);
        GLib.Test.message("Hat command %s parent=%d actual=%d content_min=%d",
            dialog.title, width, window.get_width(), minimum);
        fail_if(window.get_width() > width + 1 || minimum > window.get_width(),
            "the real command form and header cannot enlarge their narrow parent");
        Graphene.Rect bounds;
        fail_if_not(dialog.compute_bounds(window, out bounds));
        fail_if(bounds.origin.x < -0.5f || bounds.origin.x + bounds.size.width > window.get_width() + 0.5f);
        foreach (var widget in widgets(dialog.child)) {
            if (!(widget is Button || widget is Adw.PreferencesRow) ||
                    !widget.get_visible() || !widget.get_mapped()) continue;
            fail_if_not(widget.compute_bounds(dialog.child, out bounds));
            fail_if(bounds.origin.x < -0.5f || bounds.origin.x + bounds.size.width > dialog.child.get_width() + 0.5f,
                "native header actions and form controls must fit the actual content area");
        }
    }

    private static void capture(Adw.Window window, Adw.Dialog dialog, string name) {
        string? directory = Environment.get_variable("DINOX_HATS_CAPTURE_DIR");
        if (directory == null) return;
        DirUtils.create_with_parents(directory, 0700);
        settle(200);
        fail_if_not(window.get_mapped() && dialog.get_mapped(),
            "the native window and its actual dialog must be visible before capture");
        var snapshot = new Snapshot();
        // Capture the actual window/sheet backgrounds as well as the controls.
        new WidgetPaintable(window).snapshot(snapshot,
            window.get_width(), window.get_height());
        var node = snapshot.to_node();
        var renderer = window.get_renderer();
        if (fail_if(node == null || renderer == null)) return;
        var texture = renderer.render_texture(node, null);
        fail_if_not(texture.save_to_png(Path.build_filename(directory, name + ".png")));
    }

    private void test_layout() {
        OccupantListRuntimeTest.Fixture? fixture = null;
        var manager = Adw.StyleManager.get_default();
        var previous_scheme = manager.color_scheme;
        var previous_direction = Widget.get_default_direction();
        var style = new InterfaceStyle(Gdk.Display.get_default());
        style.apply("website");
        try {
            fixture = new OccupantListRuntimeTest.Fixture();
            int initial_writes = fixture.first_stream.writes;
            foreach (var scheme in new Adw.ColorScheme[] { Adw.ColorScheme.FORCE_LIGHT, Adw.ColorScheme.FORCE_DARK }) {
                manager.color_scheme = scheme;
                foreach (var direction in new TextDirection[] { TextDirection.LTR, TextDirection.RTL }) {
                    Widget.set_default_direction(direction);
                    foreach (int width in new int[] { 320, 500 }) {
                        foreach (string task in new string[] { "create", "edit", "assign", "unassign", "destroy" }) {
                            var window = new Adw.Window();
                            Adw.Dialog? dialog = null;
                            try {
                                window.add_css_class("dino-main");
                                window.content = new Box(Orientation.VERTICAL, 0);
                                window.set_default_size(width, 640);
                                window.present(); settle();
                                // The window manager may enforce a larger
                                // minimum (for example 360 px on Windows).
                                // Compare the dialog with the actual empty
                                // parent, not the requested default size.
                                int parent_width = window.get_width();
                                dialog = render(fixture, window, task);
                                if (fail_if(dialog == null, "the actual specialized command must present an Adw.Dialog")) continue;
                                check_layout(dialog, window, parent_width);
                                capture(window, dialog, "command-%s-%d-%s-%s".printf(task, width,
                                    scheme == Adw.ColorScheme.FORCE_DARK ? "dark" : "light",
                                    direction == TextDirection.RTL ? "rtl" : "ltr"));
                            } finally {
                                if (dialog != null) { Util.clear_focus_before_detach(dialog); dialog.force_close(); }
                                window.destroy(); settle();
                            }
                        }
                    }
                }
            }
            fail_if_not_eq_int(initial_writes, fixture.first_stream.writes,
                "rendering and closing specialized forms cannot send server mutations or cancellation IQs");
        } catch (Error error) { fail_if_reached(error.message); }
        finally {
            if (fixture != null) fixture.close();
            manager.color_scheme = previous_scheme;
            Widget.set_default_direction(previous_direction);
            style.apply("classic");
            style.dispose();
        }
    }

    private void test_create() {
        OccupantListRuntimeTest.Fixture? fixture = null;
        var window = new Adw.Window();
        Adw.Dialog? dialog = null;
        try {
            fixture = new OccupantListRuntimeTest.Fixture();
            window.content = new Box(Orientation.VERTICAL, 0);
            window.set_default_size(500, 600);
            window.present(); settle();
            dialog = render(fixture, window, "create");
            if (fail_if(dialog == null)) return;
            var title = entry(dialog, _("Hat title"));
            var color = combo(dialog, _("Hat color"));
            var create = button(dialog, _("Create"));
            if (fail_if(title == null || color == null || create == null)) return;
            fail_if(create.sensitive, "Create stays disabled until the required title is provided");
            color.selected = 5;
            fail_if_not_eq_str(_("Default color"), ((Gtk.StringObject) color.selected_item).string);
            fail_if(create.sensitive, "the optional default color does not replace the required title");
            title.text = "  Maintainer  ";
            fail_if_not(create.sensitive);
            title.text = " \t ";
            fail_if(create.sensitive, "a whitespace-only title is not a valid label");
            fail_if(entry(dialog, _("Hat URI")) != null,
                "the ordinary Create renderer supplies a unique URI without making users invent identifiers");
            fail_if_not_eq_int(0, fixture.first_stream.writes,
                "editing the real form cannot publish changes before submission");
        } catch (Error error) { fail_if_reached(error.message); }
        finally {
            if (dialog != null) { Util.clear_focus_before_detach(dialog); dialog.force_close(); }
            window.destroy(); settle();
            if (fixture != null) fixture.close();
        }
    }

    private void test_edit() {
        OccupantListRuntimeTest.Fixture? fixture = null;
        var window = new Adw.Window();
        Adw.Dialog? dialog = null;
        try {
            fixture = new OccupantListRuntimeTest.Fixture();
            window.content = new Box(Orientation.VERTICAL, 0);
            window.set_default_size(500, 640);
            window.present(); settle();
            foreach (string hue in new string[] { "137.125000", "0", "360", "", "137.125001" }) {
                var form = command("create");
                var token = new DataForms.DataForm.HiddenField();
                token.var = "server-token";
                token.set_value_string("keep-opaque-value");
                form.form.add_field(token);
                var definition = new HatChoice() {
                    uri = "urn:example:unchanged-identity", title = "Original", hue = hue
                };
                form.set_data<HatChoice>("dinox-hats-edit", definition);
                render_create_hat_dialog(fixture.interactor, fixture.first,
                    fixture.room.counterpart, window, form);
                settle();
                dialog = window.get_visible_dialog();
                if (fail_if(dialog == null)) return;
                fail_if_not_eq_str(_("Edit Hat"), dialog.title);
                var title = entry(dialog, _("Hat title"));
                var color = combo(dialog, _("Hat color"));
                var save = button(dialog, _("Save"));
                Gtk.ColorDialogButton? picker = null;
                foreach (var widget in widgets(dialog)) {
                    if (widget is Gtk.ColorDialogButton) picker = (Gtk.ColorDialogButton) widget;
                }
                if (fail_if(title == null || color == null || save == null || picker == null)) return;
                fail_if_not_eq_str("Original", title.text);
                fail_if_not(save.sensitive);
                fail_if(picker.dialog.with_alpha, "Hat colors carry hue, not transparency");
                title.text = "Renamed <label>";
                bool change_color = hue == "137.125001";
                if (change_color) {
                    picker.rgba = Gdk.RGBA() { red = 0, green = 1, blue = 0.5f, alpha = 1 };
                    settle();
                    bool found_preview = false;
                    foreach (var widget in widgets(dialog)) {
                        if (widget.has_css_class("hat-tone-150")) found_preview = true;
                    }
                    fail_if_not(found_preview, "picker changes must update the actual badge preview before saving");
                }
                // This render-only fixture has no mutation context. Save populates
                // the actual command form, then the production guard rejects IQ I/O.
                save.clicked(); settle();
                var submitted = hats_submit_form(form.form);
                if (fail_if(submitted == null)) return;
                fail_if_not_eq_str("urn:xmpp:hats:commands:create", form.node);
                bool found_token = false;
                bool found_hue = false;
                foreach (var field in submitted.fields) {
                    if (field.var == "hats#uri") fail_if_not_eq_str(definition.uri, field.get_value_string());
                    if (field.var == "hats#title") fail_if_not_eq_str("Renamed <label>", field.get_value_string());
                    if (field.var == "hats#hue") {
                        found_hue = true;
                        if (change_color) fail_if(Math.fabs(double.parse(field.get_value_string()) - 150) > 0.001);
                        else fail_if_not_eq_str(hue, field.get_value_string(),
                            "renaming must not quantize, reset, or drop the original hue");
                    }
                    if (field.var == "server-token") {
                        found_token = true;
                        fail_if_not_eq_str("keep-opaque-value", field.get_value_string());
                    }
                }
                fail_if_not(found_token, "server-defined continuation fields must survive editing");
                fail_if(found_hue == (hue == ""), "default color is omitted; red zero is present");
                if (window.get_visible_dialog() != null) window.get_visible_dialog().force_close();
                dialog = null; settle();
            }
            var picker = new Gtk.ColorDialogButton(new Gtk.ColorDialog());
            picker.rgba = Gdk.RGBA() { red = 0, green = 1, blue = 0.5f, alpha = 1 };
            double? chosen = HatFormChoices.parse_hue(HatFormChoices.picker_hue(picker, "225"));
            fail_if(chosen == null || Math.fabs(chosen - 150) > 0.001,
                "the native picker's selected color must become the XEP-0317 hue");
            picker.rgba = Gdk.RGBA() { red = 0.5f, green = 0.5f, blue = 0.5f, alpha = 1 };
            fail_if_not_eq_str("137.125", HatFormChoices.picker_hue(picker, "137.125"),
                "a color without hue must not unexpectedly change the hat to red");
            fail_if_not_eq_int(0, fixture.first_stream.writes);
        } catch (Error error) { fail_if_reached(error.message); }
        finally {
            if (dialog != null) { Util.clear_focus_before_detach(dialog); dialog.force_close(); }
            window.destroy(); settle();
            if (fixture != null) fixture.close();
        }
    }

    private void test_picker() {
        OccupantListRuntimeTest.Fixture? fixture = null;
        var window = new Adw.Window();
        Adw.Dialog? dialog = null;
        Gtk.Window? chooser = null;
        var style = new InterfaceStyle(Gdk.Display.get_default());
        style.apply("website");
        try {
            fixture = new OccupantListRuntimeTest.Fixture();
            window.content = new Box(Orientation.VERTICAL, 0);
            window.set_default_size(500, 640);
            window.present(); settle();
            dialog = render(fixture, window, "edit");
            if (fail_if(dialog == null)) return;
            Gtk.ColorDialogButton? picker = null;
            foreach (var widget in widgets(dialog)) {
                if (widget is Gtk.ColorDialogButton) picker = (Gtk.ColorDialogButton) widget;
            }
            if (fail_if(picker == null)) return;
            string before = HatFormChoices.picker_hue(picker, "225");
            picker.activate();
            var windows = Gtk.Window.get_toplevels();
            int64 deadline = get_monotonic_time() + 3000000;
            // GtkButton activates after its click animation; the chooser is
            // asynchronous as well. Wait for its window, not a fixed delay.
            while (chooser == null && get_monotonic_time() < deadline) {
                settle(20);
                for (uint i = 0; i < windows.get_n_items(); i++) {
                    var candidate = windows.get_item(i) as Gtk.Window;
                    if (candidate != null && candidate.visible && candidate.title == _("Hat color")) chooser = candidate;
                }
            }
            if (fail_if(chooser == null, "the actual native color chooser must open")) return;
            settle(100);
            string? directory = Environment.get_variable("DINOX_HATS_CAPTURE_DIR");
            if (directory != null) {
                DirUtils.create_with_parents(directory, 0700);
                var snapshot = new Gtk.Snapshot();
                new WidgetPaintable(chooser).snapshot(snapshot, chooser.get_width(), chooser.get_height());
                var node = snapshot.to_node();
                if (node != null) chooser.get_renderer().render_texture(node, null)
                    .save_to_png(Path.build_filename(directory, "native-color-picker.png"));
            }
            chooser.close(); settle();
            fail_if_not_eq_str(before, HatFormChoices.picker_hue(picker, "225"),
                "canceling the native chooser must not change the selected hue");
            fail_if_not_eq_int(0, fixture.first_stream.writes);
        } catch (Error error) { fail_if_reached(error.message); }
        finally {
            if (chooser != null) chooser.close();
            if (dialog != null) { Util.clear_focus_before_detach(dialog); dialog.force_close(); }
            window.destroy(); settle();
            if (fixture != null) fixture.close();
            style.apply("classic"); style.dispose();
        }
    }

    private static void close_retained_create(OccupantListRuntimeTest.Fixture fixture,
            Adw.Window window, out Button? retained, ref WeakRef observer) {
        Adw.Dialog? dialog = render(fixture, window, "create");
        retained = dialog != null ? button(dialog, _("Create")) : null;
        if (dialog == null || retained == null) {
            fail_if_reached("the actual Create dialog and button are required for lifetime verification");
            observer.set(null);
            return;
        }
        var title = entry(dialog, _("Hat title"));
        if (title != null) title.text = "Maintainer";
        // Keep the observer at its caller-owned address throughout finalization.
        observer.set(dialog);
        Util.clear_focus_before_detach(dialog);
        dialog.force_close();
        settle(250);
    }

    private void test_lifetime() {
        OccupantListRuntimeTest.Fixture? fixture = null;
        var window = new Adw.Window();
        try {
            fixture = new OccupantListRuntimeTest.Fixture();
            window.content = new Box(Orientation.VERTICAL, 0);
            window.set_default_size(500, 600);
            window.present(); settle();
            Button? retained;
            var dialog_ref = WeakRef(null);
            close_retained_create(fixture, window, out retained, ref dialog_ref);
            settle();
            fail_if(dialog_ref.get() != null,
                "the actual Create callback cannot keep its closed dialog and command context alive");
            if (retained != null) retained.clicked();
            fail_if_not_eq_int(0, fixture.first_stream.writes,
                "a retained former submit button cannot perform any operation after dialog close");
        } catch (Error error) { fail_if_reached(error.message); }
        finally { window.destroy(); settle(); if (fixture != null) fixture.close(); }
    }
}
}
