#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIBOMEMO_C_README_SHA256="83adeac2f4760208e75160502dce8931a9c918151fb4518ce6e3f011abed2057"
LIBOMEMO_C_ADDITIONAL_PERMISSION='Additional Permissions For Submission to Apple App Store: Provided that you are otherwise in compliance with the GPLv3 for each covered work you convey (including without limitation making the Corresponding Source available in compliance with Section 6 of the GPLv3), Open Whisper Systems and Dino Team also grant you the additional permission to convey through the Apple App Store non-source executable versions of the Program as incorporated into each applicable covered work as Executable Versions only under the Mozilla Public License version 2.0 (https://www.mozilla.org/en-US/MPL/2.0/).'
GNUPG_REQUIRED_SERIES="2.4"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

ok() {
    echo "OK: $*"
}

usage() {
    cat <<'EOF'
Usage:
  check-flatpak-runtime.sh manifest [MANIFEST [BOM]]
  check-flatpak-runtime.sh layout
  check-flatpak-runtime.sh writer
  check-flatpak-runtime.sh media
  check-flatpak-runtime.sh runtime
  check-flatpak-runtime.sh --self-test [MANIFEST BOM]
  check-flatpak-runtime.sh --help

Modes:
  manifest   Validate the source manifest and its pinned license inventory.
  layout     Validate installed DinoX, Google/libwebrtc, and license files.
  writer     Run scanner-free FFmpeg AAC/M4A and H.264/MP4 writer probes.
  media      Run writer probes plus dynamic GStreamer playback probes.
  runtime    Run layout and media checks for a locally installed Flatpak.

Forgejo/DIND must use only manifest, layout, and writer. The media/runtime
modes invoke gst-inspect and gst-launch and are reserved for controlled local
or dedicated runtime testing.
EOF
}

require_file() {
    local path="$1"
    [[ -s "$path" ]] || fail "missing or empty file: $path"
}

production_plugin_names() {
    cat <<'EOF'
google-webrtc.so
http-files.so
ice.so
notification-sound.so
omemo.so
openpgp.so
mqtt.so
libtor-manager.so
bot-features.so
EOF
}

translation_catalog_inventory() {
    cat <<'EOF'
dino|main/po/LINGUAS|ar arz bg bn ca cs da de es et fi fr he hi hu id it ja lt lv nb nl pcm pl pt pt_BR ro ru sk sv tr uk ur vi yue zh_CN zh_TW
dino-omemo|plugins/omemo/po/LINGUAS|ar arz bg bn ca cs da de es et fi fr he hi hu id it ja lt lv nb nl pcm pl pt pt_BR ro ru sk sv tr uk ur vi yue zh_CN zh_TW
dino-openpgp|plugins/openpgp/po/LINGUAS|ar arz bg bn ca cs da de es et fi fr he hi hu id it ja lt lv nb nl pcm pl pt pt_BR ro ru sk sv tr uk ur vi yue zh_CN zh_TW
EOF
}

required_translation_catalogs() {
    local domain linguas_relative languages language

    while IFS='|' read -r domain linguas_relative languages; do
        for language in $languages; do
            printf '%s/LC_MESSAGES/%s.mo\n' "$language" "$domain"
        done
    done < <(translation_catalog_inventory)
}

check_translation_inventory_against_checkout() {
    local domain linguas_relative languages linguas_file
    local embedded checkout embedded_count unique_count checkout_count

    require_command awk
    require_command grep
    require_command sed
    require_command sort
    require_command tr
    require_command wc

    while IFS='|' read -r domain linguas_relative languages; do
        linguas_file="$PROJECT_ROOT/$linguas_relative"
        require_file "$linguas_file"

        embedded="$(
            tr '[:space:]' '\n' <<< "$languages" \
                | sed '/^$/d' \
                | LC_ALL=C sort -u
        )"
        checkout="$(
            awk '{
                sub(/#.*/, "")
                for (field = 1; field <= NF; field++) {
                    print $field
                }
            }' "$linguas_file" | LC_ALL=C sort -u
        )"
        [[ "$embedded" == "$checkout" ]] \
            || fail "embedded Flatpak language inventory differs from $linguas_relative ($domain)"

        embedded_count="$(wc -w <<< "$languages" | tr -d '[:space:]')"
        unique_count="$(grep -c . <<< "$embedded")"
        checkout_count="$(grep -c . <<< "$checkout")"
        [[ "$embedded_count" -eq "$unique_count" ]] \
            || fail "embedded Flatpak language inventory contains duplicates ($domain)"
        [[ "$unique_count" -eq "$checkout_count" ]] \
            || fail "embedded Flatpak language inventory count differs from $linguas_relative ($domain)"
    done < <(translation_catalog_inventory)

    ok "Flatpak translation inventory matches all checkout LINGUAS sets"
}

check_required_runtime_content() {
    local prefix="$1"
    local plugin catalog

    while IFS= read -r plugin; do
        require_file "$prefix/lib/dino/plugins/$plugin"
    done < <(production_plugin_names)

    while IFS= read -r catalog; do
        require_file "$prefix/share/locale/$catalog"
    done < <(required_translation_catalogs)
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

create_temp_directory() {
    local name="$1"
    local temp_root="${TMPDIR:-/tmp}"
    local created

    mkdir -p "$temp_root" \
        || fail "cannot create temporary directory root: $temp_root"
    [[ -d "$temp_root" && -w "$temp_root" ]] \
        || fail "temporary directory root is not writable: $temp_root"
    created="$(mktemp -d "$temp_root/$name.XXXXXX")" \
        || fail "cannot create temporary directory below: $temp_root"
    printf '%s\n' "$created"
}

require_gnupg_series() {
    local version

    version="$(gpg --version 2>/dev/null | head -1 \
        | sed -nE 's/^.*\(GnuPG\) ([0-9]+(\.[0-9]+)+).*$/\1/p')"
    case "$version" in
        "$GNUPG_REQUIRED_SERIES".*) ;;
        *) fail "Flatpak GnuPG version is '${version:-unknown}', expected $GNUPG_REQUIRED_SERIES.x" ;;
    esac
}

run_bounded() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 30s "$@"
    else
        "$@"
    fi
}

