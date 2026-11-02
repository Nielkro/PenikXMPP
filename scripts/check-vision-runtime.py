#!/usr/bin/env python3
"""Validate an offline desktop vision bundle in a merged runtime directory."""
from __future__ import annotations

import argparse
import hashlib
import json
import mmap
import os
from pathlib import Path, PurePosixPath
import platform
import re
import stat
import struct
import subprocess
import sys
import tempfile

# Keep these integrity pins aligned with the isolated offline producer.
PINS = {
    "webrtc": [".", "6f37672d358475cd17544121a12494da454d85fb"],
    "tensorflow": ["third_party/tflite/src", "a12cd7d36bb3dbae1dd7a4b572643084bc62f6e1"],
    "xnnpack": ["third_party/xnnpack/src", "d9ff5bf36955f97c657013272acd3a46d696b301"],
    "pthreadpool": ["third_party/pthreadpool/src", "02460584c6092e527c8b89f7df4de143d70e801f"],
}
MEDIAPIPE = "cad7f3ab99ebf175947e40c5252c642612aae927"
MODEL_LICENSE_SHA256 = "8707eef0533987efc5b155d64761eeb6e20793f50b9bd1a68dad1cf4719d0ed8"
CUSTOM_OPS = {
    "LICENSE": MODEL_LICENSE_SHA256,
    "mediapipe/util/tflite/operations/transpose_conv_bias.cc": "bc94fe6231cd2e08de8169d13bf47def82cb8ed72486924b823da7cc1012e457",
    "mediapipe/util/tflite/operations/transpose_conv_bias.h": "ce13d252688f657df2448e3de5ed5ba8253eebb5856afc23e290eb5be59cf786",
}
SOURCES = {"vision_inference.hpp", "vision_inference.cpp", "vision_protocol.hpp", "face_decoder.hpp",
    "vision_worker_main.cpp", "vision_android_wire.hpp", "vision_android_jni.cpp",
    "vision_android_wire_smoke.cpp", "vision_protocol_smoke.cpp", "face_decoder_golden_test.cpp"}
MODELS = {
    "selfie_segmenter_landscape-v1.tflite": (250177, "490e9ea734313e0de10fa0cd9e3c6133e36ea4db2b7a49bde9ef019f72796b8e",
        "https://storage.googleapis.com/mediapipe-models/image_segmenter/selfie_segmenter_landscape/float16/1/selfie_segmenter_landscape.tflite"),
    "blaze-face-short-range-v1.tflite": (229746, "b4578f35940bf5a1a655214a1cce5cab13eba73c1297cd78e1a04c2380b0152f",
        "https://storage.googleapis.com/mediapipe-models/face_detector/blaze_face_short_range/float16/1/blaze_face_short_range.tflite"),
}
MANIFEST = "dinox-vision-runtime-manifest.json"
CHECKSUMS = "dinox-vision-SHA256SUMS"
MAX_FILES = 1024
MAX_BYTES = 384 * 1024 * 1024
MAX_MANIFEST_BYTES = 16 * 1024 * 1024
REQUIRED_LICENSE_COMPONENTS = {"tflite", "xnnpack", "boringssl", "pthreadpool"}
ELF_SYSTEM = {"libc.so.6", "libm.so.6", "libpthread.so.0", "libdl.so.2", "librt.so.1",
    "libstdc++.so.6", "libgcc_s.so.1", "ld-linux-x86-64.so.2"}
PE_SYSTEM = {"kernel32.dll", "kernelbase.dll", "ntdll.dll", "advapi32.dll", "bcrypt.dll", "crypt32.dll",
    "user32.dll", "gdi32.dll", "ole32.dll", "oleaut32.dll", "shell32.dll", "shlwapi.dll", "ws2_32.dll",
    "secur32.dll", "version.dll", "dbghelp.dll", "iphlpapi.dll", "psapi.dll", "winmm.dll", "winhttp.dll",
    "setupapi.dll", "msvcrt.dll", "ucrtbase.dll"}


def fail(message: str) -> None:
    raise ValueError(message)


