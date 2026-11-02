#!/usr/bin/env python3

"""Guard MUC member-popover input, snapshot lifecycle, and Win32 focus."""

from pathlib import Path
import sys


def require(source: str, needle: str, path: Path) -> bool:
    if needle in source:
        return True
    print(f"{path}: missing member-popover input marker: {needle}", file=sys.stderr)
    return False


def require_order(source: str, first: str, second: str, path: Path) -> bool:
    first_position = source.find(first)
    second_position = source.find(second, first_position + len(first))
    if first_position >= 0 and second_position >= 0:
        return True
    print(f"{path}: required ordering missing: {first} before {second}", file=sys.stderr)
    return False


def forbid(source: str, needle: str, path: Path) -> bool:
    if needle not in source:
        return True
    print(f"{path}: retired member-list state returned: {needle}", file=sys.stderr)
    return False


def require_count(source: str, needle: str, count: int, path: Path) -> bool:
    actual = source.count(needle)
    if actual >= count:
        return True
    print(
        f"{path}: expected at least {count} occurrences of {needle}, found {actual}",
        file=sys.stderr,
    )
    return False


def method_block(source: str, signature: str) -> str:
    start = source.find(signature)
    if start < 0:
        return ""
    opening_brace = source.find("{", start + len(signature))
    if opening_brace < 0:
        return ""

    depth = 0
    for position in range(opening_brace, len(source)):
        if source[position] == "{":
            depth += 1
        elif source[position] == "}":
            depth -= 1
            if depth == 0:
                return source[start : position + 1]
    return ""


