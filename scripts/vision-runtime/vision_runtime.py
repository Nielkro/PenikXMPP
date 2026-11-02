#!/usr/bin/env python3
"""Pinned, offline producer for isolated vision runtimes, not a WebRTC SDK build."""
from __future__ import annotations

import argparse
import datetime as dt
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile

PINS = {
    "webrtc": (".", "6f37672d358475cd17544121a12494da454d85fb"),
    "tensorflow": ("third_party/tflite/src", "a12cd7d36bb3dbae1dd7a4b572643084bc62f6e1"),
    "xnnpack": ("third_party/xnnpack/src", "d9ff5bf36955f97c657013272acd3a46d696b301"),
    "pthreadpool": ("third_party/pthreadpool/src", "02460584c6092e527c8b89f7df4de143d70e801f"),
}
MEDIAPIPE = "cad7f3ab99ebf175947e40c5252c642612aae927"
OP_FILES = {
    "mediapipe/util/tflite/operations/transpose_conv_bias.cc": "bc94fe6231cd2e08de8169d13bf47def82cb8ed72486924b823da7cc1012e457",
    "mediapipe/util/tflite/operations/transpose_conv_bias.h": "ce13d252688f657df2448e3de5ed5ba8253eebb5856afc23e290eb5be59cf786",
    "LICENSE": "8707eef0533987efc5b155d64761eeb6e20793f50b9bd1a68dad1cf4719d0ed8",
}
MODELS = {
    "selfie_segmenter_landscape-v1.tflite": (250177, "490e9ea734313e0de10fa0cd9e3c6133e36ea4db2b7a49bde9ef019f72796b8e",
        "https://storage.googleapis.com/mediapipe-models/image_segmenter/selfie_segmenter_landscape/float16/1/selfie_segmenter_landscape.tflite"),
    "blaze-face-short-range-v1.tflite": (229746, "b4578f35940bf5a1a655214a1cce5cab13eba73c1297cd78e1a04c2380b0152f",
        "https://storage.googleapis.com/mediapipe-models/face_detector/blaze_face_short_range/float16/1/blaze_face_short_range.tflite"),
}
SOURCES = ("vision_inference.hpp", "vision_inference.cpp", "vision_protocol.hpp", "face_decoder.hpp",
    "vision_worker_main.cpp", "vision_android_wire.hpp", "vision_android_jni.cpp",
    "vision_android_wire_smoke.cpp", "vision_protocol_smoke.cpp", "face_decoder_golden_test.cpp")
ABIS = {"arm64-v8a": ("arm64", 183), "armeabi-v7a": ("arm", 40), "x86_64": ("x64", 62), "x86": ("x86", 3)}
REQUIRED_DEPS = {"//third_party/tflite:tflite_standalone", "//third_party/tflite:tflite_builtin_op_resolver_standalone",
    "//third_party/xnnpack:xnnpack_standalone", "//third_party/boringssl:boringssl"}
ARMV7_REQUIRED_DEPS = REQUIRED_DEPS - {"//third_party/xnnpack:xnnpack_standalone"} | {
    "//third_party/pthreadpool:pthreadpool_standalone"}
XNNPACK_PROFILE = "tflite-xnnpack-one-thread-v1"
ARMV7_CPU_PROFILE = "tflite-builtin-one-thread-android-armv7-v1"
ARMV7_CPU_DEFINE = "DINOX_VISION_ANDROID_ARMV7_TFLITE_CPU_ONLY"
ANDROID_BUILD_PIN = "3e1e94361a492574eaeb681f411ec07c646fd774"
ANDROID_JNI_CONFIG = "//build/config/android:hide_all_but_jni"
ANDROID_JNI_OLD_CONFIG = "//build/config/android:hide_all_but_jni_onload"
ANDROID_JNI_MAP = "build/android/android_only_jni_exports.lst"
ANDROID_JNI_CONFIG_FILE = "build/config/android/BUILD.gn"
ANDROID_JNI_MAP_SHA = "76c04f136e02e23bfc6c3cc3879af7269b55861a3fadefb1274fed0599bf540c"
ANDROID_JNI_CONFIG_SHA = "a612a8d463bedb98813c59a2744bc1e06a1ecb578e4f2e7b2d75438d265e779a"
JNI_SYMBOLS = ["Java_eu_siacs_conversations_xmpp_jingle_NativeVisionBridge_" + name
    for name in ("nativeCreate", "nativeApplyDemand", "nativeInfer", "nativeClose")]


def inference_profile(platform: str, abi: str | None) -> str:
    # No CLI backend override: the only non-XNN profile is this exact ABI.
    if platform == "android":
        if abi not in ABIS:
            fail("Android inference profile requires an exact supported ABI")
        return ARMV7_CPU_PROFILE if abi == "armeabi-v7a" else XNNPACK_PROFILE
    if platform not in ("linux", "windows") or abi is not None:
        fail("Desktop inference profile requires Linux/Windows x64 without an Android ABI")
    return XNNPACK_PROFILE


def inference_backend(profile: str) -> str:
    if profile not in (XNNPACK_PROFILE, ARMV7_CPU_PROFILE):
        fail("Unknown inference profile")
    return "tflite_builtin_cpu" if profile == ARMV7_CPU_PROFILE else "tflite_xnnpack_cpu"


def android_page_alignment(abi: str) -> int:
    # Android supports 16 KiB pages on the 64-bit ABIs; the 32-bit ABIs
    # retain the NDK's 4 KiB minimum. Keep build and package checks identical.
    if abi not in ABIS:
        fail("Android page alignment requires an exact supported ABI")
    return 16384 if abi in ("arm64-v8a", "x86_64") else 4096


def fail(message: str) -> None:
    raise RuntimeError(message)


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def utc() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def regular(path: Path) -> Path:
    if path.is_symlink() or not path.is_file():
        fail(f"Missing regular cached input: {path}")
    return path


def checked_file(path: Path, expected: str, size: int | None = None) -> None:
    regular(path)
    if (size is not None and path.stat().st_size != size) or digest(path) != expected:
        fail(f"Pinned cached input differs: {path.name}")


def gn_module() -> str:
    return '''# Generated pinned isolated consumer; no full WebRTC/SDK target.
source_set("custom_segmentation_cpu") {
  sources = [ "third_party/mediapipe_cpu/mediapipe/util/tflite/operations/transpose_conv_bias.cc",
              "third_party/mediapipe_cpu/mediapipe/util/tflite/operations/transpose_conv_bias.h" ]
  include_dirs = [ "third_party/mediapipe_cpu" ]
  deps = [ "//third_party/tflite:tflite_standalone" ]
  configs -= [ "//build/config/compiler:chromium_code" ]
  configs += [ "//build/config/compiler:no_chromium_code" ]
}
source_set("vision_inference") {
  sources = [ "vision_inference.cpp", "vision_inference.hpp", "vision_protocol.hpp", "face_decoder.hpp" ]
  include_dirs = [ "third_party/mediapipe_cpu" ]
  deps = [ ":custom_segmentation_cpu", "//third_party/tflite:tflite_standalone",
           "//third_party/tflite:tflite_builtin_op_resolver_standalone",
           "//third_party/boringssl" ]
  if (is_android && current_cpu == "arm") {
    # Pinned Chromium XNNPACK has no standalone ARM32 branch. This define is
    # restricted again in C++; all other consumers must use a real delegate.
    defines = [ "DINOX_VISION_ANDROID_ARMV7_TFLITE_CPU_ONLY=1" ]
  } else {
    deps += [ "//third_party/xnnpack:xnnpack_standalone" ]
  }
  configs -= [ "//build/config/compiler:chromium_code", "//build/config/compiler:no_exceptions" ]
  configs += [ "//build/config/compiler:no_chromium_code", "//build/config/compiler:exceptions" ]
  if (is_win) {
    cflags_cc = [ "/std:c++20", "/WX", "/clang:-Wunsafe-buffer-usage" ]
  } else {
    cflags_cc = [ "-std=c++20", "-Werror", "-Wunsafe-buffer-usage" ]
  }
}
if (is_android) {
  shared_library("dinox_vision_inference") {
    output_name = "dinox_vision_inference"
    sources = [ "vision_android_jni.cpp", "vision_android_wire.hpp" ]
    deps = [ ":vision_inference" ]
    libs = [ "android" ]
    # This bridge uses four named Java_* entrypoints, not JNI_OnLoad registration.
    configs -= [ "//build/config/compiler:chromium_code", "//build/config/compiler:no_exceptions",
                 "//build/config/android:hide_all_but_jni_onload" ]
    configs += [ "//build/config/compiler:no_chromium_code", "//build/config/compiler:exceptions",
                 "//build/config/android:hide_all_but_jni" ]
    cflags_cc = [ "-std=c++20", "-Werror", "-Wunsafe-buffer-usage" ]
    ldflags = [ "-Wl,-z,max-page-size=16384", "-Wl,-z,common-page-size=16384" ]
  }
  group("vision_runtime") { deps = [ ":dinox_vision_inference" ] }
} else {
  executable("dinox-vision-worker") {
    sources = [ "vision_worker_main.cpp" ]
    deps = [ ":vision_inference" ]
    configs -= [ "//build/config/compiler:chromium_code", "//build/config/compiler:no_exceptions" ]
    configs += [ "//build/config/compiler:no_chromium_code", "//build/config/compiler:exceptions" ]
    if (is_win) {
      cflags_cc = [ "/std:c++20", "/WX", "/clang:-Wunsafe-buffer-usage" ]
    } else {
      cflags_cc = [ "-std=c++20", "-Werror", "-Wunsafe-buffer-usage" ]
    }
    if (is_win) {
      # Explicit console/wide entrypoint; no ANSI model-path startup.
      ldflags = [ "/SUBSYSTEM:CONSOLE", "/ENTRY:wmainCRTStartup" ]
    }
  }
  group("vision_runtime") { deps = [ ":dinox-vision-worker" ] }
}
'''


