#!/usr/bin/env python3
"""Keep Unicode paths out of the native MinGW driver's child-process argv."""

from __future__ import annotations

import json
import ntpath
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def relative_unicode_path(value: str, cwd: str) -> str:
    """Relativize a Windows path only when its drive and Unicode need are clear."""
    if value.isascii() or not ntpath.isabs(value):
        return value
    drive, _ = ntpath.splitdrive(value)
    cwd_drive, _ = ntpath.splitdrive(cwd)
    if not drive or drive.casefold() != cwd_drive.casefold():
        return value
    return ntpath.relpath(value, cwd).replace("\\", "/")


def rewrite_argument(value: str, cwd: str) -> str:
    # Leave macro values, linker options and other compiler flags intact.
    # Separate path operands (including those after -o/-MF/-isystem) arrive
    # here as bare absolute paths; recognize only these attached spellings.
    for prefix in ("@", "-isystem", "-iquote", "-include", "-imacros", "-MF", "-I", "-L", "-o"):
        if value.startswith(prefix):
            return prefix + relative_unicode_path(value[len(prefix):], cwd)
    return relative_unicode_path(value, cwd)


def compiler_command(interpreter: str, adapter: str, compiler: str) -> list[str]:
    # Keep Python as the compiler, not Meson's compile-only CMake launcher.
    # CMake flattens subsequent arguments into COMPILER_ARG1. A whitespace-free
    # bootstrap preserves the script path there, including Unicode and spaces.
    # The path contributes only UTF-8 hex data, never Python/shell syntax.
    bootstrap = (
        "__import__('runpy').run_path(bytes.fromhex('"
        + adapter.encode("utf-8").hex()
        + "').decode(),run_name='__main__')"
    )
    return [interpreter, "-X", "utf8", "-c", bootstrap, "--", compiler]


def write_native_file(output: Path) -> None:
    # This adapter is selected only by the native Windows distribution entry.
    # Resolve the existing compiler binaries, without replacing/updating them.
    compilers = {"c": shutil.which("gcc"), "cpp": shutil.which("g++")}
    if not all(compilers.values()):
        raise SystemExit("MinGW gcc and g++ must already be on PATH")
    interpreter = Path(sys.executable).resolve().as_posix()
    adapter = Path(__file__).resolve().as_posix()
    lines = ["[binaries]"]
    for language, compiler in compilers.items():
        command = compiler_command(interpreter, adapter, Path(compiler).resolve().as_posix())
        # Triple quotes preserve the bootstrap's Python quotes. Machine files
        # double backslashes before parsing, so backslash-escaped quotes fail.
        quoted = ["'''" + value + "'''" for value in command]
        lines.append(language + " = [" + ", ".join(quoted) + "]")
    bash_path = shutil.which("bash")
    if bash_path and "system32" in bash_path.lower():
        for candidate in ("/usr/bin/bash.exe", "/bin/bash.exe", "C:/msys64/usr/bin/bash.exe"):
            if os.path.exists(candidate):
                bash_path = candidate
                break
    if bash_path:
        lines.append(f"bash = '{Path(bash_path).resolve().as_posix()}'")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines) + "\n", encoding="utf-8")


def self_test() -> None:
    for username in ("Игорь", "Игорь Петров"):
        cwd = f"C:/Users/{username}/dinox/build/meson-private/probe"
        path = cwd + "/testfile.c"
        assert rewrite_argument(path, cwd) == "testfile.c"
        assert rewrite_argument("-o" + cwd + "/output.exe", cwd) == "-ooutput.exe"
        assert rewrite_argument("-I" + cwd + "/headers", cwd) == "-Iheaders"
        assert rewrite_argument("-L" + cwd + "/libraries", cwd) == "-Llibraries"
        assert rewrite_argument("-MF" + cwd + "/output.d", cwd) == "-MFoutput.d"
        assert rewrite_argument("@" + cwd + "/link.rsp", cwd) == "@link.rsp"
        assert rewrite_argument("c:" + path[2:], cwd) == "testfile.c"
        for unchanged in (
            '-DPROFILE_PATH="' + path + '"',
            "--unknown=" + path,
            "-Wl,--out-implib," + path,
            "D:" + path[2:],
            "//other-host/share/Игорь/file.c",
            "relative/Игорь.c",
            "/tmp/Игорь/file.c",
            "C:/msys64/mingw64/include",
            "-O2", "-o", "-isystem", "-include", "-MF", "-DИМЯ=1",
        ):
            assert rewrite_argument(unchanged, cwd) == unchanged, unchanged
    # Exercise the bootstrap without a compiler: preserve source identity,
    # argument boundaries and the adapter's exit status under either path.
    with tempfile.TemporaryDirectory(prefix="dinox-compiler-test-") as directory:
        for username in ("Игорь", "Игорь Петров"):
            adapter = Path(directory) / username / "adapter.py"
            adapter.parent.mkdir()
            adapter.write_text(
                "import json, sys\nprint(json.dumps([__file__, sys.argv[1:]]))\nsys.exit(23)\n",
                encoding="utf-8",
            )
            command = compiler_command(sys.executable, adapter.as_posix(), "test-compiler")
            assert command[4].isascii() and not any(char.isspace() for char in command[4])
            result = subprocess.run(
                command + ["-DKEEP=a b"], stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, encoding="utf-8", timeout=10,
            )
            assert result.returncode == 23, result.stderr
            assert json.loads(result.stdout) == [adapter.as_posix(), ["--", "test-compiler", "-DKEEP=a b"]]
    print("OK: Windows compiler Unicode path adapter")


def main(args: list[str]) -> int:
    if args == ["--self-test"]:
        self_test()
        return 0
    if len(args) == 2 and args[0] == "--write-native-file":
        write_native_file(Path(args[1]))
        return 0
    if len(args) < 2 or args[0] != "--":
        raise SystemExit("Usage: windows-compiler-paths.py -- COMPILER [ARG ...]")
    compiler, *arguments = args[1:]
    command = [compiler] + [rewrite_argument(arg, os.getcwd()) for arg in arguments]
    # No shell, RSP-content rewrite, logging of argument values, or tool changes.
    return subprocess.call(command)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
