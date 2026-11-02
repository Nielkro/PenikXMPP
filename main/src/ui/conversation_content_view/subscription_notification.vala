using Gtk;
using Dino.Entities;
using Xmpp;

namespace Dino.Ui.ConversationSummary {

private delegate void SubscriptionAction();

public class SubscriptionNotification : Object {
    private StreamInteractor stream_interactor;
    private Conversation? conversation;
    private ConversationView? conversation_view;
    private Widget? current_notification;
    private ViewModel.ContactSubscriptionModel? model;
    private ulong changed_handler;
    private ulong request_handler;
    private bool busy = false;
    private string feedback = "";
    private uint binding_generation = 0;
    private bool dismissed = false;
    private uint dismissed_state = 0;
    private bool has_rendered_state = false;
    private uint rendered_state = 0;
    private bool rendered_busy = false;
    private string rendered_feedback = "";

    public SubscriptionNotification(StreamInteractor stream_interactor) {
        this.stream_interactor = stream_interactor;
        var weak_owner = WeakRef(this);
        var presence = stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
        request_handler = presence.received_subscription_request.connect((jid, account) => {
            var owner = weak_owner.get() as SubscriptionNotification;
            if (owner == null || presence.is_subscription_suppressed(account, jid)) return;
            if (owner.conversation != null && owner.model != null &&
                    owner.is_current((!) owner.conversation) &&
                    ViewModel.ContactSubscriptionModel.same_account(owner.conversation.account, account) &&
                    owner.conversation.counterpart.equals_bare(jid)) {
                // A repeated incoming request is relevant even if its pending
                // flag was already set when this hint was dismissed.
                owner.dismissed = false;
                owner.model.refresh();
            }
            var manager = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY);
            var relevant = manager.create_conversation(jid.bare_jid, account, Conversation.Type.CHAT);
            manager.start_conversation(relevant);
        });
    }

    public void clear() {
        binding_generation++;
        if (model != null) {
            model.disconnect(changed_handler);
            model.deactivate();
            model = null;
        }
        remove_current_notification();
        conversation = null;
        conversation_view = null;
        busy = false;
        feedback = "";
        dismissed = false;
    }

