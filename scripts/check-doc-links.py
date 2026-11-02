#!/usr/bin/env python3
"""Check local Markdown and HTML links in public and internal documentation."""

import argparse
import re
import sys
from tempfile import TemporaryDirectory
from urllib.parse import parse_qs, unquote, urlparse
from pathlib import Path


REPO = Path(__file__).resolve().parent.parent
DEFAULT_PATHS = [
    "README.md",
    "SECURITY.md",
    "docs/index.html",
    "docs/internal",
    ".github",
]
LINK_RE = re.compile(r"\[[^\]]+\]\(([^)]+)\)")
IMAGE_LINK_RE = re.compile(r"\[!\[[^\]]*\]\([^)]+\)\]\(([^)]+)\)")
HTML_LINK_RE = re.compile(r"""\b(?:href|src)\s*=\s*["']([^"']+)["']""", re.IGNORECASE)
HTML_REFRESH_RE = re.compile(r"""\bcontent\s*=\s*["'][^"']*\burl=([^"';\s]+)""", re.IGNORECASE)
HTML_ANCHOR_RE = re.compile(r"""\b(?:id|name)\s*=\s*["']([^"']+)["']""", re.IGNORECASE)
REFERENCE_LINK_RE = re.compile(r"(?<!!)\[([^\]]+)\]\[([^\]]*)\]")
REFERENCE_DEF_RE = re.compile(r"^\[([^\]]+)\]:\s+(\S+)")
HEADING_RE = re.compile(r"^(#{1,6})\s+(.+?)\s*#*\s*$")
SCHEME_RE = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*:")
CHECK_SUFFIXES = {".html", ".md", ".yml", ".yaml"}
FENCE_RE = re.compile(r"^\s*(```|~~~)")
SELF_REPO_HOST = "git.dinox.im"
SELF_REPO_PATH_PREFIXES = (
    "/dinoxim/dinox/src/branch/master/",
    "/dinoxim/dinox/blob/master/",
    "/dinoxim/dinox/raw/branch/master/",
)
SELF_REPO_ISSUES_NEW_PATH = "/dinoxim/dinox/issues/new"


def parse_args():
    parser = argparse.ArgumentParser(
        description="Check local Markdown links in DinoX documentation."
    )
    parser.add_argument(
        "paths",
        nargs="*",
        default=DEFAULT_PATHS,
        help="files or directories to scan (default: README, SECURITY, docs/index.html, docs/internal, .github)",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="run a small built-in test for local file and heading anchor checks",
    )
    return parser.parse_args()


def iter_files(paths):
    for raw_path in paths:
        path = Path(raw_path)
        if path.is_dir():
            for child in sorted(path.rglob("*")):
                if child.is_file() and child.suffix in CHECK_SUFFIXES:
                    yield child
        elif path.is_file():
            yield path
        else:
            yield path


def split_link(link):
    link = link.strip()
    if link.startswith("<") and link.endswith(">"):
        link = link[1:-1]
    elif link.endswith(("\"", "'")):
        title_match = re.match(r"(.+?)(?:\s+['\"].*['\"])\s*$", link)
        if title_match:
            link = title_match.group(1)
    target, marker, anchor = link.partition("#")
    return target, anchor if marker else ""


def is_external_link(target):
    return bool(target) and SCHEME_RE.match(target)


def self_repo_local_path(target):
    parsed = urlparse(target)
    if parsed.scheme not in {"http", "https"} or parsed.netloc != SELF_REPO_HOST:
        return None
    for prefix in SELF_REPO_PATH_PREFIXES:
        if parsed.path.startswith(prefix):
            return unquote(parsed.path[len(prefix):])
    if parsed.path == SELF_REPO_ISSUES_NEW_PATH:
        templates = parse_qs(parsed.query).get("template", [])
        if templates:
            template = templates[0]
            if "/" in template or "\\" in template or template in {"", ".", ".."}:
                return str(Path(".github") / "ISSUE_TEMPLATE" / "__invalid_template__")
            return str(Path(".github") / "ISSUE_TEMPLATE" / template)
    return None


def slug_heading(heading):
    heading = re.sub(r"<[^>]+>", "", heading)
    heading = re.sub(r"`([^`]*)`", r"\1", heading)
    heading = heading.strip().lower()
    heading = re.sub(r"\s+", "-", heading)
    heading = "".join(
        char for char in heading if char.isalnum() or char in "-_"
    )
    return heading.strip("-")


