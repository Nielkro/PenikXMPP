#!/usr/bin/env python3
"""Run upstream's dependency license audit with the M152 codec license maps."""

import argparse
import importlib.util
from pathlib import Path
import subprocess
import sys


EXTRA_LICENSES = {
    "ffmpeg": ["third_party/ffmpeg/CREDITS.chromium",
               "third_party/ffmpeg/COPYING.LGPLv2.1"],
    "openh264": ["third_party/openh264/src/LICENSE"],
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--target", action="append", required=True)
    parser.add_argument("--root-target", help="Use the same GN root as the isolated runtime build")
    parser.add_argument("output", type=Path)
    parser.add_argument("build_directory", type=Path)
    options = parser.parse_args()
    path = options.source.resolve() / "tools_webrtc/libs/generate_licenses.py"
    spec = importlib.util.spec_from_file_location("upstream_webrtc_licenses", path)
    upstream = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(upstream)
    if options.root_target:
        # GN desc reconstructs its graph. Without the isolated root it silently
        # omits the DinoX runtime target even when gn gen built it successfully.
        def run_gn(build_directory, target):
            command = [sys.executable,
                       str(Path(upstream.find_depot_tools.DEPOT_TOOLS_PATH) / "gn.py"),
                       "desc", "--all", "--format=json",
                       "--root-target=" + options.root_target,
                       str(Path(build_directory).resolve()), target]
            result = subprocess.run(command, cwd=options.source.resolve(), text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if result.returncode:
                raise RuntimeError("GN license inventory failed:\n" + result.stdout + result.stderr)
            return result.stdout
        upstream.LicenseBuilder._run_gn = staticmethod(run_gn)
    mapping = upstream.LIB_TO_LICENSES_DICT.copy()
    for name, filenames in EXTRA_LICENSES.items():
        if name in mapping and mapping[name] != filenames:
            raise RuntimeError(f"Upstream license mapping changed for {name}")
        for filename in filenames:
            if not (options.source / filename).is_file():
                raise RuntimeError(f"Required license is missing: {filename}")
        mapping[name] = filenames
    # Unknown dependencies still fail in LicenseBuilder. Do not suppress its
    # audit or modify the pinned upstream generator in the shared checkout.
    upstream.LicenseBuilder(
        [str(options.build_directory.resolve())], options.target,
        lib_to_licenses_dict=mapping,
    ).generate_license_text(str(options.output.resolve()))
    license_file = options.output / "LICENSE.md"
    if not license_file.is_file() or not license_file.stat().st_size:
        raise RuntimeError("Upstream generator produced no license document")


if __name__ == "__main__":
    main()
