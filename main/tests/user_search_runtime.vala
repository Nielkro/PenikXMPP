using Dino.Entities;
using Gtk;
using Xmpp;
using Xmpp.Xep;

namespace Dino.Ui.Test {

class UserSearchRuntimeTest : Gee.TestCase {
    private delegate bool Ready();

    public UserSearchRuntimeTest() {
        base("UserSearchRuntime");
        add_test("no_directory_errors_and_empty_results_are_distinct", test_terminal_states);
        add_test("typed_form_controls_preserve_hidden_values_and_required_fields", test_typed_form);
        add_test("enter_and_button_cannot_start_parallel_searches", test_duplicate_search);
        add_test("deadline_cancels_request_and_ignores_late_results", test_timeout);
        add_test("closing_cancels_discovery_and_ignores_late_form", test_close);
        add_test("search_errors_do_not_trigger_a_domain_fallback_and_results_are_literal", test_results);
        add_test("legacy_fields_are_used_without_inventing_a_search_form", test_legacy_form);
        add_test("closed_dialog_releases_with_retained_controls_and_late_requests", test_lifetime);
        add_test("directory_labels_and_instructions_translate_without_changing_the_form", test_directory_translations);
    }

    private class SearchService : Dino.UserSearch {
        public Jid? service;
        public Search.Form form;
        public Gee.List<Search.Item> results = new Gee.ArrayList<Search.Item>();
        public string? hold_stage;
        public string? error_stage;
        public bool timeout_error = false;
        public Cancellable? observed_cancellable;
        public int discovery_calls = 0;
        public int form_calls = 0;
        public int search_calls = 0;
        public Account? requested_account;
        public Jid? requested_service;
        public StanzaNode? submitted_query;
        private SourceFunc? pending_resume;

        public SearchService(StreamInteractor interactor, Search.Form form) throws Error {
            base(interactor);
            this.form = form;
            service = new Jid("users.example.test");
        }

        private async void wait_if_held(string stage, Cancellable? cancellable) throws Error {
            observed_cancellable = cancellable;
            if (hold_stage == stage) {
                pending_resume = wait_if_held.callback;
                yield;
            }
            // Deliberately permit a late result after cancellation: the UI must
            // ignore it even if a service cannot stop its work immediately.
            if (error_stage == stage) {
                if (timeout_error) throw new IOError.TIMED_OUT("Fixture timeout");
                throw new IOError.PERMISSION_DENIED("Fixture server refused the request");
            }
        }

        public void release() {
            SourceFunc? callback = (owned) pending_resume;
            if (callback != null) ((!) callback)();
        }

        public override async Jid? find_search_component(Account account,
                Cancellable? cancellable = null) throws Error {
            discovery_calls++;
            requested_account = account;
            yield wait_if_held("discovery", cancellable);
            return service;
        }

        public override async Search.Form get_search_fields(Account account, Jid jid,
                Cancellable? cancellable = null) throws Error {
            form_calls++;
            requested_account = account;
            requested_service = jid;
            yield wait_if_held("form", cancellable);
            return form;
        }

        public override async Gee.List<Search.Item> perform_search(Account account, Jid jid,
                Search.Form form, Cancellable? cancellable = null) throws Error {
            search_calls++;
            requested_account = account;
            requested_service = jid;
            submitted_query = form.get_submit_query_node();
            yield wait_if_held("search", cancellable);
            return results;
        }
    }

    private SearchService service(bool typed = false, bool legacy = false) throws Error {
        string path = Path.build_filename(Environment.get_user_data_dir(), "search-" + Uuid.string_random() + ".db");
        DirUtils.create_with_parents(Environment.get_user_data_dir(), 0700);
        var interactor = new StreamInteractor.for_tests(new Database(path, "isolated-directory-test"));
        return new SearchService(interactor, form(typed, legacy));
    }

    private Account account() throws InvalidJidError {
        return new Account(new Jid("first@example.test"), "not-used") { enabled = true };
    }

