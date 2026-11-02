using Dino.Entities;
using Dino.Ui.ViewModel;
using Xmpp;

namespace Dino.Ui.Test {

class ContactListModelTest : Gee.TestCase {

    public ContactListModelTest() {
        base("ContactListModel");

        add_test("upsert_preserves_identity_and_updates_alias", test_upsert_preserves_identity_and_updates_alias);
        add_test("blank_alias_falls_back_to_bare_jid", test_blank_alias_falls_back_to_bare_jid);
        add_test("invalid_utf8_alias_is_sanitized", test_invalid_utf8_alias_is_sanitized);
        add_test("same_jid_on_two_accounts_stays_distinct", test_same_jid_on_two_accounts_stays_distinct);
        add_test("full_and_bare_jid_share_identity", test_full_and_bare_jid_share_identity);
        add_test("remove_is_account_scoped", test_remove_is_account_scoped);
        add_test("filter_tracks_alias_and_jid", test_filter_tracks_alias_and_jid);
        add_test("unicode_filter_is_casefolded", test_unicode_filter_is_casefolded);
        add_test("unicode_filter_normalizes_composed_forms", test_unicode_filter_normalizes_composed_forms);
        add_test("unicode_filter_matches_cyrillic_composed_forms", test_unicode_filter_matches_cyrillic_composed_forms);
        add_test("unicode_filter_preserves_other_scripts_and_emoji_display", test_unicode_filter_preserves_other_scripts_and_emoji_display);
        add_test("sort_is_deterministic", test_sort_is_deterministic);
        add_test("update_signal_reports_only_real_changes", test_update_signal_reports_only_real_changes);
        add_test("remove_and_clear_keep_index_consistent", test_remove_and_clear_keep_index_consistent);
        add_test("size_notifies_once_per_real_change", test_size_notifies_once_per_real_change);
    }

    private void test_upsert_preserves_identity_and_updates_alias() {
        var model = new ContactListModel();
        Account account = make_account(1, "alice@example.test");
        Jid contact = make_jid("contact@example.test");

        ContactListItem first = model.upsert(account, contact, "First name");
        ContactListItem updated = model.upsert(account, contact, "  Updated name  ");

        assert_true(first == updated, "upsert must retain the GObject identity used by Gtk.SingleSelection");
        fail_if_not_eq_int(1, (int) model.size);
        fail_if_not_eq_str("Updated name", updated.display_name);
        fail_if_not_eq_str("Updated name", (!) updated.alias);
    }

    private void test_same_jid_on_two_accounts_stays_distinct() {
        var model = new ContactListModel();
        Account first_account = make_account(11, "first@example.test");
        Account second_account = make_account(12, "second@example.test");
        Jid contact = make_jid("shared@example.test");

        ContactListItem first = model.upsert(first_account, contact, "Shared");
        ContactListItem second = model.upsert(second_account, contact, "Shared");

        fail_if_not_eq_int(2, (int) model.size);
        assert_true(first != second, "the account id is part of contact identity");
        assert_true(model.lookup(first_account, contact) == first);
        assert_true(model.lookup(second_account, contact) == second);
    }

    private void test_blank_alias_falls_back_to_bare_jid() {
        var model = new ContactListModel();
        Account account = make_account(5, "alice@example.test");
        Jid contact = make_jid("contact@example.test");

        ContactListItem item = model.upsert(account, contact, "  ");
        assert_true(item.alias == null);
        fail_if_not_eq_str("contact@example.test", item.display_name);

        model.upsert(account, contact, "Alias");
        model.upsert(account, contact, null);
        assert_true(item.alias == null);
        fail_if_not_eq_str("contact@example.test", item.display_name);
    }

    private void test_invalid_utf8_alias_is_sanitized() {
        var model = new ContactListModel();
        Account account = make_account(6, "alice@example.test");
        uint8[] invalid_alias_bytes = { 'N', 'a', 'm', 'e', 0xff, 0 };
        string invalid_alias = (string) invalid_alias_bytes;

        ContactListItem item = model.upsert(account, make_jid("contact@example.test"), invalid_alias);
        assert_true(item.display_name.validate(), "server-provided aliases must be valid before GTK sees them");
        assert_true(item.search_text.validate());
    }

    private void test_full_and_bare_jid_share_identity() {
        var model = new ContactListModel();
        Account account = make_account(21, "alice@example.test");

        ContactListItem first = model.upsert(account, make_jid("contact@example.test/device"), "Contact");
        ContactListItem second = model.upsert(account, make_jid("contact@example.test"), "Renamed");

        assert_true(first == second, "contact keys must always use the bare JID");
        fail_if_not_eq_int(1, (int) model.size);
        fail_if_not_eq_str("contact@example.test", second.jid.to_string());
    }

