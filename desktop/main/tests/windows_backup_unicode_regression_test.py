#!/usr/bin/env python3

"""Guard the bundled archive helper and manifest-safe OpenSSL call shape."""

from pathlib import Path
import sys
import re


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


def windows_view(source: str) -> str:
    """Return the branch selected by Vala when WINDOWS is defined."""

    active = True
    stack: list[tuple[bool, bool]] = []
    selected: list[str] = []
    for line in source.splitlines():
        directive = line.strip()
        if directive in ("#if WINDOWS", "#if !WINDOWS"):
            condition = directive == "#if WINDOWS"
            stack.append((active, condition))
            active = active and condition
        elif directive == "#else" and stack:
            parent_active, condition = stack[-1]
            condition = not condition
            stack[-1] = (parent_active, condition)
            active = parent_active and condition
        elif directive == "#endif" and stack:
            parent_active, _ = stack.pop()
            active = parent_active
        elif active:
            selected.append(line)
    return "\n".join(selected)


def require(source: str, needle: str, path: Path, label: str) -> bool:
    if re.sub(r"\s+", " ", needle) in re.sub(r"\s+", " ", source):
        return True
    print(f"{path}: missing {label}: {needle}", file=sys.stderr)
    return False


def forbid(source: str, needle: str, path: Path, label: str) -> bool:
    if needle not in source:
        return True
    print(f"{path}: forbidden {label}: {needle}", file=sys.stderr)
    return False


def require_count(
    source: str, needle: str, expected: int, path: Path, label: str
) -> bool:
    actual = source.count(needle)
    if actual == expected:
        return True
    print(
        f"{path}: expected {expected} {label}, found {actual}: {needle}",
        file=sys.stderr,
    )
    return False


def main() -> int:
    if len(sys.argv) != 3:
        print(
            f"usage: {Path(sys.argv[0]).name} APPLICATION_VALA MAIN_VALA",
            file=sys.stderr,
        )
        return 2

    path = Path(sys.argv[1])
    main_path = Path(sys.argv[2])
    source = path.read_text(encoding="utf-8")
    main_source = main_path.read_text(encoding="utf-8")
    stream_helper = method_block(
        source, "private static bool run_windows_backup_archive_subprocess ("
    )
    backup = windows_view(method_block(source, "private void perform_backup ("))
    restore = windows_view(
        method_block(source, "private void perform_restore_backup (")
    )

    checks = [
        require(stream_helper, "string? input_path,", path, "optional pipe input"),
        require(stream_helper, 'extract ? "extract" : "create"', path, "fixed archive helper commands"),
        require(stream_helper, "get_windows_backup_archive_helper ()", path, "shared bundled helper selection"),
        require(
            stream_helper,
            "if (input_path != null) {",
            path,
            "conditional input-file opening",
        ),
        require(
            stream_helper,
            "launcher.set_cwd ((!) cwd);",
            path,
            "Unicode-safe child cwd",
        ),
        require(
            stream_helper,
            "dino_subprocess_launcher_spawnv (launcher, argv)",
            path,
            "const-correct launcher spawn",
        ),
        forbid(stream_helper, "stdin_prefix", path, "shared password/data stdin"),
        require(
            backup,
            "run_windows_backup_archive_subprocess (\n                    false,",
            path,
            "bundled helper stdout archive",
        ),
        require(
            backup,
            '"-in", temp_tar_path,\n                    "-out", backup_path,',
            path,
            "manifest-safe OpenSSL encryption paths",
        ),
        require(backup, '"-pass", "stdin"', path, "OpenSSL password stdin"),
        require(
            restore,
            "run_windows_backup_archive_subprocess (\n                        true,",
            path,
            "bundled helper stdin extraction",
        ),
        require(
            restore,
            '"-in", backup_file,\n                    "-out", tar_path,',
            path,
            "manifest-safe OpenSSL decryption paths",
        ),
        require(restore, '"-pass", "stdin"', path, "OpenSSL password stdin"),
        require(
            source,
            "internal static void run_windows_backup_unicode_runtime_smoke ()",
            path,
            "product tar Unicode runtime smoke",
        ),
        require(
            main_source,
            "Dino.Ui.Application.run_windows_backup_unicode_runtime_smoke ();",
            main_path,
            "runtime-smoke invocation",
        ),
        forbid(backup, '"-C"', path, "Windows tar path argument"),
        forbid(restore, '"-C"', path, "Windows tar path argument"),
        forbid(backup, "system_tar", path, "system tar fallback"),
        forbid(restore, "system_tar", path, "system tar fallback"),
        forbid(source, "dinox-openssl-pass-", path, "plaintext password file"),
        forbid(source, '"-pass", "file:', path, "plaintext password file argument"),
    ]
    return 0 if all(checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
