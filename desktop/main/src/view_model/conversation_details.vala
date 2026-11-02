using Dino.Entities;
using Xmpp;
using Xmpp.Xep;
using Gee;
using Gtk;

public class Dino.Ui.ViewModel.ConversationDetails : Object {
    public signal void pin_changed();
    public signal void block_changed(BlockState action);
    public signal void notification_flipped();
    public signal void notification_changed(NotificationSetting setting);
    public signal void remove_contact();
    public signal void remove_contact_finished(Jid jid, RosterRemoveResult result);
    public bool removing_contact { get; set; default = false; }
    public signal void room_configuration_retry();
    public signal void room_configuration_save();

    public enum BlockState {
        USER,
        DOMAIN,
        UNBLOCK
    }

    public enum NotificationOptions {
        ON_OFF,
        ON_HIGHLIGHT_OFF
    }

    public enum NotificationSetting {
        DEFAULT,
        ON,
        HIGHLIGHT,
        OFF
    }

    public ViewModel.CompatAvatarPictureModel avatar { get; set; }
    public string name { get; set; }
    public bool pinned { get; set; }

    public NotificationSetting notification { get; set; }
    public NotificationOptions notification_options { get; set; }
    public bool notification_is_default { get; set; }

    public bool show_blocked { get; set; }
    public BlockState blocked { get; set; }
    
    public bool show_remove_contact { get; set; }

    public GLib.ListStore about_rows = new GLib.ListStore(typeof(PreferencesRow.Any));
    public GLib.ListStore vcard_rows = new GLib.ListStore(typeof(PreferencesRow.Any));
    public string? account_jid { get; set; }

    public bool settings_in_separate_tab { get; set; }
    public GLib.ListStore settings_rows = new GLib.ListStore(typeof(PreferencesRow.Any));
    public GLib.ListStore room_administration_rows = new GLib.ListStore(typeof(PreferencesRow.Any));
    public GLib.ListStore room_configuration_rows { get; set; }
    public GLib.ListStore members = new GLib.ListStore(typeof(ConferenceMemberListRow));
    public SortListModel members_sorted = new SortListModel(null, new CustomSorter(compare_member_rows));

    construct {
        members_sorted.set_model(members);
    }

    private static int compare_member_rows(void* item1, void* item2) {
        var row1 = item1 as Dino.Ui.ViewModel.ConferenceMemberListRow;
        var row2 = item2 as Dino.Ui.ViewModel.ConferenceMemberListRow;
        if (row1 == null || row2 == null) return 0;

        int affiliation_sorting = affiliation_rank(row1.affiliation) - affiliation_rank(row2.affiliation);
        if (affiliation_sorting != 0) return affiliation_sorting;

        return row1.name.collate(row2.name);
    }

    private static int affiliation_rank(Xmpp.Xep.Muc.Affiliation affiliation) {
        switch (affiliation) {
            case OWNER: return 0;
            case ADMIN: return 1;
            case MEMBER: return 2;
            default: return 3;
        }
    }

}

//public class Dino.Ui.ViewModel.ConferenceDetails : Dino.Ui.ViewModel.ConversationDetails {
//    public static
//}

public class Dino.Ui.Model.ConversationDetails : Object {
    public Conversation conversation { get; set; }
    public Dino.Model.ConversationDisplayName display_name { get; set; }
    public DataForms.DataForm? data_form { get; set; }
    public string? data_form_bak;
    public bool? original_members_only;
    public MucManager.MucOwnerMutationContext? room_configuration_context;
    public bool room_configuration_loading { get; set; default=false; }
    public bool room_configuration_requested { get; set; default=false; }
    public bool room_configuration_saving { get; set; default=false; }
    public bool blocked { get; set; }
    public bool domain_blocked { get; set; }

    public Xmpp.Xep.VCard4.VCard4? vcard4 { get; set; }
    public Xmpp.Xep.VCard.VCardInfo? vcard_temp { get; set; }
    public string? pep_nickname { get; set; }

    public GLib.ListStore members = new GLib.ListStore(typeof(Ui.Model.ConferenceMember));

    public void populate(StreamInteractor stream_interactor, Conversation conversation) {
        Ui.ConversationDetails.populate_dialog(this, conversation, stream_interactor);
    }
}

public class Dino.Ui.Model.ConferenceMember : Object {
    public string name { get; set; }
    public Jid jid { get; set; }
    public Xmpp.Xep.Muc.Affiliation affiliation { get; set; }
}

public class Dino.Ui.ViewModel.ConferenceMemberListRow : Object {
    public ViewModel.CompatAvatarPictureModel avatar { get; set; }
    public string name { get; set; }
    public string jid { get; set; }
    public Xmpp.Xep.Muc.Affiliation affiliation { get; set; }
    public string? affiliation_str { get; set; }

    construct {
        this.bind_property("affiliation", this, "affiliation-str", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL, (_, from_value, ref to_value) => {
            to_value = affiliation_to_str((Xmpp.Xep.Muc.Affiliation) from_value);
            return true;
        });
    }

    private string? affiliation_to_str(Xmpp.Xep.Muc.Affiliation affiliation) {
        switch (affiliation) {
            case OWNER: return _("Owner");
            case ADMIN: return _("Admin");
            case MEMBER: return _("Member");
            default: return null;
        }
    }
}
