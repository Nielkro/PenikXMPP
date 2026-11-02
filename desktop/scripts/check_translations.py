#!/usr/bin/env python3

import argparse
import gettext
import os
import re
import subprocess
import sys
from pathlib import Path
from tempfile import TemporaryDirectory
import xml.etree.ElementTree as ET

directories = [
    "main/po",
    "plugins/omemo/po",
    "plugins/openpgp/po"
]

def parse_args():
    parser = argparse.ArgumentParser(
        description="Check DinoX gettext PO syntax and translation coverage."
    )
    parser.add_argument(
        "--syntax-only",
        action="store_true",
        help="allow incomplete inactive catalogs; shipped languages must still be complete",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="run a small built-in msgfmt validation test",
    )
    return parser.parse_args()

def check_po_file(filepath):
    try:
        # Run msgfmt --statistics
        # Output is usually on stderr
        result = subprocess.run(
            ["msgfmt", "--statistics", "--output=/dev/null", filepath],
            capture_output=True,
            text=True,
            env={**os.environ, "LC_ALL": "C"}
        )
        output = result.stderr.strip()
        if result.returncode != 0:
            return 0, 0, 0, output, False
        
        # Parse output (English locale)
        # Example: "54 translated messages, 2 fuzzy translations."
        # Example: "6 translated messages, 2 fuzzy translations, 48 untranslated messages."
        
        translated = 0
        fuzzy = 0
        untranslated = 0
        
        parts = output.split(", ")
        for part in parts:
            if "translated message" in part and "untranslated" not in part:
                translated = int(part.split()[0])
            elif "fuzzy" in part:
                fuzzy = int(part.split()[0])
            elif "untranslated" in part:
                untranslated = int(part.split()[0])
                
        return translated, fuzzy, untranslated, output, True
    except Exception as e:
        return 0, 0, 0, str(e), False


def check_ui_translation_markers(root):
    errors = []
    # These names are intentionally identical in every language. Ordinary UI
    # words, including initial labels later replaced by bindings, need marking.
    technical_names = {'JID', 'DinoX', 'OMEMO'}
    properties = {'label', 'title', 'subtitle', 'tooltip-text', 'placeholder-text'}
    folders = [root / 'main/data', *(root / 'plugins').glob('*/data')]
    for folder in folders:
        for path in sorted(folder.rglob('*.ui')):
            for node in ET.parse(path).iter('property'):
                text = (node.text or '').strip()
                if (node.get('name') in properties and any(char.isalpha() for char in text)
                        and text not in technical_names
                        and node.get('translatable') != 'yes'):
                    errors.append(f'{path}: unmarked UI text: {text}')
    return errors


