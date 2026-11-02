# Windows call codec sources

The portable application includes license texts and the exact Media Foundation
patch alongside this file. The larger original source archives are available
separately at the following public URLs. Verify their SHA-256 before rebuilding.

| Source | SHA-256 |
| --- | --- |
| [M152 codec sources, including Chromium FFmpeg and OpenH264](https://git.dinox.im/dinoxim/dinox/releases/download/vendor-deps/webrtc-m152-codec-sources-6f37672d3584-sha256-2b17c14cc13b.tar.gz) | `2b17c14cc13b4b661c4a2be9b25c26240c97cec4a1c938196ed81dc9fd24278c` |
| [FFmpeg 8.1.2](https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz) | `464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c` |

`WEBRTC-CODECS.json`, `WEBRTC-GN-ARGS.gn` and `manifest.json` identify the exact
WebRTC revision, codec configuration and DinoX wrapper source commit.
`FFMPEG-WINDOWS-HARDWARE.json` records the separate hardware provider's source,
configuration and patch hashes. Its exact patch is included as
`sources/ffmpeg-mf-dynamic-bitrate.patch`.

The hardware provider is dynamically linked and uses the separate filenames
`avcodec-dinox-hw-62.dll` and `avutil-dinox-hw-60.dll`. Its build recipe is
`scripts/build-libwebrtc-windows-codec-dependency.sh` in the DinoX source tree;
use the wrapper source revision recorded in `manifest.json`. The runtime vendor
artifact contains these original sources as well as the patch and build
metadata. `FFMPEG-LICENSE` covers this provider; `LICENSE.md` contains the
separate notices for the codecs built into WebRTC.