def pack(args: argparse.Namespace) -> None:
    output = args.output.resolve()
    if output.exists():
        fail("Payload output already exists; inspect/reuse its immutable manifest instead of overwriting")
    repo = args.repo.resolve()
    custom = args.custom_op_root.resolve()
    for name, sha in OP_FILES.items():
        checked_file(custom / name, sha)
    checked_file(args.model_license, OP_FILES["LICENSE"])
    model_paths = dict(zip(MODELS, (args.segment_model, args.face_model), strict=True))
    for name, (size, sha, _) in MODELS.items():
        checked_file(model_paths[name], sha, size)
    files: dict[str, Path] = {name: regular(repo / "google-webrtc/vision" / name) for name in SOURCES}
    files.update({"third_party/mediapipe_cpu/" + name: custom / name for name in OP_FILES})
    files.update({"models/video-vision/" + name: path for name, path in model_paths.items()})
    files["licenses/MODEL_AND_CUSTOM_OP_LICENSE"] = args.model_license
    files["licenses/PROJECT_LICENSE"] = regular(args.project_license or repo / "LICENSE")
    before = {name: digest(path) for name, path in files.items()}
    output.mkdir(parents=True, mode=0o700)
    try:
        for name, path in files.items():
            destination = output / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, destination)
        (output / "BUILD.gn").write_text(gn_module(), encoding="utf-8")
        manifest = {name: {"sha256": digest(output / name), "bytes": (output / name).stat().st_size} for name in files}
        manifest["BUILD.gn"] = {"sha256": digest(output / "BUILD.gn"), "bytes": (output / "BUILD.gn").stat().st_size}
        if before != {name: digest(path) for name, path in files.items()} or any(manifest[name]["sha256"] != sha for name, sha in before.items()):
            fail("Inputs changed while creating payload; refuse a mixed source snapshot")
        payload_id = hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest()
        write_json(output / "payload-manifest.json", {"schema": 1, "utc": utc(), "payload_id": payload_id,
            "files": manifest, "pins": PINS, "mediapipe_custom_op_revision": MEDIAPIPE,
            "models": {name: {"bytes": size, "sha256": sha, "url": url, "license": "Apache-2.0"}
                for name, (size, sha, url) in MODELS.items()}, "full_webrtc_sdk_build": False,
            "source_review_and_runtime_acceptance": "Caller responsibility; this manifest proves source integrity only"})
    except BaseException:
        # Retain incomplete evidence for the caller; no recursive deletion of arbitrary paths.
        write_json(output / "pack-failure.json", {"status": "FAILED", "utc": utc()})
        raise
    print(f"Immutable offline payload ready: {output}")


def verify_payload(payload: Path) -> dict:
    manifest = json.loads(regular(payload / "payload-manifest.json").read_text())
    if manifest.get("schema") != 1 or manifest.get("pins") != {key: list(value) for key, value in PINS.items()}:
        fail("Payload pin/schema mismatch")
    if manifest.get("mediapipe_custom_op_revision") != MEDIAPIPE:
        fail("Custom-op revision differs")
    expected_models = {name: {"bytes": size, "sha256": sha, "url": url, "license": "Apache-2.0"}
        for name, (size, sha, url) in MODELS.items()}
    if manifest.get("models") != expected_models or manifest.get("full_webrtc_sdk_build") is not False:
        fail("Payload model provenance/full-SDK marker differs")
    files = manifest["files"]
    expected = set(SOURCES) | {"third_party/mediapipe_cpu/" + name for name in OP_FILES} | {
        "models/video-vision/" + name for name in MODELS} | {"licenses/MODEL_AND_CUSTOM_OP_LICENSE", "licenses/PROJECT_LICENSE", "BUILD.gn"}
    if set(files) != expected:
        fail("Payload contains a missing/unexpected source or model path")
    for name, item in files.items():
        checked_file(payload / name, item["sha256"], item["bytes"])
    expected_id = hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()
    if manifest["payload_id"] != expected_id or (payload / "BUILD.gn").read_text() != gn_module():
        fail("Payload/generated GN digest mismatch")
    for name, sha in OP_FILES.items():
        checked_file(payload / "third_party/mediapipe_cpu" / name, sha)
    for name, (size, sha, _) in MODELS.items():
        checked_file(payload / "models/video-vision" / name, sha, size)
    checked_file(payload / "licenses/MODEL_AND_CUSTOM_OP_LICENSE", OP_FILES["LICENSE"])
    return manifest


def run(command: list[str], log: Path, cwd: Path | None = None, timeout: int = 120) -> str:
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("wb") as stream:
        result = subprocess.run(command, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT, timeout=timeout, check=False)
    if result.returncode:
        fail(f"Command exited{result.returncode}; log: {log}")
    return log.read_text(encoding="utf-8", errors="replace")


def git_head(path: Path) -> str:
    # Exact process-local safe.directory only; never mutate global Git config.
    result = subprocess.run(["git", "-c", f"safe.directory={path.resolve()}", "-C", str(path), "rev-parse", "HEAD"],
        capture_output=True, text=True, check=True, timeout=30)
    return result.stdout.strip()


def dependency_provenance(src: Path) -> dict:
    result = {}
    pinned = dict(PINS)
    pinned["boringssl"] = ("third_party/boringssl/src", boring_revision(src))
    for name, (relative, expected) in pinned.items():
        root = (src / relative).resolve()
        if git_head(root) != expected:
            fail("Cached HEAD changed during build: " + name)
        changed = subprocess.run(["git", "-c", f"safe.directory={root}", "-C", str(root),
            "diff", "--name-only", "-z", "HEAD"], capture_output=True, check=True, timeout=60).stdout
        patches = {}
        for entry in changed.split(b"\0"):
            if not entry:
                continue
            path = Path(os.fsdecode(entry))
            if path.is_absolute() or ".." in path.parts:
                fail("Unexpected Git source path")
            file = root / path
            patches[str(path)] = digest(file) if file.is_file() and not file.is_symlink() else "deleted_or_symlink"
        result[name] = {"head": expected, "tracked_modified_file_sha256": patches}
    return result


def boring_revision(src: Path) -> str:
    # Read the original DEPS blob at the fixed WebRTC revision, never execute
    # Python DEPS and never trust a tracked local override as its own pin.
    result = subprocess.run(["git", "-c", f"safe.directory={src.resolve()}", "-C", str(src),
        "show", PINS["webrtc"][1] + ":DEPS"], capture_output=True, text=True, check=True, timeout=30)
    return boring_revision_from_deps(result.stdout)


def boring_revision_from_deps(text: str) -> str:
    entry = re.search(r"['\"](?:src/)?third_party/boringssl/src['\"]\s*:\s*([^,]+)", text)
    if not entry:
        fail("Fixed WebRTC DEPS has no BoringSSL source entry")
    block = entry[1]
    if re.search(r"Var\(['\"]boringssl_revision['\"]\)", block):
        revisions = re.findall(r"['\"]boringssl_revision['\"]\s*:\s*['\"]([a-f0-9]{40})['\"]", text)
    else:
        revisions = re.findall(r"[a-f0-9]{40}", block)
    if len(revisions) != 1:
        fail("Fixed WebRTC DEPS BoringSSL entry has no unambiguous literal revision")
    return revisions[0]


