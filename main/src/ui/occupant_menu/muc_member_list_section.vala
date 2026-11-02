namespace Dino.Ui.OccupantMenu {

internal enum MucMemberListSection {
    OWNER,
    ADMIN,
    MODERATOR,
    MEMBER,
    PARTICIPANT,
    VISITOR,
    BANNED
}

/**
 * Projects the independent XEP-0045 affiliation and role axes into the
 * exclusive sections shown by the member list.  Keeping this policy pure and
 * shared prevents the normal, large-room and cached presentation paths from
 * drifting apart.
 */
internal class MucMemberListSectionModel : Object {
    internal static MucMemberListSection classify(
            bool affiliation_known,
            Xmpp.Xep.Muc.Affiliation affiliation,
            bool role_known,
            Xmpp.Xep.Muc.Role role) {
        if (affiliation_known) {
            switch (affiliation) {
                case Xmpp.Xep.Muc.Affiliation.OWNER:
                    return MucMemberListSection.OWNER;
                case Xmpp.Xep.Muc.Affiliation.ADMIN:
                    return MucMemberListSection.ADMIN;
                case Xmpp.Xep.Muc.Affiliation.OUTCAST:
                    return MucMemberListSection.BANNED;
                default:
                    break;
            }
        }

        if (role_known && role == Xmpp.Xep.Muc.Role.MODERATOR) {
            return MucMemberListSection.MODERATOR;
        }
        // Voice is a live room role, independent of the long-lived member
        // affiliation. A muted member therefore belongs in the visitor
        // section until the room grants participant voice again.
        if (role_known && role == Xmpp.Xep.Muc.Role.VISITOR) {
            return MucMemberListSection.VISITOR;
        }
        if (affiliation_known &&
                affiliation == Xmpp.Xep.Muc.Affiliation.MEMBER) {
            return MucMemberListSection.MEMBER;
        }
        return MucMemberListSection.PARTICIPANT;
    }

    internal static int rank(MucMemberListSection section) {
        switch (section) {
            case MucMemberListSection.OWNER:
                return 0;
            case MucMemberListSection.ADMIN:
                return 1;
            case MucMemberListSection.MODERATOR:
                return 2;
            case MucMemberListSection.MEMBER:
                return 3;
            case MucMemberListSection.PARTICIPANT:
                return 4;
            case MucMemberListSection.VISITOR:
                return 5;
            case MucMemberListSection.BANNED:
            default:
                return 6;
        }
    }

    internal static string key(MucMemberListSection section) {
        switch (section) {
            case MucMemberListSection.OWNER:
                return "owner";
            case MucMemberListSection.ADMIN:
                return "admin";
            case MucMemberListSection.MODERATOR:
                return "moderator";
            case MucMemberListSection.MEMBER:
                return "member";
            case MucMemberListSection.PARTICIPANT:
                return "participant";
            case MucMemberListSection.VISITOR:
                return "visitor";
            case MucMemberListSection.BANNED:
            default:
                return "banned";
        }
    }

    internal static bool role_is_redundant(
            MucMemberListSection section,
            Xmpp.Xep.Muc.Role role) {
        switch (role) {
            case Xmpp.Xep.Muc.Role.MODERATOR:
                return section == MucMemberListSection.OWNER ||
                    section == MucMemberListSection.ADMIN ||
                    section == MucMemberListSection.MODERATOR;
            case Xmpp.Xep.Muc.Role.PARTICIPANT:
                return section == MucMemberListSection.PARTICIPANT;
            case Xmpp.Xep.Muc.Role.VISITOR:
                return section == MucMemberListSection.VISITOR;
            default:
                return true;
        }
    }
}

}