check_elf_layout() {
    local prefix="$1"

    require_command python3
    require_command ldd
    python3 - "$prefix" <<'PY'
import mmap
import os
import pathlib
import posixpath
import re
import struct
import subprocess
import sys

root = pathlib.Path(sys.argv[1]).resolve()
errors = []
elfs = []


def fail(message):
    errors.append(message)


def is_flatpak_app_library_path(entry):
    """Return true only for Flatpak's canonical runtime library directory."""
    return entry == "/app/lib"


def read_c_string(image, offset, limit):
    if offset < 0 or offset >= limit:
        raise ValueError(f"string offset outside ELF image: {offset}")
    end = image.find(b"\0", offset, limit)
    if end < 0:
        raise ValueError("unterminated ELF dynamic string")
    return image[offset:end].decode("utf-8", errors="replace")


def parse_elf(path):
    with path.open("rb") as handle:
        if os.fstat(handle.fileno()).st_size < 16:
            return None
        image = mmap.mmap(handle.fileno(), 0, access=mmap.ACCESS_READ)
        try:
            if image[:4] != b"\x7fELF":
                return None
            elf_class = image[4]
            encoding = image[5]
            if encoding == 1:
                endian = "<"
            elif encoding == 2:
                endian = ">"
            else:
                raise ValueError(f"unsupported ELF byte order {encoding}")

            if elf_class == 2:
                phoff = struct.unpack_from(endian + "Q", image, 32)[0]
                phentsize = struct.unpack_from(endian + "H", image, 54)[0]
                phnum = struct.unpack_from(endian + "H", image, 56)[0]
                ph_format = endian + "IIQQQQQQ"
                dynamic_format = endian + "qQ"
            elif elf_class == 1:
                phoff = struct.unpack_from(endian + "I", image, 28)[0]
                phentsize = struct.unpack_from(endian + "H", image, 42)[0]
                phnum = struct.unpack_from(endian + "H", image, 44)[0]
                ph_format = endian + "IIIIIIII"
                dynamic_format = endian + "iI"
            else:
                raise ValueError(f"unsupported ELF class {elf_class}")

            expected_ph_size = struct.calcsize(ph_format)
            if phentsize < expected_ph_size:
                raise ValueError("ELF program header is shorter than expected")
            if phoff + phentsize * phnum > len(image):
                raise ValueError("ELF program header table is truncated")

            load_segments = []
            dynamic_segment = None
            for index in range(phnum):
                header = struct.unpack_from(ph_format, image, phoff + index * phentsize)
                if elf_class == 2:
                    segment_type, _, offset, vaddr, _, file_size, _, _ = header
                else:
                    segment_type, offset, vaddr, _, file_size, _, _, _ = header
                if offset + file_size > len(image):
                    raise ValueError("ELF segment exceeds file size")
                if segment_type == 1:  # PT_LOAD
                    load_segments.append((vaddr, file_size, offset))
                elif segment_type == 2:  # PT_DYNAMIC
                    dynamic_segment = (offset, file_size)

            needed_offsets = []
            runtime_path_offsets = []
            string_table_vaddr = None
            string_table_size = None
            if dynamic_segment is not None:
                entry_size = struct.calcsize(dynamic_format)
                dynamic_offset, dynamic_size = dynamic_segment
                for offset in range(dynamic_offset, dynamic_offset + dynamic_size, entry_size):
                    if offset + entry_size > len(image):
                        raise ValueError("ELF dynamic table is truncated")
                    tag, value = struct.unpack_from(dynamic_format, image, offset)
                    if tag == 0:  # DT_NULL
                        break
                    if tag == 1:  # DT_NEEDED
                        needed_offsets.append(value)
                    elif tag == 5:  # DT_STRTAB
                        string_table_vaddr = value
                    elif tag == 10:  # DT_STRSZ
                        string_table_size = value
                    elif tag in (15, 29):  # DT_RPATH / DT_RUNPATH
                        runtime_path_offsets.append(value)

            needed = []
            runtime_paths = []
            if needed_offsets or runtime_path_offsets:
                if string_table_vaddr is None or string_table_size is None:
                    raise ValueError("ELF dynamic strings have no DT_STRTAB/DT_STRSZ")
                string_table_offset = None
                for vaddr, file_size, offset in load_segments:
                    if vaddr <= string_table_vaddr < vaddr + file_size:
                        string_table_offset = offset + string_table_vaddr - vaddr
                        break
                if string_table_offset is None:
                    raise ValueError("ELF DT_STRTAB is not backed by a PT_LOAD segment")
                string_table_limit = string_table_offset + string_table_size
                if string_table_limit > len(image):
                    raise ValueError("ELF dynamic string table is truncated")
                needed = [
                    read_c_string(image, string_table_offset + offset, string_table_limit)
                    for offset in needed_offsets
                ]
                runtime_paths = [
                    read_c_string(image, string_table_offset + offset, string_table_limit)
                    for offset in runtime_path_offsets
                ]

            has_oracle_marker = (
                image.find(b"DINOX_WEBRTC_IN_PROCESS_TEST_ORACLE") >= 0
                or image.find(b"DINOX_WEBRTC_ENABLE_IN_PROCESS_TEST_ORACLE") >= 0
            )
            return {
                "needed": needed,
                "runtime_paths": runtime_paths,
                "has_oracle_marker": has_oracle_marker,
            }
        finally:
            image.close()


for directory, _, filenames in os.walk(root):
    for filename in filenames:
        path = pathlib.Path(directory, filename)
        if path.is_symlink() or not path.is_file():
            continue
        try:
            parsed = parse_elf(path)
        except (OSError, ValueError, struct.error) as error:
            fail(f"{path.relative_to(root)}: ELF parse failed: {error}")
            continue
        if parsed is None:
            continue
        elfs.append((path, parsed))
        for value in parsed["runtime_paths"]:
            for entry in value.split(":"):
                if entry.startswith("/") and not is_flatpak_app_library_path(entry):
                    fail(
                        f"{path.relative_to(root)}: foreign absolute ELF "
                        f"RPATH/RUNPATH: {entry}"
                    )
        if parsed["has_oracle_marker"]:
            fail(f"{path.relative_to(root)}: release-forbidden WebRTC test oracle marker")

for path in root.rglob("*"):
    if not path.is_file():
        continue
    lowered = path.name.lower()
    if "webrtc" in lowered and (
        "test-oracle" in lowered
        or "test_oracle" in lowered
        or "smoke" in lowered
    ):
        fail(f"{path.relative_to(root)}: release-forbidden WebRTC test artifact")

legacy_rtp = [
    path for path in root.rglob("rtp.so")
    if path.is_file() and path.parent.name == "plugins" and path.parent.parent.name == "dino"
]
for path in legacy_rtp:
    fail(f"{path.relative_to(root)}: legacy GStreamer RTP plugin must not be installed")

for path in root.rglob("libgstnice.so*"):
    if path.is_file():
        fail(f"{path.relative_to(root)}: unused libnice GStreamer plugin must not be installed")

for executable in (root / "bin" / "stunbdc", root / "bin" / "stund"):
    if executable.exists():
        fail(f"{executable.relative_to(root)}: unused libnice diagnostic tool must not be installed")

bot_plugins = [
    (path, parsed) for path, parsed in elfs
    if path.name == "bot-features.so"
    and path.parent.name == "plugins"
    and path.parent.parent.name == "dino"
]
if len(bot_plugins) != 1:
    fail(f"expected exactly one installed dino/plugins/bot-features.so, found {len(bot_plugins)}")


def require_single_elf(candidates, expected_path, description):
    if len(candidates) != 1:
        fail(f"expected exactly one installed {description}, found {len(candidates)}")
        return None
    path, parsed = candidates[0]
    if path != expected_path:
        fail(
            f"{description} is installed at {path.relative_to(root)}, "
            f"expected {expected_path.relative_to(root)}"
        )
    return path, parsed


for plugin_name in (
    "google-webrtc.so",
    "http-files.so",
    "ice.so",
    "notification-sound.so",
    "omemo.so",
    "openpgp.so",
    "mqtt.so",
    "libtor-manager.so",
    "bot-features.so",
):
    require_single_elf(
        [
            (path, parsed)
            for path, parsed in elfs
            if path.name == plugin_name
            and path.parent.name == "plugins"
            and path.parent.parent.name == "dino"
        ],
        root / "lib" / "dino" / "plugins" / plugin_name,
        f"dino/plugins/{plugin_name}",
    )


google_plugin = require_single_elf(
    [(path, parsed) for path, parsed in elfs if path.name == "google-webrtc.so"],
    root / "lib" / "dino" / "plugins" / "google-webrtc.so",
    "dino/plugins/google-webrtc.so",
)
google_wrapper = require_single_elf(
    [(path, parsed) for path, parsed in elfs if path.name == "libdinox-google-webrtc.so"],
    root / "lib" / "dinox" / "libdinox-google-webrtc.so",
    "lib/dinox/libdinox-google-webrtc.so",
)
google_worker = require_single_elf(
    [(path, parsed) for path, parsed in elfs if path.name == "dinox-webrtc-worker"],
    root / "lib" / "dinox" / "dinox-webrtc-worker",
    "lib/dinox/dinox-webrtc-worker",
)

search_dirs = []
for candidate in (
    root / "lib" / "dino" / "plugins",
    root / "lib" / "dinox",
    root / "lib",
    root / "lib64",
):
    if candidate.is_dir():
        search_dirs.append(str(candidate))
for path, _ in elfs:
    if ".so" in path.name:
        directory = str(path.parent)
        if directory not in search_dirs:
            search_dirs.append(directory)

environment = os.environ.copy()
library_path = search_dirs
if environment.get("LD_LIBRARY_PATH"):
    library_path.append(environment["LD_LIBRARY_PATH"])
environment["LD_LIBRARY_PATH"] = ":".join(library_path)

ldd_results = {}
for path, parsed in elfs:
    if not parsed["needed"]:
        continue
    result = subprocess.run(
        ["ldd", str(path)],
        check=False,
        capture_output=True,
        env=environment,
        text=True,
    )
    output = result.stdout + result.stderr
    ldd_results[path] = output
    missing = sorted(set(re.findall(r"^\s*(\S+)\s+=>\s+not found\s*$", output, re.MULTILINE)))
    if missing:
        fail(f"{path.relative_to(root)}: unresolved ELF dependencies: {', '.join(missing)}")
    elif result.returncode != 0:
        detail = " ".join(output.strip().split())
        fail(f"{path.relative_to(root)}: ldd failed with {result.returncode}: {detail}")

if len(bot_plugins) == 1:
    bot_path, bot = bot_plugins[0]
    sibling_omemo = bot_path.with_name("omemo.so")
    if "omemo.so" not in bot["needed"]:
        fail(f"{bot_path.relative_to(root)}: DT_NEEDED omemo.so is missing")
    if not sibling_omemo.is_file():
        fail(f"{bot_path.relative_to(root)}: sibling omemo.so is missing")
    else:
        try:
            if parse_elf(sibling_omemo) is None:
                fail(f"{sibling_omemo.relative_to(root)}: sibling omemo.so is not ELF")
        except (OSError, ValueError, struct.error) as error:
            fail(f"{sibling_omemo.relative_to(root)}: ELF parse failed: {error}")
    if not any(
        entry == "$ORIGIN" or entry.startswith("$ORIGIN/")
        for value in bot["runtime_paths"]
        for entry in value.split(":")
    ):
        fail(f"{bot_path.relative_to(root)}: sibling lookup has no $ORIGIN RPATH/RUNPATH")

    output = ldd_results.get(bot_path, "")
    match = re.search(r"^\s*omemo\.so\s+=>\s+(\S+)\s+\(", output, re.MULTILINE)
    if match is None:
        fail(f"{bot_path.relative_to(root)}: ldd did not resolve omemo.so")
    elif sibling_omemo.is_file() and os.path.realpath(match.group(1)) != os.path.realpath(sibling_omemo):
        fail(
            f"{bot_path.relative_to(root)}: omemo.so resolved to {match.group(1)}, "
            f"not sibling {sibling_omemo}"
        )


def normalized_origin_paths(parsed):
    normalized = set()
    for value in parsed["runtime_paths"]:
        for raw_entry in value.split(":"):
            entry = raw_entry.replace("${ORIGIN}", "$ORIGIN")
            if entry == "$ORIGIN":
                normalized.add(entry)
            elif entry.startswith("$ORIGIN/"):
                suffix = posixpath.normpath(entry[len("$ORIGIN/"):])
                normalized.add("$ORIGIN" if suffix == "." else f"$ORIGIN/{suffix}")
    return normalized


def require_relative_runtime_dir(binary, parsed, target_dir, description):
    relative = os.path.relpath(target_dir, binary.parent).replace(os.sep, "/")
    expected = "$ORIGIN" if relative == "." else f"$ORIGIN/{posixpath.normpath(relative)}"
    if expected not in normalized_origin_paths(parsed):
        fail(
            f"{binary.relative_to(root)}: {description} requires relative "
            f"RPATH/RUNPATH {expected}"
        )


def require_needed_resolution(binary, parsed, soname, expected_path):
    relative = binary.relative_to(root)
    if soname not in parsed["needed"]:
        fail(f"{relative}: DT_NEEDED {soname} is missing")
        return
    if not expected_path.is_file():
        fail(f"{relative}: packaged dependency is missing: {expected_path.relative_to(root)}")
        return
    output = ldd_results.get(binary, "")
    match = re.search(
        rf"^\s*{re.escape(soname)}\s+=>\s+(\S+)\s+\(",
        output,
        re.MULTILINE,
    )
    if match is None:
        fail(f"{relative}: ldd did not resolve {soname}")
    elif os.path.realpath(match.group(1)) != os.path.realpath(expected_path):
        fail(
            f"{relative}: {soname} resolved to {match.group(1)}, "
            f"not packaged {expected_path.relative_to(root)}"
        )


if google_plugin is not None and google_wrapper is not None and google_worker is not None:
    plugin_path, plugin = google_plugin
    wrapper_path, wrapper = google_wrapper
    worker_path, worker = google_worker
    if not os.access(worker_path, os.X_OK):
        fail(f"{worker_path.relative_to(root)}: worker is not executable")

    require_relative_runtime_dir(
        plugin_path,
        plugin,
        root / "lib",
        "DinoX library lookup",
    )
    require_relative_runtime_dir(
        plugin_path,
        plugin,
        wrapper_path.parent,
        "private Google/libwebrtc wrapper lookup",
    )
    require_relative_runtime_dir(
        wrapper_path,
        wrapper,
        wrapper_path.parent,
        "private FFmpeg sibling lookup",
    )
    require_relative_runtime_dir(
        worker_path,
        worker,
        wrapper_path.parent,
        "Google/libwebrtc wrapper sibling lookup",
    )

    require_needed_resolution(
        plugin_path, plugin, "libdinox-google-webrtc.so", wrapper_path
    )
    require_needed_resolution(
        plugin_path, plugin, "libdino.so.0", root / "lib" / "libdino.so.0"
    )
    require_needed_resolution(
        worker_path, worker, "libdinox-google-webrtc.so", wrapper_path
    )
    for soname in ("libavcodec-dinox-hw.so.62", "libavutil-dinox-hw.so.60"):
        require_needed_resolution(wrapper_path, wrapper, soname, wrapper_path.with_name(soname))

if errors:
    for error in errors:
        print(f"FAIL: {error}", file=sys.stderr)
    raise SystemExit(1)

print(
    f"OK: {len(elfs)} installed ELF files have package-local runtime paths "
    "and resolvable dependencies"
)
PY
}