    private void test_remove_is_account_scoped() {
        var model = new ContactListModel();
        Account first_account = make_account(31, "first@example.test");
        Account second_account = make_account(32, "second@example.test");
        Jid contact = make_jid("shared@example.test");

        model.upsert(first_account, contact, null);
        ContactListItem remaining = model.upsert(second_account, contact, null);

        assert_true(model.remove(first_account, contact));
        assert_false(model.remove(first_account, contact));
        fail_if_not_eq_int(1, (int) model.size);
        assert_true(model.lookup(second_account, contact) == remaining);
    }

    private void test_filter_tracks_alias_and_jid() {
        var model = new ContactListModel();
        Account account = make_account(41, "alice@example.test");
        Jid contact = make_jid("ada.lovelace@example.test");

        ContactListItem item = model.upsert(account, contact, "Countess Byron");
        assert_true(item.matches("COUNTESS byr"));
        assert_true(item.matches("lovelace@example"));
        assert_false(item.matches("grace"));

        model.upsert(account, contact, "Grace Hopper");
        assert_true(item.matches("grace hopper"));
        assert_false(item.matches("Countess Byron"));
        assert_true(item.matches("ada.lovelace@example.test"), "JID search remains available after an alias update");
    }

    private void test_sort_is_deterministic() {
        var model = new ContactListModel();
        Account first_account = make_account(51, "first@example.test");
        Account second_account = make_account(52, "second@example.test");

        ContactListItem alpha = model.upsert(first_account, make_jid("z@example.test"), "Alpha");
        ContactListItem zulu = model.upsert(first_account, make_jid("a@example.test"), "Zulu");
        ContactListItem alpha_second_account = model.upsert(second_account, make_jid("z@example.test"), "Alpha");

        assert_true(ContactListItem.compare(alpha, zulu) < 0);
        assert_true(ContactListItem.compare(alpha, alpha_second_account) != 0,
                "equal names and JIDs must still have a stable account tie-breaker");
    }

    private void test_unicode_filter_is_casefolded() {
        var model = new ContactListModel();
        Account account = make_account(45, "alice@example.test");
        ContactListItem item = model.upsert(account, make_jid("contact@example.test"), "Straße");

        assert_true(item.matches("STRASSE"), "Unicode search must use case folding, not byte-wise lowercase");
    }

    private void test_unicode_filter_normalizes_composed_forms() {
        var model = new ContactListModel();
        Account account = make_account(46, "alice@example.test");
        ContactListItem item = model.upsert(account, make_jid("contact@example.test"), "José");

        assert_true(item.matches("Jose\u0301"),
                "composed and decomposed Unicode input must produce the same search key");
    }

    private void test_unicode_filter_matches_cyrillic_composed_forms() {
        var model = new ContactListModel();
        Account account = make_account(47, "alice@example.test");
        Jid jid = make_jid("yoga@example.test");
        ContactListItem item = model.upsert(account, jid, "Йога");

        assert_true(item.matches("йОГА"));
        assert_true(item.matches("И\u0306ога"), "decomposed Cyrillic must match the composed alias");
        assert_true(item.matches("и\u0306ОГА"));
        assert_false(item.matches("Иога"), "normalization must not discard the Cyrillic breve");
        fail_if_not_eq_str("Йога", item.display_name);

        ContactListItem updated = model.upsert(account, jid, "И\u0306ога");
        assert_true(updated == item, "Unicode alias updates must retain the contact identity");
        assert_true(updated.matches("ЙОГА"));
        fail_if_not_eq_str("И\u0306ога", updated.display_name);
        fail_if_not_eq_str("И\u0306ога", (!) updated.alias);
    }

    private void test_unicode_filter_preserves_other_scripts_and_emoji_display() {
        var model = new ContactListModel();
        Account account = make_account(48, "alice@example.test");
        Jid jid = make_jid("unicode@example.test");
        ContactListItem item = model.upsert(account, jid, null);
        string[] aliases = { "ΟΣ", "العربية", "עברית", "中文 · 日本語", "한글", "हिन्दी", "Ａｌｉｃｅ", "👩🏽‍💻 🏳️‍🌈" };
        string[] queries = { "ος", "العربية", "עברית", "日本語", "\u1112\u1161\u11ab\u1100\u1173\u11af", "हिन्दी", "alice", "👩🏽‍💻" };

        for (int i = 0; i < aliases.length; i++) {
            ContactListItem updated = model.upsert(account, jid, aliases[i]);
            assert_true(updated == item);
            assert_true(updated.matches(queries[i]), "search must support the original script and Unicode equivalents");
            fail_if_not_eq_str(aliases[i], updated.display_name);
            fail_if_not_eq_str(aliases[i], (!) updated.alias);
            fail_if_not_eq_str("unicode@example.test", updated.jid.to_string());
        }
        assert_false(item.matches("👩‍💻"), "search must preserve emoji skin tones and joiner sequences");
        fail_if_not_eq_int(1, (int) model.size);
    }