def safe_name(name: str) -> PurePosixPath:
    if not isinstance(name, str) or len(name) > 512 or "\\" in name or ":" in name or "\0" in name:
        fail("invalid manifest path")
    path = PurePosixPath(name)
    if path.is_absolute() or name != path.as_posix() or any(part in ("", ".", "..") for part in path.parts):
        fail("unsafe manifest path")
    return path


def dependency_source_root(name: str) -> str | None:
    parts = safe_name(name).parts
    if len(parts) >= 3 and parts[0] == "third_party":
        return "/".join(parts[:2])
    if len(parts) >= 4 and parts[:2] == ("buildtools", "third_party"):
        return "/".join(parts[:3])
    # The own modules/.../third_party/mediapipe_cpu sources/license are pinned
    # separately in source_files; generated out/... paths add no source root.
    return None


def regular(base: Path, name: str, limit: int = MAX_BYTES) -> Path:
    relative = safe_name(name)
    path = base
    for part in relative.parts:
        path /= part
        if path.is_symlink():
            fail("vision bundle rejects symlinks: " + name)
    if not stat.S_ISREG(path.stat().st_mode) or not 0 < path.stat().st_size <= limit:
        fail("missing, empty or oversized regular vision file: " + name)
    return path


def digest(path: Path) -> str:
    sha = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            sha.update(block)
    return sha.hexdigest()


def metadata(item: object) -> None:
    if (not isinstance(item, dict) or set(item) != {"bytes", "sha256"} or
        type(item["bytes"]) is not int or not 0 < item["bytes"] <= MAX_BYTES or
        not isinstance(item["sha256"], str) or not re.fullmatch(r"[a-f0-9]{64}", item["sha256"])):
        fail("invalid bounded file metadata")


def checked(base: Path, name: str, item: dict) -> Path:
    metadata(item)
    path = regular(base, name)
    if path.stat().st_size != item["bytes"] or digest(path) != item["sha256"]:
        fail("vision file size/hash differs: " + name)
    return path


def no_duplicate_keys(pairs: list) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            fail("duplicate manifest key")
        result[key] = value
    return result


def command(args: list[str], limit: int = 8 * 1024 * 1024) -> str:
    # Native tools can produce large output. Bound both runtime and the output
    # read into memory, and never forward model/image contents to logs.
    environment = dict(os.environ, LC_ALL="C")
    environment.pop("LD_LIBRARY_PATH", None)
    child_options = {}
    if os.name == "posix":
        import resource

        def bound_output() -> None:
            resource.setrlimit(resource.RLIMIT_FSIZE, (limit, limit))

        child_options["preexec_fn"] = bound_output
    with tempfile.TemporaryFile() as output:
        result = subprocess.run(args, stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT,
            env=environment, timeout=20, check=False, **child_options)
        if result.returncode or output.tell() >= limit:
            fail("vision static/startup command failed or exceeded its output bound")
        output.seek(0)
        return output.read().decode("utf-8", errors="replace")


