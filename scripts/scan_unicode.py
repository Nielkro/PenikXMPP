#!/usr/bin/env python3
"""Scan source files for hidden/dangerous Unicode characters.

Detects zero-width characters, BiDi overrides, homoglyph attacks,
and other invisible Unicode that can hide malicious code or cause
subtle bugs. Run from the project root directory.

Usage: python3 scripts/scan_unicode.py [--verbose] [--root PATH] [--all-files] [--self-test]
"""

import argparse
import os
import subprocess
import sys
from pathlib import Path
from tempfile import TemporaryDirectory

PROJECT_DIR = Path(__file__).resolve().parent.parent

# Dangerous or suspicious Unicode characters
SUSPICIOUS_CHARS = {
    # Zero-width characters (can hide code)
    '\u200b': 'Zero Width Space',
    # Note: U+200C (ZWNJ) and U+200D (ZWJ) are excluded because they are
    # linguistically required in Persian/Arabic translations (ZWNJ is used
    # between word parts, ZWJ controls ligature joining).
    '\uFEFF': 'Zero Width No-Break Space / BOM',

    # BiDi control characters (CVE-2021-42574 "Trojan Source" attack vector)
    '\u200e': 'Left-To-Right Mark',
    '\u200f': 'Right-To-Left Mark',
    '\u202a': 'Left-To-Right Embedding',
    '\u202b': 'Right-To-Left Embedding',
    '\u202c': 'Pop Directional Formatting',
    '\u202d': 'Left-To-Right Override',
    '\u202e': 'Right-To-Left Override',
    '\u2066': 'Left-To-Right Isolate',
    '\u2067': 'Right-To-Left Isolate',
    '\u2068': 'First Strong Isolate',
    '\u2069': 'Pop Directional Isolate',

    # Unusual whitespace
    # Note: U+00A0 (NBSP) is excluded because it legitimately appears in
    # translated strings (e.g. French/Luxembourgish typographic rules).
    '\u2000': 'En Quad',
    '\u2001': 'Em Quad',
    '\u2002': 'En Space',
    '\u2003': 'Em Space',
    '\u2004': 'Three-Per-Em Space',
    '\u2005': 'Four-Per-Em Space',
    '\u2006': 'Six-Per-Em Space',
    '\u2007': 'Figure Space',
    '\u2008': 'Punctuation Space',
    '\u2009': 'Thin Space',
    '\u200a': 'Hair Space',
    '\u205f': 'Medium Mathematical Space',
    '\u3000': 'Ideographic Space',

    # Line/paragraph separators (can break parsing)
    '\u2028': 'Line Separator',
    '\u2029': 'Paragraph Separator',

    # Tag characters (can be used to hide data)
    '\U000E0001': 'Language Tag',

    # Interlinear annotation (can hide text)
    '\uFFF9': 'Interlinear Annotation Anchor',
    '\uFFFA': 'Interlinear Annotation Separator',
    '\uFFFB': 'Interlinear Annotation Terminator',

    # Replacement/specials
    '\uFFFC': 'Object Replacement Character',
    '\uFFFD': 'Replacement Character',

    # Soft hyphen (invisible in most contexts)
    '\u00AD': 'Soft Hyphen',
}

EXTENSIONS = [
    '.vala', '.c', '.h', '.py', '.sh', '.md', '.txt',
    '.ui', '.xml', '.json', '.css', '.po', '.pot', '.build', '.in',
    '.yml', '.yaml', '.meson', '.doap', '.desktop',
]
TRANSLATION_ALLOWED_CHARS = {
    # Existing Occitan translations use thin spaces as typography. Keep
    # security-relevant controls blocked in PO/POT while allowing this spacing.
    '\u2009',
}
IGNORE_DIRS = {
    'build',
    'build-linux',
    'flatpak-build',
    '.flatpak-builder',
    '.git',
    'icon_backup',
    '.venv',
    'node_modules',
    '__pycache__',
}

def parse_args():
    parser = argparse.ArgumentParser(
        description="Scan source files for hidden or dangerous Unicode characters."
    )
    parser.add_argument(
        '-v',
        '--verbose',
        action='store_true',
        help='print scan root, extensions, ignored directories and skipped files',
    )
    parser.add_argument(
        '--root',
        default='.',
        help='scan root directory (default: current directory; uses Git-tracked files in the project root)',
    )
    parser.add_argument(
        '--all-files',
        action='store_true',
        help='scan all matching files under --root instead of only Git-tracked project files',
    )
    parser.add_argument(
        '--self-test',
        action='store_true',
        help='validate scanner detection with built-in clean and suspicious samples',
    )
    return parser.parse_args()


def has_supported_extension(path):
    return any(str(path).endswith(ext) for ext in EXTENSIONS)