check_layout() {
    local prefix="${DINOX_FLATPAK_APP_PREFIX:-/app}"
    local license_root="$prefix/share/licenses/dinox"
    local component notice
    local -a bundled_components=(
        libcanberra libnice sqlcipher protobuf protobuf-c libomemo-c
        qrencode libevent tor lyrebird cjson mosquitto unbound ibus-compat
    )

    [[ -x "$prefix/bin/dinox" ]] || fail "DinoX executable is missing: $prefix/bin/dinox"
    check_required_runtime_content "$prefix"
    [[ -x "$prefix/bin/tor" ]] || fail "bundled Tor executable is missing: $prefix/bin/tor"
    [[ -x "$prefix/bin/lyrebird" ]] \
        || fail "bundled Lyrebird executable is missing: $prefix/bin/lyrebird"
    require_file "$prefix/share/tor/geoip"
    require_file "$prefix/share/tor/geoip6"
    require_command gpg
    require_command gpgconf
    require_command dirmngr
    require_command gpg-agent
    require_command gpg-connect-agent
    require_gnupg_series
    require_file "$prefix/lib/dinox/libdinox-google-webrtc.so"
    require_file "$prefix/lib/dinox/ibus-compat/libibus-1.0.so.5.0.530"
    require_file "$prefix/lib/dinox/ibus-compat/METADATA"
    [[ ! -e "$prefix/lib/dinox/ibus-compat/libibus-1.0.so.5" ]] \
        || fail "IBus fallback must not install a default SONAME alias"
    require_file "$license_root/corresponding-sources/ibus-compat/ibus_1.5.30.orig.tar.gz"
    require_file "$license_root/corresponding-sources/ibus-compat/prepare-ibus-compat.sh"
    local ibus_recipe_sha
    ibus_recipe_sha="$(sed -n 's/^recipe_sha256=//p' "$prefix/lib/dinox/ibus-compat/METADATA")"
    [[ "$ibus_recipe_sha" =~ ^[0-9a-f]{64}$ ]] || fail "IBus build-recipe checksum is missing"
    printf '%s  %s\n' "$ibus_recipe_sha" \
        "$license_root/corresponding-sources/ibus-compat/prepare-ibus-compat.sh" \
        | sha256sum -c - >/dev/null || fail "IBus exact build recipe checksum mismatch"
    printf '%s  %s\n' \
        '05b84d4a45139face161596e5ade8e6c5da55cfaf6f194861da66516190f5b96' \
        "$license_root/corresponding-sources/ibus-compat/ibus_1.5.30.orig.tar.gz" \
        | sha256sum -c - >/dev/null || fail "IBus exact source archive checksum mismatch"
    [[ -x "$prefix/lib/dinox/dinox-webrtc-worker" ]] \
        || fail "Google/libwebrtc worker is missing or not executable"
    local vision_gate="$prefix/libexec/dinox-vision-runtime-gate"
    require_file "$vision_gate"
    require_command python3
    python3 "$vision_gate" --base "$prefix/lib/dinox" --platform linux \
        || fail "installed Vision worker/model/license/manifest bundle is invalid"
    [[ -x "$prefix/libexec/dinox-flatpak-runtime-gate" ]] \
        || fail "installed Flatpak runtime gate is missing"

    for notice in LICENSE LICENSE.md PATENTS manifest.json \
            FFMPEG-LICENSE LIBVA-LICENSE FFMPEG-VP8-VAAPI.json \
            NVIDIA-CODEC-HEADERS-LICENSE WEBRTC-CODECS.json WEBRTC-GN-ARGS.gn; do
        require_file "$license_root/google-libwebrtc/$notice"
    done
    require_file "$license_root/google-libwebrtc/sources/ffmpeg-8.1.2.tar.xz"
    require_file "$license_root/google-libwebrtc/sources/libva-2.20.0.tar.gz"
    require_file "$license_root/google-libwebrtc/sources/nv-codec-headers-n8.1.24.15.tar.gz"
    require_file "$license_root/google-libwebrtc/sources/ffmpeg-dinox-symbol-versions.patch"
    printf '%s  %s\n' \
        'e3630fac46c8459340de0b1eb58916f1f3dada03899bded00bca332486375903' \
        "$license_root/google-libwebrtc/sources/ffmpeg-dinox-symbol-versions.patch" \
        | sha256sum -c - >/dev/null \
        || fail "Private FFmpeg symbol-version patch hash differs"
    printf '%s  %s\n' \
        '1e1600606cde2c04f5b1a71cb3b2e966b3ffe4e252a6ddec5781151d982e259f' \
        "$license_root/google-libwebrtc/sources/nv-codec-headers-n8.1.24.15.tar.gz" \
        | sha256sum -c - >/dev/null \
        || fail "NVIDIA codec headers source hash differs"
    require_file "$license_root/google-libwebrtc/sources/webrtc-m152-codec-sources-6f37672d3584-sha256-2b17c14cc13b.tar.gz"
    printf '%s  %s\n' \
        '2b17c14cc13b4b661c4a2be9b25c26240c97cec4a1c938196ed81dc9fd24278c' \
        "$license_root/google-libwebrtc/sources/webrtc-m152-codec-sources-6f37672d3584-sha256-2b17c14cc13b.tar.gz" \
        | sha256sum -c - >/dev/null \
        || fail "installed Google/libwebrtc codec sources checksum mismatch"
    require_file "$license_root/dinox/LICENSE"
    require_file "$license_root/dinox/NOTICE"
    require_file "$license_root/dinox/AUTHORS"
    require_file "$license_root/THIRD_PARTY_NOTICES.md"
    for component in "${bundled_components[@]}"; do
        [[ -d "$license_root/third-party/$component" ]] \
            || fail "third-party license directory is missing: $component"
        find "$license_root/third-party/$component" -type f -size +0c -print -quit \
            | grep -q . || fail "third-party license text is missing: $component"
    done
    printf '%s  %s\n' "$LIBOMEMO_C_README_SHA256" \
        "$license_root/third-party/libomemo-c/README.md" | sha256sum -c - >/dev/null \
        || fail "installed libomemo-c additional-permission README checksum mismatch"
    grep -Fx "$LIBOMEMO_C_ADDITIONAL_PERMISSION" \
        "$license_root/third-party/libomemo-c/README.md" >/dev/null \
        || fail "installed libomemo-c App Store additional permission is missing"
    [[ ! -e "$prefix/libexec/dinox-flatpak-stage-module-licenses" ]] \
        || fail "build-only Flatpak license staging helper leaked into the runtime"

    grep -q '"webrtc_milestone"[[:space:]]*:[[:space:]]*152' \
        "$license_root/google-libwebrtc/manifest.json" \
        || fail "installed Google/libwebrtc manifest is not milestone 152"
    grep -q '"target_os"[[:space:]]*:[[:space:]]*"linux"' \
        "$license_root/google-libwebrtc/manifest.json" \
        || fail "installed Google/libwebrtc manifest is not the Linux runtime"

    set +e
    run_bounded "$prefix/lib/dinox/dinox-webrtc-worker" >/dev/null 2>&1
    local worker_status=$?
    set -e
    [[ "$worker_status" -eq 2 ]] \
        || fail "Google/libwebrtc worker loader/argument smoke returned $worker_status instead of 2"

    check_elf_layout "$prefix"

    ok "Flatpak layout, Google/libwebrtc notices, and bundled-module license texts"
}

