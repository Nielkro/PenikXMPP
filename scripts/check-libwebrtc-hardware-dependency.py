#!/usr/bin/env python3
"""Validate the private hardware codec dependency, including its actual files."""

import argparse
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path

FFMPEG_SHA256 = "464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c"
LIBVA_SHA256 = "117f8d658a5fc9ea406ca80a3eb4ae1d70b15a54807c9ed77199c812bed73b60"
NVCODEC_SHA256 = "1e1600606cde2c04f5b1a71cb3b2e966b3ffe4e252a6ddec5781151d982e259f"
ELF_PATCH_SHA256 = "e3630fac46c8459340de0b1eb58916f1f3dada03899bded00bca332486375903"
MF_PATCH_SHA256 = "e16236715ae685d9adbabad511aa9c48f96037865d13d9ae0fbc49c3bdcf7672"


def digest(path):
    sha = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            sha.update(chunk)
    return sha.hexdigest()


def validate(root, manifest_name, platform):
    data = json.loads((root / manifest_name).read_text())
    expected = {
        "ffmpeg_version": "8.1.2", "license": "LGPL-2.1-or-later",
        "linkage": "dynamic-private", "source_sha256": FFMPEG_SHA256,
        "corresponding_source": "sources/ffmpeg-8.1.2.tar.xz",
    }
    sources = {"sources/ffmpeg-8.1.2.tar.xz": FFMPEG_SHA256}
    if platform == "linux":
        expected.update({
            "layout": "dinox-ffmpeg-hardware-codecs-v3", "codecs": ["VP8", "H264"],
            "decoders": ["vp8", "h264"], "encoders": ["h264_vaapi", "h264_nvenc"],
            "hwaccels": ["vp8_vaapi", "h264_vaapi", "h264_nvdec"], "parsers": ["h264"],
            "hardware_apis": ["VA-API", "CUDA"], "libva_header_version": "2.20.0",
            "libva_source_sha256": LIBVA_SHA256,
            "libva_corresponding_source": "sources/libva-2.20.0.tar.gz",
            "nvcodec_header_version": "8.1.24.15", "nvcodec_source_sha256": NVCODEC_SHA256,
            "nvcodec_corresponding_source": "sources/nv-codec-headers-n8.1.24.15.tar.gz",
            "patch": "sources/ffmpeg-dinox-symbol-versions.patch", "patch_sha256": ELF_PATCH_SHA256,
            "elf_symbol_versions": ["DINOX_HW_LIBAVCODEC_62", "DINOX_HW_LIBAVUTIL_60"],
        })
        sources.update({"sources/ffmpeg-dinox-symbol-versions.patch": ELF_PATCH_SHA256,
                        "sources/libva-2.20.0.tar.gz": LIBVA_SHA256,
                        "sources/nv-codec-headers-n8.1.24.15.tar.gz": NVCODEC_SHA256})
        libraries = ["libavcodec-dinox-hw.so.62", "libavutil-dinox-hw.so.60"]
        library_dir = "lib"
        if not (root / "NVIDIA-CODEC-HEADERS-LICENSE").read_text().strip():
            raise ValueError("Missing nv-codec-headers notices")
    else:
        expected.update({
            "layout": "dinox-ffmpeg-windows-hardware-v1", "target_os": "win", "target_cpu": "x64",
            "hardware_apis": ["Media Foundation", "D3D11VA"], "codecs": ["H264"],
            "encoders": ["h264_mf"], "decoders": ["h264"], "hwaccels": ["h264_d3d11va", "h264_d3d11va2"],
            "encoder_requires_hw_encoding": True, "dynamic_bitrate": True,
            "patch": "sources/ffmpeg-mf-dynamic-bitrate.patch", "patch_sha256": MF_PATCH_SHA256,
        })
        sources["sources/ffmpeg-mf-dynamic-bitrate.patch"] = MF_PATCH_SHA256
        libraries = ["avcodec-dinox-hw-62.dll", "avutil-dinox-hw-60.dll"]
        library_dir = "bin"
    for key, expected_value in expected.items():
        if data.get(key) != expected_value:
            raise ValueError(f"Hardware codec dependency {key} does not match the required recipe")
    for relative, expected_hash in sources.items():
        if digest(root / relative) != expected_hash:
            raise ValueError("Corresponding source checksum mismatch: " + relative)
    hashes = data.get("libraries", {})
    if set(hashes) != set(libraries):
        raise ValueError("Hardware codec dependency library inventory mismatch")
    if platform == "windows" and shutil.which("objdump") is None:
        raise ValueError("objdump is required to validate the private Windows DLL dependency closure")
    if platform == "linux" and shutil.which("readelf") is None:
        raise ValueError("readelf is required to validate the private Linux SONAMEs")
    for name in libraries:
        if digest(root / library_dir / name) != hashes[name]:
            raise ValueError("Hardware codec dependency binary checksum mismatch: " + name)
        binary = root / library_dir / name
        if platform == "linux":
            dynamic = subprocess.check_output(["readelf", "-d", str(binary)], text=True)
            if not re.search(r"\(SONAME\).*\[" + re.escape(name) + r"\]", dynamic):
                raise ValueError("Private Linux library has an incorrect SONAME: " + name)
            versions = subprocess.check_output(["readelf", "--version-info", str(binary)], text=True)
            required_versions = ["DINOX_HW_LIBAVUTIL_60"]
            if "avcodec" in name:
                required_versions.append("DINOX_HW_LIBAVCODEC_62")
            if any(version not in versions for version in required_versions):
                raise ValueError("Missing private FFmpeg ELF symbol namespace: " + name)
            if re.search(r"(?<!DINOX_HW_)LIBAV(?:CODEC|UTIL)_[0-9]+", versions):
                raise ValueError("Private FFmpeg library refers to the public ELF symbol namespace")
            if re.search(r"\(NEEDED\).*\[libav(?:codec|util)\.so\.", dynamic):
                raise ValueError("Private Linux library imports a conflicting public FFmpeg SONAME")
        else:
            # Keep the native MinGW tool's argv relative; the Windows cwd API
            # accepts the Unicode parent directory without an ANSI conversion.
            report = subprocess.check_output(
                ["objdump", "-p", binary.name], cwd=binary.parent, text=True
            )
            allowed = {"avcodec-dinox-hw-62.dll", "avutil-dinox-hw-60.dll", "kernel32.dll", "msvcrt.dll",
                       "ucrtbase.dll", "ole32.dll", "oleaut32.dll", "user32.dll", "advapi32.dll",
                       "mfplat.dll", "mf.dll", "mfuuid.dll", "mfreadwrite.dll", "propsys.dll",
                       "d3d11.dll", "dxgi.dll", "dxva2.dll", "bcrypt.dll", "secur32.dll",
                       "ws2_32.dll", "shlwapi.dll", "shell32.dll", "gdi32.dll"}
            if "file format pei-x86-64" not in report:
                raise ValueError("Private Windows codec is not an x64 PE image: " + name)
            imports = re.findall(r"DLL Name:\s+(\S+)", report)
            if not imports:
                raise ValueError("Missing Windows DLL import table: " + name)
            for imported in imports:
                if imported.lower() not in allowed and not imported.lower().startswith("api-ms-win-"):
                    raise ValueError("Unshipped non-system Windows DLL dependency: " + imported)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--manifest", default="manifest.json")
    parser.add_argument("--platform", choices=["linux", "windows"], required=True)
    args = parser.parse_args()
    validate(args.root, args.manifest, args.platform)