def check_supported_languages(root):
    """Check shipped languages against freshly extracted strings, not stale POTs.

    Inactive PO files remain translation work in progress. LINGUAS is a release
    commitment: do not remove a previously complete language to pass this gate.
    """
    errors = check_ui_translation_markers(root)
    language_sets = []
    for directory in directories:
        path = root / directory / 'LINGUAS'
        codes = ' '.join(line.split('#', 1)[0] for line in path.read_text(encoding='utf-8').splitlines()).split()
        if not codes or len(codes) != len(set(codes)):
            errors.append(f'{path}: empty or duplicate language list')
        if any(not re.fullmatch(r'[a-z]{2,3}(?:_[A-Z]{2})?', code) for code in codes):
            errors.append(f'{path}: invalid locale code')
        language_sets.append(set(codes))
    if any(codes != language_sets[0] for codes in language_sets):
        errors.append('All three LINGUAS files must contain the same complete languages')
    source = (root / 'main/src/ui/interface_language.vala').read_text(encoding='utf-8')
    match = re.search(r'public const string\[\] CODES = \{(.*?)\};', source, re.S)
    choices = re.findall(r'"([A-Za-z_]+)"', match[1]) if match else []
    if (len(choices) != len(set(choices)) or
            set(choices) != language_sets[0] | {'en', 'system'} or 'en' in language_sets[0]):
        errors.append('Language choices must match LINGUAS plus system and source English')
    if errors:
        return errors

    env = {**os.environ, 'LC_ALL': 'C'}
    with TemporaryDirectory() as temporary:
        temp = Path(temporary)
        for directory in directories:
            folder = root / directory
            pot = temp / 'current.pot'
            extracted = subprocess.run(
                ['xgettext', '--from-code=UTF-8', '-f', str(folder / 'POTFILES'),
                 '-D', str(root), '-k_', '-kn:1,2', '-o', str(pot)],
                cwd=root, env=env, capture_output=True, text=True)
            if extracted.returncode or not pot.exists():
                errors.append(f'{directory}: extraction failed: {extracted.stderr.strip()}')
                continue
            for code in sorted(language_sets[0]):
                po = folder / (code + '.po')
                merged = temp / 'merged.po'
                result = subprocess.run(
                    ['msgmerge', '--quiet', '--no-fuzzy-matching', str(po), str(pot), '-o', str(merged)],
                    env=env, capture_output=True, text=True)
                if result.returncode:
                    errors.append(f'{po}: {result.stderr.strip()}')
                    continue
                translated, fuzzy, missing, raw, valid = check_po_file(str(merged))
                compiled = temp / 'catalog.mo'
                checked = subprocess.run(
                    ['msgfmt', '--check', '--check-format', '-o', str(compiled), str(merged)],
                    env=env, capture_output=True, text=True)
                if not valid or checked.returncode or fuzzy or missing or not translated:
                    errors.append(f'{po}: incomplete or invalid: {raw}; {checked.stderr.strip()}')
                    continue
                # msgfmt counts a plural message as translated even when one
                # msgstr[n] is empty. Inspect every compiled form as well.
                with compiled.open('rb') as stream:
                    catalog = gettext.GNUTranslations(stream)
                forms = re.search(r'nplurals\s*=\s*(\d+)', catalog.info().get('plural-forms', ''))
                plural_keys = {key[0] for key in catalog._catalog if isinstance(key, tuple)}
                blank = any(not text.strip() for key, text in catalog._catalog.items() if key != '')
                missing_forms = bool(plural_keys) and (forms is None or any(
                    (key, index) not in catalog._catalog
                    for key in plural_keys for index in range(int(forms[1]))))
                if blank or missing_forms:
                    errors.append(f'{po}: empty translation or missing plural form')
    return errors

def run_self_test():
    with TemporaryDirectory() as tmp_dir:
        root = Path(tmp_dir)
        valid = root / "valid.po"
        valid.write_text(
            "\n".join([
                'msgid ""',
                'msgstr ""',
                '"Content-Type: text/plain; charset=UTF-8\\n"',
                "",
                'msgid "Hello"',
                'msgstr "Hallo"',
                "",
            ]),
            encoding="utf-8",
        )
        _t, _fz, _u, raw, ok = check_po_file(str(valid))
        if not ok:
            raise AssertionError(f"valid PO file failed msgfmt: {raw}")

        broken = root / "broken.po"
        broken.write_text(
            "\n".join([
                'msgid "Broken"',
                'msgstr "Unclosed',
                "",
            ]),
            encoding="utf-8",
        )
        _t, _fz, _u, _raw, ok = check_po_file(str(broken))
        if ok:
            raise AssertionError("broken PO file passed msgfmt")

    print("Self-test OK")

    # A newly added source string, a missing plugin locale and an unsupported
    # selector entry must fail even while inactive catalogs may be unfinished.
    with TemporaryDirectory() as tmp_dir:
        root = Path(tmp_dir)
        source = root / 'main/src/ui/interface_language.vala'
        source.parent.mkdir(parents=True)
        choices = 'public const string[] CODES = { "system", "en", "de" };'
        source.write_text(choices)
        (root / 'text.vala').write_text('void main() { _("Hello"); }')
        po = ('msgid ""\nmsgstr ""\n'
              '"Content-Type: text/plain; charset=UTF-8\\n"\n'
              '"Language: de\\n"\n'
              '"Plural-Forms: nplurals=2; plural=(n != 1);\\n"\n\n'
              'msgid "Hello"\nmsgstr "Hallo"\n')
        for directory in directories:
            folder = root / directory
            folder.mkdir(parents=True)
            (folder / 'LINGUAS').write_text('de\n')
            (folder / 'POTFILES').write_text('text.vala\n')
            (folder / 'de.po').write_text(po)
            (folder / 'el.po').write_text('msgid "Hello"\nmsgstr ""\n')
        assert not check_supported_languages(root), 'complete catalogs rejected'
        (root / 'text.vala').write_text('void main() { _("Hello"); _("New text"); }')
        assert len(check_supported_languages(root)) == 3, 'new source text not detected'
        (root / 'text.vala').write_text('void main() { _("Hello"); }')
        (root / directories[1] / 'de.po').write_text(po.replace('msgid "Hello"', '#, fuzzy\nmsgid "Hello"'))
        assert check_supported_languages(root), 'fuzzy plugin translation accepted'
        (root / directories[1] / 'de.po').write_text(po)
        (root / directories[1] / 'LINGUAS').write_text('de\nel\n')
        assert check_supported_languages(root), 'mismatched plugin languages accepted'
        (root / directories[1] / 'LINGUAS').write_text('de\n')
        source.write_text(choices.replace('"de"', '"de", "el"'))
        assert check_supported_languages(root), 'unsupported selector entry accepted'
        source.write_text(choices)
        (root / 'text.vala').write_text('void main() { _("Hello"); n("One", "Many", 2); }')
        plural_po = po + '\nmsgid "One"\nmsgid_plural "Many"\nmsgstr[0] "Eins"\nmsgstr[1] "Viele"\n'
        for directory in directories:
            (root / directory / 'de.po').write_text(plural_po)
        assert not check_supported_languages(root), 'complete plurals rejected'
        (root / directories[2] / 'de.po').write_text(plural_po.replace('msgstr[1] "Viele"', 'msgstr[1] ""'))
        assert check_supported_languages(root), 'empty plugin plural form accepted'
        ui = root / 'main/data/test.ui'
        ui.parent.mkdir(parents=True)
        ui.write_text('<interface><property name="label">Enter password</property></interface>')
        assert check_ui_translation_markers(root), 'unmarked visible UI text accepted'
        ui.write_text('<interface><property name="label" translatable="1">Enter password</property></interface>')
        assert check_ui_translation_markers(root), 'gettext-incompatible numeric translation marker accepted'
        ui.write_text('<interface><property name="label" translatable="yes">Enter password</property>'
                      '<property name="label">DinoX</property></interface>')
        assert not check_ui_translation_markers(root), 'marked UI text or a product name rejected'
    print('Supported-language gate self-test OK')

