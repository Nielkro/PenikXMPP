using Dino.Entities;
using Dino.Ui.ViewModel;
using Xmpp;

namespace Dino.Ui.Test {

class ContactListSelectionModelTest : Gee.TestCase {

    public ContactListSelectionModelTest() {
        base("ContactListSelectionModel");

        add_test("initial_selection_is_empty", test_initial_selection_is_empty);
        add_test("filters_by_query_and_account", test_filters_by_query_and_account);
        add_test("alias_update_refilters", test_alias_update_refilters);
        add_test("alias_reorder_preserves_selection", test_alias_reorder_preserves_selection);
        add_test("disabled_account_and_remove_clear_selection", test_disabled_account_and_remove_clear_selection);
        add_test("empty_filtered_account_disable_resets_filter", test_empty_filtered_account_disable_resets_filter);
        add_test("query_notify_observes_updated_projection", test_query_notify_observes_updated_projection);
        add_test("hidden_selection_does_not_reappear", test_hidden_selection_does_not_reappear);
        add_test("insert_and_remove_before_selection_preserve_identity", test_insert_and_remove_before_selection_preserve_identity);
        add_test("activation_selects_exact_position", test_activation_selects_exact_position);
        add_test("projection_releases_callbacks", test_projection_releases_callbacks);
    }

    private void test_initial_selection_is_empty() {
        var contacts = new ContactListModel();
        Account account = make_account(100, "alice@example.test");
        contacts.upsert(account, make_jid("first@example.test"), "First");

        var projection = new ContactListSelectionModel(contacts);

        assert_true(projection.selection.autoselect == false);
        assert_true(projection.selection.can_unselect);
        assert_true(projection.selection.selected == Gtk.INVALID_LIST_POSITION,
            "a populated model must not select contact 0 during construction");
        assert_true(projection.selected_item == null,
            "the selection model must start without a selected contact");
    }

    private void test_filters_by_query_and_account() {
        var contacts = new ContactListModel();
        Account first_account = make_account(101, "first@example.test");
        Account second_account = make_account(102, "second@example.test");
        ContactListItem first = contacts.upsert(first_account, make_jid("shared@example.test"), "Alpha Person");
        ContactListItem second = contacts.upsert(second_account, make_jid("shared@example.test"), "Beta Person");
        contacts.upsert(first_account, make_jid("other@example.test"), "Other");
        var projection = new ContactListSelectionModel(contacts);

        fail_if_not_eq_int(3, (int) projection.items.get_n_items());
        projection.update_query("person");
        fail_if_not_eq_int(2, (int) projection.items.get_n_items());
        projection.update_account_filter(first_account);
        fail_if_not_eq_int(1, (int) projection.items.get_n_items());
        assert_true(projection.items.get_item(0) == first);
        assert_true(projection.items.get_item(0) != second);
    }

    private void test_alias_update_refilters() {
        var contacts = new ContactListModel();
        Account account = make_account(111, "alice@example.test");
        Jid jid = make_jid("contact@example.test");
        contacts.upsert(account, jid, "Before");
        var projection = new ContactListSelectionModel(contacts);

        projection.update_query("after");
        fail_if_not_eq_int(0, (int) projection.items.get_n_items());
        contacts.upsert(account, jid, "After");
        fail_if_not_eq_int(1, (int) projection.items.get_n_items());
    }

    private void test_alias_reorder_preserves_selection() {
        var contacts = new ContactListModel();
        Account account = make_account(121, "alice@example.test");
        ContactListItem alpha = contacts.upsert(account, make_jid("alpha@example.test"), "Alpha");
        ContactListItem zulu = contacts.upsert(account, make_jid("zulu@example.test"), "Zulu");
        var projection = new ContactListSelectionModel(contacts);

        assert_true(projection.select(zulu));
        assert_true(projection.selected_item == zulu);
        int transient_null_notifies = 0;
        projection.notify["selected-item"].connect(() => {
            if (projection.selected_item == null) transient_null_notifies++;
        });
        contacts.upsert(account, zulu.jid, "Aardvark");

        assert_true(projection.selected_item == zulu, "selection must follow the same GObject after sorting changes");
        assert_true(transient_null_notifies == 0,
                "sorting must not publish a transient null selection");
        assert_true(projection.items.get_item(0) == zulu);
        assert_true(projection.items.get_item(1) == alpha);
    }

    private void test_disabled_account_and_remove_clear_selection() {
        var contacts = new ContactListModel();
        Account account = make_account(131, "alice@example.test");
        ContactListItem item = contacts.upsert(account, make_jid("contact@example.test"), "Contact");
        var projection = new ContactListSelectionModel(contacts);

        assert_true(projection.select(item));
        account.enabled = false;
        fail_if_not_eq_int(0, (int) projection.items.get_n_items());
        assert_true(projection.selected_item == null);

        account.enabled = true;
        assert_true(projection.select(item));
        contacts.remove(account, item.jid);
        assert_true(projection.selected_item == null);
    }