    private Search.Form form(bool typed, bool legacy) throws Error {
        var query = new StanzaNode.build("query", Search.NS_URI).add_self_xmlns();
        if (legacy) {
            query.put_node(new StanzaNode.build("nick", Search.NS_URI));
            query.put_node(new StanzaNode.build("email", Search.NS_URI));
            return new Search.Form.from_query(query);
        }
        var x = new StanzaNode.build("x", DataForms.NS_URI)
            .add_self_xmlns().put_attribute("type", "form");
        x.put_node(field("FORM_TYPE", "hidden", "jabber:iq:search"));
        x.put_node(field("token", "hidden", "keep <token> & Привет"));
        var search = field("search", "text-single", "");
        search.put_attribute("label", "Search <name> & Пользователь");
        if (typed) search.put_node(new StanzaNode.build("required", DataForms.NS_URI));
        x.put_node(search);
        if (typed) {
            x.put_node(field("exact", "boolean", "0").put_attribute("label", "Exact <match>"));
            var category = field("category", "list-single", "local").put_attribute("label", "Category");
            foreach (string option in new string[] { "local", "all" }) {
                category.put_node(new StanzaNode.build("option", DataForms.NS_URI)
                    .put_attribute("label", option).put_node(new StanzaNode.build("value", DataForms.NS_URI)
                    .put_node(new StanzaNode.text(option))));
            }
            x.put_node(category);
        }
        query.put_node(x);
        return new Search.Form.from_query(query);
    }

    private StanzaNode field(string name, string type, string value) {
        return new StanzaNode.build("field", DataForms.NS_URI).put_attribute("var", name)
            .put_attribute("type", type).put_node(new StanzaNode.build("value", DataForms.NS_URI)
            .put_node(new StanzaNode.text(value)));
    }

    private void wait_for(Ready ready, string message) {
        int64 deadline = get_monotonic_time() + 2 * TimeSpan.SECOND;
        while (!ready() && get_monotonic_time() < deadline) {
            MainContext.default().iteration(false);
            Thread.usleep(1000);
        }
        fail_if_not(ready(), message);
    }

    private void ready(UserSearchDialog dialog) {
        wait_for(() => dialog.search_control.sensitive && !dialog.activity_control.spinning,
            "server form should enable the search control and stop the spinner");
    }

    private void test_terminal_states() {
        try {
            var absent = service();
            absent.service = null;
            var dialog = new UserSearchDialog.with_service(absent, account());
            wait_for(() => dialog.retry_control.visible, "no directory must finish discovery");
            fail_if_not_eq_str(_("This server does not provide a searchable user directory. You can add a contact by their XMPP address."), dialog.status_control.label);
            fail_if(dialog.activity_control.spinning || dialog.activity_control.visible);
            fail_if(dialog.search_control.sensitive);
            fail_if_not_eq_int(0, absent.form_calls);
            dialog.closed();

            var failed = service();
            failed.error_stage = "form";
            dialog = new UserSearchDialog.with_service(failed, account());
            wait_for(() => dialog.retry_control.visible, "form failure must finish discovery");
            fail_if_not_eq_str(_("The server directory could not process this request. Try again later."), dialog.status_control.label);
            fail_if(dialog.activity_control.spinning || dialog.search_control.sensitive);
            fail_if_not_eq_int(1, failed.form_calls);
            dialog.closed();

            var timeout = service();
            timeout.error_stage = "form";
            timeout.timeout_error = true;
            dialog = new UserSearchDialog.with_service(timeout, account());
            wait_for(() => dialog.retry_control.visible, "IQ timeout must finish the request");
            fail_if_not_eq_str(_("The server directory did not respond. Check your connection and try again."), dialog.status_control.label);
            fail_if(dialog.activity_control.spinning || dialog.search_control.sensitive);
            dialog.closed();
        } catch (Error error) { fail_if_reached(error.message); }
    }

