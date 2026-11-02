using Dino.Entities;
using Dino.Ui.ViewModel;
using Gee;
using Gtk;
using Xmpp;

namespace Dino.Ui.Test {

class ContactSelectionViewRuntimeTest : Gee.TestCase {
    public ContactSelectionViewRuntimeTest() {
        base("ContactSelectionViewRuntime");
        add_test("initial_contact_is_not_autoselected_before_binding",
            test_initial_contact_is_not_autoselected_before_binding);
    }

    private void test_initial_contact_is_not_autoselected_before_binding() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-contact-selection-view-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;
        ContactSelectionView? view = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "contact-selection-view-runtime-test");
            var stream_interactor = new StreamInteractor.for_tests((!) db);
            var account = new Account(new Jid("account@example.test"), "secret") {
                id = 501,
                enabled = true
            };
            var accounts = new ArrayList<Account>();
            accounts.add(account);
            var contacts = new ContactListModel();
            contacts.upsert(account, new Jid("first@example.test"), "First Contact");

            view = new ContactSelectionView(stream_interactor, accounts, contacts);
            ((!) view).set_filter("");
            ListView? list_view = find_contact_list_view((!) view);
            if (list_view == null) {
                fail_if(true, "the contact ListView must exist");
                return;
            }
            SingleSelection? selection = ((!) list_view).model as SingleSelection;
            if (selection == null) {
                fail_if(true, "the contact ListView must use SingleSelection");
                return;
            }
            SingleSelection contact_selection = (!) selection;
            fail_if(contact_selection.selected != Gtk.INVALID_LIST_POSITION,
                "contact 0 must not be selected before the user chooses a row");
            fail_if(((!) view).done || ((!) view).selected_account != null ||
                    ((!) view).selected_jid != null,
                "the view must not publish a choice during construction");

            fail_if_not_eq_int(1, (int) contact_selection.get_n_items(),
                "the first contact must be available after model initialisation");
            int choice_changed_count = 0;
            ((!) view).choice_changed.connect(() => choice_changed_count++);
            contact_selection.set_selected(0);
            fail_if_not_eq_int(1, choice_changed_count,
                "the first user selection must publish exactly one choice");
            fail_if(!((!) view).done || ((!) view).selected_account != account ||
                    ((!) view).selected_jid == null ||
                    !((!) view).selected_jid.equals_bare(new Jid("first@example.test")),
                "the first user selection must become the active contact choice");
        } catch (Error error) {
            GLib.Test.message("Unexpected contact selection view error: %s", error.message);
            GLib.Test.fail();
        } finally {
            if (view != null) ((!) view).deactivate();
            if (db != null) ((!) db).close();
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-shm");
            FileUtils.remove(db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private ListView? find_contact_list_view(Widget widget) {
        if (widget is ListView) {
            SingleSelection? selection = ((ListView) widget).model as SingleSelection;
            GLib.ListModel? items = selection != null ? ((!) selection).model : null;
            if (items is SortListModel) {
                return (ListView) widget;
            }
        }
        Widget? child = widget.get_first_child();
        while (child != null) {
            ListView? found = find_contact_list_view((!) child);
            if (found != null) return found;
            child = ((!) child).get_next_sibling();
        }
        return null;
    }
}

}

namespace Dino.Ui {

/** Lightweight factory row for ContactSelectionView's lifecycle test. */
internal class ContactListViewRow : Object {
    private Label widget = new Label("");

    public Widget get_widget() {
        return widget;
    }

    public void bind(StreamInteractor stream_interactor, ContactListItem item,
            bool show_account_hint, bool show_jid_with_account_hint = false) {
    }

    public void unbind() {
    }

    public void cleanup() {
    }

    public void set_show_account_hint(bool show_account_hint) {
    }
}

}