def elf_dependencies(path: Path, loads: list, dynamic_segment: tuple) -> tuple[set, set]:
    """Read bounded ELF64 DT_NEEDED and version requirements without binutils."""
    with path.open("rb") as source, mmap.mmap(source.fileno(), 0, access=mmap.ACCESS_READ) as data:
        def rva(address: int, size: int) -> int:
            for start, file_size, offset in loads:
                if start <= address and address - start + size <= file_size:
                    return offset + address - start
            fail("ELF dynamic address is outside file-backed LOAD segments")

        offset, size = dynamic_segment
        if not 16 <= size <= 4096 * 16 or size % 16:
            fail("unbounded/misaligned ELF dynamic table")
        tags = {}
        terminated = False
        for position in range(offset, offset + size, 16):
            tag, value = struct.unpack_from("<qQ", data, position)
            if tag == 0:
                terminated = True
                break
            tags.setdefault(tag, []).append(value)
        if not terminated:
            fail("unterminated ELF dynamic table")
        for tag in (5, 10, 0x6ffffffe, 0x6fffffff):
            if len(tags.get(tag, [])) != 1:
                fail("missing/duplicate ELF dynamic string/version metadata")
        string_size = tags[10][0]
        if not 1 <= string_size <= 8 * 1024 * 1024:
            fail("unbounded ELF dynamic strings")
        strings = rva(tags[5][0], string_size)

        def name(relative: int) -> str:
            if not 0 <= relative < string_size:
                fail("ELF string is outside the dynamic string table")
            start = strings + relative
            end = data.find(b"\0", start, min(start + 1024, strings + string_size))
            if end < 0:
                fail("unbounded ELF dynamic string")
            return data[start:end].decode("ascii")

        needed_values = tags.get(1, [])
        if not 1 <= len(needed_values) <= 128:
            fail("missing/unbounded ELF dependency inventory")
        needed = {name(value) for value in needed_values}
        if needed - ELF_SYSTEM:
            fail("vision worker imports non-system ELF libraries: " + ", ".join(sorted(needed - ELF_SYSTEM)))
        if 15 in tags or 29 in tags:
            fail("standalone vision worker must use system libraries without a custom RPATH")
        count = tags[0x6fffffff][0]
        if not 1 <= count <= 128:
            fail("unbounded ELF version dependency inventory")
        address = tags[0x6ffffffe][0]
        versions = set()
        auxiliary_count = 0
        for index in range(count):
            version, aux_count, filename, auxiliary, next_record = struct.unpack_from("<HHIII", data, rva(address, 16))
            auxiliary_count += aux_count
            if version != 1 or not 1 <= aux_count <= 512 or auxiliary_count > 2048 or name(filename) not in needed or auxiliary < 16:
                fail("invalid/unbounded ELF version requirement")
            aux_address = address + auxiliary
            for aux_index in range(aux_count):
                _, _, _, version_name, next_aux = struct.unpack_from("<IHHII", data, rva(aux_address, 16))
                requirement = name(version_name)
                if requirement.startswith("GLIBC_"):
                    match = re.fullmatch(r"GLIBC_([0-9]+(?:\.[0-9]+)*)", requirement)
                    if not match:
                        fail("vision worker imports private/invalid GLIBC versions")
                    versions.add(tuple(map(int, match[1].split("."))))
                if (aux_index + 1 < aux_count and next_aux < 16) or (aux_index + 1 == aux_count and next_aux != 0):
                    fail("invalid ELF version auxiliary chain")
                aux_address += next_aux
            if (index + 1 < count and next_record < 16) or (index + 1 == count and next_record != 0):
                fail("invalid ELF version requirement chain")
            address += next_record
        if not versions or max(versions) > (2, 35):
            fail("vision worker exceeds the GLIBC 2.35 baseline")
        return needed, versions


