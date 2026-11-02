#!/usr/bin/env python3

"""Guard contact virtualization, the untouched MUC selector, and dialog lifecycle."""

from pathlib import Path
import sys


def require(source: str, needle: str, path: Path) -> bool:
    if needle in source:
        return True
    print(f"{path}: missing required contact virtualization marker: {needle}", file=sys.stderr)
    return False


def forbid(source: str, needle: str, path: Path) -> bool:
    if needle not in source:
        return True
    print(f"{path}: legacy eager contact-list marker remains: {needle}", file=sys.stderr)
    return False


def require_count(source: str, needle: str, expected: int, path: Path) -> bool:
    actual = source.count(needle)
    if actual == expected:
        return True
    print(
        f"{path}: expected {expected} occurrence(s) of {needle}, found {actual}",
        file=sys.stderr,
    )
    return False


def require_order(source: str, first: str, second: str, path: Path) -> bool:
    first_position = source.find(first)
    second_position = source.find(second, first_position + len(first))
    if first_position >= 0 and second_position >= 0:
        return True
    print(
        f"{path}: required ordering missing: {first} before {second}",
        file=sys.stderr,
    )
    return False


def main() -> int:
    if len(sys.argv) != 8:
        print(
            f"usage: {Path(sys.argv[0]).name} SELECT_CONTACT CONTACT_VIEW CONTACT_ROW "
            "ADD_CONFERENCE SETTINGS_PAGE SETTINGS_ROW APPLICATION",
            file=sys.stderr,
        )
        return 2

    (
        select_path,
        view_path,
        row_path,
        conference_path,
        settings_path,
        settings_row_path,
        application_path,
    ) = map(Path, sys.argv[1:])
    select_source = select_path.read_text(encoding="utf-8")
    view_source = view_path.read_text(encoding="utf-8")
    row_source = row_path.read_text(encoding="utf-8")
    conference_source = conference_path.read_text(encoding="utf-8")
    settings_source = settings_path.read_text(encoding="utf-8")
    settings_row_source = settings_row_path.read_text(encoding="utf-8")
    application_source = application_path.read_text(encoding="utf-8")
    contacts_action_start = application_source.find(
        'SimpleAction contacts_action = new SimpleAction ("add_chat", null);'
    )
    contacts_action_end = application_source.find(
        "add_action (contacts_action);", contacts_action_start
    )
    contacts_action_source = (
        application_source[contacts_action_start:contacts_action_end]
        if contacts_action_start >= 0 and contacts_action_end >= 0
        else ""
    )

    checks = [
        require(select_source, "new ContactRosterModelSource", select_path),
        require(select_source, "new ContactSelectionView", select_path),
        forbid(select_source, "new RosterList", select_path),
        forbid(select_source, "new SelectJidFragment", select_path),
        require(select_source, "selected.connect(on_selected)", select_path),
        forbid(select_source, "selected.connect((account, jid) =>", select_path),
        require(view_source, "new ListView(projection.selection, factory)", view_path),
        require(view_source, "factory.unbind.connect", view_path),
        require(view_source, "factory.teardown.connect", view_path),
        require(row_source, "presence_observer).unsubscribe()", row_path),
        require(row_source, "avatar_observer).unsubscribe()", row_path),
        require(row_source, "set_show_account_hint", row_path),
        require(view_source, "row.set_show_account_hint(show_account_hint)", view_path),
        require(view_source, "UI-TIMING ContactSelectionView.summary", view_path),
        require(view_source, "pool_max=%d bound_max=%d", view_path),
        require(view_source, "projection.activate_position(position)", view_path),
        require(conference_source, "new SelectJidFragment", conference_path),
        require(settings_source, "new ListView(null, contact_factory)", settings_path),
        require(settings_source, "new ContactRosterModelSource", settings_path),
        require(settings_source, "new NoSelection", settings_path),
        require(settings_source, "contact_factory.unbind.connect", settings_path),
        require(settings_source, "contact_factory.teardown.connect", settings_path),
        require(settings_source, "detach_contact_list_view();", settings_path),
        require(settings_source, "release_detached_factory_rows();", settings_path),
        require(settings_source, "contact_list_view.factory = null", settings_path),
        require(settings_source, "factory_rows.clear()", settings_path),
        require(settings_source, "min_content_height = 320", settings_path),
        require(settings_source, "propagate_natural_height = false", settings_path),
        require(settings_source, "list_item).activatable = false", settings_path),
        require(settings_source, "list_item).selectable = false", settings_path),
        require(settings_source, "list_item).accessible_label = accessible_label", settings_path),
        require(settings_source, "add_contact_button.update_property(", settings_path),
        require(settings_source, "UI-TIMING Preferences.contacts.factory_%s", settings_path),
        require(settings_source, "pool_max=%d bound_max=%d", settings_path),
        require(settings_source, "live_pool=%d live_bound=%d", settings_path),
        forbid(settings_source, "CONTACT_BATCH_SIZE", settings_path),
        forbid(settings_source, "append_contact_batch", settings_path),
        forbid(settings_source, "pending_contacts", settings_path),
        require(
            settings_row_source,
            "identity_row.bind(preferences_model.stream_interactor, item, show_account_hint, true)",
            settings_row_path,
        ),
        require(settings_row_source, "edit_requested", settings_row_path),
        require(settings_row_source, "mute_requested", settings_row_path),
        require(settings_row_source, "block_requested", settings_row_path),
        require(settings_row_source, "remove_requested", settings_row_path),
        require(settings_row_source, "new Label(_(\"Removing\"))", settings_row_path),
        require(settings_row_source, "button.update_property(AccessibleProperty.LABEL", settings_row_path),
        require(settings_row_source, "identity_row.unbind()", settings_row_path),
        require(settings_row_source, ").get_conversation(", settings_row_path),
        require_count(settings_row_source, ").create_conversation(", 1, settings_row_path),
        require(settings_source, "Conversation.NotifySetting.OFF", settings_path),
        require(settings_source, "Conversation.NotifySetting.DEFAULT", settings_path),
        require(settings_row_source, ").is_blocked(", settings_row_path),
        require(settings_source, "set_jid_handle(account, jid, alias_to_set)", settings_path),
        require(settings_source, "item.jid.equals_bare(jid)", settings_path),
        require(settings_source, 'new_alias == "" ? null : new_alias', settings_path),
        require(settings_source, "pending_removals", settings_path),
        require(settings_source, "get_contact_key", settings_path),
        require(settings_source, "remove_jid_async", settings_path),
        require(settings_source, "Conversation history will be kept", settings_path),
        require(settings_source, "RosterRemoveResult.SERVER_REJECTED", settings_path),
        require(settings_source, "RosterRemoveResult.UNAVAILABLE", settings_path),
        require_order(
            settings_source,
            "RosterRemoveResult result = yield roster_manager.remove_jid_async(account, jid);\n"
            "        pending_removals.remove(contact_key);",
            "if (this.get_root() == null) return;",
            settings_path,
        ),
        require(settings_source, "roster_source).deactivate()", settings_path),
        require(
            application_source,
            "private AddChatDialog? active_add_chat_dialog = null;",
            application_path,
        ),
        require(
            contacts_action_source,
            "present_dialog ((!) active_add_chat_dialog, window);\n                return;",
            application_path,
        ),
        require(
            contacts_action_source,
            "add_chat_dialog.closed.connect (() => {",
            application_path,
        ),
        require(
            contacts_action_source,
            "present_dialog (add_chat_dialog, window);",
            application_path,
        ),
        require(
            contacts_action_source,
            "if (active_add_chat_dialog == add_chat_dialog) {\n"
            "                    active_add_chat_dialog = null;",
            application_path,
        ),
        require_count(contacts_action_source, "new AddChatDialog", 1, application_path),
        require_order(
            contacts_action_source,
            "if (active_add_chat_dialog != null) {",
            "AddChatDialog add_chat_dialog = new AddChatDialog",
            application_path,
        ),
        require_order(
            contacts_action_source,
            "active_add_chat_dialog = add_chat_dialog;",
            "add_chat_dialog.closed.connect (() => {",
            application_path,
        ),
        require_order(
            contacts_action_source,
            "add_chat_dialog.closed.connect (() => {",
            "present_dialog (add_chat_dialog, window);",
            application_path,
        ),
    ]
    return 0 if all(checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