    private void test_empty_filtered_account_disable_resets_filter() {
        var contacts = new ContactListModel();
        Account populated_account = make_account(132, "populated@example.test");
        Account empty_account = make_account(133, "empty@example.test");
        contacts.upsert(populated_account, make_jid("contact@example.test"), "Contact");
        var projection = new ContactListSelectionModel(contacts);

        projection.update_account_filter(empty_account);
        assert_true(projection.account_filter == empty_account);
        fail_if_not_eq_int(0, (int) projection.items.get_n_items());

        empty_account.enabled = false;
        assert_true(projection.account_filter == null,
                "a disabled empty account must not remain as a stale active filter");
        fail_if_not_eq_int(1, (int) projection.items.get_n_items());
    }

    private void test_query_notify_observes_updated_projection() {
        var contacts = new ContactListModel();
        Account account = make_account(135, "alice@example.test");
        contacts.upsert(account, make_jid("alpha@example.test"), "Alpha");
        contacts.upsert(account, make_jid("beta@example.test"), "Beta");
        var projection = new ContactListSelectionModel(contacts);
        int notify_count = 0;
        bool observed_consistent = false;
        projection.notify["query"].connect(() => {
            notify_count++;
            observed_consistent = projection.query == "alpha" && projection.items.get_n_items() == 1;
        });

        projection.update_query("alpha");
        fail_if_not_eq_int(1, notify_count);
        assert_true(observed_consistent, "notify::query must run after the filtered projection is current");
        projection.update_query("alpha");
        fail_if_not_eq_int(1, notify_count);
    }

    private void test_hidden_selection_does_not_reappear() {
        var contacts = new ContactListModel();
        Account account = make_account(136, "alice@example.test");
        ContactListItem alpha = contacts.upsert(account, make_jid("alpha@example.test"), "Alpha");
        contacts.upsert(account, make_jid("beta@example.test"), "Beta");
        var projection = new ContactListSelectionModel(contacts);

        assert_true(projection.select(alpha));
        projection.update_query("beta");
        assert_true(projection.selected_item == null);
        projection.update_query("");
        assert_true(projection.selected_item == null, "clearing the filter must not resurrect an invalidated selection");
    }

    private void test_insert_and_remove_before_selection_preserve_identity() {
        var contacts = new ContactListModel();
        Account account = make_account(137, "alice@example.test");
        Jid alpha_jid = make_jid("alpha@example.test");
        ContactListItem selected = contacts.upsert(account, make_jid("selected@example.test"), "Selected");
        var projection = new ContactListSelectionModel(contacts);

        assert_true(projection.select(selected));
        int transient_null_notifies = 0;
        projection.notify["selected-item"].connect(() => {
            if (projection.selected_item == null) transient_null_notifies++;
        });
        contacts.upsert(account, alpha_jid, "Alpha");
        assert_true(projection.selected_item == selected);
        contacts.remove(account, alpha_jid);
        assert_true(projection.selected_item == selected);
        assert_true(transient_null_notifies == 0,
                "inserting or removing another item must not publish a transient null selection");
        contacts.clear();
        assert_true(projection.selected_item == null);
    }

    private void test_projection_releases_callbacks() {
        var contacts = new ContactListModel();
        Account account = make_account(141, "alice@example.test");
        contacts.upsert(account, make_jid("before-release@example.test"), "Before release");
        WeakRef projection_ref = WeakRef(null);
        set_projection_weak_ref(contacts, ref projection_ref);

        assert_true(projection_ref.get() == null, "callback wiring must not retain the projection");
        account.enabled = false;
        account.enabled = true;
        contacts.upsert(account, make_jid("after-release@example.test"), "Still safe");
    }

    private void test_activation_selects_exact_position() {
        var contacts = new ContactListModel();
        Account account = make_account(138, "alice@example.test");
        ContactListItem alpha = contacts.upsert(account, make_jid("alpha@example.test"), "Alpha");
        ContactListItem beta = contacts.upsert(account, make_jid("beta@example.test"), "Beta");
        var projection = new ContactListSelectionModel(contacts);

        assert_true(projection.select(alpha));
        ContactListItem? activated = projection.activate_position(1);
        assert_true(activated == beta, "activation must resolve the item at the emitted ListView position");
        assert_true(projection.selected_item == beta,
                "activation must replace a stale previous selection before submitting");
        assert_true(projection.activate_position(2) == null, "out-of-range activation must be ignored");
        assert_true(projection.selected_item == beta, "invalid activation must not clear a valid selection");
    }

    private void set_projection_weak_ref(ContactListModel contacts, ref WeakRef projection_ref) {
        var projection = new ContactListSelectionModel(contacts);
        projection_ref.set(projection);
    }

    private Account make_account(int id, string jid) {
        var account = new Account(make_jid(jid), "secret");
        account.id = id;
        account.enabled = true;
        return account;
    }

    private Jid make_jid(string value) {
        try {
            return new Jid(value);
        } catch (InvalidJidError error) {
            GLib.Test.message("Invalid test JID %s: %s", value, error.message);
            GLib.Test.fail();
            assert_not_reached();
        }
    }
}

}