def graph_source_inventory(src: Path, metadata: dict, reachable: set[str]) -> dict:
    files = set()
    for label, values in metadata.items():
        if label.split("(", 1)[0] not in reachable or not isinstance(values, dict):
            continue
        for field in ("sources", "inputs", "public"):
            paths = values.get(field, [])
            if not isinstance(paths, list):
                continue
            for name in paths:
                if not isinstance(name, str):
                    continue
                file = src / name[2:] if name.startswith("//") else Path(name)
                if not file.is_absolute():
                    file = src / file
                resolved = file.resolve()
                if src in resolved.parents and resolved.is_file():
                    files.add(resolved)
    if not files:
        fail("GN source metadata produced no reachable file hashes")
    return {str(file.relative_to(src)): digest(file) for file in sorted(files)}


def resource_gate() -> dict:
    lines = Path("/proc/self/cgroup").read_text().splitlines()
    path = next((line[3:] for line in lines if line.startswith("0::")), None)
    if not path or ".." in Path(path).parts:
        fail("Build needs the provided bounded cgroup-v2 systemd launcher")
    root = Path("/sys/fs/cgroup") / path.lstrip("/")
    memory = (root / "memory.max").read_text().strip()
    swap = (root / "memory.swap.max").read_text().strip()
    cpu = (root / "cpu.max").read_text().split()
    if memory == "max" or int(memory) > 6 * 1024**3 or swap != "0" or cpu[0] == "max" or int(cpu[0]) > int(cpu[1]):
        fail("Resource limits require CPU<=100%, MemoryMax<=6GiB and MemorySwapMax=0")
    return {"cgroup_v2": path, "memory_max_bytes": int(memory), "swap_max_bytes": 0, "cpu_max": cpu, "ninja_jobs": 2}


def labels_from_graph(text: str) -> set[str]:
    return set(re.findall(r"//[A-Za-z0-9_./-]*:[A-Za-z0-9_.+\-]+", text))


def graph_gate(text: str, platform: str = "linux", abi: str | None = None) -> set[str]:
    profile = inference_profile(platform, abi)
    labels = labels_from_graph(text)
    missing = (ARMV7_REQUIRED_DEPS if profile == ARMV7_CPU_PROFILE else REQUIRED_DEPS) - labels
    if missing:
        fail("Missing standalone graph labels: " + ",".join(sorted(missing)))
    forbidden = [label for label in labels if label == "//:webrtc" or any(label.split(":", 1)[0] == prefix or
        label.split(":", 1)[0].startswith(prefix + "/") for prefix in ("//sdk", "//mediapipe", "//third_party/mediapipe"))]
    if forbidden:
        fail("Full SDK/MediaPipe graph is forbidden: " + ",".join(sorted(forbidden)))
    if profile == ARMV7_CPU_PROFILE and any(label.split(":", 1)[0] == "//third_party/xnnpack" or
            label.split(":", 1)[0].startswith("//third_party/xnnpack/") for label in labels):
        fail("Android ARMv7 CPU-only graph unexpectedly reaches XNNPACK")
    return labels


def android_api_overrides(src: Path) -> str:
    # Discover actual declared API argument names in the pinned cached build tree,
    # then verify the resulting compiler triples; never infer min API from Java alone.
    config = (src / "build/config/android/config.gni").read_text()
    config = re.sub(r"(?m)#.*$", "", config)
    blocks = []
    for match in re.finditer(r"declare_args\(\)\s*\{", config):
        start = match.end()
        depth = 1
        quoted = False
        escaped = False
        for index in range(start, len(config)):
            char = config[index]
            if quoted:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == '"':
                    quoted = False
            elif char == '"':
                quoted = True
            elif char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
                if not depth:
                    blocks.append(config[start:index])
                    break
    declared = "\n".join(blocks)
    keys = [key for key in ("android_ndk_api_level", "android32_ndk_api_level", "android64_ndk_api_level", "android_min_sdk_version")
        if re.search(r"(?m)^\s*" + key + r"\s*=", declared)]
    if not keys:
        fail("Pinned cached Android config has no recognized declared API argument; inspect it before building")
    return "\n".join(key + " = 23" for key in keys)


def compile_gate(path: Path, platform: str, abi: str | None) -> dict:
    profile = inference_profile(platform, abi)
    commands = json.loads(path.read_text())
    if not isinstance(commands, list) or not commands:
        fail("No actual compile commands exported")
    android_targets = []
    own_jni = False
    own_inference = 0
    for item in commands:
        words = item.get("arguments") or shlex.split(item["command"])
        own = Path(item["file"]).name == "vision_inference.cpp"
        defines = []
        for index, word in enumerate(words):
            definition = word[2:] if word.startswith(("-D", "/D")) and len(word) > 2 else (
                words[index + 1] if word in ("-D", "/D") and index + 1 < len(words) else "")
            if definition.split("=", 1)[0] == ARMV7_CPU_DEFINE:
                defines.append(definition)
            if word in ("-U" + ARMV7_CPU_DEFINE, "/U" + ARMV7_CPU_DEFINE) or (
                    word in ("-U", "/U") and index + 1 < len(words) and words[index + 1] == ARMV7_CPU_DEFINE):
                fail("Compiler command overrides the fixed inference profile")
        expected_defines = [ARMV7_CPU_DEFINE + "=1"] if own and profile == ARMV7_CPU_PROFILE else []
        if defines != expected_defines:
            fail("CPU-only compiler define is missing or used outside its exact Android ARMv7 inference source")
        if own:
            own_inference += 1
        targets = [word.split("=", 1)[1] for word in words if word.startswith("--target=")]
        targets += [words[index + 1] for index, word in enumerate(words[:-1]) if word in ("--target", "-target")]
        own_android_target = False
        for target in targets:
            match = re.fullmatch(r"(.+)-linux-android(?:eabi)?(\d+)", target)
            if match:
                if int(match[2]) != 23:
                    fail("Actual Android compiler target is not API23: " + target)
                android_targets.append(target)
                if Path(item["file"]).name == "vision_android_jni.cpp" or own:
                    prefix = {"arm64-v8a": "aarch64", "armeabi-v7a": "arm", "x86_64": "x86_64", "x86": "i686"}[abi]
                    if not match[1].startswith(prefix):
                        fail("Actual own compiler architecture differs from requested ABI")
                    if abi == "armeabi-v7a" and not any(word.startswith("-mfpu=neon") for word in words):
                        fail("ARMv7 own sources do not prove their NEON baseline")
                    own_android_target = True
                    if Path(item["file"]).name == "vision_android_jni.cpp":
                        own_jni = True
        if own and platform == "android" and not own_android_target:
            fail("Own inference compiler target has no exact Android API23/ABI proof")
    if own_inference != 1:
        fail("Expected exactly one actual own inference compiler command")
    if platform == "android" and (not own_jni or not android_targets):
        fail("JNI has no proven actual Android API23 compile command")
    return {"commands": len(commands), "sha256": digest(path), "android_api": 23 if own_jni else None,
        "android_targets": sorted(set(android_targets)), "abi": abi, "inference_profile": profile,
        "inference_backend": inference_backend(profile), "inference_threads": 1}


def dependency_source_root(name: str) -> str | None:
    relative = Path(name)
    if (relative.is_absolute() or ".." in relative.parts or str(relative) != name or "\\" in name):
        fail("Unsafe source/license inventory path")
    parts = relative.parts
    if len(parts) >= 3 and parts[0] == "third_party":
        return "/".join(parts[:2])
    if len(parts) >= 4 and parts[:2] == ("buildtools", "third_party"):
        return "/".join(parts[:3])
    # Own modules/.../third_party/mediapipe_cpu is covered by the separately
    # pinned custom-op license. Generated out/... files introduce no new root.
    return None


def required_license_roots(snapshot: dict, platform: str = "linux", abi: str | None = None) -> set[str]:
    profile = inference_profile(platform, abi)
    if not isinstance(snapshot, dict) or not snapshot:
        fail("Missing actual reachable source hash inventory for license attribution")
    required = ("tflite", "boringssl", "pthreadpool") if profile == ARMV7_CPU_PROFILE else (
        "tflite", "xnnpack", "boringssl", "pthreadpool")
    roots = {"third_party/" + component for component in required}
    for name, sha in snapshot.items():
        if not isinstance(name, str) or not isinstance(sha, str) or not re.fullmatch(r"[a-f0-9]{64}", sha):
            fail("Malformed reachable source hash inventory")
        root = dependency_source_root(name)
        if root:
            if profile == ARMV7_CPU_PROFILE and root == "third_party/xnnpack":
                fail("Android ARMv7 CPU-only source snapshot unexpectedly contains XNNPACK")
            roots.add(root)
    return roots


