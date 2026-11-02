using Gtk;
using Adw;
using Dino.Entities;
using Xmpp;
using Gee;

namespace Dino.Ui {

public class UserSearchDialog : Adw.Dialog {
    private Account account;
    private UserSearch user_search;
    private Jid? search_component_jid;
    private Xmpp.Xep.Search.Form? search_form;
    private string? initial_query;
    private Box form_box;
    private ListBox results_list;
    private Button search_button;
    private Button retry_button;
    private Label directory_hint;
    private Label status_label;
    private Gtk.Spinner spinner;
    private Cancellable? request_cancellable;
    private uint deadline_source = 0;
    private uint request_generation = 0;
    private uint request_timeout_ms = 25000;
    private bool dialog_closed = false;
    private Gee.List<ViewModel.PreferencesRow.Any> field_models = new ArrayList<ViewModel.PreferencesRow.Any>();

    public signal void contact_selected(Jid jid);

    public UserSearchDialog(StreamInteractor stream_interactor, Account account, string? initial_query = null) {
        initialize(new UserSearch(stream_interactor), account, initial_query);
    }

    // The runtime tests inject a service, exercising the production controls
    // without connecting to a server or changing any user account.
    internal UserSearchDialog.with_service(UserSearch service, Account account,
            string? initial_query = null, uint request_timeout_ms = 25000) {
        this.request_timeout_ms = request_timeout_ms;
        initialize(service, account, initial_query);
    }

    private void initialize(UserSearch service, Account account, string? initial_query) {
        this.account = account;
        this.user_search = service;
        this.initial_query = initial_query;
        title = _("Search server directory");
        content_width = 500;
        content_height = 600;
        setup_ui();
        closed.connect(on_closed);
        unmap.connect(on_unmapped);
        initialize_search();
    }

    private void setup_ui() {
        var toolbar_view = new Adw.ToolbarView();
        var header_bar = new Adw.HeaderBar() { decoration_layout = ":" };
        toolbar_view.add_top_bar(header_bar);
        var close_button = new Button.with_label(_("Close"));
        connect_close_button(close_button, this);
        header_bar.pack_start(close_button);

        var content_box = new Box(Orientation.VERTICAL, 12) {
            margin_top = 12, margin_bottom = 12, margin_start = 12, margin_end = 12
        };
        directory_hint = new Label(_("Search a directory provided by your server, not your saved contacts.")) {
            wrap = true, xalign = 0
        };
        directory_hint.add_css_class("dim-label");
        content_box.append(directory_hint);
        status_label = new Label("") { wrap = true, xalign = 0, visible = false };
        content_box.append(status_label);
        spinner = new Gtk.Spinner() { visible = false, halign = Align.CENTER };
        content_box.append(spinner);

        var scrolled = new ScrolledWindow() { vexpand = true };
        var search_content = new Box(Orientation.VERTICAL, 12);
        form_box = new Box(Orientation.VERTICAL, 6);
        search_content.append(form_box);
        search_button = new Button.with_label(_("Search")) { sensitive = false };
        search_button.add_css_class("suggested-action");
        connect_search_button(search_button, this);
        search_content.append(search_button);
        retry_button = new Button.with_label(_("Try again")) { visible = false };
        connect_retry_button(retry_button, this);
        search_content.append(retry_button);
        results_list = new ListBox() { selection_mode = SelectionMode.NONE };
        results_list.add_css_class("boxed-list");
        search_content.append(results_list);
        scrolled.child = search_content;
        content_box.append(scrolled);
        toolbar_view.content = content_box;
        child = toolbar_view;
        set_default_widget(search_button);
    }

    // Static helpers are intentional. Vala captures an instance method's
    // implicit `this` in its closure block even when the lambda uses WeakRef.
    // Child controls and the deadline must not keep their owning dialog alive.
    private static void connect_close_button(Button button, UserSearchDialog owner) {
        var weak_dialog = WeakRef(owner);
        button.clicked.connect(() => {
            var dialog = weak_dialog.get() as UserSearchDialog;
            if (dialog != null) dialog.close();
        });
    }