    public void init(Conversation conversation, ConversationView view) {
        clear();
        if (conversation.type_ != Conversation.Type.CHAT ||
                conversation.counterpart.equals_bare(conversation.account.bare_jid) ||
                stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY).is_subscription_suppressed(conversation.account, conversation.counterpart)) return;
        this.conversation = conversation;
        this.conversation_view = view;
        model = new ViewModel.ContactSubscriptionModel(stream_interactor, conversation.account, conversation.counterpart);
        changed_handler = model.changed.connect(rebuild);
        rebuild();
    }

    private bool is_current(Conversation target) {
        return conversation == target && conversation_view != null && conversation_view.conversation == target;
    }

    private void rebuild() {
        if (conversation == null || model == null || !is_current((!) conversation)) return;
        uint state = subscription_state();
        if (dismissed && dismissed_state != state) dismissed = false;
        if (dismissed && !busy) {
            remove_current_notification();
            return;
        }
        if (has_rendered_state && rendered_state == state && rendered_busy == busy &&
                rendered_feedback == feedback && current_notification != null &&
                current_notification.get_parent() != null) return;
        remove_current_notification();
        if (model.receives_presence && model.shares_presence && !model.incoming_pending && !busy) {
            feedback = "";
            return;
        }

        var box = new Box(Orientation.VERTICAL, 6) {
            margin_start = 10, margin_end = 10, margin_top = 8, margin_bottom = 8
        };
        var header = new Box(Orientation.HORIZONTAL, 6);
        header.append(new Label(model.describe()) { wrap = true, xalign = 0, hexpand = true });
        var close = new Button.from_icon_name("window-close-symbolic") {
            tooltip_text = _("Close"), valign = Align.START, sensitive = !busy
        };
        close.add_css_class("flat");
        uint generation = binding_generation;
        var weak_owner = WeakRef(this);
        var weak_notification = WeakRef(box);
        close.clicked.connect(() => {
            var owner = weak_owner.get() as SubscriptionNotification;
            if (owner == null || owner.binding_generation != generation || owner.busy ||
                    owner.conversation == null || !owner.is_current((!) owner.conversation) ||
                    owner.current_notification != weak_notification.get() ||
                    owner.subscription_state() != state) return;
            owner.dismissed = true;
            owner.dismissed_state = state;
            owner.feedback = "";
            owner.remove_current_notification();
        });
        header.append(close);
        box.append(header);
        if (!model.receives_presence || !model.shares_presence) {
            box.append(new Label(_("Some servers require contact approval before sharing OMEMO keys.")) {
                wrap = true, xalign = 0
            });
        }
        if (!model.connected) {
            box.append(new Label(_("Connect this account to manage contact permissions.")) { wrap = true, xalign = 0 });
        }
        if (feedback != "") box.append(new Label(feedback) { wrap = true, xalign = 0 });
        var actions = new Box(Orientation.HORIZONTAL, 6);
        if (model.incoming_pending) {
            add_action(actions, _("Accept"), () => { change_permissions.begin(true, false); });
            add_action(actions, _("Deny"), () => { change_permissions.begin(false, true); });
        } else if (!model.in_roster) {
            add_action(actions, _("Add to Contacts"), () => {
                if (conversation == null || !is_current((!) conversation)) return;
                var dialog = AddContactDialog.for_account(stream_interactor, conversation.account);
                dialog.jid = conversation.counterpart.bare_jid.to_string();
                dialog.present(conversation_view);
            });
        } else {
            if (!model.receives_presence && !model.outgoing_pending) {
                add_action(actions, _("Send request"), () => { change_permissions.begin(false, false); });
            }
            if (!model.shares_presence && !model.preapproved) {
                if (stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY).supports_subscription_preapproval(model.account)) {
                    add_action(actions, _("Share my online status"), () => { change_permissions.begin(true, false); });
                } else {
                    box.append(new Label(_("To share your online status, accept this contact's request when it arrives.")) { wrap = true, xalign = 0 });
                }
            }
        }
        if (actions.get_first_child() != null) box.append(actions);
        current_notification = box;
        rendered_state = state;
        rendered_busy = busy;
        rendered_feedback = feedback;
        has_rendered_state = true;
        conversation_view.add_notification(box);
    }

    private uint subscription_state() {
        if (model == null) return 0;
        return (model.in_roster ? 1U : 0U) |
            (model.receives_presence ? 2U : 0U) |
            (model.shares_presence ? 4U : 0U) |
            (model.outgoing_pending ? 8U : 0U) |
            (model.preapproved ? 16U : 0U) |
            (model.incoming_pending ? 32U : 0U) |
            (model.connected ? 64U : 0U);
    }

    private void add_action(Box actions, string label, owned SubscriptionAction callback) {
        var button = new Button.with_label(label) { sensitive = model != null && model.connected && !busy };
        button.clicked.connect(() => { callback(); });
        actions.append(button);
    }

    private async void change_permissions(bool grant_presence, bool deny) {
        if (busy || conversation == null || !is_current((!) conversation)) return;
        Conversation target = (!) conversation;
        uint generation = binding_generation;
        busy = true;
        feedback = "";
        rebuild();
        try {
            var presence = stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
            if (deny) {
                yield presence.deny_subscription_async(target.account, target.counterpart);
            } else {
                var roster = stream_interactor.get_module<RosterManager>(RosterManager.IDENTITY);
                if (roster.get_roster_item(target.account, target.counterpart) == null) {
                    if (!(yield roster.add_jid_async(target.account, target.counterpart, null))) {
                        throw new IOError.FAILED("The server rejected adding the contact");
                    }
                }
                var result = yield presence.request_mutual_subscription(target.account, target.counterpart, grant_presence);
                if (generation == binding_generation && is_current(target)) {
                    feedback = result == MutualSubscriptionResult.MANUAL_APPROVAL_REQUIRED
                        ? _("Request sent. You still need to accept this contact's request when it arrives.")
                        : _("Contact request sent. The server will update the permissions after approval.");
                }
            }
        } catch (Error error) {
            warning("Could not change contact permissions: %s", error.message);
            if (generation == binding_generation && is_current(target)) feedback = _("Could not send the contact request. Check your connection and try again.");
        }
        if (generation == binding_generation && is_current(target)) {
            busy = false;
            model.refresh();
        }
    }

    private void remove_current_notification() {
        if (current_notification != null && conversation_view != null) {
            // A content rebuild may already have detached this widget.
            if (current_notification.get_parent() != null) conversation_view.remove_notification(current_notification);
        }
        current_notification = null;
        has_rendered_state = false;
    }

    public override void dispose() {
        clear();
        if (request_handler != 0) {
            stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY).disconnect(request_handler);
            request_handler = 0;
        }
        base.dispose();
    }
}

}