def elf_gate(path: Path, readelf: str | None) -> tuple[dict, str]:
    with path.open("rb") as source:
        data = source.read(64)
    if (len(data) != 64 or data[:7] != b"\x7fELF\x02\x01\x01" or
        struct.unpack_from("<H", data, 18)[0] != 62 or struct.unpack_from("<H", data, 16)[0] not in (2, 3) or
        struct.unpack_from("<I", data, 20)[0] != 1 or struct.unpack_from("<H", data, 52)[0] != 64):
        fail("Linux vision worker must be a little-endian x64 ELF executable")
    phoff = struct.unpack_from("<Q", data, 32)[0]
    entry_size, count = struct.unpack_from("<HH", data, 54)
    if entry_size < 56 or not 0 < count <= 128 or phoff + entry_size * count > path.stat().st_size:
        fail("malformed Linux ELF program headers")
    segments = []
    loads = []
    dynamic_segment = None
    interpreter = False
    with path.open("rb") as source:
        for index in range(count):
            source.seek(phoff + index * entry_size)
            kind, _, offset, address, _, file_size, memory_size, align = struct.unpack("<IIQQQQQQ", source.read(56))
            if offset + file_size > path.stat().st_size or file_size > memory_size:
                fail("ELF program segment extends beyond its file/memory")
            if kind == 3:
                if interpreter or not 1 <= file_size <= 256:
                    fail("ELF has a duplicate or unbounded interpreter")
                source.seek(offset)
                loader = source.read(file_size)
                if loader not in (b"/lib64/ld-linux-x86-64.so.2\0", b"/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2\0"):
                    fail("ELF vision worker requires a non-system interpreter")
                interpreter = True
            if kind == 1:
                segments.append({"offset": offset, "vaddr": address, "alignment": align})
                loads.append((address, file_size, offset))
            if kind == 2:
                if dynamic_segment is not None:
                    fail("duplicate ELF dynamic segment")
                dynamic_segment = (offset, file_size)
    if not segments or not interpreter:
        fail("Linux vision worker lacks executable LOAD/INTERP segments")
    if dynamic_segment is None:
        fail("ELF worker lacks a dynamic segment")
    _, glibc = elf_dependencies(path, loads, dynamic_segment)
    if readelf is not None:
        command([readelf, "--dynamic", "--wide", str(path)])
        command([readelf, "--version-info", "--wide", str(path)])
    if platform.system() == "Linux" and platform.machine() in ("x86_64", "AMD64"):
        if not os.access(path, os.X_OK):
            fail("Linux vision worker is not executable")
        command([str(path), "--help"], 1024 * 1024)
    return ({"machine": 62, "class": 64, "type": struct.unpack_from("<H", data, 16)[0],
        "required_page_bytes": None, "LOAD": segments}, ".".join(map(str, max(glibc))))


