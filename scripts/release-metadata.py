#!/usr/bin/env python3
"""Promote one prepared release without duplicating or reformatting its history."""

import argparse
from datetime import date
import os
from pathlib import Path
import re
import tempfile
import xml.etree.ElementTree as ET
from xml.parsers import expat

DOAP = "http://usefulinc.com/ns/doap#"
RDF = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"


class XmlBlock:
    def __init__(self, text, start, end, element, opening_end, closing_start, self_closing):
        self.text, self.first, self.last, self.element = text, start, end, element
        self.opening_end, self.closing_start, self.self_closing = opening_end, closing_start, self_closing

    def group(self):
        return self.text

    def start(self):
        return self.first

    def end(self):
        return self.last


def release_date(value):
    if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", value):
        raise ValueError("release needs a real YYYY-MM-DD date")
    date.fromisoformat(value)
    return value


def local_name(element):
    return element.tag.rsplit("}", 1)[-1]


def release_blocks(text):
    # XML callbacks ignore comments/CDATA and enforce the real container path.
    # Byte offsets let us retain every unrelated original XML byte verbatim.
    root = ET.fromstring(text)
    if root.tag == f"{{{RDF}}}RDF":
        path = (f"{RDF}}}RDF", f"{DOAP}}}Project", f"{DOAP}}}release")
        elements = root.findall(f"{{{DOAP}}}Project/{{{DOAP}}}release")
    elif root.tag == "component":
        path = ("component", "releases", "release")
        elements = root.findall("releases/release")
    else:
        raise ValueError("unsupported release metadata XML root")
    return xml_blocks(text, path, elements)


def xml_blocks(text, path, elements):
    data = text.encode("utf-8")
    parser = expat.ParserCreate(namespace_separator="}")
    stack, offsets, blocks = [], [], []

    def opening_end(start):
        quote = None
        for index in range(start, len(data)):
            char = data[index]
            if quote:
                if char == quote:
                    quote = None
            elif char in (ord("'"), ord('"')):
                quote = char
            elif char == ord(">"):
                return index + 1
        raise ValueError("unterminated XML release tag")

    def start(name, attributes):
        stack.append(name)
        if tuple(stack) == path:
            first = parser.CurrentByteIndex
            offsets.append((first, opening_end(first)))

    def end(name):
        if tuple(stack) == path:
            first, tag_end = offsets.pop()
            self_closing = data[tag_end - 2:tag_end] == b"/>"
            last = tag_end if self_closing else opening_end(parser.CurrentByteIndex)
            char_first = len(data[:first].decode("utf-8"))
            char_last = char_first + len(data[first:last].decode("utf-8"))
            blocks.append(XmlBlock(text[char_first:char_last], char_first, char_last,
                elements[len(blocks)], len(data[:tag_end].decode("utf-8")),
                char_last - 2 if self_closing else len(data[:parser.CurrentByteIndex].decode("utf-8")), self_closing))
        stack.pop()

    parser.StartElementHandler, parser.EndElementHandler = start, end
    parser.Parse(data, True)
    if len(blocks) != len(elements):
        raise ValueError("release XML offsets disagree with the parsed structure")
    return blocks


def insert_release(text, kind, content):
    root = ET.fromstring(text)
    if kind == "doap":
        releases = release_blocks(text)
        if releases:
            first = releases[0].start()
            line = text.rfind("\n", 0, first) + 1
            if not text[line:first].strip():
                first = line
            return text[:first] + content + text[first:]
        path = (f"{RDF}}}RDF", f"{DOAP}}}Project")
        containers = xml_blocks(text, path, root.findall(f"{{{DOAP}}}Project"))
    else:
        containers = xml_blocks(text, ("component", "releases"), root.findall("releases"))
    if len(containers) != 1:
        raise ValueError("release metadata needs exactly one real insertion container")
    container = containers[0]
    if container.self_closing:
        name = re.match(r"<([^\s/>]+)", container.group()).group(1)
        block = container.group()[:-2] + ">" + content + f"</{name}>"
        return text[:container.start()] + block + text[container.end():]
    position = container.closing_start if kind == "doap" else container.opening_end
    return text[:position] + content + text[position:]


def replace_attribute(block, name, value):
    opening = re.match(r"<release\b[^>]*>", block).group()
    pattern = rf"\b{re.escape(name)}\s*=\s*(['\"])[^'\"]*\1"
    if re.search(pattern, opening):
        updated = re.sub(pattern, f'{name}="{value}"', opening, count=1)
    else:
        closing = "/>" if opening.endswith("/>") else ">"
        updated = opening[:-len(closing)] + f' {name}="{value}"' + closing
    return updated + block[len(opening):]