check_media_runtime() {
    local inspect_gstreamer="${1:-1}"
    local ffmpeg_path encoders muxers element
    local tmpdir audio_file video_file av_file uri
    local -a playback_elements=(
        playbin uridecodebin decodebin typefind filesrc queue capsfilter fakesink
        audioconvert audioresample level appsink videoconvert
        qtdemux matroskademux avdec_aac avdec_h264 opusdec vorbisdec vp8dec vp9dec
        autoaudiosink pulsesink
    )

    require_command ffmpeg
    require_command dd
    if [[ "$inspect_gstreamer" == "1" ]]; then
        require_command gst-inspect-1.0
        require_command gst-launch-1.0
    fi

    ffmpeg_path="$(command -v ffmpeg)"
    [[ "$ffmpeg_path" == "/usr/bin/ffmpeg" ]] \
        || fail "Flatpak must use the runtime ffmpeg, found: $ffmpeg_path"
    [[ -d /usr/lib/x86_64-linux-gnu/codecs-extra ]] \
        || fail "org.freedesktop.Platform.codecs-extra is not mounted"
    find /usr/lib/x86_64-linux-gnu/codecs-extra -type f -name 'libx264.so*' -print -quit \
        | grep -q . || fail "codecs-extra does not provide libx264"
    [[ "${GST_PLUGIN_SYSTEM_PATH:-}" == *"/codecs-extra/"* ]] \
        || fail "GNOME runtime GStreamer path does not include codecs-extra"

    encoders="$(ffmpeg -hide_banner -encoders 2>/dev/null)"
    muxers="$(ffmpeg -hide_banner -muxers 2>/dev/null)"
    grep -Eq '[[:space:]]aac([[:space:]]|$)' <<< "$encoders" \
        || fail "runtime ffmpeg has no AAC encoder"
    grep -Eq '[[:space:]]libx264([[:space:]]|$)' <<< "$encoders" \
        || fail "runtime ffmpeg/codecs-extra has no libx264 H.264 encoder"
    grep -Eq '[[:space:]]ipod([[:space:]]|$)' <<< "$muxers" \
        || fail "runtime ffmpeg has no iPod/M4A muxer"
    grep -Eq '[[:space:]]mp4([[:space:]]|$)' <<< "$muxers" \
        || fail "runtime ffmpeg has no MP4 muxer"

    if [[ "$inspect_gstreamer" == "1" ]]; then
        for element in "${playback_elements[@]}"; do
            run_bounded gst-inspect-1.0 "$element" >/dev/null 2>&1 \
                || fail "GStreamer playback element is unavailable: $element"
        done
    fi

    tmpdir="$(create_temp_directory dinox-flatpak-runtime)"
    trap 'rm -rf "$tmpdir"' EXIT
    audio_file="$tmpdir/audio.m4a"
    video_file="$tmpdir/video.mp4"
    av_file="$tmpdir/audio-video.mp4"

    dd if=/dev/zero bs=24000 count=1 2>/dev/null \
        | ffmpeg -hide_banner -loglevel error -y \
            -f s16le -ar 48000 -ac 1 -i pipe:0 -vn \
            -c:a aac -b:a 96000 -movflags +faststart -f ipod "$audio_file"
    require_file "$audio_file"

    dd if=/dev/zero bs=49152 count=1 2>/dev/null \
        | ffmpeg -hide_banner -loglevel error -y \
            -f rawvideo -pix_fmt bgra -s:v 64x64 -r 5 -i pipe:0 -an \
            -c:v libx264 -preset veryfast -tune zerolatency -profile:v baseline \
            -b:v 300000 -maxrate 300000 -bufsize 600000 \
            -pix_fmt yuv420p -movflags +faststart -f mp4 "$video_file"
    require_file "$video_file"

    ffmpeg -hide_banner -loglevel error -y \
        -i "$video_file" -i "$audio_file" \
        -map 0:v:0 -map 1:a:0 -c copy -shortest -movflags +faststart "$av_file"
    require_file "$av_file"

    if [[ "$inspect_gstreamer" == "1" ]]; then
        run_bounded gst-launch-1.0 -q \
            filesrc location="$audio_file" ! qtdemux ! decodebin ! \
            audioconvert ! audioresample ! \
            appsink sync=false wait-on-eos=false max-buffers=1 drop=true \
            || fail "GStreamer AAC/M4A demux/decode/appsink smoke failed"
        run_bounded gst-launch-1.0 -q \
            filesrc location="$video_file" ! qtdemux ! decodebin ! \
            videoconvert ! fakesink \
            || fail "GStreamer H.264/MP4 demux/decode smoke failed"
        uri="file://$av_file"
        run_bounded gst-launch-1.0 -q playbin uri="$uri" \
            audio-sink="fakesink sync=false" video-sink="fakesink sync=false" \
            || fail "GStreamer playbin playback smoke failed"
    fi

    rm -rf "$tmpdir"
    trap - EXIT
    if [[ "$inspect_gstreamer" == "1" ]]; then
        ok "runtime FFmpeg AAC/H.264 writers and GStreamer playback stack"
    else
        ok "runtime FFmpeg AAC/H.264 writers (GStreamer scanner not invoked)"
    fi
}