    private static void connect_search_button(Button button, UserSearchDialog owner) {
        var weak_dialog = WeakRef(owner);
        button.clicked.connect(() => {
            var dialog = weak_dialog.get() as UserSearchDialog;
            if (dialog != null) dialog.on_search_clicked();
        });
    }

    private static void connect_retry_button(Button button, UserSearchDialog owner) {
        var weak_dialog = WeakRef(owner);
        button.clicked.connect(() => {
            var dialog = weak_dialog.get() as UserSearchDialog;
            if (dialog != null) dialog.initialize_search();
        });
    }

    private static void connect_entry_row(Adw.EntryRow row, UserSearchDialog owner) {
        var weak_dialog = WeakRef(owner);
        row.entry_activated.connect(() => {
            var dialog = weak_dialog.get() as UserSearchDialog;
            if (dialog != null) dialog.on_search_clicked();
        });
    }

    private static void connect_result_button(Button button, UserSearchDialog owner, Jid jid) {
        var weak_dialog = WeakRef(owner);
        button.clicked.connect(() => {
            var dialog = weak_dialog.get() as UserSearchDialog;
            if (dialog == null || dialog.dialog_closed || dialog.busy) return;
            dialog.contact_selected(jid);
            dialog.close();
        });
    }

    private static uint attach_deadline(UserSearchDialog owner, uint generation, uint timeout_ms) {
        var weak_dialog = WeakRef(owner);
        return Timeout.add(timeout_ms, () => {
            var dialog = weak_dialog.get() as UserSearchDialog;
            if (dialog != null) dialog.on_deadline(generation);
            return Source.REMOVE;
        });
    }

    private void on_deadline(uint generation) {
        if (!is_current_request(generation)) return;
        deadline_source = 0;
        Cancellable cancellable = (!) request_cancellable;
        finish_request(generation);
        set_status(_("The server directory did not respond. Check your connection and try again."));
        retry_button.visible = search_form == null;
        // Cancel the actual IQ, removing its pending XMPP response handler.
        cancellable.cancel();
    }

    private bool busy { get { return request_cancellable != null; } }

    private uint begin_request(string message) {
        request_generation++;
        request_cancellable = new Cancellable();
        search_button.sensitive = false;
        retry_button.visible = false;
        form_box.sensitive = false;
        results_list.sensitive = false;
        set_status(message);
        spinner.visible = true;
        spinner.start();
        uint generation = request_generation;
        deadline_source = attach_deadline(this, generation, request_timeout_ms);
        return generation;
    }

    private bool is_current_request(uint generation) {
        return !dialog_closed && request_generation == generation && busy;
    }

    private void finish_request(uint generation) {
        if (!is_current_request(generation)) return;
        if (deadline_source != 0) {
            Source.remove(deadline_source);
            deadline_source = 0;
        }
        request_cancellable = null;
        spinner.stop();
        spinner.visible = false;
        form_box.sensitive = true;
        results_list.sensitive = true;
        search_button.sensitive = search_form != null;
    }

    private void set_status(string message) {
        status_label.label = message;
        status_label.visible = message != "";
    }

    private void clear_form() {
        Widget? child;
        while ((child = form_box.get_first_child()) != null) form_box.remove(child);
        field_models.clear();
        search_form = null;
        search_component_jid = null;
    }

    private void clear_results() {
        ListBoxRow? row;
        while ((row = results_list.get_row_at_index(0)) != null) results_list.remove(row);
    }

    private void initialize_search() {
        if (dialog_closed || busy) return;
        clear_form();
        clear_results();
        search_button.sensitive = false;
        init_search.begin();
    }