    private void test_typed_form() {
        try {
            var backend = service(true);
            var current_account = account();
            var dialog = new UserSearchDialog.with_service(backend, current_account);
            ready(dialog);
            var input = dialog.form_widgets.get_first_child() as Adw.EntryRow;
            var toggle_row = ((!) input).get_next_sibling() as Adw.ActionRow;
            var category = ((!) toggle_row).get_next_sibling() as Adw.ComboRow;
            if (fail_if(input == null || toggle_row == null || category == null)) return;
            fail_if(((!) input).use_markup);
            fail_if_not_eq_str("Search <name> & Пользователь *", ((!) input).title);
            dialog.search_control.clicked();
            fail_if_not_eq_int(0, backend.search_calls);
            fail_if_not_eq_str(_("Fill in the required search fields."), dialog.status_control.label);
            ((!) input).text = "Alice <name> & Привет";
            var toggle = ((!) toggle_row).activatable_widget as Gtk.Switch;
            if (fail_if(toggle == null)) return;
            ((!) toggle).active = true;
            ((!) category).selected = 1;
            dialog.search_control.clicked();
            wait_for(() => backend.search_calls == 1 && !dialog.activity_control.spinning, "typed search must complete");
            fail_if(backend.requested_account != current_account);
            fail_if_not_eq_str("users.example.test", backend.requested_service.to_string());
            var submitted = backend.submitted_query.get_subnode("x", DataForms.NS_URI);
            fail_if_not_eq_str("submit", submitted.get_attribute("type"));
            fail_if_not_eq_str("jabber:iq:search", value(submitted, "FORM_TYPE"));
            fail_if_not_eq_str("keep <token> & Привет", value(submitted, "token"));
            fail_if_not_eq_str("Alice <name> & Привет", value(submitted, "search"));
            fail_if_not_eq_str("1", value(submitted, "exact"));
            fail_if_not_eq_str("all", value(submitted, "category"));
            fail_if_not_eq_str("form", backend.form.kind);
            dialog.closed();
        } catch (Error error) { fail_if_reached(error.message); }
    }

    private string value(StanzaNode node, string name) {
        foreach (StanzaNode field in node.get_subnodes("field", DataForms.NS_URI)) {
            if (field.get_attribute("var") == name) return field.get_deep_string_content("value") ?? "";
        }
        return "";
    }