check_manifest() {
    local manifest="${2:-im.dinox.dinox.json}"
    local bom="${3:-packaging/flatpak/THIRD_PARTY_NOTICES.md}"

    require_command python3
    require_file "$manifest"
    require_file "$bom"

    python3 - "$manifest" "$bom" <<'PY'
import json
import pathlib
import sys

manifest_path = pathlib.Path(sys.argv[1])
bom_path = pathlib.Path(sys.argv[2])
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
bom = bom_path.read_text(encoding="utf-8")

def require(condition, message):
    if not condition:
        raise SystemExit(f"FAIL: {message}")

require(manifest.get("id") == "im.dinox.dinox", "unexpected Flatpak application id")
require(manifest.get("runtime") == "org.gnome.Platform", "unexpected Flatpak runtime")
require(manifest.get("runtime-version") == "50", "Flatpak must target GNOME 50")

modules = manifest.get("modules", [])
by_name = {module.get("name"): module for module in modules}
require(len(by_name) == len(modules), "Flatpak module names must be unique")
require("openh264" not in by_name, "self-built OpenH264 module must not be bundled")
require("pipewire" not in by_name, "obsolete GStreamer PipeWire capture module must not be bundled")
require("dinox-flatpak-license-helper" in by_name, "Flatpak license staging helper is missing")
require(by_name.get("tcl", {}).get("cleanup") == ["*"], "Tcl must remain build-only")
require(by_name.get("intltool", {}).get("cleanup") == ["*"], "intltool must remain build-only")
require(by_name.get("qrencode", {}).get("cleanup") != ["*"],
        "qrencode cleanup must preserve its installed license text")
ibus_compat = by_name.get("ibus-compat", {})
ibus_commands = "\n".join(ibus_compat.get("build-commands", []))
require("bash prepare-ibus-compat.sh --prefix /app --source-archive ibus_1.5.30.orig.tar.gz" in ibus_commands,
        "private IBus client-only build is missing")
require("/app/share/licenses/dinox/third-party/ibus-compat/COPYING" in ibus_commands,
        "private IBus LGPL license staging is missing")
require("/app/share/licenses/dinox/corresponding-sources/ibus-compat/" in ibus_commands,
        "private IBus exact source staging is missing")
require("install -m0644 prepare-ibus-compat.sh /app/share/licenses/dinox/corresponding-sources/ibus-compat/prepare-ibus-compat.sh" in ibus_commands,
        "private IBus exact build recipe staging is missing")
ibus_sources = ibus_compat.get("sources", [])
require(any(source.get("url") == "https://old-releases.ubuntu.com/ubuntu/pool/main/i/ibus/ibus_1.5.30.orig.tar.gz"
            and source.get("sha256") == "05b84d4a45139face161596e5ade8e6c5da55cfaf6f194861da66516190f5b96"
            for source in ibus_sources), "private IBus source pin is missing")

libnice_options = set(by_name.get("libnice", {}).get("config-opts", []))
for required in (
    "-Dtests=disabled",
    "-Dgtk_doc=disabled",
    "-Dexamples=disabled",
    "-Dintrospection=disabled",
    "-Dgstreamer=disabled",
):
    require(required in libnice_options, f"missing libnice build option: {required}")
libnice_cleanup = set(by_name.get("libnice", {}).get("cleanup", []))
for required in ("/bin/stunbdc", "/bin/stund"):
    require(required in libnice_cleanup, f"missing libnice runtime cleanup: {required}")

# Unbound 1.24's configure requires Expat even for a library-only build.
# --without-libexpat is parsed as the literal search prefix "no", not disablement.
unbound_options = by_name.get("unbound", {}).get("config-opts", [])
require("--with-libunbound-only" in unbound_options,
        "Unbound must remain a client-library-only build")
expat_options = [option for option in unbound_options
                 if option.startswith(("--with-libexpat", "--without-libexpat"))]
require(expat_options == ["--with-libexpat=/usr"],
        "Unbound must use Expat from the Flatpak SDK (--with-libexpat=/usr)")

license_destinations = {
    "libcanberra": "libcanberra",
    "libnice": "libnice",
    "sqlcipher": "sqlcipher",
    "protobuf": "protobuf",
    "libprotobuf-c": "protobuf-c",
    "libomemo-c": "libomemo-c",
    "qrencode": "qrencode",
    "libevent": "libevent",
    "tor": "tor",
    "lyrebird": "lyrebird",
    "cjson": "cjson",
    "mosquitto": "mosquitto",
    "unbound": "unbound",
}
for module_name, destination_name in license_destinations.items():
    module = by_name.get(module_name)
    require(module is not None, f"licensed Flatpak module is missing: {module_name}")
    commands = "\n".join(module.get("post-install", []))
    expected = f"dinox-flatpak-stage-module-licenses {destination_name} /run/build/{module_name}"
    require(expected in commands, f"module license staging is missing: {module_name}")

finish_args = manifest.get("finish-args", [])
require(finish_args.count("--filesystem=home:ro") == 1,
        "manifest must grant exactly one read-only home filesystem permission")
require(not any(arg.startswith("--filesystem=home") and
                arg != "--filesystem=home:ro" for arg in finish_args),
        "manifest must not grant another or writable home filesystem permission")
require(not any(arg.startswith("--filesystem=host") for arg in finish_args),
        "manifest must not grant host-wide filesystem access")
require("--nofilesystem=~/.local/share/dinox" in finish_args,
        "manifest must keep the native DinoX data directory hidden")
require(not any("xdg-run/pipewire-0" in arg for arg in finish_args),
        "obsolete direct PipeWire filesystem permission remains")
require(not any("GST_PLUGIN_PATH=" in arg for arg in finish_args),
        "manifest must use the GNOME runtime GST_PLUGIN_SYSTEM_PATH")
require(not any("LD_LIBRARY_PATH" in arg for arg in finish_args),
        "manifest must not expose a global LD_LIBRARY_PATH")

dino = by_name.get("dino")
require(dino is not None, "DinoX application module is missing")
# The prebuilt Vision worker is bound to the producer manifest byte for byte.
# Flatpak's default debug extraction also rewrites ELF files when strip=false.
build_options = dino.get("build-options", {})
require(build_options.get("strip") is False,
        "DinoX module must disable stripping to preserve the pinned Vision worker")
require(build_options.get("no-debuginfo") is True,
        "DinoX module must disable debug extraction to preserve the pinned Vision worker")
for arch, overrides in build_options.get("arch", {}).items():
    require(overrides.get("strip", False) is False and
            overrides.get("no-debuginfo", True) is True,
            f"DinoX {arch} build options must preserve the pinned Vision worker")
options = set(dino.get("config-opts", []))
for required in (
    "-Ddnssec=enabled",
    "-Dplugin-rtp=disabled",
    "-Dplugin-google-webrtc=enabled",
    "-Dgoogle-libwebrtc-wrapper=enabled",
    "-Dgoogle-libwebrtc-test-oracle=false",
    "-Dgoogle-libwebrtc-tests=false",
    "-Dgoogle-libwebrtc-runtime-root=/run/build/dino/libwebrtc-m152-linux-x86_64-runtime",
):
    require(required in options, f"missing application build option: {required}")
require(not any(option in options for option in (
    "-Dplugin-rtp=enabled",
    "-Dplugin-rtp-h264=enabled",
    "-Dplugin-rtp-vaapi=enabled",
    "-Dplugin-rtp-v4l2-sl=enabled",
)), "old GStreamer RTP/capture path is enabled")

runtime_sources = [
    source for source in dino.get("sources", [])
    if source.get("url", "").endswith(
        "libwebrtc-m152-linux-x86_64-runtime-abi40-ipc10-sha256-2479cdb9ab7e.tar.gz"
    )
]
require(len(runtime_sources) == 1, "expected exactly one Google/libwebrtc Linux runtime source")
require(runtime_sources[0].get("sha256") ==
        "2479cdb9ab7eace826e28d519a9dd33478329e34c303ed716c196005d9cec46f",
        "Google/libwebrtc Linux runtime digest is not the LICENSE.md-complete artifact")

post_install_commands = dino.get("post-install", [])
post_install = "\n".join(post_install_commands)
for installed in (
    "dinox/LICENSE",
    "dinox/NOTICE",
    "dinox/AUTHORS",
    "THIRD_PARTY_NOTICES.md",
    "dinox-flatpak-runtime-gate",
    "rm -f /app/libexec/dinox-flatpak-stage-module-licenses",
):
    require(installed in post_install, f"Flatpak post-install omits: {installed}")
expected_gate_install = (
    "install -Dm0755 /run/build/dino/scripts/check-flatpak-runtime.sh "
    "/app/libexec/dinox-flatpak-runtime-gate"
)
require(expected_gate_install in post_install_commands,
        "Flatpak post-install must install the runtime gate exactly once")
require(post_install_commands.count(expected_gate_install) == 1,
        "Flatpak post-install installs the runtime gate more than once")
for command in post_install_commands:
    if "dinox-flatpak-runtime-gate" in command:
        require(command == expected_gate_install,
                "Flatpak post-install must not execute the layout gate before cleanup/export")

for module in modules:
    for source in module.get("sources", []):
        url = source.get("url")
        digest = source.get("sha256") or source.get("sha512")
        if url and digest:
            require(url in bom, f"third-party inventory omits source URL: {url}")
            require(digest in bom, f"third-party inventory omits source digest: {digest}")

for statement in (
    "org.freedesktop.Platform.codecs-extra",
    "/usr/bin/ffmpeg",
    "GStreamer",
    "Google/libwebrtc",
):
    require(statement in bom, f"third-party inventory omits runtime statement: {statement}")

print("OK: Flatpak manifest architecture, pinned sources, and license inventory")
PY
}