    private async void init_search() {
        uint generation = begin_request(_("Looking for a server directory…"));
        Cancellable cancellable = (!) request_cancellable;
        try {
            Jid? service = yield user_search.find_search_component(account, cancellable);
            if (!is_current_request(generation)) return;
            finish_request(generation);
            if (service == null) {
                set_status(_("This server does not provide a searchable user directory. You can add a contact by their XMPP address."));
                retry_button.visible = true;
                return;
            }
            search_component_jid = service;
            directory_hint.label = _("Directory: %s\nAccount: %s\nThis searches the server directory, not your saved contacts.").printf(
                service.to_string(), account.bare_jid.to_string());
            generation = begin_request(_("Loading the search form…"));
            cancellable = (!) request_cancellable;
            var form = yield user_search.get_search_fields(account, (!) service, cancellable);
            if (!is_current_request(generation)) return;
            bool query_applied = build_form_ui(form);
            finish_request(generation);
            set_status("");
            initial_query = null;
            if (query_applied) on_search_clicked();
        } catch (Error error) {
            if (!is_current_request(generation)) return;
            finish_request(generation);
            clear_form();
            search_button.sensitive = false;
            show_request_error(error);
            retry_button.visible = true;
        }
    }

    private void show_request_error(Error error) {
        if (error is IOError.TIMED_OUT) {
            set_status(_("The server directory did not respond. Check your connection and try again."));
        } else if (error is IOError.NOT_CONNECTED || error is IOError.CLOSED) {
            set_status(_("Connect this account before searching its server directory."));
        } else {
            set_status(_("The server directory could not process this request. Try again later."));
        }
    }

    private bool build_form_ui(Xmpp.Xep.Search.Form form) throws Error {
        // Prefer an explicit query field. Filling every name and email field
        // would turn a single search term into several unintended conditions.
        Xmpp.Xep.DataForms.DataForm.TextSingleField? query_field = null;
        foreach (var field in form.fields) {
            if (field is Xmpp.Xep.DataForms.DataForm.TextSingleField && is_query_field(field.var)) {
                if (query_field == null || field.var == "search") {
                    query_field = (Xmpp.Xep.DataForms.DataForm.TextSingleField) field;
                }
                if (field.var == "search") break;
            }
        }
        bool query_applied = initial_query != null && initial_query != "" && query_field != null;
        if (query_applied) ((!) query_field).value = (!) initial_query;
        if (form.instructions != null && form.instructions != "") {
            form_box.append(new Label(translate_known_search_text(form.instructions) ?? form.instructions) {
                wrap = true, xalign = 0
            });
        }
        foreach (var field in form.fields) {
            if (field.type_ == Xmpp.Xep.DataForms.DataForm.Type.HIDDEN) continue;
            var model = Util.get_data_form_field_view_model(field);
            if (model == null) {
                throw new IOError.NOT_SUPPORTED("Unsupported server search field type");
            }
            // Translate display metadata only. Keep the original server schema
            // and entered values for submission, including unknown labels.
            string? display_label = translate_known_search_text(field.label);
            if (field.var == "first" && field.label == "Name") display_label = _("First name");
            if (field.label == null || field.label == "") display_label = field_label(field.var);
            if (display_label != null) {
                model.title = display_label + (field.required && display_label != "" ? " *" : "");
            }
            field_models.add(model);
            var row = Util.row_to_preference_row(model, false);
            if (row == null) throw new IOError.NOT_SUPPORTED("Unsupported server search control");
            if (row is Adw.EntryRow) {
                ((Adw.EntryRow) row).show_apply_button = false;
                connect_entry_row((Adw.EntryRow) row, this);
            }
            form_box.append(row);
        }
        search_form = form;
        return query_applied;
    }

    private static bool is_query_field(string? name) {
        return name == "search" || name == "first" || name == "last" || name == "nick" || name == "email";
    }