    private void test_directory_translations() {
        try {
            string[] names = { "user", "fn", "first", "middle", "last", "nick",
                "bday", "ctry", "locality", "email", "orgname", "orgunit", "custom", "search" };
            string[] labels = { "User", "Full Name", "Name", "Middle Name", "Family Name", "Nickname",
                "Birthday", "Country", "City", "Email", "Organization Name", "Organization Unit",
                "Unknown <field> & Имя", "" };
            string[] titles = { _("Username"), _("Full Name"), _("First name"), _("Middle Name"),
                _("Last name"), _("Nickname"), _("Birthday"), _("Country"), _("City"), _("Email"),
                _("Organization Name"), _("Organization Unit"), "Unknown <field> & Имя", _("Search term") };
            string sql_instruction = "Fill in the form to search for any matching XMPP User (Add * to the end of field to match substring)";
            string[] instructions = { sql_instruction,
                "Fill in the form to search for any matching XMPP User", "Ищи <b>только</b> & here" };
            string[] displayed_instructions = { _(sql_instruction),
                _("Fill in the form to search for any matching XMPP User"), "Ищи <b>только</b> & here" };
            foreach (string instruction in instructions) {
                var query = new StanzaNode.build("query", Search.NS_URI).add_self_xmlns();
                var x = new StanzaNode.build("x", DataForms.NS_URI).add_self_xmlns().put_attribute("type", "form");
                x.put_node(field("FORM_TYPE", "hidden", "jabber:iq:search"));
                x.put_node(field("token", "hidden", "Country"));
                x.put_node(new StanzaNode.build("instructions", DataForms.NS_URI)
                    .put_node(new StanzaNode.text(instruction)));
                for (int i = 0; i < names.length; i++) {
                    var node = field(names[i], "text-single", "Full Name <Привет> & *");
                    if (labels[i] != "") node.put_attribute("label", labels[i]);
                    if (i == 0 || i == names.length - 1) {
                        node.put_node(new StanzaNode.build("required", DataForms.NS_URI));
                    }
                    x.put_node(node);
                }
                query.put_node(x);
                string original_form = query.to_xml();
                var backend = service();
                backend.form = new Search.Form.from_query(query);
                var dialog = new UserSearchDialog.with_service(backend, account());
                ready(dialog);
                var help = dialog.form_widgets.get_first_child() as Label;
                if (fail_if(help == null)) return;
                int instruction_index = instruction == instructions[0] ? 0 : (instruction == instructions[1] ? 1 : 2);
                fail_if_not_eq_str(displayed_instructions[instruction_index], ((!) help).label);
                fail_if(((!) help).use_markup);
                Widget? widget = ((!) help).get_next_sibling();
                for (int i = 0; i < names.length; i++) {
                    var row = widget as Adw.EntryRow;
                    if (fail_if(row == null)) return;
                    string suffix = i == 0 || i == names.length - 1 ? " *" : "";
                    fail_if_not_eq_str(titles[i] + suffix, ((!) row).title);
                    fail_if_not_eq_str("Full Name <Привет> & *", ((!) row).text);
                    fail_if(((!) row).use_markup);
                    widget = ((!) row).get_next_sibling();
                }
                fail_if_not_eq_str(original_form, query.to_xml(), "display translation must preserve server metadata and values");
                dialog.search_control.clicked();
                ready(dialog);
                var submitted = backend.submitted_query.get_subnode("x", DataForms.NS_URI);
                fail_if_not_eq_str("Country", value(submitted, "token"));
                fail_if_not_eq_str("jabber:iq:search", value(submitted, "FORM_TYPE"));
                foreach (string name in names) {
                    fail_if_not_eq_str("Full Name <Привет> & *", value(submitted, name));
                }
                fail_if_not_eq_str(original_form, query.to_xml());
                dialog.closed();
            }
        } catch (Error error) { fail_if_reached(error.message); }
    }

    private void test_duplicate_search() {
        try {
            var backend = service();
            backend.hold_stage = "search";
            var dialog = new UserSearchDialog.with_service(backend, account());
            ready(dialog);
            var input = dialog.form_widgets.get_first_child() as Adw.EntryRow;
            ((!) input).text = "Alice";
            dialog.search_control.clicked();
            wait_for(() => backend.search_calls == 1, "first search must reach the service");
            fail_if_not(dialog.activity_control.spinning);
            fail_if(dialog.search_control.sensitive);
            dialog.search_control.clicked();
            ((!) input).entry_activated();
            fail_if_not_eq_int(1, backend.search_calls);
            backend.release();
            ready(dialog);
            fail_if_not_eq_str(_("No users found."), dialog.status_control.label);
            fail_if_not_eq_int(1, backend.discovery_calls);
            fail_if_not_eq_int(1, backend.search_calls);
            dialog.closed();
        } catch (Error error) { fail_if_reached(error.message); }
    }

    private void test_timeout() {
        try {
            var backend = service();
            backend.hold_stage = "search";
            var dialog = new UserSearchDialog.with_service(backend, account(), null, 40);
            ready(dialog);
            dialog.search_control.clicked();
            wait_for(() => backend.search_calls == 1, "search must start");
            Cancellable token = (!) backend.observed_cancellable;
            wait_for(() => token.is_cancelled(), "deadline must cancel the underlying request");
            fail_if(dialog.activity_control.spinning || dialog.activity_control.visible);
            fail_if_not(dialog.search_control.sensitive);
            fail_if_not_eq_str(_("The server directory did not respond. Check your connection and try again."), dialog.status_control.label);
            backend.results.add(new Search.Item() { jid = new Jid("late@example.test") });
            backend.release();
            // Resume callbacks run in the main context; they must leave the
            // timeout message intact and must not publish their late result.
            for (int i = 0; i < 20; i++) MainContext.default().iteration(false);
            fail_if(dialog.result_widgets.get_first_child() != null);
            fail_if_not_eq_str(_("The server directory did not respond. Check your connection and try again."), dialog.status_control.label);
            backend.results.clear();
            backend.hold_stage = null;
            dialog.search_control.clicked();
            wait_for(() => backend.search_calls == 2 && !dialog.activity_control.spinning, "user retry must use a new single request");
            fail_if_not_eq_str(_("No users found."), dialog.status_control.label);
            fail_if_not_eq_int(1, backend.discovery_calls);
            dialog.closed();
        } catch (Error error) { fail_if_reached(error.message); }
    }

