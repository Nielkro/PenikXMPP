#!/usr/bin/env python3
"""Check every offered language through DinoX's native catalog loader.

Fresh extraction and PO compilation provide the expected strings; the native
probe locates the built catalogs through SearchPathGenerator and performs real
gettext calls. This verifies catalog coverage/loading, not all application
behavior or linguistic quality. The wider language matrix covers UI/behavior.
"""

import argparse
import gettext
import json
import os
import re
from pathlib import Path
import struct
import subprocess
import tempfile
from language_test_support import native_locale

DOMAINS = {"dino": "main/po", "dino-omemo": "plugins/omemo/po", "dino-openpgp": "plugins/openpgp/po"}
NUMBERS = (0, 1, 2, 3, 4, 5, 10, 11, 12, 19, 20, 21, 22, 99, 100, 101, 102, 103, 111, 200, 1000000)
RTL = {"ar", "arz", "he", "ur"}


def run(command, **kwargs):
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, encoding="utf-8", errors="strict", **kwargs)
    if result.returncode:
        raise RuntimeError(f"{command[0]} failed ({result.returncode}): {result.stdout}\n{result.stderr}")
    return result.stdout


def raw_catalog(path):
    """Keep context and original plural keys, which GNUTranslations flattens."""
    data = path.read_bytes()
    magic = struct.unpack_from("<I", data)[0]
    endian = "<" if magic == 0x950412DE else ">" if magic == 0xDE120495 else None
    if endian is None:
        raise ValueError(f"Invalid catalog: {path}")
    count, originals, translations = struct.unpack_from(endian + "3I", data, 8)
    entries = {}
    for i in range(count):
        length, offset = struct.unpack_from(endian + "2I", data, originals + 8 * i)
        size, target = struct.unpack_from(endian + "2I", data, translations + 8 * i)
        if offset + length > len(data) or target + size > len(data):
            raise ValueError(f"Truncated catalog: {path}")
        entries[data[offset:offset + length].decode("utf-8")] = data[target:target + size].decode("utf-8")
    return entries


def offered_languages(root):
    sets = []
    for folder in DOMAINS.values():
        text = (root / folder / "LINGUAS").read_text(encoding="utf-8")
        codes = " ".join(line.split("#", 1)[0] for line in text.splitlines()).split()
        if len(codes) != len(set(codes)) or not codes:
            raise ValueError(f"Invalid LINGUAS in {folder}")
        sets.append(set(codes))
    if any(value != sets[0] for value in sets[1:]):
        raise ValueError("Offered languages differ between gettext domains")
    return sorted(sets[0] | {"en"})


def prepare_keys(root, temp):
    result = {}
    for domain, folder in DOMAINS.items():
        pot, po, mo = (temp / (domain + suffix) for suffix in (".pot", "-source.po", "-source.mo"))
        run(["xgettext", "--from-code=UTF-8", "-f", str(root / folder / "POTFILES"),
             "-D", str(root), "-k_", "-kn:1,2", "-o", str(pot)], cwd=root)
        run(["msgen", str(pot), "-o", str(po)])
        run(["msgfmt", "-o", str(mo), str(po)])
        result[domain] = sorted(set(raw_catalog(mo)) - {""})
    return result


def requests(root, build, temp, language, keys):
    domains = []
    for domain, folder in DOMAINS.items():
        reference = None
        if language != "en":
            compiled = temp / f"{domain}-{language}.mo"
            run(["msgfmt", "--check", "--check-format", "-o", str(compiled), str(root / folder / (language + ".po"))])
            entries = raw_catalog(compiled)
            missing = [key for key in keys[domain] if key not in entries or not all(entries[key].split("\0"))]
            if missing:
                raise ValueError(f"{domain}/{language}: missing translations: {missing[:5]}")
            with compiled.open("rb") as stream:
                reference = gettext.GNUTranslations(stream)
            plural_count = re.search(r"nplurals\s*=\s*(\d+)", reference.info().get("plural-forms", ""))
            if plural_count is None or any(
                    "\0" in key and len(entries[key].split("\0")) != int(plural_count.group(1))
                    for key in keys[domain]):
                raise ValueError(f"{domain}/{language}: incomplete plural forms")
            if not (build / folder / language / "LC_MESSAGES" / (domain + ".mo")).is_file():
                raise ValueError(f"Built {domain}/{language} catalog is missing")
        queries = []
        for key in keys[domain]:
            forms = key.split("\0")
            context, msgid = forms[0].split("\004", 1) if "\004" in forms[0] else (None, forms[0])
            plural = forms[1] if len(forms) > 1 else None
            for n in NUMBERS if plural is not None else (1,):
                if reference is None:
                    expected = plural if plural is not None and n != 1 else msgid
                elif plural is not None:
                    expected = reference.npgettext(context, msgid, plural, n) if context else reference.ngettext(msgid, plural, n)
                else:
                    expected = reference.pgettext(context, msgid) if context else reference.gettext(msgid)
                query = {"id": msgid, "expected": expected}
                if context is not None:
                    query["context"] = context
                if plural is not None:
                    query.update(plural=plural, n=n)
                queries.append(query)
        domains.append({"name": domain, "path": str((build / folder).resolve()), "queries": queries})
    return {"language": language, "rtl": language in RTL, "domains": domains}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, default=Path("build"))
    parser.add_argument("--probe", type=Path)
    parser.add_argument("--language", action="append", help="default: all offered languages, including source English")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    build = args.build_dir.resolve()
    probe = (args.probe or build / "main" / ("language-catalog-probe.exe" if os.name == "nt" else "language-catalog-probe")).resolve()
    offered = offered_languages(root)
    selected = args.language or offered
    if any(code not in offered for code in selected):
        parser.error("requested language is not offered by DinoX")
    results = []
    with native_locale("en") as base_env, tempfile.TemporaryDirectory(prefix="dinox-language-catalogs-") as directory:
        if base_env is None:
            print("SKIP: a native English system locale is required for catalog loading")
            return 77
        temp = Path(directory)
        keys = prepare_keys(root, temp)
        for language in selected:
            request = requests(root, build, temp, language, keys)
            request["languages"] = offered
            path = temp / "request.json"
            path.write_text(json.dumps(request, ensure_ascii=False), encoding="utf-8")
            env = base_env.copy()
            for name in ("TEXTDOMAINDIR", "DINOX_UI_TEST_LOCALE_DIR"):
                env.pop(name, None)
            env.update(LANGUAGE=language, DINOX_TEST_APP_LANGUAGE=language)
            output = run([str(probe), str(path)], env=env)
            print(output, end="", flush=True)
            results.append({"language": language, "direction": "rtl" if language in RTL else "ltr",
                            "source_entries": {domain: len(items) for domain, items in keys.items()},
                            "native_lookups": sum(len(domain["queries"]) for domain in request["domains"])})
    if args.report:
        args.report.write_text(json.dumps({"scope": "native catalog lookup, all current source keys and plural boundary values", "results": results}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"PASS {len(results)} application languages; main, OMEMO and OpenPGP catalogs")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, ValueError, OSError) as error:
        raise SystemExit(str(error))