    private void test_update_signal_reports_only_real_changes() {
        var model = new ContactListModel();
        Account account = make_account(55, "alice@example.test");
        Jid contact = make_jid("contact@example.test");
        ContactListItem item = model.upsert(account, contact, "Before");
        int signal_count = 0;
        ContactListItem? signalled_item = null;
        ContactListItemChange signalled_changes = ContactListItemChange.NONE;
        int alias_notifies = 0;
        int display_notifies = 0;
        int search_notifies = 0;
        int sort_notifies = 0;
        model.item_updated.connect((updated_item, changes) => {
            signal_count++;
            signalled_item = updated_item;
            signalled_changes = changes;
        });
        item.notify["alias"].connect(() => { alias_notifies++; });
        item.notify["display-name"].connect(() => { display_notifies++; });
        item.notify["search-text"].connect(() => { search_notifies++; });
        item.notify["sort-key"].connect(() => { sort_notifies++; });

        model.upsert(account, contact, "  Before  ");
        fail_if_not_eq_int(0, signal_count);
        fail_if_not_eq_int(0, alias_notifies);
        fail_if_not_eq_int(0, display_notifies);
        fail_if_not_eq_int(0, search_notifies);
        fail_if_not_eq_int(0, sort_notifies);

        model.upsert(account, contact, "After");
        fail_if_not_eq_int(1, signal_count);
        assert_true(signalled_item == item);
        assert_true((signalled_changes & ContactListItemChange.ALIAS) != 0);
        assert_true((signalled_changes & ContactListItemChange.DISPLAY_NAME) != 0);
        assert_true((signalled_changes & ContactListItemChange.SEARCH_TEXT) != 0);
        assert_true((signalled_changes & ContactListItemChange.SORT_KEY) != 0);
        fail_if_not_eq_int(1, alias_notifies);
        fail_if_not_eq_int(1, display_notifies);
        fail_if_not_eq_int(1, search_notifies);
        fail_if_not_eq_int(1, sort_notifies);
    }

    private void test_remove_and_clear_keep_index_consistent() {
        var model = new ContactListModel();
        Account account = make_account(56, "alice@example.test");
        Jid first_jid = make_jid("first@example.test");
        Jid second_jid = make_jid("second@example.test");
        ContactListItem second = model.upsert(account, second_jid, "Second");
        model.upsert(account, first_jid, "First");

        bool remove_observed_consistent = false;
        model.items.items_changed.connect((position, removed, added) => {
            if (removed == 1) {
                remove_observed_consistent = model.lookup(account, first_jid) == null;
            }
        });

        assert_true(model.remove(account, first_jid));
        assert_true(remove_observed_consistent, "lookup must already be empty during synchronous remove notification");
        fail_if_not_eq_int(1, (int) model.items.get_n_items());
        assert_true(model.items.get_item(0) == second);
        assert_true(model.lookup(account, first_jid) == null);

        model.clear();
        fail_if_not_eq_int(0, (int) model.items.get_n_items());
        assert_true(model.lookup(account, second_jid) == null);

        Jid appended_jid = make_jid("appended@example.test");
        bool append_observed_consistent = false;
        model.items.items_changed.connect((position, removed, added) => {
            if (added == 1) {
                append_observed_consistent = model.lookup(account, appended_jid) != null;
            }
        });
        model.upsert(account, appended_jid, "Appended");
        assert_true(append_observed_consistent, "lookup must already contain an item during synchronous append notification");
    }

    private void test_size_notifies_once_per_real_change() {
        var model = new ContactListModel();
        Account account = make_account(57, "alice@example.test");
        Jid jid = make_jid("contact@example.test");
        int notify_count = 0;
        uint observed_size = 99;
        model.notify["size"].connect(() => {
            notify_count++;
            observed_size = model.size;
        });

        model.upsert(account, jid, "Contact");
        fail_if_not_eq_int(1, notify_count);
        fail_if_not_eq_int(1, (int) observed_size);
        model.upsert(account, jid, "Renamed");
        fail_if_not_eq_int(1, notify_count);
        model.remove(account, jid);
        fail_if_not_eq_int(2, notify_count);
        fail_if_not_eq_int(0, (int) observed_size);
        model.clear();
        fail_if_not_eq_int(2, notify_count);

        model.upsert(account, jid, "Contact again");
        fail_if_not_eq_int(3, notify_count);
        model.clear();
        fail_if_not_eq_int(4, notify_count);
        fail_if_not_eq_int(0, (int) observed_size);
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