def main() -> int:
    if len(sys.argv) != 14:
        print(
            f"usage: {Path(sys.argv[0]).name} OCCUPANTS_ENTRY OCCUPANT_LIST OCCUPANT_ROW MEMBER_SECTION "
            "OCCUPANT_VIEW CONVERSATION_ITEM SELECTOR_ROW UI_HELPER CONVERSATION_DETAILS ADD_GROUPCHAT "
            "WIN32_C WIN32_H WIN32_VAPI",
            file=sys.stderr,
        )
        return 2

    entry_path, list_path, row_path, section_path, view_path, conversation_item_path, selector_path, helper_path, details_path, add_groupchat_path, win32_c_path, win32_h_path, win32_vapi_path = map(
        Path, sys.argv[1:]
    )
    entry_source = entry_path.read_text(encoding="utf-8")
    list_source = list_path.read_text(encoding="utf-8")
    row_source = row_path.read_text(encoding="utf-8")
    section_source = section_path.read_text(encoding="utf-8")
    view_source = view_path.read_text(encoding="utf-8")
    conversation_item_source = conversation_item_path.read_text(encoding="utf-8")
    selector_source = selector_path.read_text(encoding="utf-8")
    helper_source = helper_path.read_text(encoding="utf-8")
    details_source = details_path.read_text(encoding="utf-8")
    add_groupchat_source = add_groupchat_path.read_text(encoding="utf-8")
    win32_c_source = win32_c_path.read_text(encoding="utf-8")
    win32_h_source = win32_h_path.read_text(encoding="utf-8")
    win32_vapi_source = win32_vapi_path.read_text(encoding="utf-8")
    lightweight_refresh_source = method_block(
        list_source,
        "private void refresh_item_lightweight(OccupantListItem item)",
    )
    snapshot_apply_source = method_block(
        list_source,
        "private void apply_snapshot_item_state(OccupantListItem item,",
    )
    root_event_source = method_block(
        entry_source,
        "private bool on_root_event(Gdk.Event event)",
    )
    connection_state_source = method_block(
        entry_source,
        "private void on_connection_state_changed(Account account,",
    )
    stream_resumed_source = method_block(
        entry_source,
        "private void on_stream_resumed(Account account, XmppStream stream)",
    )
    ensure_menu_source = method_block(
        entry_source,
        "private void ensure_menu()",
    )
    destructor_source = method_block(
        entry_source,
        "~OccupantsEntry()",
    )
    deferred_cleanup_source = method_block(
        view_source,
        "public void deactivate_for_deferred_cleanup()",
    )
    focus_release_source = method_block(
        view_source,
        "private void release_focus_to_parent()",
    )
    closed_source = method_block(
        view_source,
        "private void on_closed()",
    )
    safe_after_close_source = method_block(
        view_source,
        "public void detach_safely_after_close()",
    )
    avatar_menu_source = method_block(
        conversation_item_source,
        "private void open_avatar_menu()",
    )

    checks = [
        require(entry_source, "member_button_pointer_sequence_active = true;", entry_path),
        require(entry_source, "menu_pointer_sequence_active = true;", entry_path),
        require(entry_source, "attach_menu_click_guard(new_menu);", entry_path),
        require(
            entry_source,
            ".connection_state_changed.connect(on_connection_state_changed);",
            entry_path,
        ),
        require(
            entry_source,
            "stream_interactor.stream_resumed.connect(",
            entry_path,
        ),
        require(
            connection_state_source,
            "button.sensitive = false;",
            entry_path,
        ),
        require(
            connection_state_source,
            "cancel_pending_menu_open();",
            entry_path,
        ),
        require(
            connection_state_source,
            "if (menu != null)",
            entry_path,
        ),
        require_order(
            connection_state_source,
            "cancel_pending_menu_open();",
            "button.sensitive = false;",
            entry_path,
        ),
        require(
            connection_state_source,
            "button.sensitive = is_groupchat_joined_selected();",
            entry_path,
        ),
        require(
            stream_resumed_source,
            "button.sensitive = is_groupchat_joined_selected();",
            entry_path,
        ),
        require(
            stream_resumed_source,
            "stream_interactor.get_stream(account) != stream",
            entry_path,
        ),
        require(
            ensure_menu_source,
            "if (button.active) button.active = false;",
            entry_path,
        ),
        require_order(
            ensure_menu_source,
            "!is_groupchat_joined_selected())",
            "if (button.active) button.active = false;",
            entry_path,
        ),
        require_order(
            ensure_menu_source,
            "if (button.active) button.active = false;",
            "button.sensitive = is_groupchat_joined_selected();",
            entry_path,
        ),
        require(
            destructor_source,
            "connection_state_handler);",
            entry_path,
        ),
        require(
            destructor_source,
            "stream_resumed_handler);",
            entry_path,
        ),
        require(
            entry_source,
            "if (member_button_pointer_sequence_active || menu_pointer_sequence_active)",
            entry_path,
        ),
        require_order(
            entry_source,
            "if (member_button_pointer_sequence_active || menu_pointer_sequence_active)",
            "schedule_outside_popdown((!) active_menu);",
            entry_path,
        ),
        require(root_event_source, "button.compute_bounds((!) current_root", entry_path),
        forbid(root_event_source, ".pick(", entry_path),
        forbid(root_event_source, ".is_ancestor(", entry_path),
        forbid(entry_source, "private weak Widget? outside_click_root", entry_path),
        forbid(entry_source, "private weak Gtk.Window? outside_click_window", entry_path),
        require(
            deferred_cleanup_source,
            "release_focus_to_parent();",
            view_path,
        ),
        require_order(
            deferred_cleanup_source,
            "release_focus_to_parent();",
            "list.deactivate_for_deferred_cleanup();",
            view_path,
        ),
        require(focus_release_source, "cursor = current.get_parent();", view_path),
        require(focus_release_source, "parent).grab_focus()) return;", view_path),
        require(focus_release_source, "root).set_focus(null);", view_path),
        forbid(focus_release_source, ".is_ancestor(", view_path),
        require(
            view_source,
            "GTK_TOOLTIP_SAFE_DETACH_DELAY_MS = 550",
            view_path,
        ),
        require(
            view_source,
            "minor < 18 || (minor == 18 && micro < 5)",
            view_path,
        ),
        require(view_source, "this.closed.connect(on_closed);", view_path),
        require(
            closed_source,
            "mark_safe_detach_deadline();",
            view_path,
        ),
        require_order(
            closed_source,
            "mark_safe_detach_deadline();",
            "reset();",
            view_path,
        ),
        require(
            view_source,
            "public uint get_safe_detach_delay_ms()",
            view_path,
        ),
        require(view_source, "WeakRef view_weak = WeakRef(this);", view_path),
        require_order(
            view_source,
            "private bool run_safe_detach()",
            "if (this.visible) return Source.REMOVE;",
            view_path,
        ),
        require(
            entry_source,
            "uint safe_detach_delay_ms = old_menu.get_safe_detach_delay_ms();",
            entry_path,
        ),
        require_count(entry_source, ".popdown_for_lifecycle();", 4, entry_path),
        require(
            avatar_menu_source,
            "new AvatarMenuBinding(this, menu, avatar_picture);",
            conversation_item_path,
        ),
        require(
            avatar_menu_source,
            "connect_avatar_menu_binding(menu, menu_binding);",
            conversation_item_path,
        ),
        forbid(avatar_menu_source, "menu.unparent();", conversation_item_path),
        require(
            avatar_menu_source,
            "avatar_picture.get_root() as Widget",
            conversation_item_path,
        ),
        require(
            avatar_menu_source,
            "avatar_picture.compute_bounds((!) popover_parent",
            conversation_item_path,
        ),
        require(
            avatar_menu_source,
            "menu.set_parent((!) popover_parent);",
            conversation_item_path,
        ),
        forbid(
            avatar_menu_source,
            "menu.set_parent(avatar_picture);",
            conversation_item_path,
        ),
        require(
            conversation_item_source,
            "skeleton_weak = WeakRef(skeleton);",
            conversation_item_path,
        ),
        require(
            conversation_item_source,
            "menu_weak = WeakRef(menu);",
            conversation_item_path,
        ),
        require(
            conversation_item_source,
            "anchor_weak = WeakRef(anchor);",
            conversation_item_path,
        ),
        require(
            conversation_item_source,
            "menu.add_tick_callback(on_position_tick);",
            conversation_item_path,
        ),
        require(
            conversation_item_source,
            "anchor).compute_bounds((!) parent, out bounds)",
            conversation_item_path,
        ),
        require(
            conversation_item_source,
            "has_last_bounds && x == last_x && y == last_y",
            conversation_item_path,
        ),
        require_order(
            conversation_item_source,
            "if (has_last_bounds && x == last_x",
            "menu).set_pointing_to({",
            conversation_item_path,
        ),
        require(
            conversation_item_source,
            "closed_menu).remove_tick_callback(position_tick_id);",
            conversation_item_path,
        ),
        require_count(
            conversation_item_source,
            "menu).popdown_for_lifecycle();",
            2,
            conversation_item_path,
        ),
        require(
            conversation_item_source,
            "closed_menu).detach_safely_after_close();",
            conversation_item_path,
        ),
        require(safe_after_close_source, "schedule_safe_detach();", view_path),
        forbid(
            safe_after_close_source,
            "cancel_pending_popdown_action();",
            view_path,
        ),
        forbid(safe_after_close_source, "close_and_detach();", view_path),
        require(
            entry_source,
            "SystrayWin32.foreground_window_is_external()",
            entry_path,
        ),
        require(
            entry_source,
            "WINDOW_INACTIVE_WATCH_INTERVAL_MS",
            entry_path,
        ),
        require(
            entry_source,
            "close_menu_for_inactive_window((!) active_menu);",
            entry_path,
        ),
        require(list_source, "UI-TIMING OccupantList.activate", list_path),
        forbid(list_source, "show_list_button.visible = true", list_path),
        forbid(list_source, "show_list_button.clicked.connect", list_path),
        require(
            list_source,
            "enter_stable_empty_snapshot_surface()",
            list_path,
        ),
        require(
            list_source,
            "cache.snapshot_stream_generation == delta.room.stream_generation",
            list_path,
        ),
        require(
            list_source,
            "muc_manager.room_initial_sync_started.connect(",
            list_path,
        ),
        require(
            list_source,
            "private void on_room_initial_sync_started(Account account, Jid room_jid)",
            list_path,
        ),
        require(
            list_source,
            "get_room_occupant_generation(conversation.account,",
            list_path,
        ),
        require(
            list_source,
            "cache.lifecycle_stream_generation ==",
            list_path,
        ),
        require_order(
            list_source,
            "private void on_room_initial_sync_started(Account account, Jid room_jid)",
            "clear_cache_for_room_lifecycle(active_generation);",
            list_path,
        ),
        require(
            list_source,
            'reason == "stale-snapshot" ||',
            list_path,
        ),
        require(
            list_source,
            'reason == "snapshot-apply-abort" ||',
            list_path,
        ),
        require(
            list_source,
            'reason == "live-batch-fallback";',
            list_path,
        ),
        require(list_source, "get_role_search_text()", list_path),
        require(
            list_source,
            "Dino.AvatarReadPolicy.LOCAL_CACHE_ONLY;",
            list_path,
        ),
        forbid(list_source, "Dino.AvatarReadPolicy.NETWORK_ALLOWED", list_path),
        require(row_source, "get_visible_role_text(item)", row_path),
        require(
            section_source,
            "internal class MucMemberListSectionModel : Object",
            section_path,
        ),
        require(
            list_source,
            "switch (get_member_list_section(item))",
            list_path,
        ),
        require(row_source, "MucMemberListSectionModel.role_is_redundant", row_path),
        require(row_source, "hats_badges.set_hats(item.hats);", row_path),
        require(
            lightweight_refresh_source,
            'if (item.is_offline_member) {\n'
            '            item.hats_text = "";\n'
            '            item.hats_markup = "";\n'
            '            item.hats = new ArrayList<Xmpp.Xep.Muc.Hat>();\n'
            '        } else {\n'
            '            update_item_hats(item);\n'
            '        }',
            list_path,
        ),
        require(
            snapshot_apply_source,
            "apply_snapshot_hats(item, snapshot);",
            list_path,
        ),
        require_order(
            list_source,
            "if (completed_queue_size == 0)",
            "cache.loaded = false;",
            list_path,
        ),
        require_order(
            list_source,
            "cache.loaded = false;",
            "cache.loaded = true;",
            list_path,
        ),
        require(view_source, "UI-TIMING OccupantMenu.View.show_menu", view_path),
        require(
            view_source,
            "selected_peer_identity = target_is_live",
            view_path,
        ),
        require(
            view_source,
            "get_private_message_peer_identity(conversation.account, jid)",
            view_path,
        ),
        require(
            view_source,
            "private_message_peer_identity_matches(account,",
            view_path,
        ),
        require(
            view_source,
            "selected_room_context = muc_manager.capture_current_muc_context(",
            view_path,
        ),
        require(
            view_source,
            "muc_manager.is_current_muc_context(account,",
            view_path,
        ),
        require(
            view_source,
            "muc_manager.room_real_jid_visibility_revoked.connect(",
            view_path,
        ),
        require(
            view_source,
            "private void on_room_real_jid_visibility_revoked(Account account,",
            view_path,
        ),
        require_order(
            view_source,
            "private void on_room_real_jid_visibility_revoked(Account account,",
            "clear_selected_target_binding();",
            view_path,
        ),
        require(
            view_source,
            "SignalHandler.disconnect(muc_manager,\n                real_jid_visibility_revoked_handler_id);",
            view_path,
        ),
        require(
            view_source,
            "selected_block_target = affiliation_target != null &&",
            view_path,
        ),
        require(
            view_source,
            "if (block_target.is_full() || bound_affiliation_target == null ||",
            view_path,
        ),
        forbid(view_source, "selected_block_target ?? jid", view_path),
        forbid(view_source, "ban_for_minutes_checked", view_path),
        forbid(view_source, "Ban (10", view_path),
        forbid(view_source, "Ban (15", view_path),
        forbid(view_source, "Ban (30", view_path),
        require(view_source, "muc_manager.kick_possible(account, target)", view_path),
        require(
            view_source,
            "muc_manager.voice_change_possible(account, target, role)",
            view_path,
        ),
        require(
            view_source,
            "MucManager.can_request_affiliation_change",
            view_path,
        ),
        require(
            view_source,
            "change_role_checked_in_context(account,",
            view_path,
        ),
        require(
            view_source,
            "set_affiliation_checked_in_context(account,",
            view_path,
        ),
        require(view_source, "blocking_manager.block_checked", view_path),
        require(view_source, "blocking_manager.unblock_checked", view_path),
        require(
            view_source,
            "Conversation.Type.GROUPCHAT_PM,\n                                bound_identity",
            view_path,
        ),
        forbid(
            view_source,
            "create_conversation(target_jid, account, Conversation.Type.CHAT)",
            view_path,
        ),
        require(
            selector_source,
            "bool is_muc_pm = conversation.type_ ==",
            selector_path,
        ),
        require(
            selector_source,
            "if (conversation.type_ != Conversation.Type.CHAT) return;",
            selector_path,
        ),
        require(
            view_source,
            "invite_list.visible = muc_manager.mediated_invite_possible(",
            view_path,
        ),
        require(
            view_source,
            "muc_manager.room_info_updated.connect(\n                on_invite_permission_state_changed)",
            view_path,
        ),
        require(
            view_source,
            "muc_manager.occupant_affiliation_updated.connect((account, room,",
            view_path,
        ),
        require_count(
            view_source,
            "SignalHandler.disconnect(muc_manager,",
            3,
            view_path,
        ),
        require(
            view_source,
            "private void on_invite_permission_state_changed(Account account,",
            view_path,
        ),
        require(
            view_source,
            "!room.equals_bare(conversation.counterpart)) return;\n        update_invite_visibility();",
            view_path,
        ),
        require(
            selector_source,
            "bool can_invite_current_room =\n                muc_manager.mediated_invite_possible(",
            selector_path,
        ),
        require(
            selector_source,
            "if (!muc_manager.mediated_invite_possible(",
            selector_path,
        ),
        require_count(
            helper_source,
            "if (!muc_manager.is_joined(conversation.counterpart,",
            2,
            helper_path,
        ),
        require_count(
            helper_source,
            "if (!muc_manager.mediated_invite_possible(conversation.account,",
            2,
            helper_path,
        ),
        require(
            helper_source,
            'show_muc_invite_error_dialog_for_error(parent, "not-allowed");',
            helper_path,
        ),
        require(
            helper_source,
            "MucInviteDelivery.MEDIATED,",
            helper_path,
        ),
        forbid(helper_source, "MucInviteDelivery.DIRECT", helper_path),
        forbid(helper_source, "Send as direct invite", helper_path),
        forbid(helper_source, "direct_invite.active", helper_path),
        require(
            details_source,
            "set_config_form_detailed_in_context(",
            details_path,
        ),
        require(
            details_source,
            "destroy_room_detailed_in_context.begin(",
            details_path,
        ),
        require(
            details_source,
            "change_subject_checked_in_context(",
            details_path,
        ),
        require(
            details_source,
            '"dinox-hats-room-context"',
            details_path,
        ),
        require(
            details_source,
            "HATS_DIALOG_CONTENT_WIDTH = 700",
            details_path,
        ),
        require(
            details_source,
            "HATS_DIALOG_CONTENT_HEIGHT = 600",
            details_path,
        ),
        require(
            details_source,
            "dialog.content_height = HATS_DIALOG_CONTENT_HEIGHT;",
            details_path,
        ),
        require(
            details_source,
            "fetch_muc_vcard_in_owner_context(",
            details_path,
        ),
        require(
            add_groupchat_source,
            "get_config_form_in_context(",
            add_groupchat_path,
        ),
        require(
            add_groupchat_source,
            "publish_muc_vcard_in_owner_context(",
            add_groupchat_path,
        ),
        require(
            list_source,
            "bare_affiliation_changed.connect(",
            list_path,
        ),
        require(
            list_source,
            "on_bare_affiliation_changed",
            list_path,
        ),
        require(win32_c_source, "GetForegroundWindow ()", win32_c_path),
        require(win32_c_source, "GetWindowThreadProcessId", win32_c_path),
        require(win32_c_source, "GetCurrentProcessId ()", win32_c_path),
        require(
            win32_h_source,
            "gboolean systray_win32_foreground_window_is_external (void);",
            win32_h_path,
        ),
        require(
            win32_vapi_source,
            "public static bool foreground_window_is_external ();",
            win32_vapi_path,
        ),
    ]
    return 0 if all(checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