def original_license_proof(src: Path, file: Path) -> dict:
    # Original attribution means the Git blob at the cached source revision,
    # not a mutable local replacement which happens to be named LICENSE.
    repository = next((parent for parent in file.parents if (parent / ".git").exists()), None)
    if repository is None or (repository != src and src not in repository.parents):
        fail("License has no bounded cached original Git repository")
    revision = git_head(repository)
    relative = str(file.relative_to(repository))
    result = subprocess.run(["git", "-c", f"safe.directory={repository}", "-C", str(repository),
        "show", revision + ":" + relative], capture_output=True, check=True, timeout=30)
    original_sha = hashlib.sha256(result.stdout).hexdigest()
    if not result.stdout or len(result.stdout) > 4 * 1024 * 1024 or digest(file) != original_sha:
        fail("Cached license differs from its original Git source blob")
    result.stdout.decode("utf-8")
    return {"origin_repository": str(repository.relative_to(src)), "origin_revision": revision,
        "origin_path": relative, "original_git_blob_sha256": original_sha}


def license_inventory(src: Path, snapshot: dict, destination: Path,
        platform: str = "linux", abi: str | None = None) -> dict:
    inventory = []
    original_hashes = {}
    next_index = {}
    for source_root in sorted(required_license_roots(snapshot, platform, abi)):
        root = src / source_root
        component = root.name
        readme = root / "README.chromium"
        # Cached source layouts sometimes put the license in src/, while the GN
        # wrapper README remains at the component root.
        metadata = readme.read_text(errors="replace") if readme.is_file() else ""
        match = re.search(r"(?mi)^License File:\s*(.+)$", metadata)
        names = [name.strip() for name in match[1].split(",")] if match else ["LICENSE", "src/LICENSE", "LICENSE.txt", "src/LICENSE.txt",
            "LICENSE.TXT", "src/LICENSE.TXT", "trunk/LICENSE.TXT", "COPYING", "src/COPYING"]
        chosen = []
        for name in names:
            candidate = src / name[2:] if name.startswith("//") else root / name
            if candidate.is_file() and not candidate.is_symlink():
                candidate = candidate.resolve()
                if root.resolve() not in candidate.parents or not 0 < candidate.stat().st_size <= 4 * 1024 * 1024:
                    fail("License original is outside the attributed compiled source root: " + source_root)
                chosen.append(candidate)
                if not match:
                    break
        if not chosen or (match and len(chosen) != len(names)):
            fail("Missing complete original license material before native build: " + source_root)
        for candidate in chosen:
            proof = original_license_proof(src, candidate)
            index = next_index.get(component, 0)
            next_index[component] = index + 1
            copied = destination / component / f"{index}-{candidate.name}"
            copied.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(candidate, copied)
            source_path = str(candidate.relative_to(src))
            original_hashes[source_path] = proof["original_git_blob_sha256"]
            inventory.append({"component": component, "source_root": source_root, "source_path": source_path,
                "license_sha256": digest(candidate), "bundle_path": str(copied.relative_to(destination.parent)),
                "readme_sha256": digest(readme) if readme.is_file() else None, **proof})
    # Build-tool/sysroot runtime attribution is distinct from source GN deps and
    # must remain a release gate, not be silently called complete here.
    return {"gn_source_components": inventory, "original_license_sources_sha256": original_hashes,
        "toolchain_and_system_runtime_license_review_required": True}


def elf_gate(path: Path, machine: int, pages: int | None) -> dict:
    data = path.read_bytes()
    if data[:4] != b"\x7fELF" or len(data) < 64 or data[5] != 1 or data[4] not in (1, 2):
        fail("Artifact is not supported little-endian ELF")
    actual = struct.unpack_from("<H", data, 18)[0]
    if actual != machine:
        fail("ELF machine/ABI mismatch")
    is64 = data[4] == 2
    if is64 != (machine in (62, 183)) or data[6] != 1 or struct.unpack_from("<I", data, 20)[0] != 1:
        fail("ELF class/version differs from requested ABI")
    kind = struct.unpack_from("<H", data, 16)[0]
    if kind not in (2, 3) or (pages and kind != 3):
        fail("ELF type is not the requested executable/shared library")
    phoff = struct.unpack_from("<Q" if is64 else "<I", data, 32 if is64 else 28)[0]
    entsize, count = struct.unpack_from("<HH", data, 54 if is64 else 42)
    minimum = 56 if is64 else 32
    if entsize < minimum or count > 128 or phoff + entsize * count > len(data):
        fail("Malformed ELF program table")
    segments = []
    for index in range(count):
        values = struct.unpack_from("<IIQQQQQQ" if is64 else "<IIIIIIII", data, phoff + index * entsize)
        if values[0] != 1:
            continue
        offset, address, align = (values[2], values[3], values[7]) if is64 else (values[1], values[2], values[7])
        file_size, memory_size = (values[5], values[6]) if is64 else (values[4], values[5])
        if file_size > memory_size or offset + file_size > len(data):
            fail("ELF LOAD extends beyond the file or memory segment")
        if pages and (align < pages or align & (align - 1) or offset % pages != address % pages):
            fail(f"Actual ELF LOAD does not support {pages}-byte pages")
        segments.append({"offset": offset, "vaddr": address, "alignment": align})
    if not segments:
        fail("ELF has no LOAD segment")
    return {"machine": actual, "class": 64 if is64 else 32, "type": kind, "required_page_bytes": pages, "LOAD": segments}


def pe_gate(path: Path) -> dict:
    data = path.read_bytes()
    if data[:2] != b"MZ" or len(data) < 64:
        fail("Windows worker is not a PE executable")
    pe = struct.unpack_from("<I", data, 60)[0]
    if pe + 96 > len(data) or data[pe:pe + 4] != b"PE\0\0":
        fail("Invalid PE header")
    machine = struct.unpack_from("<H", data, pe + 4)[0]
    sections = struct.unpack_from("<H", data, pe + 6)[0]
    optional_size, characteristics = struct.unpack_from("<HH", data, pe + 20)
    section_table = pe + 24 + optional_size
    if (not 0 < sections <= 96 or optional_size < 112 or section_table + sections * 40 > len(data) or
        not characteristics & 2 or characteristics & 0x2000):
        fail("Windows worker has malformed executable headers")
    magic = struct.unpack_from("<H", data, pe + 24)[0]
    subsystem = struct.unpack_from("<H", data, pe + 24 + 68)[0]
    if machine != 0x8664 or magic != 0x20B or subsystem != 3:
        fail("Windows worker must be x64 PE32+ console/wmain")
    for index in range(sections):
        raw_size, raw_offset = struct.unpack_from("<II", data, section_table + index * 40 + 16)
        if raw_size and raw_offset + raw_size > len(data):
            fail("Windows worker section extends beyond its file")
    return {"machine": machine, "optional_magic": magic, "subsystem": subsystem, "VM_runtime_tested": False}


def stage_payload(payload: Path, modules: Path, manifest: dict) -> Path:
    modules.mkdir(parents=True, exist_ok=True)
    stage = modules / ("dinox_vision_runtime_" + manifest["payload_id"][:16])
    if stage.exists():
        verify_payload(stage)
        return stage
    temporary = Path(tempfile.mkdtemp(prefix=".dinox-vision-stage-", dir=modules))
    try:
        shutil.copytree(payload, temporary, dirs_exist_ok=True)
        verify_payload(temporary)
        try:
            temporary.rename(stage)
        except OSError as error:
            # Two independent isolated outputs may reach the same immutable
            # module simultaneously. Never replace the other reader's stage.
            if error.errno not in (errno.EEXIST, errno.ENOTEMPTY) or not stage.exists():
                raise
            verify_payload(stage)
        return stage
    finally:
        if temporary.exists():
            shutil.rmtree(temporary) # Only this newly allocated bounded copy.


def android_build_revision_from_deps(text: str) -> str:
    revisions = re.findall(r"['\"]src/build['\"]\s*:\s*['\"]https://chromium\.googlesource\.com/chromium/src/build@([a-f0-9]{40})['\"]", text)
    if revisions != [ANDROID_BUILD_PIN]:
        fail("Fixed original WebRTC DEPS does not prove the pinned Android build/export config revision")
    return revisions[0]