def collect_anchors(path):
    anchors = set()
    if path.suffix == ".html":
        for line in path.read_text(encoding="utf-8").splitlines():
            for match in HTML_ANCHOR_RE.finditer(line):
                anchors.add(match.group(1))
        return anchors

    counts = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = HEADING_RE.match(line)
        if not match:
            continue
        base = slug_heading(match.group(2))
        if not base:
            continue
        count = counts.get(base, 0)
        counts[base] = count + 1
        anchors.add(base if count == 0 else f"{base}-{count}")
    return anchors


def normalize_reference_label(label):
    return " ".join(label.strip().lower().split())


def strip_inline_code(line):
    return re.sub(r"`[^`]*`", lambda match: " " * len(match.group(0)), line)


def iter_markdown_content_lines(lines):
    in_fence = False
    for line_no, line in enumerate(lines, 1):
        if FENCE_RE.match(line):
            in_fence = not in_fence
            continue
        if not in_fence:
            yield line_no, line


def iter_html_links(lines):
    for line_no, line in enumerate(lines, 1):
        for match in HTML_LINK_RE.finditer(line):
            yield line_no, match.group(1)
        for match in HTML_REFRESH_RE.finditer(line):
            yield line_no, match.group(1)


def check_local_target(path, line_no, link, anchors_by_file):
    target, anchor = split_link(link)
    self_repo_target = self_repo_local_path(target)
    if self_repo_target is not None:
        resolved = (REPO / self_repo_target).resolve()
    elif is_external_link(target):
        return None
    elif target or anchor:
        resolved = (path.parent / target).resolve() if target else path.resolve()
    else:
        return None
    if target and not resolved.exists():
        return (path, line_no, link, resolved)
    if anchor and resolved.suffix in {".md", ".html"}:
        anchor = unquote(anchor)
        anchors = anchors_by_file.setdefault(resolved, collect_anchors(resolved))
        wanted = anchor.lower() if resolved.suffix == ".md" else anchor
        if wanted not in anchors:
            return (path, line_no, link, f"{resolved}#{anchor}")
    return None


def check_paths(paths):
    missing_inputs = []
    broken_links = []
    anchors_by_file = {}

    for path in iter_files(paths):
        if not path.exists():
            missing_inputs.append(str(path))
            continue
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except UnicodeDecodeError as error:
            broken_links.append((path, 0, "<file encoding>", str(error)))
            continue

        if path.suffix == ".html":
            for line_no, link in iter_html_links(lines):
                error = check_local_target(path, line_no, link, anchors_by_file)
                if error:
                    broken_links.append(error)
            continue

        reference_defs = {}
        for line_no, line in iter_markdown_content_lines(lines):
            reference_match = REFERENCE_DEF_RE.match(line)
            if reference_match:
                label = normalize_reference_label(reference_match.group(1))
                if label in reference_defs:
                    broken_links.append((
                        path,
                        line_no,
                        f"[{reference_match.group(1)}]:",
                        f"duplicate reference definition; first defined at line {reference_defs[label]}",
                    ))
                else:
                    reference_defs[label] = line_no
                error = check_local_target(
                    path,
                    line_no,
                    reference_match.group(2),
                    anchors_by_file,
                )
                if error:
                    broken_links.append(error)

        for line_no, line in iter_markdown_content_lines(lines):
            link_line = strip_inline_code(line)
            for match in REFERENCE_LINK_RE.finditer(link_line):
                label = match.group(2) if match.group(2) else match.group(1)
                normalized = normalize_reference_label(label)
                if normalized not in reference_defs:
                    broken_links.append((
                        path,
                        line_no,
                        match.group(0),
                        "missing reference definition",
                    ))

            for match in LINK_RE.finditer(link_line):
                link = match.group(1)
                error = check_local_target(path, line_no, link, anchors_by_file)
                if error:
                    broken_links.append(error)

            for match in IMAGE_LINK_RE.finditer(link_line):
                link = match.group(1)
                error = check_local_target(path, line_no, link, anchors_by_file)
                if error:
                    broken_links.append(error)

            for _html_line_no, link in iter_html_links([link_line]):
                error = check_local_target(path, line_no, link, anchors_by_file)
                if error:
                    broken_links.append(error)

    return missing_inputs, broken_links


