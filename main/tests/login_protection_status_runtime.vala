using Dino;
using Xmpp;

namespace Dino.Ui.Test {

class LoginProtectionStatusRuntimeTest : Gee.TestCase {
    public LoginProtectionStatusRuntimeTest() {
        base("LoginProtectionStatusRuntime");
        add_test("only_current_verified_PLUS_login_is_reported_as_protected", test_current_proof);
        add_test("connection_changes_and_policy_failures_do_not_reuse_a_success_status", test_changes);
        add_test("server_offer_is_separate_from_actual_use_and_scoped_to_current_connection", test_server_offer);
        add_test("native_icons_and_controls_follow_verified_availability", test_controls);
        add_test("both_choices_require_current_account_proof_and_reject_races", test_selection_gate);
    }

    private string status(ConnectionManager.ConnectionState state, Sasl.Flag? flag,
            bool enabled = true, bool tls = true, ConnectionManager.ConnectionError? error = null) {
        return Util.login_protection_status_text(enabled, state, error, "сервер.example", tls, flag);
    }

    private void test_current_proof() {
        var active = ConnectionManager.ConnectionState.CONNECTED;
        foreach (string mechanism in new string[]{Sasl.Mechanism.SCRAM_SHA_1_PLUS,
                Sasl.Mechanism.SCRAM_SHA_256_PLUS, Sasl.Mechanism.SCRAM_SHA_512_PLUS}) {
            var flag = new Sasl.Flag() { mechanism=mechanism, finished=true };
            assert_cmpstr(status(active, flag), CompareOperator.EQ,
                _("Extra login protection is active for this connection."));
            flag.finished = false;
            assert_cmpstr(status(active, flag), CompareOperator.EQ,
                _("The protection status is not known for this connection. It will be checked at the next login."));
            flag.finished = true;
            flag.failed = true;
            assert_cmpstr(status(active, flag), CompareOperator.EQ,
                _("The protection status is not known for this connection. It will be checked at the next login."));
        }
        foreach (string mechanism in new string[]{Sasl.Mechanism.SCRAM_SHA_1,
                Sasl.Mechanism.SCRAM_SHA_256, Sasl.Mechanism.SCRAM_SHA_512, Sasl.Mechanism.PLAIN}) {
            var flag = new Sasl.Flag() { mechanism=mechanism, finished=true };
            assert_cmpstr(status(active, flag), CompareOperator.EQ,
                _("Signed in without extra login protection. The connection is encrypted."));
            // A message claiming encryption requires an actual TLS transport.
            assert_cmpstr(status(active, flag, true, false), CompareOperator.EQ,
                _("The protection status is not known for this connection. It will be checked at the next login."));
        }
        // SM resumption or a different account without SASL evidence is unknown.
        assert_cmpstr(status(active, null), CompareOperator.EQ,
            _("The protection status is not known for this connection. It will be checked at the next login."));
    }

    private void test_changes() {
        var flag = new Sasl.Flag() { mechanism=Sasl.Mechanism.SCRAM_SHA_256_PLUS, finished=true };
        var error = new ConnectionManager.ConnectionError(ConnectionManager.ConnectionError.Source.SASL,
            "channel-binding-required");
        assert_cmpstr(status(ConnectionManager.ConnectionState.CONNECTING, flag, true, true, error), CompareOperator.EQ,
            _("Checking login protection…"));
        assert_cmpstr(status(ConnectionManager.ConnectionState.CONNECTED, flag, false), CompareOperator.EQ,
            _("Enable this account to check its login protection."));
        assert_cmpstr(status(ConnectionManager.ConnectionState.DISCONNECTED, flag), CompareOperator.EQ,
            _("Login protection will be checked when this account connects."));
        assert_cmpstr(status(ConnectionManager.ConnectionState.DISCONNECTED, flag, true, true, error), CompareOperator.EQ,
            _("%s cannot provide the required extra protection. Sign-in was not continued.").printf("сервер.example"));
        // Once a fresh authenticated connection exists, an old error cannot win.
        assert_cmpstr(status(ConnectionManager.ConnectionState.CONNECTED, flag, true, true, error), CompareOperator.EQ,
            _("Extra login protection is active for this connection."));
    }