def verify_jni_export_proof(proof: dict, sources: dict, target: str) -> None:
    if not isinstance(proof, dict) or proof.get("target") != target or proof.get("config") != ANDROID_JNI_CONFIG:
        fail("Android native target has no exact standard named-JNI export configuration proof")
    configs = proof.get("target_configs", [])
    if (not isinstance(configs, list) or any(not isinstance(value, str) for value in configs) or
            configs.count(ANDROID_JNI_CONFIG) != 1 or ANDROID_JNI_OLD_CONFIG in configs or
            proof.get("version_script") != ANDROID_JNI_MAP or proof.get("inputs") != [ANDROID_JNI_MAP] or
            proof.get("build_revision") != ANDROID_BUILD_PIN):
        fail("Android JNI export config/input/map differs from the pinned standard policy")
    originals = proof.get("original_sources")
    expected = {"DEPS": (".", PINS["webrtc"][1], "DEPS", None),
        ANDROID_JNI_MAP: ("build", ANDROID_BUILD_PIN, "android/android_only_jni_exports.lst", ANDROID_JNI_MAP_SHA),
        ANDROID_JNI_CONFIG_FILE: ("build", ANDROID_BUILD_PIN, "config/android/BUILD.gn", ANDROID_JNI_CONFIG_SHA)}
    if not isinstance(originals, dict) or set(originals) != set(expected):
        fail("Android export map/config has no complete original Git source proof")
    for name, (repo, revision, path, pinned_sha) in expected.items():
        item = originals[name]
        if not isinstance(item, dict):
            fail("Malformed original Android export source proof")
        sha = item.get("sha256", "")
        if (not isinstance(sha, str) or not re.fullmatch(r"[a-f0-9]{64}", sha) or sources.get(name) != sha or
                item.get("original_git_blob_sha256") != sha or (pinned_sha is not None and sha != pinned_sha) or
                item.get("origin_repository") != repo or item.get("origin_revision") != revision or item.get("origin_path") != path):
            fail("Android export input differs from its exact pinned original Git blob")


def jni_export_generation_gate(src: Path, out: Path, target: str, metadata: dict) -> dict:
    # Target configs, linker argument and input must all select the same stock
    # map. Prove the independent build repository via the original root DEPS;
    # never patch SDK sources or create a permissive custom export map.
    entries = [values for label, values in metadata.items() if label.split("(", 1)[0] == target]
    if len(entries) != 1 or not isinstance(entries[0], dict) or entries[0].get("type") != "shared_library":
        fail("Expected one actual isolated Android shared-library metadata target")
    values = entries[0]
    configs = values.get("configs", [])
    inputs = values.get("inputs", [])
    ldflags = values.get("ldflags", [])
    if any(not isinstance(items, list) or any(not isinstance(value, str) for value in items) for items in (configs, inputs, ldflags)):
        fail("Malformed actual Android JNI config/input/linker metadata")
    def source_path(value: str) -> Path:
        return (src / value[2:] if value.startswith("//") else out / value).resolve()
    expected_map = (src / ANDROID_JNI_MAP).resolve()
    scripts = [value.split("=", 1)[1] for value in ldflags if value.startswith("-Wl,--version-script=")]
    if (len(scripts) != 1 or source_path(scripts[0]) != expected_map or
            not any(source_path(value) == expected_map for value in inputs) or
            any("android_only_explicit_jni_exports.lst" in value for value in inputs + ldflags)):
        fail("Actual JNI linker/input still hides named Java exports or uses an unexpected map")
    if git_head(src) != PINS["webrtc"][1] or git_head(src / "build") != ANDROID_BUILD_PIN:
        fail("Android export inputs are not from the pinned root/build Git revisions")
    originals = {}
    for name, wanted_sha in (("DEPS", None), (ANDROID_JNI_MAP, ANDROID_JNI_MAP_SHA),
            (ANDROID_JNI_CONFIG_FILE, ANDROID_JNI_CONFIG_SHA)):
        file = regular(src / name)
        if wanted_sha is not None:
            checked_file(file, wanted_sha)
        originals[name] = {"sha256": digest(file), **original_license_proof(src, file)}
    revision = android_build_revision_from_deps((src / "DEPS").read_text())
    proof = {"target": target, "config": ANDROID_JNI_CONFIG, "target_configs": [value.split("(", 1)[0] for value in configs],
        "version_script": ANDROID_JNI_MAP, "inputs": [ANDROID_JNI_MAP], "build_revision": revision, "original_sources": originals}
    verify_jni_export_proof(proof, {name: item["sha256"] for name, item in originals.items()}, target)
    return proof


def jni_symbol_gate(native: Path, log: Path, readelf: Path | None = None) -> dict:
    tool = readelf or Path(shutil.which("readelf") or "readelf")
    text = run([str(tool), "--dyn-syms", "--wide", str(native)], log)
    symbols = []
    for symbol in JNI_SYMBOLS:
        lines = [line.split() for line in text.splitlines() if line.split() and line.split()[-1] == symbol]
        if not any(len(fields) >= 8 and fields[3:6] == ["FUNC", "GLOBAL", "DEFAULT"] and fields[6] != "UND" for fields in lines):
            fail("Defined public JNI release symbol missing: " + symbol.rsplit("_", 1)[-1])
        symbols.append(symbol)
    jni_exports = [fields[-1] for line in text.splitlines() if len(fields := line.split()) >= 8 and
        fields[4] in ("GLOBAL", "WEAK") and fields[5] == "DEFAULT" and fields[6] not in ("UND", "ABS") and
        (fields[-1].startswith("Java_") or fields[-1] in ("JNI_OnLoad", "JNI_OnUnload", "CrashpadHandlerMain", "NativeChildProcessService_onCreate"))]
    if sorted(jni_exports) != sorted(symbols):
        fail("Defined public JNI export set differs from the exact four bridge entrypoints")
    return {"defined_global_default_symbols": symbols, "symbol_log_sha256": digest(log)}


def vision_cached_args(cached_args: str) -> str:
    # These SDK media/example arguments are not declared by the isolated
    # vision graph. Keep every platform, toolchain, API and compiler argument;
    # --fail-on-unused-args continues to catch all other unexpected inputs.
    result = re.sub(r'(?m)^[ \t]*ffmpeg_branding[ \t]*=[ \t]*"[^"\n]*"[ \t]*$', "", cached_args)
    return re.sub(r'(?m)^[ \t]*(?:rtc_include_tests|rtc_build_examples|rtc_use_h264|rtc_use_h265)'
        r'[ \t]*=[ \t]*(?:true|false)[ \t]*$', "", result)


def inference_build_args(cached_args: str, platform: str, abi: str | None) -> str:
    profile = inference_profile(platform, abi)
    # Explicit false is essential for ARMv7; never depend on a cache/default
    # or patch the upstream wrapper to create an unsupported XNN target.
    xnn = "false" if profile == ARMV7_CPU_PROFILE else "true"
    cached = re.sub(r'(?m)^[ \t]*build_tflite_with_xnnpack[ \t]*=[ \t]*(?:true|false)[ \t]*$', "",
        vision_cached_args(cached_args))
    return cached + "\nuse_litert_tflite = false\nbuild_tflite_with_xnnpack = " + xnn + \
        "\nis_debug = false\nis_component_build = false\n"


