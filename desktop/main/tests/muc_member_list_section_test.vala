using Dino.Ui.OccupantMenu;

namespace Dino.Ui.Test {

class MucMemberListSectionTest : Gee.TestCase {
    public MucMemberListSectionTest() {
        base("MucMemberListSection");
        add_test("owner_admin_and_outcast_precede_live_role", test_owner_admin_and_outcast_precede_live_role);
        add_test("moderator_precedes_member", test_moderator_precedes_member);
        add_test("visitor_role_overrides_member_affiliation", test_visitor_role_overrides_member_affiliation);
        add_test("live_roles_classify_unaffiliated_occupants", test_live_roles_classify_unaffiliated_occupants);
        add_test("unknown_role_uses_participant_fallback", test_unknown_role_uses_participant_fallback);
        add_test("section_order_is_stable", test_section_order_is_stable);
        add_test("redundant_role_labels_are_suppressed", test_redundant_role_labels_are_suppressed);
    }

    private void test_owner_admin_and_outcast_precede_live_role() {
        assert_section(MucMemberListSection.OWNER, true,
            Xmpp.Xep.Muc.Affiliation.OWNER, true,
            Xmpp.Xep.Muc.Role.MODERATOR);
        assert_section(MucMemberListSection.ADMIN, true,
            Xmpp.Xep.Muc.Affiliation.ADMIN, true,
            Xmpp.Xep.Muc.Role.MODERATOR);
        assert_section(MucMemberListSection.OWNER, true,
            Xmpp.Xep.Muc.Affiliation.OWNER, true,
            Xmpp.Xep.Muc.Role.VISITOR);
        assert_section(MucMemberListSection.ADMIN, true,
            Xmpp.Xep.Muc.Affiliation.ADMIN, true,
            Xmpp.Xep.Muc.Role.VISITOR);
        assert_section(MucMemberListSection.BANNED, true,
            Xmpp.Xep.Muc.Affiliation.OUTCAST, true,
            Xmpp.Xep.Muc.Role.VISITOR);
    }

    private void test_moderator_precedes_member() {
        assert_section(MucMemberListSection.MODERATOR, true,
            Xmpp.Xep.Muc.Affiliation.MEMBER, true,
            Xmpp.Xep.Muc.Role.MODERATOR);
    }

    private void test_visitor_role_overrides_member_affiliation() {
        assert_section(MucMemberListSection.VISITOR, true,
            Xmpp.Xep.Muc.Affiliation.MEMBER, true,
            Xmpp.Xep.Muc.Role.VISITOR);
        assert_section(MucMemberListSection.MEMBER, true,
            Xmpp.Xep.Muc.Affiliation.MEMBER, true,
            Xmpp.Xep.Muc.Role.PARTICIPANT);
    }

    private void test_live_roles_classify_unaffiliated_occupants() {
        assert_section(MucMemberListSection.MODERATOR, false,
            Xmpp.Xep.Muc.Affiliation.NONE, true,
            Xmpp.Xep.Muc.Role.MODERATOR);
        assert_section(MucMemberListSection.PARTICIPANT, false,
            Xmpp.Xep.Muc.Affiliation.NONE, true,
            Xmpp.Xep.Muc.Role.PARTICIPANT);
        assert_section(MucMemberListSection.VISITOR, false,
            Xmpp.Xep.Muc.Affiliation.NONE, true,
            Xmpp.Xep.Muc.Role.VISITOR);
    }

    private void test_unknown_role_uses_participant_fallback() {
        assert_section(MucMemberListSection.PARTICIPANT, false,
            Xmpp.Xep.Muc.Affiliation.NONE, false,
            Xmpp.Xep.Muc.Role.MODERATOR);
    }

    private void test_section_order_is_stable() {
        MucMemberListSection[] expected = {
            MucMemberListSection.OWNER,
            MucMemberListSection.ADMIN,
            MucMemberListSection.MODERATOR,
            MucMemberListSection.MEMBER,
            MucMemberListSection.PARTICIPANT,
            MucMemberListSection.VISITOR,
            MucMemberListSection.BANNED
        };
        string[] expected_keys = {
            "owner", "admin", "moderator", "member", "participant",
            "visitor", "banned"
        };
        for (int i = 0; i < expected.length; i++) {
            assert_true(MucMemberListSectionModel.rank(expected[i]) == i,
                "unexpected member-list section rank");
            assert_true(MucMemberListSectionModel.key(expected[i]) ==
                    expected_keys[i],
                "unexpected member-list section key");
        }
    }

    private void test_redundant_role_labels_are_suppressed() {
        assert_true(MucMemberListSectionModel.role_is_redundant(
            MucMemberListSection.OWNER, Xmpp.Xep.Muc.Role.MODERATOR));
        assert_true(MucMemberListSectionModel.role_is_redundant(
            MucMemberListSection.MODERATOR, Xmpp.Xep.Muc.Role.MODERATOR));
        assert_true(MucMemberListSectionModel.role_is_redundant(
            MucMemberListSection.VISITOR, Xmpp.Xep.Muc.Role.VISITOR));
        assert_false(MucMemberListSectionModel.role_is_redundant(
            MucMemberListSection.MEMBER, Xmpp.Xep.Muc.Role.VISITOR));
    }

    private void assert_section(MucMemberListSection expected,
            bool affiliation_known,
            Xmpp.Xep.Muc.Affiliation affiliation,
            bool role_known,
            Xmpp.Xep.Muc.Role role) {
        MucMemberListSection actual = MucMemberListSectionModel.classify(
            affiliation_known, affiliation, role_known, role);
        assert_true(actual == expected,
            "unexpected member-list section classification");
    }
}

}