def main():
    args = parse_args()
    if args.self_test:
        run_self_test()
        return 0

    print(f"{'File':<40} | {'Trans':<5} | {'Fuzzy':<5} | {'Untrans':<7} | {'Status'}")
    print("-" * 80)
    
    total_untranslated = 0
    total_errors = 0
    files_with_issues = []
    files_with_errors = []

    for d in directories:
        if not os.path.exists(d):
            continue
            
        print(f"--- {d} ---")
        files = sorted([f for f in os.listdir(d) if f.endswith(".po")])
        
        for f in files:
            filepath = os.path.join(d, f)
            t, fz, u, raw, valid = check_po_file(filepath)
            
            status = "OK"
            if not valid:
                status = "ERROR"
                total_errors += 1
                files_with_errors.append((filepath, raw))
            elif u > 0:
                status = "MISSING"
                total_untranslated += u
                files_with_issues.append(filepath)
            elif fz > 0:
                status = "FUZZY"
            
            # Only print if not 100% clean or if it's interesting
            if not valid or (not args.syntax_only and (u > 0 or fz > 0)):
                print(f"{f:<40} | {t:<5} | {fz:<5} | {u:<7} | {status}")

    print("-" * 80)
    if total_errors > 0:
        print(f"Found msgfmt errors in {total_errors} files.")
        for f, raw in files_with_errors:
            print(f"  - {f}")
            if raw:
                print(f"    {raw.splitlines()[0]}")

    if args.syntax_only:
        if total_errors == 0:
            print("All PO files passed msgfmt syntax checks.")
    elif total_untranslated == 0:
        print("All files are 100% translated (ignoring fuzzy).")
    else:
        print(f"Found {total_untranslated} untranslated strings in {len(files_with_issues)} files.")
        for f in files_with_issues:
            print(f"  - {f}")

    errors = check_supported_languages(Path(__file__).resolve().parents[1])
    for error in errors:
        print(error)
    if not errors:
        print('All offered languages are complete in main, OMEMO and OpenPGP against current sources.')
    return 1 if total_errors > 0 or errors else 0

if __name__ == "__main__":
    sys.exit(main())