def build_one_locked(args: argparse.Namespace, abi: str | None) -> None:
    payload, src, job = args.payload.resolve(), args.src.resolve(), args.job.resolve()
    manifest = verify_payload(payload)
    profile = inference_profile(args.platform, abi)
    limits = resource_gate()
    for name, (relative, expected) in PINS.items():
        if git_head(src / relative) != expected:
            fail("Cached dependency HEAD differs: " + name)
    if git_head(src / "third_party/boringssl/src") != boring_revision(src):
        fail("Cached BoringSSL HEAD differs from fixed WebRTC DEPS")
    suffix = abi if abi else args.platform + "-x64"
    cached = (args.cached_out / abi if args.platform == "android" else args.cached_out).resolve()
    out = (args.out / abi if args.platform == "android" else args.out).resolve()
    if out == cached or cached in out.parents or src / "out" not in out.parents:
        fail("Output must be a separate child of cached src/out, never the shipping cache")
    cached_args = regular(cached / "args.gn").read_text()
    cached_os = re.findall(r'(?m)^\s*target_os\s*=\s*"([^"]+)"', cached_args)
    wanted_os = {"android": "android", "windows": "win", "linux": "linux"}[args.platform]
    if (cached_os and cached_os[-1] != wanted_os) or (not cached_os and args.platform != "linux"):
        fail("Cached args do not prove requested target OS")
    cpu = re.findall(r'(?m)^\s*target_cpu\s*=\s*"([^"]+)"', cached_args)
    wanted = ABIS[abi][0] if abi else "x64"
    if not cpu or cpu[-1] != wanted:
        fail("Cached args do not prove requested target CPU")
    stage = stage_payload(payload, src / "modules", manifest)
    current_job = job / suffix
    current_job.mkdir(parents=True, exist_ok=True)
    artifact_root = current_job / "artifact"
    artifact_root.mkdir(exist_ok=True)
    shutil.copytree(payload / "licenses", artifact_root / "licenses", dirs_exist_ok=True)
    shutil.copytree(payload / "models", artifact_root / "models", dirs_exist_ok=True)
    shutil.copyfile(payload / "payload-manifest.json", artifact_root / "source-provenance.json")
    module = "//" + str(stage.relative_to(src))
    root_target = module + ":vision_runtime"
    target = module + (":dinox_vision_inference" if abi else ":dinox-vision-worker")
    gn = args.gn or src / "buildtools/linux64/gn"
    siso = args.siso or src / "third_party/siso/cipd/siso"
    options = inference_build_args(cached_args, args.platform, abi)
    if abi:
        options += android_api_overrides(src) + "\n"
    out.mkdir(parents=True, exist_ok=True)
    run([str(gn), "gen", str(out), "--root=" + str(src), "--root-target=" + root_target,
        "--fail-on-unused-args", "--export-compile-commands", "--args=" + options], current_job / "gn-gen.log", src, 600)
    graph = run([str(gn), "desc", str(out), target, "deps", "--all", "--root=" + str(src), "--root-target=" + root_target],
        current_job / "dependencies.txt", src)
    labels = graph_gate(graph, args.platform, abi)
    compile_proof = compile_gate(out / "compile_commands.json", args.platform, abi)
    metadata = json.loads(run([str(gn), "desc", str(out), "//*", "--format=json", "--root=" + str(src),
        "--root-target=" + root_target], current_job / "gn-metadata.json", src, 600))
    jni_exports = jni_export_generation_gate(src, out, target, metadata) if abi else None
    source_snapshot = graph_source_inventory(src, metadata, labels | {target})
    if jni_exports:
        source_snapshot.update({name: item["sha256"] for name, item in jni_exports["original_sources"].items()})
    licenses = license_inventory(src, source_snapshot, artifact_root / "licenses/dependencies", args.platform, abi)
    source_snapshot.update(licenses["original_license_sources_sha256"])
    run([str(siso), "ninja", "-C", str(out), "-local_jobs", "2", "dinox_vision_inference" if abi else "dinox-vision-worker"],
        current_job / "compile.log", src, 18 * 3600)
    filename = "libdinox_vision_inference.so" if abi else "dinox-vision-worker" + (".exe" if args.platform == "windows" else "")
    native = regular(out / filename)
    completed_snapshot = graph_source_inventory(src, metadata, labels | {target})
    for name in licenses["original_license_sources_sha256"]:
        completed_snapshot[name] = digest(regular(src / name))
    if jni_exports:
        for name in jni_exports["original_sources"]:
            completed_snapshot[name] = digest(regular(src / name))
    generated_prefix = str(out.relative_to(src)) + "/"
    if any(not name.startswith(generated_prefix) and completed_snapshot.get(name) != sha
            for name, sha in source_snapshot.items()):
        fail("Reachable cached sources changed during compilation; refuse mixed artifact")
    source_snapshot = completed_snapshot
    destination = artifact_root / ("jni/" + abi + "/" + filename if abi else filename)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(native, destination)
    static = pe_gate(native) if args.platform == "windows" else elf_gate(native, ABIS[abi][1] if abi else 62, android_page_alignment(abi) if abi else None)
    if abi:
        static["jni"] = jni_symbol_gate(native, current_job / "symbols.txt", args.readelf)
    elif args.platform == "linux":
        destination.chmod(0o755)
        run([str(destination), "--help"], current_job / "startup-help.txt", timeout=10)
        readelf = args.readelf or Path(shutil.which("readelf") or "readelf")
        versions = run([str(readelf), "--version-info", "--wide", str(native)], current_job / "versions.txt")
        glibc = {tuple(map(int, value.split("."))) for value in re.findall(r"GLIBC_([0-9.]+)", versions)}
        maximum = max(glibc, default=(0,))
        if maximum > (2, 35):
            fail("Linux worker exceeds GLIBC2.35 compatibility baseline")
        static["maximum_GLIBC"] = ".".join(map(str, maximum))
        static["model_free_startup_help_pass"] = True
    dependencies = dependency_provenance(src)
    tools = {}
    tools["producer"] = {"script_sha256": digest(Path(__file__).resolve()),
        "launcher_sha256": digest(Path(__file__).resolve().with_name("launch-server-build.sh"))}
    for name, tool in (("gn", gn), ("siso", siso)):
        tools[name] = {"sha256": digest(tool), "version": run([str(tool), "--version"], current_job / (name + "-version.txt"), timeout=30).strip()}
    compile_commands = json.loads((out / "compile_commands.json").read_text())
    own_command = next((item for item in compile_commands if Path(item["file"]).name == "vision_inference.cpp"), None)
    if not own_command:
        fail("Own runtime compiler command was not exported")
    compiler_words = own_command.get("arguments") or shlex.split(own_command["command"])
    compiler = Path(compiler_words[0])
    if not compiler.is_absolute():
        compiler = Path(own_command["directory"]) / compiler
    compiler = compiler.resolve()
    regular(compiler)
    tools["compiler"] = {"sha256": digest(compiler), "version": run([str(compiler), "--version"], current_job / "compiler-version.txt", timeout=30).strip()}
    artifact_files = {str(path.relative_to(artifact_root)): {"bytes": path.stat().st_size, "sha256": digest(path)}
        for path in artifact_root.rglob("*") if path.is_file()}
    record = {"schema": 1, "status": "BUILT_STATIC_CHECKS_PASS_RELEASE_REVIEW_REQUIRED",
        "utc": utc(), "platform": args.platform, "abi": abi, "payload_id": manifest["payload_id"],
        "inference_profile": profile, "inference_backend": inference_backend(profile), "inference_threads": 1,
        "reachable_gn_targets": sorted(labels),
        "source_files": manifest["files"], "dependency_provenance": dependencies, "reachable_source_files_sha256": source_snapshot,
        "build_tools": tools, "cached_args_sha256": digest(cached / "args.gn"),
        "generated_args_sha256": digest(out / "args.gn"), "compile": compile_proof, "static_artifact": static,
        **({"jni_export_config": jni_exports} if jni_exports else {}),
        "licenses": licenses, "resources": limits, "artifact_files": artifact_files,
        "compiler_log_sha256": digest(current_job / "compile.log"), "full_webrtc_sdk_build": False,
        "device_call_gpu_model_acceptance_tested": False, "publishing_performed": False}
    write_json(current_job / "build-manifest.json", record)
    write_json(artifact_root / "runtime-manifest.json", record)
    checksums = [f"{digest(path)}  {path.relative_to(artifact_root)}" for path in sorted(artifact_root.rglob("*")) if path.is_file()]
    (artifact_root / "SHA256SUMS").write_text("\n".join(checksums) + "\n")
    print(f"Isolated{suffix} artifact built; release/runtime review still required: {current_job}")


def build_one(args: argparse.Namespace, abi: str | None) -> None:
    # The producer runs on Linux even for Windows cross builds. Kernel flock is
    # released on cancellation/death, unlike a stale PID lock file.
    import fcntl
    src = args.src.resolve()
    out = (args.out / abi if args.platform == "android" else args.out).resolve()
    cached = (args.cached_out / abi if args.platform == "android" else args.cached_out).resolve()
    if out == cached or cached in out.parents or src / "out" not in out.parents:
        fail("Output lock must never be created inside the shipping cache")
    out.mkdir(parents=True, exist_ok=True)
    with (out / ".vision-runtime-build.lock").open("a", encoding="utf-8") as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            fail("This isolated output already has a running producer")
        build_one_locked(args, abi)


def build(args: argparse.Namespace) -> None:
    job = args.job.resolve()
    job.mkdir(parents=True, exist_ok=True, mode=0o700)
    # One durable attempt per evidence directory; never overwrite an earlier
    # successful/failed run or race a second producer against the same receipt.
    claim = job / "attempt.claim"
    with claim.open("x", encoding="utf-8") as stream:
        stream.write(f"pid={os.getpid()} utc={utc()}\n")
    write_json(job / "status.json", {"status": "RUNNING", "utc": utc(), "platform": args.platform})
    try:
        abis = list(ABIS) if args.platform == "android" and args.abi == "all" else [args.abi if args.platform == "android" else None]
        if args.platform == "android" and any(abi not in ABIS for abi in abis):
            fail("Android ABI must be explicit or all")
        for abi in abis:
            build_one(args, abi)
    except BaseException as error:
        write_json(job / "status.json", {"status": "FAILED", "utc": utc(), "reason": str(error), "platform": args.platform})
        raise
    write_json(job / "status.json", {"status": "BUILT_RELEASE_REVIEW_REQUIRED", "utc": utc(), "platform": args.platform})