def target_block(text, matching):
    matches = [block for block in release_blocks(text) if matching(block.element)]
    if len(matches) > 1:
        raise ValueError("duplicate target release in XML metadata")
    return matches[0] if matches else None


def read_metadata(root):
    paths = [root / "docs/internal/CHANGELOG.md", root / "dino.doap",
             root / "main/data/im.dinox.dinox.appdata.xml"]
    if any(path.is_symlink() for path in paths):
        raise ValueError("release metadata must be regular checkout files")
    texts = [path.read_bytes().decode("utf-8") for path in paths]
    # Parse complete XML before computing changes or writing any file.
    doap = ET.fromstring(texts[1])
    appstream = ET.fromstring(texts[2])
    if sum(local_name(item) == "Project" for item in doap.iter()) != 1:
        raise ValueError("DOAP needs exactly one Project")
    if local_name(appstream) != "component" or len(appstream.findall("releases")) != 1:
        raise ValueError("AppStream needs exactly one component release list")
    return paths, texts


def verify_stable(changelog, doap, appstream, version):
    headings = re.findall(rf"^## \[{re.escape(version)}\] - ([^\r\n]+)\r?$", changelog, re.MULTILINE)
    doap_block = target_block(doap, lambda node: any(item.text == version
        for item in node.findall(f"{{{DOAP}}}Version/{{{DOAP}}}revision")))
    app_block = target_block(appstream, lambda node: node.get("version") == version)
    if len(headings) != 1 or not doap_block or not app_block:
        raise ValueError("unique target release is missing from changelog, DOAP or AppStream")
    dates = [release_date(headings[0])]
    versions = doap_block.element.findall(f"{{{DOAP}}}Version")
    if len(versions) != 1:
        raise ValueError("DOAP release needs exactly one Version")
    revisions = versions[0].findall(f"{{{DOAP}}}revision")
    created = versions[0].findall(f"{{{DOAP}}}created")
    names = versions[0].findall(f"{{{DOAP}}}name")
    if (len(revisions) != 1 or revisions[0].text != version or len(created) != 1 or
            any("unreleased" in (name.text or "").lower() for name in names)):
        raise ValueError("DOAP release is still unreleased or has no unique revision/date")
    dates.append(release_date(created[0].text or ""))
    if app_block.element.get("type", "stable") != "stable":
        raise ValueError("AppStream release is not stable")
    dates.append(release_date(app_block.element.get("date", "")))
    if len(set(dates)) != 1:
        raise ValueError("release dates disagree between changelog, DOAP and AppStream")


def metadata(root, version, when=None):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?", version):
        raise ValueError("invalid release version")
    paths, texts = read_metadata(root)
    changelog, doap, appstream = texts
    heading = re.compile(rf"^## \[{re.escape(version)}\](?: - ([^\r\n]+))?\r?$", re.MULTILINE)
    headings = list(heading.finditer(changelog))
    if len(headings) > 1:
        raise ValueError("duplicate target release in changelog")
    doap_block = target_block(doap, lambda node: any(item.text == version
        for item in node.findall(f"{{{DOAP}}}Version/{{{DOAP}}}revision")))
    app_block = target_block(appstream, lambda node: node.get("version") == version)

    if when is None:
        verify_stable(changelog, doap, appstream, version)
        return

    when = release_date(when)
    if headings:
        changelog = heading.sub(f"## [{version}] - {when}", changelog, count=1)
    else:
        unreleased = re.compile(r"^## \[Unreleased\]\r?$", re.MULTILINE)
        if len(unreleased.findall(changelog)) != 1:
            raise ValueError("new release needs exactly one Unreleased changelog section")
        changelog = unreleased.sub(f"## [Unreleased]\n\n## [{version}] - {when}", changelog, count=1)
    for key, url in (("Unreleased", f"https://git.dinox.im/dinoxim/dinox/compare/v{version}...HEAD"),
                     (version, f"https://git.dinox.im/dinoxim/dinox/releases/tag/v{version}")):
        link = re.compile(rf"^\[{re.escape(key)}\]:[^\r\n]*(\r?)$", re.MULTILINE)
        if len(link.findall(changelog)) > 1:
            raise ValueError("duplicate changelog release link")
        changelog = link.sub(lambda match: f"[{key}]: {url}" + match.group(1), changelog) if link.search(changelog) else \
            changelog.rstrip() + f"\n\n[{key}]: {url}\n"

    if doap_block:
        block = doap_block.group()
        if len(re.findall(r"<created>[^<]*</created>", block)) != 1:
            raise ValueError("prepared DOAP release needs exactly one created field")
        block = re.sub(r"<created>[^<]*</created>", f"<created>{when}</created>", block, count=1)
        block = re.sub(r"<name>[^<]*[Uu]nreleased[^<]*</name>", f"<name>{version}</name>", block, count=1)
        doap = doap[:doap_block.start()] + block + doap[doap_block.end():]
    else:
        block = (f"    <release>\n      <Version>\n        <name>{version}</name>\n"
                 f"        <created>{when}</created>\n        <revision>{version}</revision>\n"
                 "      </Version>\n    </release>\n")
        doap = insert_release(doap, "doap", block)

    if app_block:
        block = replace_attribute(replace_attribute(app_block.group(), "date", when), "type", "stable")
        appstream = appstream[:app_block.start()] + block + appstream[app_block.end():]
    else:
        block = (f'\n    <release date="{when}" version="{version}" type="stable">\n'
                 "      <description><p>See CHANGELOG.md for details.</p></description>\n    </release>")
        appstream = insert_release(appstream, "appstream", block)
    # Validate the fully planned result, including its actual XML hierarchy,
    # before staging any write. Unsupported layouts fail without partial edits.
    verify_stable(changelog, doap, appstream, version)
    updates = list(zip(paths, (changelog, doap, appstream)))
    staged = []
    try:
        for path, text in updates:
            with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", newline="", dir=path.parent,
                    prefix=".dinox-release-", delete=False) as temporary:
                staged.append((Path(temporary.name), path))
                temporary.write(text)
            staged[-1][0].chmod(path.stat().st_mode & 0o777)
        for temporary, path in staged:
            os.replace(temporary, path)
    finally:
        for temporary, _ in staged:
            temporary.unlink(missing_ok=True)