def pe_gate(path: Path) -> dict:
    data = path.read_bytes()  # The file/aggregate bounds were checked first.
    if len(data) < 64 or data[:2] != b"MZ":
        fail("Windows vision worker is not PE")
    offset = struct.unpack_from("<I", data, 60)[0]
    if offset + 24 > len(data) or data[offset:offset + 4] != b"PE\0\0":
        fail("invalid PE header")
    machine, count = struct.unpack_from("<HH", data, offset + 4)
    optional_size, flags = struct.unpack_from("<HH", data, offset + 20)
    optional = offset + 24
    section_table = optional + optional_size
    if (machine != 0x8664 or not 0 < count <= 96 or optional_size < 240 or
        section_table + count * 40 > len(data) or not flags & 2 or flags & 0x2000 or
        struct.unpack_from("<H", data, optional)[0] != 0x20B or
        struct.unpack_from("<H", data, optional + 68)[0] != 3):
        fail("Windows vision worker must be x64 PE32+ console executable")
    sections = []
    for index in range(count):
        virtual_size, address, raw_size, raw_offset = struct.unpack_from("<IIII", data, section_table + index * 40 + 8)
        if raw_offset + raw_size > len(data):
            fail("PE section extends beyond its file")
        sections.append((address, virtual_size, raw_offset, raw_size))

    def rva(address: int, size: int) -> int:
        for start, _, raw_offset, raw_size in sections:
            if start <= address and address - start + size <= raw_size:
                return raw_offset + address - start
        fail("PE import RVA is outside its file-backed section")

    def dll_name(address: int) -> str:
        start = rva(address, 1)
        end = None
        for index in range(256):
            location = rva(address + index, 1)
            if location != start + index:
                fail("PE import name crosses file-backed section boundaries")
            if not data[location]:
                end = location
                break
        if end is None:
            fail("unbounded PE import name")
        name = data[start:end].decode("ascii").lower()
        if name not in PE_SYSTEM and not re.fullmatch(r"(?:api|ext)-ms-win-[a-z0-9-]+\.dll", name):
            fail("vision worker imports non-system DLL: " + name)
        return name

    imports = []
    directories = struct.unpack_from("<I", data, optional + 108)[0]
    if not 2 <= directories <= 16:
        fail("PE has an invalid import directory count")
    for directory, stride in ((1, 20), (13, 32)):
        if directory >= directories:
            continue
        address, size = struct.unpack_from("<II", data, optional + 112 + directory * 8)
        if not address and not size:
            continue
        if not address or not stride <= size <= 256 * stride:
            fail("unbounded PE import directory")
        start = rva(address, size)
        terminated = False
        for relative in range(0, size - stride + 1, stride):
            words = struct.unpack_from("<" + "I" * (stride // 4), data, start + relative)
            if not any(words):
                terminated = True
                break
            if directory == 13 and words[0] != 1:
                fail("PE delay imports must use bounded RVAs")
            imports.append(dll_name(words[3] if directory == 1 else words[1]))
        if not terminated:
            fail("unterminated PE imports")
    if not imports:
        fail("PE vision worker has no validated system imports")
    return {"machine": 0x8664, "optional_magic": 0x20B, "subsystem": 3, "VM_runtime_tested": False}


def verify(base: Path, target: str, readelf: str | None) -> None:
    if base.is_symlink() or not base.is_dir():
        fail("vision base must be a regular directory")
    base = base.resolve()
    manifest_path = regular(base, MANIFEST, MAX_MANIFEST_BYTES)
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"), object_pairs_hook=no_duplicate_keys)
    if (manifest.get("schema") != 1 or manifest.get("platform") != target or
        manifest.get("status") != "PACKAGED_STATIC_CHECKS_PASS_RELEASE_REVIEW_REQUIRED" or
        manifest.get("pins") != PINS or manifest.get("mediapipe_custom_op_revision") != MEDIAPIPE or
        manifest.get("full_webrtc_sdk_build") is not False):
        fail("vision manifest platform/schema/provenance differs from the pinned producer")
    models = {name: {"bytes": size, "sha256": sha, "url": url, "license": "Apache-2.0"}
        for name, (size, sha, url) in MODELS.items()}
    if manifest.get("models") != models:
        fail("vision model provenance differs from the fixed model pins")
    source_files = manifest.get("source_files")
    if not isinstance(source_files, dict) or not 1 <= len(source_files) <= MAX_FILES:
        fail("missing or unbounded vision source manifest")
    for name, item in source_files.items():
        safe_name(name)
        metadata(item)
    expected_sources = SOURCES | {"third_party/mediapipe_cpu/" + name for name in CUSTOM_OPS} | {
        "models/video-vision/" + name for name in MODELS} | {"licenses/MODEL_AND_CUSTOM_OP_LICENSE", "licenses/PROJECT_LICENSE", "BUILD.gn"}
    if set(source_files) != expected_sources:
        fail("vision source inventory differs from the isolated producer payload")
    for name, sha in CUSTOM_OPS.items():
        if source_files["third_party/mediapipe_cpu/" + name]["sha256"] != sha:
            fail("vision source custom-op integrity pin differs")
    identity = hashlib.sha256(json.dumps(source_files, sort_keys=True).encode()).hexdigest()
    if manifest.get("payload_id") != identity:
        fail("vision payload identity differs from its frozen source files")
    files = manifest.get("files")
    if not isinstance(files, dict) or not 4 <= len(files) <= MAX_FILES:
        fail("missing or unbounded vision file manifest")
    worker = "dinox-vision-worker" + (".exe" if target == "windows" else "")
    mandatory = {worker, "dinox-vision-licenses/MODEL_AND_CUSTOM_OP_LICENSE", "dinox-vision-licenses/PROJECT_LICENSE"}
    mandatory |= {"dinox-vision-models/" + name.replace("blaze-face-short-range", "blaze_face_short_range") for name in MODELS}
    if not mandatory <= set(files):
        fail("vision manifest omits worker, pinned models or original licenses")
    total = 0
    for name, item in files.items():
        safe_name(name)
        if name != worker and not name.startswith(("dinox-vision-models/", "dinox-vision-licenses/")):
            fail("unexpected vision manifest payload path")
        metadata(item)
        total += item["bytes"]
    if total > MAX_BYTES:
        fail("vision bundle exceeds 384 MiB")
    for name, item in files.items():
        checked(base, name, item)
    expected_directories = {str(parent) for name in files for parent in PurePosixPath(name).parents if str(parent) != "."}
    actual = set()
    actual_directories = set()
    entries = 0
    for entry in base.iterdir():
        if not entry.name.startswith("dinox-vision"):
            continue
        for root, directories, names in os.walk(entry) if entry.is_dir() and not entry.is_symlink() else []:
            entries += len(directories) + len(names)
            if entries > MAX_FILES * 2:
                fail("vision directory inventory exceeds its bound")
            for name in directories + names:
                child = Path(root) / name
                if child.is_symlink():
                    fail("vision inventory contains a symlink")
                if child.is_file():
                    actual.add(child.relative_to(base).as_posix())
                elif not child.is_dir():
                    fail("vision inventory contains a special file")
                else:
                    actual_directories.add(child.relative_to(base).as_posix())
        if entry.is_symlink():
            fail("vision inventory contains a symlink")
        if entry.is_file():
            actual.add(entry.name)
        elif not entry.is_dir():
            fail("vision inventory contains a special file")
        else:
            actual_directories.add(entry.name)
    if actual != set(files) | {MANIFEST, CHECKSUMS} or actual_directories != expected_directories:
        fail("vision inventory differs from the exact manifest")
    for name, (size, sha, _) in MODELS.items():
        checked(base, "dinox-vision-models/" + name.replace("blaze-face-short-range", "blaze_face_short_range"), {"bytes": size, "sha256": sha})
    if digest(regular(base, "dinox-vision-licenses/MODEL_AND_CUSTOM_OP_LICENSE")) != MODEL_LICENSE_SHA256:
        fail("original model/custom-op license differs from its pin")
    builds = manifest.get("build_manifests")
    if not isinstance(builds, list) or len(builds) != 1:
        fail("desktop vision manifest requires exactly one producer build")
    record = builds[0]
    if (record.get("schema") != 1 or record.get("platform") != target or record.get("abi") is not None or
        record.get("status") != "BUILT_STATIC_CHECKS_PASS_RELEASE_REVIEW_REQUIRED" or
        record.get("payload_id") != identity or record.get("source_files") != source_files or
        record.get("full_webrtc_sdk_build") is not False):
        fail("vision build evidence differs from the frozen desktop payload")
    dependencies = record.get("dependency_provenance", {})
    if any(dependencies.get(name, {}).get("head") != revision for name, (_, revision) in PINS.items()):
        fail("vision build dependency pins differ")
    if not re.fullmatch(r"[a-f0-9]{40}", dependencies.get("boringssl", {}).get("head", "")):
        fail("vision build lacks pinned BoringSSL provenance")
    reachable = record.get("reachable_source_files_sha256")
    if not isinstance(reachable, dict) or not 1 <= len(reachable) <= 16384:
        fail("vision build lacks bounded reachable-source integrity evidence")
    for name, sha in reachable.items():
        safe_name(name)
        if not isinstance(sha, str) or not re.fullmatch(r"[a-f0-9]{64}", sha):
            fail("invalid reachable-source hash")
    for name in ("vision_inference.cpp", "vision_worker_main.cpp", "face_decoder.hpp"):
        if not any(path.endswith("/" + name) and sha == source_files[name]["sha256"] for path, sha in reachable.items()):
            fail("vision build omits an exact reachable frozen implementation source")
    for dependency in ("tensorflow", "xnnpack", "pthreadpool"):
        if not any(name.startswith(PINS[dependency][0] + "/") for name in reachable):
            fail("vision build omits reachable pinned dependency source: " + dependency)
    artifact_files = record.get("artifact_files", {})
    for name, item in files.items():
        original = name.replace("dinox-vision-licenses/", "licenses/", 1).replace("dinox-vision-models/", "models/video-vision/", 1)
        original = original.replace("blaze_face_short_range", "blaze-face-short-range")
        if artifact_files.get(original) != item:
            fail("vision staged file differs from producer artifact evidence: " + name)
        if original in source_files and source_files[original] != item:
            fail("vision model/license differs from the frozen source payload: " + name)
    licenses = record.get("licenses", {}).get("gn_source_components")
    if not isinstance(licenses, list) or not licenses or len(licenses) > MAX_FILES:
        fail("vision build lacks bounded transitive license evidence")
    required_license_roots = {"third_party/" + component for component in REQUIRED_LICENSE_COMPONENTS}
    required_license_roots |= {root for name in reachable if (root := dependency_source_root(name)) is not None}
    licensed_roots = set()
    license_paths = set()
    license_sources = set()
    for item in licenses:
        component = item.get("component")
        if not isinstance(component, str) or not re.fullmatch(r"[A-Za-z0-9_.+\-]+", component):
            fail("invalid vision license component")
        source = safe_name(item["source_path"])
        source_root = dependency_source_root(source.as_posix())
        if (source_root not in required_license_roots or component != PurePosixPath(source_root).name or
            item.get("source_root", source_root) != source_root):
            fail("vision license component differs from its actual reachable original source root")
        relative = safe_name(item["bundle_path"])
        if (len(relative.parts) != 3 or relative.parts[:2] != ("dependencies", component) or
            not re.fullmatch(r"[0-9]{1,4}-" + re.escape(source.name), relative.name)):
            fail("vision original license bundle path differs from its component/source filename")
        if relative in license_paths or (component, source) in license_sources:
            fail("duplicate vision original license attribution")
        sha = item["license_sha256"]
        if not isinstance(sha, str) or not re.fullmatch(r"[a-f0-9]{64}", sha):
            fail("invalid vision original license text hash")
        name = "dinox-vision-licenses/" + relative.as_posix()
        if name not in files or files[name]["sha256"] != sha:
            fail("vision package omits a producer transitive license")
        if reachable.get(source.as_posix()) != sha or item.get("original_git_blob_sha256", sha) != sha:
            fail("vision original license text hash differs from its reachable source hash")
        text = regular(base, name, 4 * 1024 * 1024).read_text(encoding="utf-8")
        if not text.strip() or "\0" in text:
            fail("vision original license must contain bounded UTF-8 text")
        licensed_roots.add(source_root)
        license_paths.add(relative)
        license_sources.add((component, source))
    if required_license_roots - licensed_roots:
        fail("vision package lacks required original license attribution: " +
            ", ".join(sorted(required_license_roots - licensed_roots)))
    sums = regular(base, CHECKSUMS, 1024 * 1024).read_text(encoding="utf-8").splitlines()
    expected_sums = {name: item["sha256"] for name, item in files.items()}
    expected_sums[MANIFEST] = digest(manifest_path)
    actual_sums = {}
    for line in sums:
        match = re.fullmatch(r"([a-f0-9]{64})  (.+)", line)
        if not match or match[2] in actual_sums:
            fail("invalid or duplicate vision checksum entry")
        safe_name(match[2])
        actual_sums[match[2]] = match[1]
    if actual_sums != expected_sums:
        fail("vision checksum inventory differs from the exact bundle")
    if target == "linux":
        proof, actual_glibc = elf_gate(base / worker, readelf)
    else:
        proof = pe_gate(base / worker)
    native = manifest.get("native_checks", {}).get(target + "-x64", {})
    static_proof = record.get("static_artifact", {})
    if set(manifest.get("native_checks", {})) != {target + "-x64"} or any(
        native.get(key) != value or static_proof.get(key) != value for key, value in proof.items()):
        fail("vision native evidence differs from the actual worker headers")
    if target == "linux":
        version = static_proof.get("maximum_GLIBC", "")
        if (not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", version) or
            version != actual_glibc or tuple(map(int, version.split("."))) > (2, 35) or
            static_proof.get("model_free_startup_help_pass") is not True):
            fail("producer lacks Linux startup/GLIBC baseline evidence")
    print("OK: exact pinned " + target + " vision worker/models/licenses/provenance bundle")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, required=True)
    parser.add_argument("--platform", choices=("linux", "windows"), required=True)
    parser.add_argument("--readelf", help="Optional additional ELF tool check; the built-in bounded parser is always used")
    args = parser.parse_args()
    try:
        verify(args.base, args.platform, args.readelf)
    except (ValueError, OSError, KeyError, TypeError, AttributeError, UnicodeError, struct.error, subprocess.SubprocessError) as error:
        print("FAIL: vision runtime: " + str(error), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