def verify_artifact(root: Path, payload: dict, platform: str) -> dict:
    root = root.resolve()
    record = json.loads(regular(root / "runtime-manifest.json").read_text())
    if (record.get("schema") != 1 or record.get("platform") != platform or
        record.get("status") != "BUILT_STATIC_CHECKS_PASS_RELEASE_REVIEW_REQUIRED" or
        record.get("payload_id") != payload["payload_id"] or record.get("source_files") != payload["files"] or
        record.get("full_webrtc_sdk_build") is not False):
        fail("Artifact build manifest is not for the exact frozen isolated sources/platform")
    profile = inference_profile(platform, record.get("abi"))
    backend = inference_backend(profile)
    if (record.get("inference_profile") != profile or record.get("inference_backend") != backend or
            type(record.get("inference_threads")) is not int or record["inference_threads"] != 1):
        fail("Artifact inference profile/backend/one-thread policy differs from its exact platform/ABI")
    compile_proof = record.get("compile", {})
    if (not isinstance(compile_proof, dict) or compile_proof.get("inference_profile") != profile or compile_proof.get("inference_backend") != backend or
            type(compile_proof.get("inference_threads")) is not int or compile_proof["inference_threads"] != 1 or
            compile_proof.get("abi") != record.get("abi") or
            (platform == "android" and compile_proof.get("android_api") != 23)):
        fail("Artifact inference profile has no matching actual compiler proof")
    targets = record.get("reachable_gn_targets")
    if (not isinstance(targets, list) or not targets or len(targets) > 10000 or
            any(not isinstance(label, str) or not re.fullmatch(r"//[A-Za-z0-9_./-]*:[A-Za-z0-9_.+\-]+", label) for label in targets) or
            len(set(targets)) != len(targets)):
        fail("Artifact has no bounded exact reachable GN labels")
    graph_gate("\n".join(targets), platform, record.get("abi"))
    if platform == "android":
        target = "//modules/dinox_vision_runtime_" + payload["payload_id"][:16] + ":dinox_vision_inference"
        verify_jni_export_proof(record.get("jni_export_config"), record.get("reachable_source_files_sha256", {}), target)
        jni = record.get("static_artifact", {}).get("jni", {})
        if jni.get("defined_global_default_symbols") != JNI_SYMBOLS or not re.fullmatch(r"[a-f0-9]{64}", jni.get("symbol_log_sha256", "")):
            fail("Android artifact has no producer proof of the exact four defined public JNI entrypoints")
    provenance = json.loads(regular(root / "source-provenance.json").read_text())
    if any(provenance.get(key) != payload[key] for key in ("payload_id", "files", "pins", "mediapipe_custom_op_revision")):
        fail("Artifact source provenance differs from frozen payload")
    dependencies = record.get("dependency_provenance", {})
    if any(dependencies.get(name, {}).get("head") != expected for name, (_, expected) in PINS.items()):
        fail("Artifact dependency pins differ")
    if not re.fullmatch(r"[a-f0-9]{40}", dependencies.get("boringssl", {}).get("head", "")):
        fail("Artifact has no fixed-DEPS BoringSSL provenance")
    files = record.get("artifact_files")
    if not isinstance(files, dict) or not files or len(files) > 1024:
        fail("Missing/bounded artifact file manifest")
    actual = set()
    total = 0
    for file in root.rglob("*"):
        if file.is_symlink():
            fail("Artifact packaging rejects symlinks")
        if file.is_file():
            actual.add(str(file.relative_to(root)))
            total += file.stat().st_size
    if total > 384 * 1024 * 1024 or actual != set(files) | {"runtime-manifest.json", "SHA256SUMS"}:
        fail("Artifact directory contains unlisted files or exceeds384MiB")
    for name, item in files.items():
        relative = Path(name)
        if relative.is_absolute() or ".." in relative.parts:
            fail("Unsafe artifact manifest path")
        checked_file(root / relative, item["sha256"], item["bytes"])
    for name, (size, sha, _) in MODELS.items():
        checked_file(root / "models/video-vision" / name, sha, size)
    checked_file(root / "licenses/MODEL_AND_CUSTOM_OP_LICENSE", OP_FILES["LICENSE"])
    inventory = record.get("licenses", {}).get("gn_source_components")
    if not isinstance(inventory, list) or not inventory:
        fail("Artifact is missing transitive GN source license evidence")
    source_hashes = record.get("reachable_source_files_sha256")
    required_roots = required_license_roots(source_hashes, platform, record.get("abi"))
    covered_roots = set()
    attributed_originals = set()
    attributed_bundles = set()
    for item in inventory:
        if not isinstance(item, dict):
            fail("Malformed original license attribution")
        source_path = item.get("source_path", "")
        source_root = dependency_source_root(source_path)
        component = item.get("component")
        if not source_root or source_root not in required_roots or component != Path(source_root).name:
            fail("License component differs from the actual reachable original source root")
        if item.get("source_root", source_root) != source_root:
            fail("License source_root differs from its original source_path")
        relative = Path(item["bundle_path"])
        if (relative.is_absolute() or ".." in relative.parts or str(relative) != item["bundle_path"] or
            len(relative.parts) != 3 or relative.parts[:2] != ("dependencies", component) or
            not re.fullmatch(r"[0-9]+-" + re.escape(Path(source_path).name), relative.name)):
            fail("Bundled license path does not match the attributed original component/filename")
        sha = item.get("license_sha256")
        if (not isinstance(sha, str) or not re.fullmatch(r"[a-f0-9]{64}", sha) or source_hashes.get(source_path) != sha or
            item.get("original_git_blob_sha256", sha) != sha):
            fail("Bundled license text SHA differs from the immutable original source SHA")
        if source_path in attributed_originals or str(relative) in attributed_bundles:
            fail("Duplicate original/bundled license attribution")
        attributed_originals.add(source_path)
        attributed_bundles.add(str(relative))
        original = regular(root / "licenses" / relative)
        if not 0 < original.stat().st_size <= 4 * 1024 * 1024:
            fail("Bundled original license text is empty or exceeds4MiB")
        checked_file(original, sha)
        original.read_bytes().decode("utf-8")
        covered_roots.add(source_root)
    if required_roots - covered_roots:
        fail("Artifact omitted reachable original license roots: " + ",".join(sorted(required_roots - covered_roots)))
    return record