run_manifest_mutation_self_test() {
    python3 - "$0" "$1" "$2" <<'PY'
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile

gate, manifest_path, bom = sys.argv[1:]
manifest = json.loads(Path(manifest_path).read_text(encoding="utf-8"))
cases = [
    ("strip", None, "disable stripping"),
    ("strip", True, "disable stripping"),
    ("no-debuginfo", None, "disable debug extraction"),
    ("no-debuginfo", False, "disable debug extraction"),
    ("arch", {"x86_64": {"strip": True}}, "x86_64 build options"),
    ("arch", {"x86_64": {"no-debuginfo": False}}, "x86_64 build options"),
]
with tempfile.TemporaryDirectory(prefix="dinox-flatpak-manifest-") as temporary:
    fixture = Path(temporary) / "manifest.json"
    for option, value, diagnostic in cases:
        mutated = copy.deepcopy(manifest)
        options = next(module for module in mutated["modules"]
                       if module.get("name") == "dino")["build-options"]
        if value is None:
            options.pop(option, None)
        else:
            options[option] = value
        fixture.write_text(json.dumps(mutated), encoding="utf-8")
        result = subprocess.run([gate, "manifest", str(fixture), bom],
                                capture_output=True, text=True, timeout=15)
        if result.returncode == 0 or diagnostic not in result.stderr:
            raise SystemExit(f"FAIL: Vision preservation fixture not rejected: {option}={value!r}")
    for bad_option in ("--without-libexpat", "--with-libexpat=no"):
        mutated = copy.deepcopy(manifest)
        options = next(module for module in mutated["modules"]
                       if module.get("name") == "unbound")["config-opts"]
        options[options.index("--with-libexpat=/usr")] = bad_option
        fixture.write_text(json.dumps(mutated), encoding="utf-8")
        result = subprocess.run([gate, "manifest", str(fixture), bom],
                                capture_output=True, text=True, timeout=15)
        if result.returncode == 0 or "Unbound must use Expat" not in result.stderr:
            raise SystemExit(f"FAIL: invalid Unbound Expat option accepted: {bad_option}")
print("OK: Flatpak manifest rejects Vision worker rewriting options (6 fixtures)")
print("OK: Flatpak manifest rejects invalid Unbound Expat options (2 fixtures)")
PY
}