    // These are known directory labels and ejabberd instructions, not user
    // content. A null result preserves the server's original display text.
    private static string? translate_known_search_text(string? text) {
        switch (text) {
            case "User": return _("Username");
            case "Full Name": return _("Full Name");
            case "First Name":
            case "Given Name": return _("First name");
            case "Middle Name": return _("Middle Name");
            case "Family Name":
            case "Last Name": return _("Last name");
            case "Birthday": return _("Birthday");
            case "Country": return _("Country");
            case "Organization Name": return _("Organization Name");
            case "Organization Unit": return _("Organization Unit");
            case "Fill in the form to search for any matching XMPP User":
                return _("Fill in the form to search for any matching XMPP User");
            case "Fill in the form to search for any matching XMPP User (Add * to the end of field to match substring)":
                return _("Fill in the form to search for any matching XMPP User (Add * to the end of field to match substring)");
            default: return null;
        }
    }

    private static string field_label(string? name) {
        switch (name) {
            case "first": return _("First name");
            case "last": return _("Last name");
            case "nick": return _("Nickname");
            case "email": return _("Email");
            case "search": return _("Search term");
            default: return name ?? "";
        }
    }

    private void on_search_clicked() {
        if (dialog_closed || busy || search_form == null || search_component_jid == null) return;
        // Multiline controls write back when their editor closes. The typed
        // entry, boolean and list models already bind to this original form.
        if (!((!) search_form).get_missing_required_fields().is_empty) {
            set_status(_("Fill in the required search fields."));
            return;
        }
        clear_results();
        do_search.begin();
    }

    private async void do_search() {
        uint generation = begin_request(_("Searching the server directory…"));
        Cancellable cancellable = (!) request_cancellable;
        try {
            var results = yield user_search.perform_search(account, (!) search_component_jid,
                (!) search_form, cancellable);
            if (!is_current_request(generation)) return;
            finish_request(generation);
            show_results(results);
        } catch (Error error) {
            if (!is_current_request(generation)) return;
            finish_request(generation);
            show_request_error(error);
        }
    }

    private void show_results(Gee.List<Xmpp.Xep.Search.Item> results) {
        clear_results();
        set_status(results.is_empty ? _("No users found.") : "");
        foreach (var item in results) {
            var row = new Adw.ActionRow() { use_markup = false, title = item.jid.to_string() };
            var details = new StringBuilder();
            foreach (var field in item.fields.entries) {
                if (field.key == "jid") continue;
                if (details.len > 0) details.append("\n");
                details.append_printf("%s: %s", field.key, field.value);
            }
            row.subtitle = details.str;
            row.subtitle_lines = 0;
            var add_button = new Button.from_icon_name("list-add-symbolic") {
                valign = Align.CENTER, tooltip_text = _("Use this XMPP address")
            };
            add_button.add_css_class("flat");
            connect_result_button(add_button, this, item.jid);
            row.add_suffix(add_button);
            results_list.append(row);
        }
    }

    private void on_closed() {
        if (dialog_closed) return;
        dialog_closed = true;
        request_generation++;
        if (deadline_source != 0) {
            Source.remove(deadline_source);
            deadline_source = 0;
        }
        Cancellable? cancellable = request_cancellable;
        request_cancellable = null;
        if (cancellable != null) ((!) cancellable).cancel();
        spinner.stop();
        spinner.visible = false;
    }

    private void on_unmapped() {
        // Older libadwaita uses a plain Gtk.Window host for these dialogs.
        // A nested dialog temporarily hides its parent, which is not a close.
        Gtk.Root? root = get_root();
        if (root is Gtk.Window && !(root is Adw.Window) && !(root is Adw.ApplicationWindow) &&
                !((Gtk.Window) root).get_visible()) on_closed();
    }

    public override void dispose() {
        on_closed();
        base.dispose();
    }

    internal Box form_widgets { get { return form_box; } }
    internal ListBox result_widgets { get { return results_list; } }
    internal Button search_control { get { return search_button; } }
    internal Button retry_control { get { return retry_button; } }
    internal Label status_control { get { return status_label; } }
    internal Gtk.Spinner activity_control { get { return spinner; } }
}

}
