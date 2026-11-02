#!/usr/bin/env python3
"""Check Git-tracked Python files with py_compile."""

import argparse
import os
import py_compile
import subprocess
import sys
from pathlib import Path
from tempfile import NamedTemporaryFile, TemporaryDirectory


PROJECT_DIR = Path(__file__).resolve().parent.parent


def parse_args():
    parser = argparse.ArgumentParser(
        description="Check Python syntax for Git-tracked Python files."
    )
    parser.add_argument(
        "files",
        nargs="*",
        help="specific Python files to check; defaults to Git-tracked *.py files",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="validate checker behavior with built-in valid and broken samples",
    )
    return parser.parse_args()


def tracked_python_files():
    result = subprocess.run(
        ["git", "ls-files", "*.py"],
        cwd=PROJECT_DIR,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return [PROJECT_DIR / line for line in result.stdout.splitlines() if line]


def check_file(path, quiet=False):
    if not path.exists():
        if not quiet:
            print(f"{path}: file not found", file=sys.stderr)
        return False
    if not path.is_file():
        if not quiet:
            print(f"{path}: not a regular file", file=sys.stderr)
        return False

    tmp_name = None
    try:
        with NamedTemporaryFile(prefix="dinox-pycompile-", suffix=".pyc", delete=False) as tmp:
            tmp_name = tmp.name
        py_compile.compile(str(path), cfile=tmp_name, doraise=True)
    except py_compile.PyCompileError as error:
        if not quiet:
            print(error.msg, file=sys.stderr)
        return False
    finally:
        if tmp_name and os.path.exists(tmp_name):
            os.unlink(tmp_name)
    return True


def run_self_test():
    with TemporaryDirectory(prefix="dinox-python-syntax-self-test-") as tmp:
        root = Path(tmp)
        valid = root / "valid.py"
        valid.write_text('print("valid")\n', encoding="utf-8")
        if not check_file(valid):
            raise AssertionError("self-test rejected valid Python")

        broken = root / "broken.py"
        broken.write_text("def broken(:\n", encoding="utf-8")
        if check_file(broken, quiet=True):
            raise AssertionError("self-test accepted broken Python")

        missing = root / "missing.py"
        if check_file(missing, quiet=True):
            raise AssertionError("self-test accepted missing Python file")

        if check_file(root, quiet=True):
            raise AssertionError("self-test accepted directory path")

    print("Self-test OK")


def main():
    args = parse_args()
    if args.self_test:
        run_self_test()
        return 0

    if args.files:
        files = [Path(path) if os.path.isabs(path) else PROJECT_DIR / path for path in args.files]
    else:
        files = tracked_python_files()

    failed = False
    for path in files:
        if not check_file(path):
            failed = True

    if failed:
        return 1

    print(f"Python syntax OK ({len(files)} files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