def self_test():
    historical = '<release><Version><name>Old Über</name><created>2026-09-01</created><revision>1.2.2</revision></Version></release>'
    old_app = '<release date="2026-09-01" version="1.2.2"><description><p xml:lang="de">Alte Änderungen</p></description></release>'
    pending = '<release><Version><name>1.2.3 (Unreleased)</name><created>Unreleased</created><revision>1.2.3</revision></Version></release>'
    pending_app = '<release version="1.2.3" type="development"><description><p>Keep this description.</p></description></release>'
    with tempfile.TemporaryDirectory(prefix="dinox-release-metadata-") as directory:
        root = Path(directory)
        (root / "docs/internal").mkdir(parents=True)
        (root / "main/data").mkdir(parents=True)
        def fixture(existing=True):
            (root / "docs/internal/CHANGELOG.md").write_text("## [Unreleased]\n\n" +
                ("## [1.2.3] - Unreleased\n\nKeep notes.\n\n" if existing else "Keep notes.\n\n") +
                "## [1.2.2] - 2026-09-01\n\nOld notes.\n", encoding="utf-8")
            (root / "dino.doap").write_text('<rdf:RDF xmlns="http://usefulinc.com/ns/doap#" xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><Project>' +
                (pending if existing else "") + historical + "  </Project></rdf:RDF>", encoding="utf-8")
            (root / "main/data/im.dinox.dinox.appdata.xml").write_text("<component><releases>" +
                (pending_app if existing else "") + old_app + "</releases></component>", encoding="utf-8")
        for existing in (False, True):
            fixture(existing)
            metadata(root, "1.2.3", "2026-10-12")
            metadata(root, "1.2.3")
            paths, texts = read_metadata(root)
            metadata(root, "1.2.3", "2026-10-12")
            assert texts == read_metadata(root)[1]
            assert historical in texts[1] and old_app in texts[2] and "Keep notes." in texts[0]
            if existing:
                assert "Keep this description." in texts[2]
        for relative in ("docs/internal/CHANGELOG.md", "dino.doap", "main/data/im.dinox.dinox.appdata.xml"):
            fixture()
            path = root / relative
            text = path.read_text()
            duplicate = "## [1.2.3] - Unreleased\n" if relative.endswith("md") else pending if relative == "dino.doap" else pending_app
            path.write_text(text + duplicate if relative.endswith("md") else text.replace(pending if relative == "dino.doap" else pending_app, duplicate * 2))
            _, before = read_metadata(root)
            try:
                metadata(root, "1.2.3", "2026-10-12")
                raise AssertionError("duplicate target accepted")
            except ValueError:
                assert before == read_metadata(root)[1]
        for relative in ("dino.doap", "main/data/im.dinox.dinox.appdata.xml"):
            fixture()
            (root / relative).write_text("<broken>")
            before = {path: path.read_bytes() for path in (root / "docs/internal/CHANGELOG.md", root / "dino.doap", root / "main/data/im.dinox.dinox.appdata.xml")}
            try:
                metadata(root, "1.2.3", "2026-10-12")
                raise AssertionError("malformed XML accepted")
            except ET.ParseError:
                assert all(path.read_bytes() == value for path, value in before.items())
        for relative, original, pending_value in (
            ("docs/internal/CHANGELOG.md", "## [1.2.3] - 2026-10-12", "## [1.2.3] - Unreleased"),
            ("dino.doap", "<created>2026-10-12</created>", "<created>Unreleased</created>"),
            ("dino.doap", "<name>1.2.3</name>", "<name>1.2.3 (Unreleased)</name>"),
            ("main/data/im.dinox.dinox.appdata.xml", 'type="stable"', 'type="development"'),
            ("dino.doap", "<created>2026-10-12</created>", "<created>2026-10-13</created>"),
        ):
            fixture()
            metadata(root, "1.2.3", "2026-10-12")
            path = root / relative
            path.write_text(path.read_text().replace(original, pending_value, 1))
            _, before = read_metadata(root)
            try:
                metadata(root, "1.2.3")
                raise AssertionError("pending or inconsistent release accepted as stable")
            except ValueError:
                assert before == read_metadata(root)[1]
        # Commented, CDATA, foreign-namespace and nested release-looking text
        # must never substitute for the real direct AppStream release entry.
        for fake in (
            f"<!--{pending_app}-->",
            f"<description><![CDATA[<releases>{pending_app}</releases>]]></description>",
            f"<description>{pending_app}</description>",
            '<x:release xmlns:x="urn:example" version="1.2.3" type="stable" date="2026-10-12"/>',
        ):
            fixture()
            metadata(root, "1.2.3", "2026-10-12")
            path = root / "main/data/im.dinox.dinox.appdata.xml"
            block = target_block(path.read_text(), lambda node: node.get("version") == "1.2.3")
            text = path.read_text()
            text = text[:block.start()] + fake + text[block.end():]
            path.write_text(text)
            try:
                metadata(root, "1.2.3")
                raise AssertionError("fake release entry accepted")
            except ValueError:
                pass
            metadata(root, "1.2.3", "2026-10-12")
            metadata(root, "1.2.3")
            assert fake in path.read_text()
        fixture()
        path = root / "main/data/im.dinox.dinox.appdata.xml"
        path.write_text(path.read_text().replace(pending_app, '<release version="1.2.3" type="development"/>'))
        metadata(root, "1.2.3", "2026-10-12")
        metadata(root, "1.2.3")
        assert len([item for item in ET.fromstring(path.read_text()).findall("releases/release")
                    if item.get("version") == "1.2.3"]) == 1
        fixture(False)
        markers = '<?kept text="<release>"?><!--\n<release>Untouched</release>\n-->'
        path = root / "dino.doap"
        path.write_text(path.read_text().replace(historical, "<name>中文 Кириллица Über</name>" + markers))
        app_path = root / "main/data/im.dinox.dinox.appdata.xml"
        app_path.write_text('<component><description><p>中文 Кириллица Über</p></description>' + markers + '<releases/></component>')
        metadata(root, "1.2.3", "2026-10-12")
        metadata(root, "1.2.3")
        assert markers in path.read_text() and markers in app_path.read_text()
        assert "中文 Кириллица Über" in path.read_text() and "中文 Кириллица Über" in app_path.read_text()
        fixture()
        changelog = root / "docs/internal/CHANGELOG.md"
        changelog.write_text(changelog.read_text() + "[Unreleased]: old-compare\n[1.2.3]: old-release\n")
        paths, _ = read_metadata(root)
        for path in paths:
            path.write_bytes(path.read_bytes().replace(b"\n", b"\r\n"))
        metadata(root, "1.2.3", "2026-10-12")
        final = {path: path.read_bytes() for path in paths}
        assert len(re.findall(rb"(?m)^\[Unreleased\]:", final[changelog])) == 1
        assert len(re.findall(rb"(?m)^\[1\.2\.3\]:", final[changelog])) == 1
        metadata(root, "1.2.3", "2026-10-12")
        assert all(path.read_bytes() == data for path, data in final.items())
    print("OK: release metadata promotion, idempotence, preserved history, duplicate/XML rejection and stable gate")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("prepare", "check-stable", "self-test"))
    parser.add_argument("version", nargs="?")
    parser.add_argument("--date")
    parser.add_argument("--root", type=Path, default=Path.cwd())
    args = parser.parse_args()
    if args.mode == "self-test":
        if args.version or args.date:
            parser.error("self-test takes no release arguments")
        self_test()
        return
    if not args.version or (args.mode == "prepare") != bool(args.date):
        parser.error("prepare needs VERSION --date DATE; check-stable needs only VERSION")
    try:
        metadata(args.root, args.version, args.date)
    except (OSError, ValueError, ET.ParseError, expat.ExpatError) as error:
        parser.exit(1, f"ERROR: release metadata: {error}\n")


if __name__ == "__main__":
    main()
