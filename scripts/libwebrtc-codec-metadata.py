#!/usr/bin/env python3
"""Stage or validate the pinned desktop codec configuration and source archive."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess


PIN = "6f37672d358475cd17544121a12494da454d85fb"
BUILD_PIN = "3e1e94361a492574eaeb681f411ec07c646fd774"
SOURCE_NAME = "webrtc-m152-codec-sources-6f37672d3584-sha256-2b17c14cc13b.tar.gz"
SOURCE_SHA256 = "2b17c14cc13b4b661c4a2be9b25c26240c97cec4a1c938196ed81dc9fd24278c"
EXPECTED_ARGS = {
    "rtc_use_h264": "true",
    "proprietary_codecs": "true",
    "ffmpeg_branding": '"Chrome"',
    "rtc_use_h265": "false",
}
MANIFEST_NAME = "WEBRTC-CODECS.json"
ARGS_NAME = "WEBRTC-GN-ARGS.gn"


def digest(path):
    sha = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            sha.update(block)
    return sha.hexdigest()


def checked_args(path):
    # Only explicit single assignments are accepted; ambiguous GN expressions
    # must be resolved by the build recipe instead of guessed by the packager.
    text = path.read_text(encoding="utf-8")
    result = {}
    for name, expected in EXPECTED_ARGS.items():
        values = re.findall(r"^\s*" + name + r"\s*=\s*([^\n#]+?)\s*(?:#.*)?$", text, re.M)
        if values != [expected]:
            raise ValueError(f"Expected exactly one {name} = {expected}, found {values!r}")
        result[name] = expected.strip('"') if expected.startswith('"') else expected == "true"
    return result


def expected_metadata():
    return {
        "webrtc_commit": PIN,
        "chromium_build_commit": BUILD_PIN,
        "codec_factory_scope": "libwebrtc-builtin",
        "codecs": ["H264", "VP9", "VP8"],
        "h264_encoder": "OpenH264",
        "h264_decoder": "FFmpeg",
        "h264_builtin_hardware_acceleration": False,
        "codec_source": "sources/" + SOURCE_NAME,
        "codec_source_sha256": SOURCE_SHA256,
        "codec_source_url": "https://git.dinox.im/dinoxim/dinox/releases/download/vendor-deps/" + SOURCE_NAME,
    }


def validate(root):
    metadata = json.loads((root / MANIFEST_NAME).read_text(encoding="utf-8"))
    for name, value in expected_metadata().items():
        if metadata.get(name) != value:
            raise ValueError(f"Codec metadata {name} does not match the M152 pin")
    if metadata.get("gn_args") != checked_args(root / ARGS_NAME):
        raise ValueError("Codec metadata disagrees with the staged GN arguments")
    if metadata.get("gn_args_sha256") != digest(root / ARGS_NAME):
        raise ValueError("Staged GN arguments checksum mismatch")
    if digest(root / metadata["codec_source"]) != SOURCE_SHA256:
        raise ValueError("Codec source archive checksum mismatch")
    return metadata


def stage(source, build, archive, output):
    for repo, expected in [(source, PIN), (source / "build", BUILD_PIN)]:
        actual = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
        if actual != expected:
            raise ValueError(f"Source pin mismatch in {repo}: {actual}")
    args = checked_args(build / "args.gn")
    if digest(archive) != SOURCE_SHA256:
        raise ValueError("Codec source archive does not match the published M152 source snapshot")
    (output / "sources").mkdir(parents=True, exist_ok=True)
    shutil.copyfile(archive, output / "sources" / SOURCE_NAME)
    shutil.copyfile(build / "args.gn", output / ARGS_NAME)
    metadata = expected_metadata()
    metadata.update(gn_args=args, gn_args_sha256=digest(output / ARGS_NAME))
    (output / MANIFEST_NAME).write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    validate(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    staging = commands.add_parser("stage")
    staging.add_argument("source", type=Path)
    staging.add_argument("build", type=Path)
    staging.add_argument("archive", type=Path)
    staging.add_argument("output", type=Path)
    checking = commands.add_parser("check")
    checking.add_argument("root", type=Path)
    options = parser.parse_args()
    if options.command == "stage":
        stage(options.source, options.build, options.archive, options.output)
    else:
        validate(options.root)


if __name__ == "__main__":
    main()