def deterministic_zip(root: Path, destination: Path) -> None:
    # No host paths, timestamps, uid/gid or model/pixel contents enter logs.
    with zipfile.ZipFile(destination, "x", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for file in sorted(root.rglob("*")):
            if not file.is_file():
                continue
            info = zipfile.ZipInfo(str(file.relative_to(root)), (1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = ((0o100755 if os.access(file, os.X_OK) else 0o100644) << 16)
            with file.open("rb") as source, archive.open(info, "w") as target:
                shutil.copyfileobj(source, target, length=1024 * 1024)


def android_license_assets(stage: Path, license_root: Path, payload: dict, dependencies: dict) -> None:
    assets = stage / "assets/vision"
    assets.mkdir(parents=True, exist_ok=True)
    shutil.copytree(license_root, assets / "LICENSES")
    paragraphs = ["# DinoX vision runtime: original licenses and pinned sources\n",
        "These texts are bundled in APK assets. No About-screen asset reader is implied.\n",
        "Original license files are also copied byte-for-byte under LICENSES/.\n",
        "## Pinned source revisions\n"]
    for name, (relative, revision) in sorted(PINS.items()):
        paragraphs.append(f"{name}: {revision} ({relative})\n")
    paragraphs.append(f"MediaPipe custom CPU operation: {MEDIAPIPE}\n")
    paragraphs.append("Payload SHA256 identity: " + payload["payload_id"] + "\n")
    paragraphs.append("## Actual dependency revisions and source patch hashes\n")
    paragraphs.append(json.dumps(dependencies, sort_keys=True, indent=2) + "\n")
    paragraphs.append("## Model source and integrity pins\n")
    for name, metadata in sorted(payload["models"].items()):
        paragraphs.append(f"{name}\nSource: {metadata['url']}\nLicense: {metadata['license']}\n"
            f"SHA256: {metadata['sha256']}\nBytes: {metadata['bytes']}\n")
    paragraphs.append("## Complete original license texts\n")
    for file in sorted(license_root.rglob("*")):
        if not file.is_file():
            continue
        relative = file.relative_to(license_root)
        # Preserve original bytes in LICENSES; refuse non-text inputs rather
        # than silently substituting broken characters in the combined notice.
        original = file.read_bytes().decode("utf-8")
        paragraphs.append(f"===== BEGIN ORIGINAL LICENSE: {relative} (SHA256 {digest(file)}) =====\n"
            + original + f"\n===== END ORIGINAL LICENSE: {relative} =====\n")
    (assets / "THIRD_PARTY_NOTICES.md").write_text("\n".join(paragraphs), encoding="utf-8")


def package(args: argparse.Namespace) -> None:
    payload = verify_payload(args.payload.resolve())
    artifacts = [(path.resolve(), verify_artifact(path, payload, args.platform)) for path in args.artifact]
    if args.platform == "android":
        abis = [record.get("abi") for _, record in artifacts]
        if len(abis) != 4 or set(abis) != set(ABIS):
            fail("AAR requires exactly one matched artifact for each of the four ABIs")
        artifacts.sort(key=lambda item: item[1]["abi"])
    elif len(artifacts) != 1 or artifacts[0][1].get("abi") is not None:
        fail("Desktop package requires exactly one matched x64 artifact")
    # Dependencies may carry deliberate toolchain/platform patches. The four
    # Android ABI jobs must nevertheless use the same actual source patches.
    if any(record["dependency_provenance"] != artifacts[0][1]["dependency_provenance"] for _, record in artifacts[1:]):
        fail("Android ABI dependency sources/patches do not match")
    output = args.output.resolve()
    if output.exists():
        fail("Package output already exists; never replace a release attempt")
    output.mkdir(parents=True, mode=0o700)
    stage = output / "runtime-staging"
    stage.mkdir()
    try:
        native_checks = {}
        for root, record in artifacts:
            abi = record.get("abi")
            name = "libdinox_vision_inference.so" if abi else "dinox-vision-worker" + (".exe" if args.platform == "windows" else "")
            relative = Path("jni") / abi / name if abi else Path(name)
            native = regular(root / relative)
            if abi:
                proof = elf_gate(native, ABIS[abi][1], android_page_alignment(abi))
                proof["jni"] = jni_symbol_gate(native, output / "checks" / (abi + "-symbols.txt"), args.readelf)
            elif args.platform == "windows":
                proof = pe_gate(native)
            else:
                proof = elf_gate(native, 62, None)
                if not record.get("static_artifact", {}).get("model_free_startup_help_pass") or not re.fullmatch(
                    r"[0-9]+(?:\.[0-9]+)*", record.get("static_artifact", {}).get("maximum_GLIBC", "")):
                    fail("Linux worker has no producer startup/GLIBC proof")
                if tuple(map(int, record["static_artifact"]["maximum_GLIBC"].split("."))) > (2, 35):
                    fail("Linux producer GLIBC proof exceeds baseline")
            native_checks[abi or args.platform + "-x64"] = proof
            destination = stage / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(native, destination)
            destination.chmod(0o755)
        first = artifacts[0][0]
        license_root = stage / ("META-INF/licenses/dinox-vision" if args.platform == "android" else "dinox-vision-licenses")
        for root, _ in artifacts:
            for file in sorted((root / "licenses").rglob("*")):
                if not file.is_file():
                    continue
                destination = license_root / file.relative_to(root / "licenses")
                if destination.exists():
                    if digest(destination) != digest(file):
                        fail("Matched ABI license texts differ for the same package path")
                else:
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(file, destination)
        for name in MODELS:
            # Desktop's current installed_vision_paths() uses underscores;
            # Java's pinned Face asset deliberately uses hyphens.
            installed = name if args.platform == "android" else name.replace("blaze-face-short-range", "blaze_face_short_range")
            destination = stage / ("assets/video-vision" if args.platform == "android" else "dinox-vision-models") / installed
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(first / "models/video-vision" / name, destination)
        if args.platform == "android":
            android_license_assets(stage, license_root, payload, artifacts[0][1]["dependency_provenance"])
            (stage / "AndroidManifest.xml").write_text('<manifest xmlns:android="http://schemas.android.com/apk/res/android" '
                'package="im.dinox.vision.runtime"><uses-sdk android:minSdkVersion="23"/></manifest>\n', encoding="utf-8")
            with zipfile.ZipFile(stage / "classes.jar", "x"):
                pass # JNI-only AAR: Bridge Java classes stay in the application.
            (stage / "R.txt").write_text("", encoding="utf-8")
        # Re-read source artifact manifests/hashes after copying to reject races.
        for root, record in artifacts:
            if verify_artifact(root, payload, args.platform) != record:
                fail("Artifact changed while assembling the package")
        staged = {str(file.relative_to(stage)): {"bytes": file.stat().st_size, "sha256": digest(file)}
            for file in sorted(stage.rglob("*")) if file.is_file()}
        manifest = {"schema": 1, "status": "PACKAGED_STATIC_CHECKS_PASS_RELEASE_REVIEW_REQUIRED", "platform": args.platform,
            "payload_id": payload["payload_id"], "pins": payload["pins"], "source_files": payload["files"],
            "mediapipe_custom_op_revision": MEDIAPIPE, "models": payload["models"], "files": staged,
            "build_manifests": [record for _, record in artifacts], "native_checks": native_checks,
            "inference_profiles": {record["abi"] or args.platform + "-x64": {
                "profile": record["inference_profile"], "backend": record["inference_backend"], "threads": record["inference_threads"]}
                for _, record in artifacts},
            "android_min_sdk": 23 if args.platform == "android" else None,
            "jni_bridge_in_application": args.platform == "android", "full_webrtc_sdk_build": False,
            "toolchain_system_runtime_license_review_required": True, "device_call_gpu_model_acceptance_tested": False,
            "publishing_performed": False}
        manifest_relative = "META-INF/dinox/vision-runtime-manifest.json" if args.platform == "android" else "dinox-vision-runtime-manifest.json"
        write_json(stage / manifest_relative, manifest)
        checksum_relative = "META-INF/dinox/SHA256SUMS" if args.platform == "android" else "dinox-vision-SHA256SUMS"
        sums = [f"{digest(file)}  {file.relative_to(stage)}" for file in sorted(stage.rglob("*")) if file.is_file()]
        (stage / checksum_relative).write_text("\n".join(sums) + "\n")
        filename = "dinox-vision-runtime.aar" if args.platform == "android" else "dinox-vision-runtime-" + args.platform + "-x64.zip"
        deterministic_zip(stage, output / filename)
        write_json(output / "package-manifest.json", {"schema": 1, "status": manifest["status"],
            "payload_id": payload["payload_id"], "platform": args.platform, "archive": filename,
            "archive_bytes": (output / filename).stat().st_size, "archive_sha256": digest(output / filename),
            "runtime_manifest_path": "runtime-staging/" + manifest_relative,
            "runtime_manifest_sha256": digest(stage / manifest_relative), "publishing_performed": False})
        (output / "SHA256SUMS").write_text(f"{digest(output / filename)}  {filename}\n"
            f"{digest(output / 'package-manifest.json')}  package-manifest.json\n")
    except BaseException:
        write_json(output / "package-failure.json", {"status": "FAILED", "utc": utc()})
        raise
    print(f"Matched package and staging ready, release review required: {output / filename}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    prepare = actions.add_parser("pack", help="Freeze existing local cached files; never download/build")
    prepare.add_argument("--repo", type=Path, required=True)
    prepare.add_argument("--custom-op-root", type=Path, required=True)
    prepare.add_argument("--segment-model", type=Path, required=True)
    prepare.add_argument("--face-model", type=Path, required=True)
    prepare.add_argument("--model-license", type=Path, required=True)
    prepare.add_argument("--project-license", type=Path)
    prepare.add_argument("--output", type=Path, required=True)
    producer = actions.add_parser("build", help="Server-only bounded isolated target; use systemd launcher")
    producer.add_argument("--payload", type=Path, required=True)
    producer.add_argument("--platform", choices=("linux", "windows", "android"), required=True)
    producer.add_argument("--abi", default="all")
    producer.add_argument("--src", type=Path, required=True)
    producer.add_argument("--cached-out", type=Path, required=True)
    producer.add_argument("--out", type=Path, required=True)
    producer.add_argument("--job", type=Path, required=True)
    producer.add_argument("--gn", type=Path)
    producer.add_argument("--siso", type=Path)
    producer.add_argument("--readelf", type=Path)
    bundle = actions.add_parser("package", help="Assemble matched existing producer artifacts; no build/download/publish")
    bundle.add_argument("--payload", type=Path, required=True)
    bundle.add_argument("--platform", choices=("linux", "windows", "android"), required=True)
    bundle.add_argument("--artifact", type=Path, action="append", required=True,
        help="Artifact directory with runtime-manifest.json; exactly four different ABI directories for Android")
    bundle.add_argument("--output", type=Path, required=True)
    bundle.add_argument("--readelf", type=Path)
    args = parser.parse_args()
    try:
        {"pack": pack, "build": build, "package": package}[args.action](args)
    except (RuntimeError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print("VISION_RUNTIME_FAILED: " + str(error), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