    private void test_server_offer() {
        var active = ConnectionManager.ConnectionState.CONNECTED;
        var flag = new Sasl.Flag() { mechanism=Sasl.Mechanism.SCRAM_SHA_256,
            finished=true, server_offers_channel_binding=true };
        // An offer alone must not enable a policy which cannot actually work.
        assert_true(Util.login_protection_availability(true, active, true, flag) == Util.LoginProtectionAvailability.INCOMPATIBLE);
        flag.server_offers_channel_binding = false;
        assert_true(Util.login_protection_availability(true, active, true, flag) == Util.LoginProtectionAvailability.UNAVAILABLE);
        flag.mechanism = Sasl.Mechanism.SCRAM_SHA_256_PLUS;
        flag.server_offers_channel_binding = true;
        assert_true(Util.login_protection_availability(true, active, true, flag) == Util.LoginProtectionAvailability.AVAILABLE);
        assert_true(Util.login_protection_availability(false, active, true, flag) == Util.LoginProtectionAvailability.UNKNOWN);
        assert_true(Util.login_protection_availability(true, active, false, flag) == Util.LoginProtectionAvailability.UNKNOWN);
        assert_true(Util.login_protection_availability(true, active, true, null) == Util.LoginProtectionAvailability.UNKNOWN);
        assert_true(Util.login_protection_availability(true, ConnectionManager.ConnectionState.CONNECTING, true, flag) == Util.LoginProtectionAvailability.CHECKING);
        assert_true(Util.login_protection_availability(true, ConnectionManager.ConnectionState.DISCONNECTED, true, flag) == Util.LoginProtectionAvailability.UNKNOWN);
        flag.finished = false;
        assert_true(Util.login_protection_availability(true, active, true, flag) == Util.LoginProtectionAvailability.UNKNOWN);
        flag.finished = true;
        flag.failed = true;
        assert_true(Util.login_protection_availability(true, active, true, flag) == Util.LoginProtectionAvailability.UNKNOWN);
        var error = new ConnectionManager.ConnectionError(ConnectionManager.ConnectionError.Source.CONNECTION, null);
        assert_true(Util.login_protection_availability(true, ConnectionManager.ConnectionState.DISCONNECTED, false, null, error) == Util.LoginProtectionAvailability.FAILED);
    }

    private void test_controls() {
        var mode = new Adw.ComboRow() { use_subtitle=true };
        var server = new Adw.ActionRow() { use_markup=false };
        var icon = new Gtk.Image();
        var spinner = new Gtk.Spinner();
        foreach (var availability in new Util.LoginProtectionAvailability[]{
                Util.LoginProtectionAvailability.AVAILABLE, Util.LoginProtectionAvailability.UNAVAILABLE,
                Util.LoginProtectionAvailability.INCOMPATIBLE, Util.LoginProtectionAvailability.UNKNOWN,
                Util.LoginProtectionAvailability.CHECKING, Util.LoginProtectionAvailability.FAILED,
                Util.LoginProtectionAvailability.AVAILABLE}) {
            Util.render_login_protection_controls(mode, server, icon, spinner, availability, true);
            bool available = availability == Util.LoginProtectionAvailability.AVAILABLE;
            assert_true(mode.sensitive == available);
            assert_cmpuint(mode.model.get_n_items(), CompareOperator.EQ, available ? 2 : 1);
            assert_cmpuint(mode.selected, CompareOperator.EQ, available ? 1 : 0);
            assert_true(icon.has_css_class("success") == available);
            assert_true(spinner.spinning == (availability == Util.LoginProtectionAvailability.CHECKING));
            assert_cmpstr(server.subtitle, CompareOperator.EQ, Util.login_protection_availability_text(availability));
            if (available) assert_cmpstr(icon.icon_name, CompareOperator.EQ, "object-select-symbolic");
            if (availability == Util.LoginProtectionAvailability.UNAVAILABLE || availability == Util.LoginProtectionAvailability.INCOMPATIBLE) {
                assert_cmpstr(icon.icon_name, CompareOperator.EQ, "window-close-symbolic");
                assert_true(icon.has_css_class("error"));
            }
            if (availability == Util.LoginProtectionAvailability.FAILED) {
                assert_false(icon.has_css_class("error"));
                assert_true(icon.has_css_class("warning"));
                assert_cmpstr(((Gtk.StringList) mode.model).get_string(0), CompareOperator.EQ, _("Check failed"));
            }
        }
    }

    private void test_selection_gate() {
        try {
            var account = new Entities.Account(new Jid("алёна@example.test"), "fixture") { enabled=true };
            var other = new Entities.Account(new Jid("борис@example.test"), "fixture") { enabled=true };
            var active = ConnectionManager.ConnectionState.CONNECTED;
            var flag = new Sasl.Flag() { mechanism=Sasl.Mechanism.SCRAM_SHA_256_PLUS, finished=true, server_offers_channel_binding=true };
            assert_true(Util.apply_verified_login_protection_mode(account, 1, active, true, flag));
            assert_true(account.require_channel_binding);
            assert_false(other.require_channel_binding);
            // A disconnect after opening the dropdown must reject the action.
            assert_false(Util.apply_verified_login_protection_mode(account, 0, ConnectionManager.ConnectionState.DISCONNECTED, true, flag));
            assert_true(account.require_channel_binding);
            assert_false(Util.apply_verified_login_protection_mode(account, Gtk.INVALID_LIST_POSITION, active, true, flag));
            assert_true(Util.apply_verified_login_protection_mode(account, 0, active, true, flag));
            assert_false(account.require_channel_binding);
            flag.mechanism = Sasl.Mechanism.SCRAM_SHA_256;
            foreach (uint selected in new uint[]{0, 1}) {
                assert_false(Util.apply_verified_login_protection_mode(account, selected, active, true, flag));
                assert_false(account.require_channel_binding);
            }
            flag.server_offers_channel_binding = false;
            assert_false(Util.apply_verified_login_protection_mode(account, 1, active, true, flag));
            assert_false(other.require_channel_binding);
        } catch (Error error) { fail_if_reached(error.message); }
    }
}
}