run_layout_fixture_self_test() {
    local fixture_root plugin_dir private_dir plugin catalog

    require_command cc
    fixture_root="$(create_temp_directory dinox-flatpak-layout-fixture)"
    trap 'rm -rf "$fixture_root"' RETURN
    plugin_dir="$fixture_root/lib/dino/plugins"
    private_dir="$fixture_root/lib/dinox"
    mkdir -p "$plugin_dir" "$private_dir"

    cc -shared -fPIC -x c -Wl,-soname,libdino.so.0 \
        -o "$fixture_root/lib/libdino.so.0" - <<'EOF'
int dinox_flatpak_fixture_libdino(void) {
    return 1;
}
EOF

    cc -shared -fPIC -x c -Wl,-soname,omemo.so -o "$plugin_dir/omemo.so" - <<'EOF'
int dinox_flatpak_fixture_omemo(void) {
    return 7;
}
EOF
    cc -shared -fPIC -x c -o "$plugin_dir/bot-features.so" - \
        -L"$plugin_dir" -Wl,--no-as-needed -l:omemo.so -Wl,--as-needed \
        -Wl,-rpath,'$ORIGIN' <<'EOF'
extern int dinox_flatpak_fixture_omemo(void);
int dinox_flatpak_fixture_bot(void) {
    return dinox_flatpak_fixture_omemo();
}
EOF
    cc -shared -fPIC -x c -Wl,-soname,libavcodec-dinox-hw.so.62 \
        -o "$private_dir/libavcodec-dinox-hw.so.62" - <<'EOF'
int dinox_flatpak_fixture_avcodec(void) {
    return 62;
}
EOF
    cc -shared -fPIC -x c -Wl,-soname,libavutil-dinox-hw.so.60 \
        -o "$private_dir/libavutil-dinox-hw.so.60" - <<'EOF'
int dinox_flatpak_fixture_avutil(void) {
    return 60;
}
EOF
    cc -shared -fPIC -x c -Wl,-soname,libdinox-google-webrtc.so \
        -o "$private_dir/libdinox-google-webrtc.so" - \
        -L"$private_dir" -Wl,--no-as-needed \
        -l:libavcodec-dinox-hw.so.62 -l:libavutil-dinox-hw.so.60 -Wl,--as-needed \
        -Wl,-rpath,'$ORIGIN' <<'EOF'
extern int dinox_flatpak_fixture_avcodec(void);
extern int dinox_flatpak_fixture_avutil(void);
int dinox_flatpak_fixture_wrapper(void) {
    return dinox_flatpak_fixture_avcodec() + dinox_flatpak_fixture_avutil();
}
EOF
    cc -x c -o "$private_dir/dinox-webrtc-worker" - \
        -L"$private_dir" -Wl,--no-as-needed -l:libdinox-google-webrtc.so \
        -Wl,--as-needed -Wl,-rpath,'$ORIGIN' <<'EOF'
extern int dinox_flatpak_fixture_wrapper(void);
int main(void) {
    return dinox_flatpak_fixture_wrapper() == 122 ? 0 : 1;
}
EOF
    cc -shared -fPIC -x c -o "$plugin_dir/google-webrtc.so" - \
        -L"$private_dir" -L"$fixture_root/lib" -Wl,--no-as-needed \
        -l:libdinox-google-webrtc.so -l:libdino.so.0 -Wl,--as-needed \
        -Wl,-rpath,'$ORIGIN/../..:$ORIGIN/../../dinox' <<'EOF'
extern int dinox_flatpak_fixture_wrapper(void);
extern int dinox_flatpak_fixture_libdino(void);
int dinox_flatpak_fixture_google_plugin(void) {
    return dinox_flatpak_fixture_wrapper() + dinox_flatpak_fixture_libdino();
}
EOF

    for plugin in \
            http-files.so ice.so notification-sound.so openpgp.so mqtt.so \
            libtor-manager.so; do
        cp "$plugin_dir/omemo.so" "$plugin_dir/$plugin"
    done
    while IFS= read -r catalog; do
        mkdir -p "$(dirname "$fixture_root/share/locale/$catalog")"
        printf 'fixture %s\n' "$catalog" \
            > "$fixture_root/share/locale/$catalog"
    done < <(required_translation_catalogs)

    check_required_runtime_content "$fixture_root" >/dev/null
    check_elf_layout "$fixture_root" >/dev/null

    mv "$plugin_dir/http-files.so" "$fixture_root/http-files.so.missing"
    if (check_required_runtime_content "$fixture_root") >/dev/null 2>&1; then
        fail "layout fixture accepted a missing production plugin"
    fi
    if check_elf_layout "$fixture_root" >/dev/null 2>&1; then
        fail "ELF layout fixture accepted a missing production plugin"
    fi
    mv "$fixture_root/http-files.so.missing" "$plugin_dir/http-files.so"

    catalog="$fixture_root/share/locale/zh_TW/LC_MESSAGES/dino.mo"
    mv "$catalog" "$fixture_root/dino-lo.mo.missing"
    if (check_required_runtime_content "$fixture_root") >/dev/null 2>&1; then
        fail "layout fixture accepted a missing required translation catalog"
    fi
    mv "$fixture_root/dino-lo.mo.missing" "$catalog"

    cc -shared -fPIC -x c -o "$plugin_dir/google-webrtc.so" - \
        -L"$private_dir" -L"$fixture_root/lib" -Wl,--no-as-needed \
        -l:libdinox-google-webrtc.so -l:libdino.so.0 -Wl,--as-needed \
        -Wl,-rpath,'$ORIGIN/../..:$ORIGIN/..' <<'EOF'
extern int dinox_flatpak_fixture_wrapper(void);
extern int dinox_flatpak_fixture_libdino(void);
int dinox_flatpak_fixture_google_plugin(void) {
    return dinox_flatpak_fixture_wrapper() + dinox_flatpak_fixture_libdino();
}
EOF
    if check_elf_layout "$fixture_root" >/dev/null 2>&1; then
        fail "layout fixture accepted a Google WebRTC plugin without the private relative RUNPATH"
    fi
    cc -shared -fPIC -x c -o "$plugin_dir/google-webrtc.so" - \
        -L"$private_dir" -L"$fixture_root/lib" -Wl,--no-as-needed \
        -l:libdinox-google-webrtc.so -l:libdino.so.0 -Wl,--as-needed \
        -Wl,-rpath,'$ORIGIN/../..:$ORIGIN/../../dinox' <<'EOF'
extern int dinox_flatpak_fixture_wrapper(void);
extern int dinox_flatpak_fixture_libdino(void);
int dinox_flatpak_fixture_google_plugin(void) {
    return dinox_flatpak_fixture_wrapper() + dinox_flatpak_fixture_libdino();
}
EOF

    # /app is Flatpak's stable application mount and /app/lib its default
    # library directory. The exact path is package-local, not a host or
    # build-directory leak; no broader /app prefix is accepted.
    cc -shared -fPIC -x c -o "$fixture_root/flatpak-app-rpath.so" - \
        -Wl,-rpath,/app/lib <<'EOF'
int dinox_flatpak_fixture_app_rpath(void) {
    return 1;
}
EOF
    check_elf_layout "$fixture_root" >/dev/null
    rm -f "$fixture_root/flatpak-app-rpath.so"

    local rejected_rpath
    for rejected_rpath in \
            "$fixture_root/build-leak" \
            /app/lib/dinox \
            /app/libevil \
            /app/lib/../../tmp \
            /workspace/build \
            /usr/local/lib; do
        cc -shared -fPIC -x c -o "$fixture_root/rejected-absolute-rpath.so" - \
            -Wl,-rpath,"$rejected_rpath" <<'EOF'
int dinox_flatpak_fixture_rejected_absolute_rpath(void) {
    return 1;
}
EOF
        if check_elf_layout "$fixture_root" >/dev/null 2>&1; then
            fail "layout fixture accepted foreign absolute ELF RPATH: $rejected_rpath"
        fi
        rm -f "$fixture_root/rejected-absolute-rpath.so"
    done

    mv "$plugin_dir/omemo.so" "$fixture_root/omemo.so.missing"
    if check_elf_layout "$fixture_root" >/dev/null 2>&1; then
        fail "layout fixture accepted an unresolved sibling omemo.so"
    fi
    mv "$fixture_root/omemo.so.missing" "$plugin_dir/omemo.so"

    cp "$plugin_dir/omemo.so" "$plugin_dir/rtp.so"
    if check_elf_layout "$fixture_root" >/dev/null 2>&1; then
        fail "layout fixture accepted a legacy rtp.so plugin"
    fi
    rm -f "$plugin_dir/rtp.so"

    cp "$plugin_dir/omemo.so" "$fixture_root/libgstnice.so"
    if check_elf_layout "$fixture_root" >/dev/null 2>&1; then
        fail "layout fixture accepted an unused libnice GStreamer plugin"
    fi
    rm -f "$fixture_root/libgstnice.so"

    mkdir -p "$fixture_root/bin"
    printf '#!/usr/bin/env sh\nexit 0\n' > "$fixture_root/bin/stund"
    if check_elf_layout "$fixture_root" >/dev/null 2>&1; then
        fail "layout fixture accepted an unused libnice diagnostic tool"
    fi
    rm -f "$fixture_root/bin/stund"

    cc -shared -fPIC -x c -o "$fixture_root/release-wrapper.so" - <<'EOF'
const char dinox_flatpak_fixture_oracle[] =
    "DINOX_WEBRTC_IN_PROCESS_TEST_ORACLE";
EOF
    if check_elf_layout "$fixture_root" >/dev/null 2>&1; then
        fail "layout fixture accepted a WebRTC test oracle marker"
    fi
    rm -f "$fixture_root/release-wrapper.so"

    printf '#!/usr/bin/env sh\nexit 0\n' > "$fixture_root/dinox-webrtc-test-oracle"
    if check_elf_layout "$fixture_root" >/dev/null 2>&1; then
        fail "layout fixture accepted a named WebRTC test artifact"
    fi

    rm -rf "$fixture_root"
    trap - RETURN
    ok "Flatpak installed-layout ELF fixtures"
}

