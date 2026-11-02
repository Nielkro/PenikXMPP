#!/usr/bin/env python3

"""Guard local/global history deletion choices and the German warning text."""

from pathlib import Path
import ast
import sys


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


def po_translation(source: str, expected_msgid: str) -> str:
    for entry in source.split("\n\n"):
        msgid_values: list[str] = []
        msgstr_values: list[str] = []
        active_values: list[str] | None = None
        for line in entry.splitlines():
            if line.startswith("msgid "):
                active_values = msgid_values
                active_values.append(line[len("msgid ") :])
            elif line.startswith("msgstr "):
                active_values = msgstr_values
                active_values.append(line[len("msgstr ") :])
            elif line.startswith('"') and active_values is not None:
                active_values.append(line)

        msgid = "".join(ast.literal_eval(value) for value in msgid_values)
        if msgid == expected_msgid:
            return "".join(ast.literal_eval(value) for value in msgstr_values)
    return ""


def require(source: str, needle: str, path: Path) -> bool:
    if needle in source:
        return True
    print(f"{path}: missing clear-history marker: {needle}", file=sys.stderr)
    return False


def forbid(source: str, needle: str, path: Path) -> bool:
    if needle not in source:
        return True
    print(f"{path}: obsolete clear-history marker: {needle}", file=sys.stderr)
    return False


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {Path(sys.argv[0]).name} HELPER DE_PO", file=sys.stderr)
        return 2

    helper_path = Path(sys.argv[1])
    de_po_path = Path(sys.argv[2])
    helper_source = helper_path.read_text(encoding="utf-8")
    de_po_source = de_po_path.read_text(encoding="utf-8")
    dialog = method_block(helper_source, "public static void show_clear_history_dialog(")

    expected_translation = (
        "Lokales Löschen entfernt die gespeicherten Nachrichten von diesem Gerät. "
        "Unverschlüsselte Nachrichten kannst du erneut laden, solange sie im Serverarchiv liegen. "
        "Bereits auf diesem Gerät entschlüsselte OMEMO-Nachrichten lassen sich nach lokalem Löschen "
        "nicht allein aus dem Serverarchiv wiederherstellen. Mit „Für alle löschen“ "
        "werden außerdem Löschanfragen für deine eigenen gesendeten Nachrichten verschickt."
    )
    warning = (
        "Local deletion removes the saved messages from this device. "
        "Unencrypted messages can be loaded again while they remain in the server archive. "
        "OMEMO messages already decrypted on this device cannot be restored from the archive alone "
        "after local deletion. Deleting for everyone also sends removal requests for your own sent messages."
    )
    translated_warning = po_translation(
        de_po_source,
        warning,
    )

    checks = [
        bool(dialog),
        require(dialog, "conversation.type_ == Conversation.Type.CHAT ||", helper_path),
        require(dialog, "conversation.type_ == Conversation.Type.GROUPCHAT;", helper_path),
        require(dialog, warning, helper_path),
        require(dialog, "if (supports_global_deletion)", helper_path),
        require(dialog, 'dialog.add_response("local", _("Delete locally"));', helper_path),
        require(dialog, 'dialog.add_response("global", _("Delete for everyone"));', helper_path),
        require(dialog, 'if (response == "local")', helper_path),
        require(dialog, "clear_conversation_history(conversation, false);", helper_path),
        require(dialog, 'response == "global" && supports_global_deletion', helper_path),
        require(dialog, "clear_conversation_history(conversation, true);", helper_path),
        forbid(dialog, "Also delete for chat partner", helper_path),
        forbid(dialog, "global_check", helper_path),
        translated_warning == expected_translation,
    ]
    if translated_warning != expected_translation:
        print(
            f"{de_po_path}: unexpected German clear-history warning: "
            f"{translated_warning!r}",
            file=sys.stderr,
        )

    return 0 if all(checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
