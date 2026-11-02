using Xmpp.DnsSecurity;

namespace Xmpp.Test {

class DnsSecurityPolicyTest : Gee.TestCase {
    public DnsSecurityPolicyTest() {
        base("DnsSecurityPolicy");
        add_test("old_accounts_default_off_unknown_values_fail", test_settings);
        add_test("bogus_and_outage_never_become_unsigned", test_lookup_failures);
        add_test("tlsa_requires_authenticated_target_and_addresses", test_delegation);
        add_test("unsigned_and_missing_tlsa_follow_selected_mode", test_absence);
        add_test("off_preserves_existing_tls", test_off);
        add_test("discovery_cannot_verify_a_certificate", test_discovery);
        add_test("same_domain_accounts_do_not_share_attempts", test_accounts);
        add_test("late_results_rejected_after_change_or_cancel", test_late_results);
    }

    private void test_settings() {
        try {
            assert_true(Mode.from_setting(null) == Mode.OFF);
            foreach (Mode mode in new Mode[]{Mode.OFF, Mode.WHEN_AVAILABLE, Mode.REQUIRED}) {
                assert_true(Mode.from_setting(mode.to_setting()) == mode);
            }
        } catch (Error e) { assert_not_reached(); }
        foreach (string value in new string[]{"", "automatic", "REQUIRED", "required ", "обязательно"}) {
            bool rejected = false;
            try { Mode.from_setting(value); }
            catch (ConfigurationError e) { rejected = true; }
            assert_true(rejected);
        }
    }

    private void test_lookup_failures() {
        foreach (Mode mode in new Mode[]{Mode.WHEN_AVAILABLE, Mode.REQUIRED}) {
            foreach (bool target in new bool[]{false, true}) {
                foreach (TlsaRecords records in new TlsaRecords[]{TlsaRecords.ABSENT, TlsaRecords.UNSUPPORTED, TlsaRecords.USABLE}) {
                    assert_true(decide_endpoint(mode, target, Validation.BOGUS,
                        Validation.SECURE, records) == Decision.REJECT_BOGUS);
                    assert_true(decide_endpoint(mode, target, Validation.SECURE,
                        Validation.BOGUS, records) == Decision.REJECT_BOGUS);
                    assert_true(decide_endpoint(mode, target, Validation.INDETERMINATE,
                        Validation.SECURE, records) == Decision.RETRY_LOOKUP);
                    assert_true(decide_endpoint(mode, target, Validation.SECURE,
                        Validation.INDETERMINATE, records) == Decision.RETRY_LOOKUP);
                }
            }
        }
    }

    private void test_delegation() {
        foreach (Mode mode in new Mode[]{Mode.WHEN_AVAILABLE, Mode.REQUIRED}) {
            assert_true(decide_endpoint(mode, true, Validation.SECURE,
                Validation.SECURE, TlsaRecords.USABLE) == Decision.VERIFY_TLSA);
            Decision unavailable = mode == Mode.REQUIRED ? Decision.REJECT_REQUIRED : Decision.EXISTING_TLS;
            // A TLSA record on an attacker's redirected SRV target is not proof
            // of the original account domain's authorization.
            assert_true(decide_endpoint(mode, false, Validation.SECURE,
                Validation.SECURE, TlsaRecords.USABLE) == unavailable);
            assert_true(decide_endpoint(mode, true, Validation.INSECURE,
                Validation.SECURE, TlsaRecords.USABLE) == unavailable);
            assert_true(decide_endpoint(mode, true, Validation.SECURE,
                Validation.INSECURE, TlsaRecords.USABLE) == unavailable);
        }
    }

    private void test_absence() {
        foreach (TlsaRecords records in new TlsaRecords[]{TlsaRecords.ABSENT, TlsaRecords.UNSUPPORTED}) {
            assert_true(decide_endpoint(Mode.WHEN_AVAILABLE, true, Validation.SECURE,
                Validation.SECURE, records) == Decision.EXISTING_TLS);
            assert_true(decide_endpoint(Mode.REQUIRED, true, Validation.SECURE,
                Validation.SECURE, records) == Decision.REJECT_REQUIRED);
        }
        assert_true(decide_endpoint(Mode.WHEN_AVAILABLE, true, Validation.INSECURE,
            Validation.INSECURE, TlsaRecords.USABLE) == Decision.EXISTING_TLS);
        assert_true(decide_endpoint(Mode.REQUIRED, true, Validation.INSECURE,
            Validation.INSECURE, TlsaRecords.USABLE) == Decision.REJECT_REQUIRED);
    }

    private void test_off() {
        foreach (Validation state in new Validation[]{Validation.SECURE, Validation.INSECURE, Validation.BOGUS, Validation.INDETERMINATE}) {
            assert_true(decide_endpoint(Mode.OFF, false, state, state,
                TlsaRecords.USABLE) == Decision.EXISTING_TLS);
            assert_true(decide_discovery(Mode.OFF, state) == DiscoveryDecision.USE_EXISTING_LOOKUP);
        }
    }

    private void test_discovery() {
        foreach (Mode mode in new Mode[]{Mode.WHEN_AVAILABLE, Mode.REQUIRED}) {
            assert_true(decide_discovery(mode, Validation.SECURE) == DiscoveryDecision.CONTINUE_WITH_ANSWER);
            assert_true(decide_discovery(mode, Validation.BOGUS) == DiscoveryDecision.REJECT_BOGUS);
            assert_true(decide_discovery(mode, Validation.INDETERMINATE) == DiscoveryDecision.RETRY_LOOKUP);
        }
        assert_true(decide_discovery(Mode.WHEN_AVAILABLE, Validation.INSECURE) == DiscoveryDecision.CONTINUE_WITH_ANSWER);
        assert_true(decide_discovery(Mode.REQUIRED, Validation.INSECURE) == DiscoveryDecision.REJECT_REQUIRED);
    }

    private void test_accounts() {
        var account_a = new Attempt(Mode.REQUIRED);
        var account_b = new Attempt(Mode.OFF);
        assert_true(account_a.is_current(account_a));
        assert_true(account_b.is_current(account_b));
        assert_false(account_a.is_current(account_b));
        account_a.cancel();
        assert_false(account_a.is_current(account_a));
        assert_true(account_b.is_current(account_b));
        assert_true(account_b.mode == Mode.OFF);
    }

    private void test_late_results() {
        var old = new Attempt(Mode.REQUIRED);
        var current = new Attempt(Mode.REQUIRED);
        assert_false(old.is_current(current));
        assert_false(old.is_current(null));
        current.cancel();
        assert_false(current.is_current(current));
        var fresh = new Attempt(Mode.REQUIRED);
        assert_true(fresh.is_current(fresh));
    }
}

}
