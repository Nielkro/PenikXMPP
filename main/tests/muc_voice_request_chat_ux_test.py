#!/usr/bin/env python3

"""Guard the visitor-side MUC voice-request chat workflow."""

from pathlib import Path
import sys


def require(source: str, needle: str, path: Path) -> bool:
    if needle in source:
        return True
    print(f"{path}: missing MUC voice-request UX marker: {needle}", file=sys.stderr)
    return False


def forbid(source: str, needle: str, path: Path) -> bool:
    if needle not in source:
        return True
    print(f"{path}: retired MUC voice-request UX returned: {needle}", file=sys.stderr)
    return False


def main() -> int:
    if len(sys.argv) != 7:
        print(
            f"usage: {Path(sys.argv[0]).name} CHAT_INPUT_UI CHAT_INPUT_VIEW "
            "CHAT_INPUT_CONTROLLER APPLICATION CONVERSATION_DETAILS MAIN_MESON",
            file=sys.stderr,
        )
        return 2

    ui_path, view_path, controller_path, application_path, details_path, meson_path = map(
        Path, sys.argv[1:]
    )
    ui = ui_path.read_text(encoding="utf-8")
    view = view_path.read_text(encoding="utf-8")
    controller = controller_path.read_text(encoding="utf-8")
    application = application_path.read_text(encoding="utf-8")
    details = details_path.read_text(encoding="utf-8")
    meson = meson_path.read_text(encoding="utf-8")

    checks = [
        require(ui, 'id="request_voice_button"', ui_path),
        require(ui, '<property name="label" translatable="yes">Request permission</property>', ui_path),
        require(view, "[GtkChild] public unowned Button request_voice_button;", view_path),
        require(controller, "request_voice_button.clicked.connect(request_voice);", controller_path),
        require(controller, "voice_request_manager.request_voice(", controller_path),
        require(controller, "voice_request_manager.get_own_request(", controller_path),
        require(controller, "voice_request_manager.own_request_changed.connect(", controller_path),
        require(controller, "OwnMucVoiceRequestState.SENDING", controller_path),
        require(controller, "OwnMucVoiceRequestState.SENT", controller_path),
        require(controller, "OwnMucVoiceRequestState.FAILED", controller_path),
        require(controller, "ErrorStanza.CONDITION_RESOURCE_CONSTRAINT", controller_path),
        require(controller, "ErrorStanza.CONDITION_FORBIDDEN", controller_path),
        require(controller, "request_voice_button.visible = true;", controller_path),
        forbid(controller, "OPEN_CONVERSATION_DETAILS_URI", controller_path),
        forbid(controller, 'activate_action("open-conversation-details"', controller_path),
        forbid(application, "show_voice_request_failure", application_path),
        forbid(application, "voice_request_manager.own_request_failed.connect", application_path),
        forbid(details, "new ContactDetails.PermissionsProvider", details_path),
        forbid(meson, "src/ui/contact_details/permissions_provider.vala", meson_path),
    ]
    return 0 if all(checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