    private void test_close() {
        try {
            var backend = service();
            backend.hold_stage = "discovery";
            var dialog = new UserSearchDialog.with_service(backend, account());
            wait_for(() => backend.discovery_calls == 1, "discovery must start");
            Cancellable token = (!) backend.observed_cancellable;
            dialog.closed();
            fail_if_not(token.is_cancelled());
            fail_if(dialog.activity_control.spinning || dialog.activity_control.visible);
            backend.release();
            for (int i = 0; i < 20; i++) MainContext.default().iteration(false);
            fail_if_not_eq_int(0, backend.form_calls);
            fail_if(dialog.form_widgets.get_first_child() != null);
            dialog.search_control.clicked();
            dialog.retry_control.clicked();
            fail_if_not_eq_int(1, backend.discovery_calls);
        } catch (Error error) { fail_if_reached(error.message); }
    }

    private void test_results() {
        try {
            var backend = service();
            backend.error_stage = "search";
            var dialog = new UserSearchDialog.with_service(backend, account());
            ready(dialog);
            dialog.search_control.clicked();
            wait_for(() => backend.search_calls == 1 && !dialog.activity_control.spinning, "server error must finish search");
            fail_if_not_eq_str(_("The server directory could not process this request. Try again later."), dialog.status_control.label);
            fail_if_not_eq_int(1, backend.discovery_calls);
            backend.error_stage = null;
            var item = new Search.Item() { jid = new Jid("alice@example.test") };
            item.fields["name"] = "<b>Alice</b> & Привет";
            backend.results.add(item);
            dialog.search_control.clicked();
            wait_for(() => backend.search_calls == 2 && !dialog.activity_control.spinning, "explicit retry should show results");
            var row = dialog.result_widgets.get_row_at_index(0) as Adw.ActionRow;
            if (fail_if(row == null)) return;
            fail_if(((!) row).use_markup);
            fail_if_not_eq_str("name: <b>Alice</b> & Привет", ((!) row).subtitle);
            fail_if_not_eq_int(1, backend.discovery_calls);
            dialog.closed();
        } catch (Error error) { fail_if_reached(error.message); }
    }

    private void test_legacy_form() {
        try {
            var backend = service(false, true);
            backend.hold_stage = "search";
            var dialog = new UserSearchDialog.with_service(backend, account(), "Alice");
            wait_for(() => backend.search_calls == 1, "prefilled legacy nick search should start once");
            fail_if_not(backend.form.is_legacy_form);
            fail_if_not_eq_int(2, backend.form.fields.size);
            fail_if(backend.submitted_query.get_subnode("x", DataForms.NS_URI) != null);
            fail_if_not_eq_str("Alice", backend.submitted_query.get_deep_string_content("nick"));
            fail_if(backend.submitted_query.get_subnode("email", Search.NS_URI) != null,
                "one term must not be copied into every legacy form field");
            backend.release();
            ready(dialog);
            dialog.closed();
        } catch (Error error) { fail_if_reached(error.message); }
    }

    private class RetainedControls : Object {
        public Button search;
        public Button retry;
        public Box form;
        public ListBox results;
        public Label status;
        public Gtk.Spinner activity;
        public Adw.EntryRow? entry;