def run_self_test():
    with TemporaryDirectory() as tmp_dir:
        root = Path(tmp_dir)
        doc = root / "doc.md"
        doc.write_text(
            "\n".join([
                "# Top",
                "## Bot List & Actions",
                "## SASL / SCRAM Authentication",
                "## Repeat",
                "## Repeat",
            ]),
            encoding="utf-8",
        )
        index = root / "README.md"
        index.write_text(
            "\n".join([
                "[top](doc.md#top)",
                "[punctuation](doc.md#bot-list--actions)",
                "[slash](doc.md#sasl--scram-authentication)",
                "[duplicate](doc.md#repeat-1)",
                "[title](doc.md#top \"Top heading\")",
                "[![badge](https://img.shields.io/badge/test-ok-green.svg)](doc.md#top)",
            ]),
            encoding="utf-8",
        )
        missing_inputs, broken_links = check_paths([str(index)])
        if missing_inputs or broken_links:
            raise AssertionError(f"unexpected self-test failures: {broken_links}")

        broken = root / "broken.md"
        broken.write_text("[missing](doc.md#does-not-exist)", encoding="utf-8")
        _missing_inputs, broken_links = check_paths([str(broken)])
        if not broken_links:
            raise AssertionError("self-test did not detect a missing heading anchor")

        broken_image_link = root / "broken-image-link.md"
        broken_image_link.write_text(
            "[![badge](https://img.shields.io/badge/test-ok-red.svg)](doc.md#missing)",
            encoding="utf-8",
        )
        _missing_inputs, broken_links = check_paths([str(broken_image_link)])
        if not broken_links:
            raise AssertionError("self-test did not detect a broken image wrapper link")

        duplicate = root / "duplicate.md"
        duplicate.write_text(
            "\n".join([
                "[Same]: doc.md#top",
                "[same]: doc.md#top",
            ]),
            encoding="utf-8",
        )
        _missing_inputs, broken_links = check_paths([str(duplicate)])
        if not broken_links:
            raise AssertionError("self-test did not detect a duplicate reference definition")

        references = root / "references.md"
        references.write_text(
            "\n".join([
                "[defined][Doc]",
                "[collapsed][]",
                "[Doc]: doc.md#top",
                "[collapsed]: doc.md#top",
                "[Angle]: <https://git.dinox.im/dinoxim/dinox>",
            ]),
            encoding="utf-8",
        )
        _missing_inputs, broken_links = check_paths([str(references)])
        if broken_links:
            raise AssertionError(f"unexpected reference-link self-test failures: {broken_links}")

        broken_reference_target = root / "broken-reference-target.md"
        broken_reference_target.write_text("[Broken]: doc.md#missing", encoding="utf-8")
        _missing_inputs, broken_links = check_paths([str(broken_reference_target)])
        if not broken_links:
            raise AssertionError("self-test did not detect a broken reference definition target")

        missing_reference = root / "missing-reference.md"
        missing_reference.write_text("[missing][No Such Label]", encoding="utf-8")
        _missing_inputs, broken_links = check_paths([str(missing_reference)])
        if not broken_links:
            raise AssertionError("self-test did not detect a missing reference definition")

        code_reference = root / "code-reference.md"
        code_reference.write_text("`array[key][name]`", encoding="utf-8")
        _missing_inputs, broken_links = check_paths([str(code_reference)])
        if broken_links:
            raise AssertionError(f"self-test treated inline code as a reference link: {broken_links}")

        code_inline_link = root / "code-inline-link.md"
        code_inline_link.write_text(
            "`[missing](doc.md#missing)` and `![missing](missing.png)` and `<img src=\"missing.png\">`",
            encoding="utf-8",
        )
        _missing_inputs, broken_links = check_paths([str(code_inline_link)])
        if broken_links:
            raise AssertionError(f"self-test treated inline code as an inline link: {broken_links}")

        code_block = root / "code-block.md"
        code_block.write_text(
            "\n".join([
                "```markdown",
                "[missing](doc.md#missing)",
                "[missing][No Such Label]",
                "[Broken]: doc.md#missing",
                "```",
            ]),
            encoding="utf-8",
        )
        _missing_inputs, broken_links = check_paths([str(code_block)])
        if broken_links:
            raise AssertionError(f"self-test treated fenced code as links: {broken_links}")

        tilde_code_block = root / "tilde-code-block.md"
        tilde_code_block.write_text(
            "\n".join([
                "~~~markdown",
                "[missing](doc.md#missing)",
                "[missing][No Such Label]",
                "[Broken]: doc.md#missing",
                "~~~",
            ]),
            encoding="utf-8",
        )
        _missing_inputs, broken_links = check_paths([str(tilde_code_block)])
        if broken_links:
            raise AssertionError(f"self-test treated tilde fenced code as links: {broken_links}")

        markdown_html = root / "markdown-html.md"
        markdown_html.write_text('<img src="doc.md" alt="test">', encoding="utf-8")
        _missing_inputs, broken_links = check_paths([str(markdown_html)])
        if broken_links:
            raise AssertionError(f"unexpected Markdown HTML self-test failures: {broken_links}")

        broken_markdown_html = root / "broken-markdown-html.md"
        broken_markdown_html.write_text('<img src="missing.png" alt="test">', encoding="utf-8")
        _missing_inputs, broken_links = check_paths([str(broken_markdown_html)])
        if not broken_links:
            raise AssertionError("self-test did not detect broken HTML inside Markdown")

        html = root / "index.html"
        html.write_text(
            "\n".join([
                '<h2 id="intro">Intro</h2>',
                '<a name="legacy"></a>',
                '<link rel="canonical" href="doc.md">',
                '<img src="doc.md" alt="test">',
                '<meta http-equiv="refresh" content="0; url=doc.md">',
                '<a href="#intro">intro</a>',
                '<a href="index.html#legacy">legacy</a>',
            ]),
            encoding="utf-8",
        )
        _missing_inputs, broken_links = check_paths([str(html)])
        if broken_links:
            raise AssertionError(f"unexpected HTML link self-test failures: {broken_links}")

        broken_html_anchor = root / "broken-html-anchor.html"
        broken_html_anchor.write_text(
            '<h2 id="intro">Intro</h2><a href="index.html#missing">missing</a>',
            encoding="utf-8",
        )
        _missing_inputs, broken_links = check_paths([str(broken_html_anchor)])
        if not broken_links:
            raise AssertionError("self-test did not detect broken HTML anchors")

        self_repo_links = root / "self-repo-links.md"
        self_repo_links.write_text(
            "\n".join([
                "[security](https://git.dinox.im/dinoxim/dinox/src/branch/master/SECURITY.md)",
                "[testing](https://git.dinox.im/dinoxim/dinox/blob/master/docs/internal/TESTING.md#automated-test-baseline)",
            ]),
            encoding="utf-8",
        )
        _missing_inputs, broken_links = check_paths([str(self_repo_links)])
        if broken_links:
            raise AssertionError(f"unexpected self-repo link self-test failures: {broken_links}")

        broken_self_repo_link = root / "broken-self-repo-link.md"
        broken_self_repo_link.write_text(
            "[missing](https://git.dinox.im/dinoxim/dinox/src/branch/master/docs/internal/missing.md)",
            encoding="utf-8",
        )
        _missing_inputs, broken_links = check_paths([str(broken_self_repo_link)])
        if not broken_links:
            raise AssertionError("self-test did not detect a broken self-repo link")

        self_repo_issue_template = root / "self-repo-issue-template.md"
        self_repo_issue_template.write_text(
            "[bug](https://git.dinox.im/dinoxim/dinox/issues/new?template=BugReport.yml)",
            encoding="utf-8",
        )
        _missing_inputs, broken_links = check_paths([str(self_repo_issue_template)])
        if broken_links:
            raise AssertionError(f"unexpected issue-template self-test failures: {broken_links}")

        broken_self_repo_issue_template = root / "broken-self-repo-issue-template.md"
        broken_self_repo_issue_template.write_text(
            "[missing](https://git.dinox.im/dinoxim/dinox/issues/new?template=Missing.yml)",
            encoding="utf-8",
        )
        _missing_inputs, broken_links = check_paths([str(broken_self_repo_issue_template)])
        if not broken_links:
            raise AssertionError("self-test did not detect a broken issue-template link")

        invalid_self_repo_issue_template = root / "invalid-self-repo-issue-template.md"
        invalid_self_repo_issue_template.write_text(
            "[invalid](https://git.dinox.im/dinoxim/dinox/issues/new?template=../config.yml)",
            encoding="utf-8",
        )
        _missing_inputs, broken_links = check_paths([str(invalid_self_repo_issue_template)])
        if not broken_links:
            raise AssertionError("self-test did not detect an invalid issue-template path")

        broken_html = root / "broken.html"
        broken_html.write_text(
            "\n".join([
                '<a href="missing.html">missing</a>',
                '<meta http-equiv="refresh" content="0; url=also-missing.html">',
            ]),
            encoding="utf-8",
        )
        _missing_inputs, broken_links = check_paths([str(broken_html)])
        if len(broken_links) != 2:
            raise AssertionError("self-test did not detect broken HTML links")

    print("Self-test OK")


def main():
    args = parse_args()
    if args.self_test:
        run_self_test()
        return 0

    missing_inputs, broken_links = check_paths(args.paths)

    for path in missing_inputs:
        print(f"missing input: {path}", file=sys.stderr)
    for path, line_no, link, resolved in broken_links:
        print(f"{path}:{line_no}: missing {link} -> {resolved}", file=sys.stderr)

    if missing_inputs or broken_links:
        return 1

    print("Documentation links OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