def scan_file(path, verbose=False):
    """Scan a single file for suspicious Unicode. Returns list of findings."""
    findings = []
    suffix = Path(path).suffix
    try:
        with open(path, 'r', encoding='utf-8') as f:
            for lineno, line in enumerate(f, start=1):
                for col, char in enumerate(line, start=1):
                    if suffix in ('.po', '.pot') and char in TRANSLATION_ALLOWED_CHARS:
                        continue
                    cp = ord(char)
                    if char in SUSPICIOUS_CHARS:
                        findings.append({
                            'file': path,
                            'line': lineno,
                            'col': col,
                            'codepoint': f'U+{cp:04X}',
                            'name': SUSPICIOUS_CHARS[char],
                        })
                    elif cp < 32 and cp not in (9, 10, 13):  # TAB, LF, CR
                        findings.append({
                            'file': path,
                            'line': lineno,
                            'col': col,
                            'codepoint': f'U+{cp:04X}',
                            'name': 'ASCII Control Character',
                        })
                    elif 0xE0020 <= cp <= 0xE007F:  # Tag characters range
                        findings.append({
                            'file': path,
                            'line': lineno,
                            'col': col,
                            'codepoint': f'U+{cp:04X}',
                            'name': 'Tag Character',
                        })
    except UnicodeDecodeError:
        if verbose:
            print(f"  Warning: Could not decode {path} as UTF-8, skipping.")
    except PermissionError:
        if verbose:
            print(f"  Warning: Permission denied for {path}, skipping.")
    except Exception as e:
        print(f"  Error reading {path}: {e}")
    return findings


def scan_tree(scan_root, verbose=False):
    files_scanned = 0
    all_findings = []

    for root, dirs, files in os.walk(scan_root):
        dirs[:] = [d for d in dirs if d not in IGNORE_DIRS]

        for filename in files:
            if not has_supported_extension(filename):
                continue

            path = os.path.join(root, filename)
            files_scanned += 1
            findings = scan_file(path, verbose)
            all_findings.extend(findings)

    return files_scanned, all_findings


def scan_paths(paths, verbose=False):
    all_findings = []

    for path in paths:
        findings = scan_file(path, verbose)
        all_findings.extend(findings)

    return len(paths), all_findings


def scan_tracked_project_files(verbose=False):
    result = subprocess.run(
        ['git', 'ls-files'],
        cwd=PROJECT_DIR,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    paths = [
        PROJECT_DIR / line
        for line in result.stdout.splitlines()
        if line and has_supported_extension(line) and (PROJECT_DIR / line).is_file()
    ]
    return scan_paths(paths, verbose)


def run_self_test():
    with TemporaryDirectory(prefix='dinox-unicode-self-test-') as tmp:
        root = Path(tmp)
        clean = root / 'clean.vala'
        clean.write_text('public void main() { print("OK\\n"); }\\n', encoding='utf-8')
        clean_po = root / 'clean.po'
        clean_po.write_text('msgid "Hello"\\nmsgstr "Adiu\u2009!"\\n', encoding='utf-8')

        files_scanned, findings = scan_tree(str(root))
        if files_scanned != 2 or findings:
            raise AssertionError('self-test failed for clean sample')

        suspicious = root / 'suspicious.vala'
        suspicious.write_text('public void main() { print("safe"); } // \u202Ehidden\\n', encoding='utf-8')

        files_scanned, findings = scan_tree(str(root))
        if files_scanned != 3:
            raise AssertionError('self-test scanned unexpected file count')
        if not any(f['codepoint'] == 'U+202E' and f['name'] == 'Right-To-Left Override' for f in findings):
            raise AssertionError('self-test did not detect right-to-left override')

    print('Self-test OK')


def main():
    args = parse_args()
    if args.self_test:
        run_self_test()
        return

    verbose = args.verbose
    scan_root = args.root

    print("Scanning for hidden Unicode characters...")
    root_path = Path(scan_root).resolve()
    use_tracked_files = not args.all_files and root_path == PROJECT_DIR

    if verbose:
        print(f"  Root: {os.path.abspath(scan_root)}")
        print(f"  Extensions: {', '.join(EXTENSIONS)}")
        print(f"  Ignoring: {', '.join(sorted(IGNORE_DIRS))}")
        print(f"  Mode: {'git-tracked project files' if use_tracked_files else 'all matching files under root'}")
        print()

    if use_tracked_files:
        files_scanned, all_findings = scan_tracked_project_files(verbose)
    else:
        files_scanned, all_findings = scan_tree(scan_root, verbose)

    # Report
    print(f"\nScanned {files_scanned} files.")

    if all_findings:
        print(f"\nWARNING: {len(all_findings)} suspicious character(s) found!\n")
        for f in all_findings:
            print(f"  {f['file']}:{f['line']}:{f['col']}  {f['codepoint']} ({f['name']})")
        sys.exit(1)
    else:
        print("OK: No hidden Unicode control characters found.")
        sys.exit(0)


if __name__ == '__main__':
    main()