        public RetainedControls(UserSearchDialog dialog) {
            search = dialog.search_control;
            retry = dialog.retry_control;
            form = dialog.form_widgets;
            results = dialog.result_widgets;
            status = dialog.status_control;
            activity = dialog.activity_control;
            entry = form.get_first_child() as Adw.EntryRow;
        }
    }

    private RetainedControls create_closed_dialog(SearchService backend,
            string? held_stage, ref WeakRef dialog_weak) throws Error {
        backend.hold_stage = held_stage;
        var dialog = new UserSearchDialog.with_service(backend, account());
        if (held_stage == "discovery") {
            wait_for(() => backend.discovery_calls == 1,
                "lifetime fixture must suspend directory discovery");
        } else if (held_stage == "form") {
            wait_for(() => backend.form_calls == 1,
                "lifetime fixture must suspend the form request");
        } else {
            ready(dialog);
            backend.results.add(new Search.Item() { jid = new Jid("alice@example.test") });
            dialog.search_control.clicked();
            if (held_stage == "search") {
                wait_for(() => backend.search_calls == 1,
                    "lifetime fixture must suspend the search request");
            } else {
                ready(dialog);
                fail_if_not(dialog.result_widgets.get_first_child() != null,
                    "completed lifetime fixture must retain result controls as well as form controls");
            }
        }
        var controls = new RetainedControls(dialog);
        // Register this stable weak-ref before dropping the only external
        // dialog reference on return. Do not force dispose or disconnect the
        // production signals: retained controls must not keep the dialog alive.
        dialog_weak.set(dialog);
        dialog.closed();
        if (held_stage != null) {
            fail_if_not(backend.observed_cancellable != null &&
                ((!) backend.observed_cancellable).is_cancelled(),
                "closing must cancel the held directory request");
        }
        fail_if(controls.activity.spinning || controls.activity.visible);
        return controls;
    }

    private void assert_dialog_released(ref WeakRef dialog_weak, string message) {
        int64 deadline = get_monotonic_time() + 2 * TimeSpan.SECOND;
        while (dialog_weak.get() != null && get_monotonic_time() < deadline) {
            MainContext.default().iteration(false);
            Thread.usleep(1000);
        }
        fail_if(dialog_weak.get() != null, message);
    }

    private void test_lifetime() {
        try {
            foreach (string stage in new string[] { "complete", "discovery", "form", "search" }) {
                var backend = service();
                // GLib registers the GWeakRef's address. Keep it on this stack
                // and pass by reference rather than copying an initialized one.
                WeakRef dialog_weak = WeakRef(null);
                var controls = create_closed_dialog(backend,
                    stage == "complete" ? null : stage, ref dialog_weak);
                string closed_status = controls.status.label;
                int discovery_calls = backend.discovery_calls;
                int form_calls = backend.form_calls;
                int search_calls = backend.search_calls;
                backend.release();
                assert_dialog_released(ref dialog_weak,
                    "closed directory dialog must release despite retained controls and a late " + stage + " callback");
                controls.search.clicked();
                controls.retry.clicked();
                if (controls.entry != null) ((!) controls.entry).entry_activated();
                for (int i = 0; i < 20; i++) MainContext.default().iteration(false);
                fail_if_not_eq_int(discovery_calls, backend.discovery_calls);
                fail_if_not_eq_int(form_calls, backend.form_calls);
                fail_if_not_eq_int(search_calls, backend.search_calls);
                fail_if_not_eq_str(closed_status, controls.status.label);
                fail_if(controls.activity.spinning || controls.activity.visible);
                if (stage == "discovery" || stage == "form") {
                    fail_if(controls.form.get_first_child() != null,
                        "late discovery and form callbacks must not populate a closed dialog");
                }
                if (stage != "complete") {
                    fail_if(controls.results.get_first_child() != null,
                        "late search results must not populate a closed dialog");
                }
            }
        } catch (Error error) { fail_if_reached(error.message); }
    }
}

}