self_test() {
    local manifest="${2:-}"
    local bom="${3:-}"

    "$0" --help >/dev/null
    if "$0" __invalid_mode__ >/dev/null 2>&1; then
        fail "argument parser accepted an invalid mode"
    fi

    if [[ -n "$manifest" || -n "$bom" ]]; then
        [[ -n "$manifest" && -n "$bom" ]] \
            || fail "--self-test requires both MANIFEST and BOM when paths are supplied"
        check_manifest manifest "$manifest" "$bom"
        run_manifest_mutation_self_test "$manifest" "$bom"
    elif [[ -s im.dinox.dinox.json && \
            -s packaging/flatpak/THIRD_PARTY_NOTICES.md ]]; then
        check_manifest manifest \
            im.dinox.dinox.json \
            packaging/flatpak/THIRD_PARTY_NOTICES.md
        run_manifest_mutation_self_test \
            im.dinox.dinox.json packaging/flatpak/THIRD_PARTY_NOTICES.md
    else
        echo "SKIP: manifest parser fixture not available outside the source tree"
    fi

    check_translation_inventory_against_checkout
    run_layout_fixture_self_test
    ok "Flatpak gate argument parser self-test"
}

mode="${1:-runtime}"
case "$mode" in
    -h|--help|help)
        [[ $# -eq 1 ]] || fail "--help does not accept additional arguments"
        usage
        ;;
    --self-test)
        [[ $# -eq 1 || $# -eq 3 ]] \
            || fail "--self-test accepts either no paths or MANIFEST BOM"
        self_test "$@"
        ;;
    manifest)
        [[ $# -ge 1 && $# -le 3 ]] \
            || fail "manifest accepts at most MANIFEST and BOM paths"
        check_manifest "$@"
        ;;
    layout)
        [[ $# -eq 1 ]] || fail "layout does not accept additional arguments"
        check_layout
        ;;
    writer)
        [[ $# -eq 1 ]] || fail "writer does not accept additional arguments"
        check_media_runtime 0
        ;;
    media)
        [[ $# -eq 1 ]] || fail "media does not accept additional arguments"
        check_media_runtime 1
        ;;
    runtime)
        [[ $# -eq 1 ]] || fail "runtime does not accept additional arguments"
        check_layout
        check_media_runtime 1
        ;;
    *)
        usage >&2
        fail "unknown mode: $mode"
        ;;
esac
