# Building DinoX on Windows

[Deutsche Anleitung](WINDOWS_BUILD.md)

This guide produces a `dist` folder containing `dinox.exe` and the files it
needs. You can then create a ZIP to share the complete program.

## Start here

| What do you want to do? | Steps to follow |
|---|---|
| Build on this Windows computer for the first time | [1](#1-set-up-msys2-once) and [2](#2-install-the-build-tools-once), then [3](#3-get-the-source-and-choose-a-version) through [7](#7-test-dinox-on-windows). |
| Rebuild the latest `master` | [3A](#3a-rebuild-the-current-master), then [4](#4-prepare-the-dependencies) through [7](#7-test-dinox-on-windows). Add step [8](#8-create-the-zip-and-checksum) if you want a ZIP. |
| Build the Windows package for a particular release, such as `v2.3.3` | [3B](#3b-build-a-particular-release-version), then [4](#4-prepare-the-dependencies) through [8](#8-create-the-zip-and-checksum). Add step [9](#9-upload-the-windows-package-to-an-existing-release) to upload it. |
| Prepare a completely new version as a project maintainer | [Section 10](#10-publish-a-new-version-as-a-project-maintainer). This also requires the Linux build computer. |

**A normal Windows rebuild needs no Linux commands.** Step 3 selects either
`master` or a release version. From step 4 onwards, both use the same procedure.

Open **MSYS2 MINGW64** from the Windows Start menu as your normal user. All
commands in steps 1 through 9 belong in that window, not PowerShell, Command
Prompt, MSYS or UCRT64.

Copy each complete command block, including its parentheses. Wait for it to
finish before running the next block. Stop on an error and keep the log.
The parentheses let an error stop the block without closing your terminal.

The examples use `$HOME/dinox`. MINGW64 replaces `$HOME` with your user folder;
you do not need to substitute your user name. Each build block changes to the
correct folder itself. If you deliberately keep DinoX elsewhere, replace
`$HOME/dinox` with that path. Keep the quotation marks around paths with spaces.

## 1. Set up MSYS2 once

You need Windows 10 version 1903 or later, or Windows 11, on 64-bit Intel/AMD.
Install [MSYS2](https://www.msys2.org/) in `C:\msys64`. Downloads and building
require internet access and enough free disk space.

On a **new installation**, run this in MSYS2 MINGW64:

```bash
pacman -Syu
```

If MSYS2 asks you to close the window, close it, reopen MINGW64 and repeat
the command.

If this computer already builds DinoX successfully, start a rebuild at step 3.
The configured official release VM keeps its tested MSYS2 and compiler versions;
updates are checked in a separate test VM first.

## 2. Install the build tools once

This is part of the initial setup. Copy the entire package list into MINGW64:

```bash
pacman -S --needed --noconfirm \
  git curl tar unzip base-devel \
  mingw-w64-x86_64-toolchain mingw-w64-x86_64-vala \
  mingw-w64-x86_64-meson mingw-w64-x86_64-ninja \
  mingw-w64-x86_64-pkgconf mingw-w64-x86_64-cmake \
  mingw-w64-x86_64-python mingw-w64-x86_64-gtk4 \
  mingw-w64-x86_64-python-dnspython mingw-w64-x86_64-python-cryptography \
  mingw-w64-x86_64-python-h2 \
  mingw-w64-x86_64-libadwaita mingw-w64-x86_64-glib2 \
  mingw-w64-x86_64-glib-networking mingw-w64-x86_64-gdk-pixbuf2 \
  mingw-w64-x86_64-libgee mingw-w64-x86_64-libsoup3 \
  mingw-w64-x86_64-json-glib mingw-w64-x86_64-sqlcipher \
  mingw-w64-x86_64-icu mingw-w64-x86_64-libgcrypt \
  mingw-w64-x86_64-gnupg mingw-w64-x86_64-gpgme \
  mingw-w64-x86_64-pinentry \
  mingw-w64-x86_64-gnutls mingw-w64-x86_64-qrencode \
  mingw-w64-x86_64-libsecret mingw-w64-x86_64-libyaml \
  mingw-w64-x86_64-libsrtp mingw-w64-x86_64-libnice \
  mingw-w64-x86_64-gstreamer mingw-w64-x86_64-gst-plugins-base \
  mingw-w64-x86_64-gst-plugins-good mingw-w64-x86_64-gst-plugins-bad \
  mingw-w64-x86_64-gst-plugins-ugly mingw-w64-x86_64-gst-libav \
  mingw-w64-x86_64-opus mingw-w64-x86_64-openh264 \
  mingw-w64-x86_64-libvpx mingw-w64-x86_64-protobuf-c \
  mingw-w64-x86_64-openssl mingw-w64-x86_64-libarchive mingw-w64-x86_64-librsvg \
  mingw-w64-x86_64-hicolor-icon-theme \
  mingw-w64-x86_64-adwaita-icon-theme \
  mingw-w64-x86_64-cantarell-fonts mingw-w64-x86_64-mosquitto \
  mingw-w64-x86_64-unbound \
  mingw-w64-x86_64-go
```

The DinoX script in step 4 downloads the additional library versions required
by the selected source version.

## 3. Get the source and choose a version

Close a running DinoX test build before rebuilding it.

If the source is not already in `$HOME/dinox`, run this block first. It downloads
the source. If the folder exists, it only checks it and displays its Windows path:

```bash
(
  set -euo pipefail
  if [[ ! -e "$HOME/dinox" ]]; then
    git clone https://git.dinox.im/dinoxim/dinox.git "$HOME/dinox"
  fi
  cd "$HOME/dinox" || { echo 'ERROR: DinoX source folder not found. Complete step 3 first.' >&2; exit 1; }
  if [[ ! -e .git || ! -f scripts/build-windows-dist.sh ]]; then
    echo 'ERROR: This folder does not contain the DinoX source. Check the folder.' >&2
    exit 1
  fi
  cygpath -w "$PWD"
)
```

Choose **A or B**, not both. For later rebuilds, you can start directly with
the appropriate block.

### 3A. Rebuild the current master

`master` is the current development version. This block downloads changes and
selects that version. It does not delete your own changes; if any are present,
it stops and explains why.

```bash
(
  set -euo pipefail
  cd "$HOME/dinox" || { echo 'ERROR: DinoX source folder not found. Complete step 3 first.' >&2; exit 1; }
  if [[ ! -e .git || ! -f scripts/build-windows-dist.sh ]]; then
    echo 'ERROR: This folder does not contain the DinoX source. Check the folder.' >&2
    exit 1
  fi
  changes="$(git status --porcelain)"
  if [[ -n "$changes" ]]; then
    echo 'STOP: The source folder has local changes. Save or commit them first.' >&2
    git status --short
    exit 1
  fi
  git config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  git fetch --prune origin
  git switch master
  git branch --set-upstream-to=origin/master master
  git merge --ff-only origin/master
  if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/master)" ]]; then
    echo 'STOP: Local master has additional commits. Nothing was reset.' >&2
    exit 1
  fi
  echo 'Selected source version:'
  git log -1 --format='%h %s'
)
```

When “Selected source version” and a commit line appear, continue with step 4.
A commit is a saved source version. Its short identifier lets you see later
which version you built.

### 3B. Build a particular release version

A release tag such as `v2.3.3` identifies the fixed source for that version.
The tag can already exist while Forgejo is still building the Linux packages.
`git pull` does **not** select this tag automatically.

At the prompt, enter the version including `v`, such as `v2.3.3`, and press Enter:

```bash
(
  set -euo pipefail
  cd "$HOME/dinox" || { echo 'ERROR: DinoX source folder not found. Complete step 3 first.' >&2; exit 1; }
  if [[ ! -e .git || ! -f scripts/build-windows-dist.sh ]]; then
    echo 'ERROR: This folder does not contain the DinoX source. Check the folder.' >&2
    exit 1
  fi
  changes="$(git status --porcelain)"
  if [[ -n "$changes" ]]; then
    echo 'STOP: The source folder has local changes. Save or commit them first.' >&2
    git status --short
    exit 1
  fi
  read -r -p 'Which release version? For example v2.3.3: ' release_tag
  if [[ ! "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo 'ERROR: Include the v in the version, for example v2.3.3.' >&2
    exit 1
  fi
  git fetch origin "refs/tags/$release_tag:refs/tags/$release_tag"
  git switch --detach "refs/tags/$release_tag"
  version="$(tr -d '[:space:]' < VERSION)"
  if [[ "v$version" != "$release_tag" ]]; then
    echo 'ERROR: The version file does not match the release tag.' >&2
    exit 1
  fi
  echo 'Selected source version:'
  git log -1 --format='%h %s'
)
```

Git's “detached HEAD” message is expected here: the source stays at the chosen
version. Continue with steps 4 through 8 and, if needed, 9.
**You do not need section 10 for this.**

Older releases can require different dependencies. Their technical requirements
are documented in the `WINDOWS_BUILD_EN.md` from that tag. The procedure here
applies to 2.3.3 and the current development version.

## 4. Prepare the dependencies

Run this after selecting or updating the source. The script downloads and
checks the required files, reusing existing downloads that still match.

```bash
(
  set -euo pipefail
  cd "$HOME/dinox" || { echo 'ERROR: DinoX source folder not found. Complete step 3 first.' >&2; exit 1; }
  if [[ ! -e .git || ! -f scripts/build-windows-dist.sh ]]; then
    echo 'ERROR: This folder does not contain the DinoX source. Check the folder.' >&2
    exit 1
  fi
  mkdir -p "$HOME/dinox-build-logs"
  log_file="$(mktemp "$HOME/dinox-build-logs/prepare-$(date +%Y%m%d-%H%M%S)-XXXXXX.log")"
  printf 'Log file: %s\n' "$log_file"
  CMAKE_BUILD_PARALLEL_LEVEL=2 GOMAXPROCS=2 \
    bash scripts/prepare-windows-build-deps.sh 2>&1 | tee "$log_file"
)
```

Wait for the command prompt to return. If the command fails, stop before step 5.
Its output is also saved in the displayed `prepare-…log` under
`$HOME/dinox-build-logs`. Downloaded libraries are stored in `$HOME/vendor-deps`.

## 5. Build DinoX from scratch

DinoX must be closed. The script removes the old `build` and `dist` folders,
compiles everything, runs the automated tests and creates the complete program
folder. You do not need to delete those folders manually.

```bash
(
  set -euo pipefail
  cd "$HOME/dinox" || { echo 'ERROR: DinoX source folder not found. Complete step 3 first.' >&2; exit 1; }
  if [[ ! -e .git || ! -f scripts/build-windows-dist.sh ]]; then
    echo 'ERROR: This folder does not contain the DinoX source. Check the folder.' >&2
    exit 1
  fi
  DINOX_BUILD_JOBS=2 bash scripts/build-windows-dist.sh
)
```

The build uses two concurrent compiler tasks to limit memory use. It can take
some time. While it runs, do not start another build, update the source or
switch versions in this folder.

Output stays visible in the terminal and is also saved in full. `BUILD_LOG=…`
shows the log path at the beginning and end. The build has succeeded only when
it ends with **`WINDOWS_BUILD_EXIT_CODE=0`**. Investigate any other result in
the log before continuing.

The default build profile is called `release`, meaning the code is optimized
for use. This does not assign a new version or upload anything to Forgejo.

## 6. Find the program and logs

Open the completed program folder in Windows Explorer:

```bash
explorer.exe "$(cygpath -w "$HOME/dinox/dist")"
```

It contains `dinox.exe`. **The whole folder belongs to the program**, not just
the executable. Running this completed folder does not require MSYS2.

Open the log folder with:

```bash
explorer.exe "$(cygpath -w "$HOME/dinox-build-logs")"
```

- `prepare-…log`: preparation and downloads from step 4.
- `compile-…log`: the complete build and tests from step 5.
- `compile-….warnings.txt`: compiler warnings from that entire build.
- `package-…log`: ZIP creation from step 8.

If you set `DINOX_WINDOWS_LOG_DIR`, the build log is stored there instead.
The `BUILD_LOG=…` output always gives the actual path. Logs survive the next
clean build. `build_log.txt` in the source folder contains only part of the
build and does not replace the full `compile-…log`.

At the end, `WINDOWS_COMPILER_WARNING_COUNT=…` counts compiler warnings across
all build steps. `BUILD_WARNINGS=…` points to the separate warning list. This
summary also appears when a build fails. An earlier “Warnings in this
invocation: 0” message covers only that invocation, not the preceding steps.

## 7. Test DinoX on Windows

Double-click `dinox.exe` in Explorer. This tests the completed package without
MINGW64 supplying missing files from its installation.

Before sharing it, check that:

1. DinoX starts without a missing-DLL message; windows, text, icons and emoji appear.
2. An account connects and chats open.
3. Settings, microphone, speakers and camera work. Also test a call and voice/video messages.
4. The icon in the notification area beside the clock opens and hides DinoX. Notifications open the correct chat, and disabled notification sounds stay silent.
5. Menus and icons are readable in light, dark and high-contrast themes at your display scaling.
6. DinoX exits completely.

For publication, also test the functions changed since the previous release.
Starting the whole `dist` folder on a Windows computer without MSYS2 provides
an additional check that all required files are included. Keep the build log
and a short record of your manual tests.

If you only want to use DinoX yourself, you are finished. To share a ZIP,
continue with step 8.

## 8. Create the ZIP and checksum

Exit DinoX after testing. Do not run `git pull` or switch source versions
between building and packaging. The ZIP script packages the folder you have
**already built and tested**; it does not compile a new program.

```bash
(
  set -euo pipefail
  cd "$HOME/dinox" || { echo 'ERROR: DinoX source folder not found. Complete step 3 first.' >&2; exit 1; }
  if [[ ! -e .git || ! -f scripts/build-windows-dist.sh ]]; then
    echo 'ERROR: This folder does not contain the DinoX source. Check the folder.' >&2
    exit 1
  fi
  changes="$(git status --porcelain)"
  if [[ -n "$changes" ]]; then
    echo 'STOP: The source folder has local changes. Save or commit them first.' >&2
    git status --short
    exit 1
  fi
  version="$(tr -d '[:space:]' < VERSION)"
  source_commit="$(git rev-parse HEAD)"
  output_dir="$HOME/dinox-packages/$version/$source_commit"
  mkdir -p "$HOME/dinox-build-logs"
  log_file="$(mktemp "$HOME/dinox-build-logs/package-$(date +%Y%m%d-%H%M%S)-XXXXXX.log")"
  printf 'Log file: %s\n' "$log_file"
  bash scripts/package-windows-dist.sh "$PWD/dist" "$output_dir" \
    2>&1 | tee "$log_file"
  cp dist/build-info.txt "$output_dir/build-info.txt"
  cd "$output_dir"
  sha256sum -c "DinoX-$version-windows-x86_64.zip.sha256"
  cygpath -w "$output_dir"
  explorer.exe "$(cygpath -w "$output_dir")"
)
```

The script rechecks the program and ZIP contents. Success produces
`WINDOWS_ZIP_READY=…`, `WINDOWS_ZIP_SHA256_READY=…` and a checksum result of
`OK`. It then opens the output folder.

For 2.3.3, that folder contains these two files:

```text
DinoX-2.3.3-windows-x86_64.zip
DinoX-2.3.3-windows-x86_64.zip.sha256
```

The version number comes from the source automatically. Packages are stored
under `$HOME/dinox-packages`, separated by version and commit identifier so
builds from different sources are kept apart. `build-info.txt` also records
which source produced the package.

The script requires unchanged source and a matching built program. A failed
check means there is no valid new ZIP. Old ZIP and checksum files with the
same names are removed before validation. The ZIP size limit is 512 MiB.
Do not rename the files or repack them with another program afterwards.

## 9. Upload the Windows package to an existing release

Use this section when the release tag is already fixed, for example `v2.3.3`.
You need write access to the Forgejo project. This is not required for your
own `master` test build.

First check in MINGW64 that the package came from the release source:

```bash
(
  set -euo pipefail
  cd "$HOME/dinox" || { echo 'ERROR: DinoX source folder not found. Complete step 3 first.' >&2; exit 1; }
  if [[ ! -e .git || ! -f scripts/build-windows-dist.sh ]]; then
    echo 'ERROR: This folder does not contain the DinoX source. Check the folder.' >&2
    exit 1
  fi
  changes="$(git status --porcelain)"
  if [[ -n "$changes" ]]; then
    echo 'STOP: The source folder has local changes. Save or commit them first.' >&2
    git status --short
    exit 1
  fi
  release_tag="v$(tr -d '[:space:]' < VERSION)"
  git fetch origin "refs/tags/$release_tag:refs/tags/$release_tag"
  source_commit="$(sed -n 's/^source_commit=//p' dist/build-info.txt)"
  if [[ "$(git rev-parse "refs/tags/$release_tag^{commit}")" != "$source_commit" ]]; then
    echo 'STOP: This Windows package was not built from the selected release tag.' >&2
    exit 1
  fi
  echo 'The Windows package matches the release tag.'
  printf '%s: %s\n' "$release_tag" "$source_commit"
)
```

After “The Windows package matches the release tag”, continue:

1. Wait for the Forgejo Linux build to finish and the release to be published.
2. Open [DinoX Releases](https://git.dinox.im/dinoxim/dinox/releases) in your browser and sign in.
3. Open the matching version and its edit page.
4. Attach the ZIP and its `.sha256` file from step 8, then save.
5. Download both files from the release page into a new, empty folder.

For the final check, return to MINGW64. This block asks for the Windows folder
containing the downloaded files. Enter the path without surrounding quotes;
spaces are supported:

```bash
(
  set -euo pipefail
  read -r -p 'Windows folder containing ZIP and checksum: ' download_dir
  cd "$(cygpath -u "$download_dir")"
  read -r -p 'Version without v, for example 2.3.3: ' version
  sha256sum -c "DinoX-$version-windows-x86_64.zip.sha256"
)
```

`OK` confirms the download. An error means the files do not match or are incomplete.

The release tag has already started the Linux build; uploading Windows files
needs no additional Forgejo build. Do not publish an unfinished release draft.
`forgejo-release.sh upload` is intended for drafts; after publication, add
Windows files through the browser's release editor.

For your next `master` rebuild, start at step 3A. Its block switches back from
the selected release to `master` automatically.

<a id="9-publish-a-new-official-release"></a>

## 10. Publish a new version as a project maintainer

Use this section only when the version does **not** have a release tag yet.
For the Windows package of `v2.3.3`, follow 3B through 9.

This procedure uses two computers. A and C run on the configured **Linux build
computer with push access**. B runs on **Windows in MINGW64**. The Windows
release VM keeps its tested tools; it does not need another MSYS2 update.

### A. Linux: Prepare the new version

All intended changes and release notes must already be committed and pushed.
This requires the configured [Linux build computer](BUILD.md#linux-source-build).
The block first asks for the source folder on that computer and changes to it.
Enter the path without surrounding quotes, even if it contains spaces.

```bash
(
  set -euo pipefail
  read -r -p 'Full path to the DinoX source folder on Linux: ' repo
  cd "$repo" || { echo "ERROR: The specified folder does not exist." >&2; exit 1; }
  if [[ ! -e .git || ! -f scripts/release.sh ]]; then
    echo "ERROR: This is not a DinoX source folder with Git history." >&2
    exit 1
  fi
  trap 'echo "STOP: This step failed. Do not continue." >&2' ERR
  test "$(git branch --show-current)" = master || { echo "STOP: Select the master development branch first." >&2; exit 1; }
  changes="$(git status --porcelain)"
  test -z "$changes" || { echo "STOP: Save or commit local changes first." >&2; git status --short; exit 1; }
  git fetch origin '+refs/heads/master:refs/remotes/origin/master'
  test "$(git rev-parse HEAD)" = "$(git rev-parse origin/master)" || { echo "STOP: Local source and origin/master differ. Reconcile them first." >&2; exit 1; }
  git fetch origin --tags
  bash scripts/prepare-linux-source-build-deps.sh
  vendor_root="$(cd "${DINOX_LINUX_VENDOR_ROOT:-$PWD/.vendor-deps}" && pwd -P)"
  export DINOX_LIBWEBRTC_RUNTIME_ROOT="$vendor_root/libwebrtc-m152-linux-x86_64-runtime"
  export DINOX_LOCAL_LIBOMEMO_C_ROOT="$vendor_root/linux-source-deps"
  read -r -p 'New release version (without v): ' release_version
  ./scripts/release.sh "$release_version" --prepare
  printf 'RELEASE_VERSION=%s\nRELEASE_COMMIT=%s\n' \
    "$release_version" "$(git rev-parse HEAD)"
)
```

The script updates version information, builds and tests DinoX, and creates a
commit. Confirm its push with `y` after successful checks. It prints
`RELEASE_VERSION` and `RELEASE_COMMIT`. Keep both values. The 40-character commit
identifier specifies the source that both Windows and Linux must use.

Do not add changes to `master` before step C. No release tag has been published
and no Forgejo package build has started yet.

### B. Windows: Build and test that source

Close DinoX and open MINGW64 as your normal user. For this case, the following
block replaces step 3A/3B. Paste the full commit identifier from A at the prompt:

```bash
(
  set -euo pipefail
  cd "$HOME/dinox" || { echo 'ERROR: DinoX source folder not found. Complete step 3 first.' >&2; exit 1; }
  if [[ ! -e .git || ! -f scripts/build-windows-dist.sh ]]; then
    echo 'ERROR: This folder does not contain the DinoX source. Check the folder.' >&2
    exit 1
  fi
  changes="$(git status --porcelain)"
  if [[ -n "$changes" ]]; then
    echo 'STOP: The source folder has local changes. Save or commit them first.' >&2
    git status --short
    exit 1
  fi
  repo="$PWD"
  read -r -p 'Release commit from step A (40 characters): ' release_commit
  [[ "$release_commit" =~ ^[0-9a-f]{40}$ ]] || { echo "ERROR: Expected a 40-character commit ID." >&2; exit 1; }
  git -C "$repo" fetch origin '+refs/heads/master:refs/remotes/origin/master'
  test "$release_commit" = "$(git -C "$repo" rev-parse origin/master)" || { echo "STOP: origin/master does not match the prepared commit." >&2; exit 1; }
  git -C "$repo" switch --detach "$release_commit"
  test "$(git -C "$repo" rev-parse HEAD)" = "$release_commit"
  echo 'Selected source version:'
  git -C "$repo" log -1 --format='%H %s'
)
```

Now complete **steps 4 through 8 in this guide**: prepare dependencies, build
from scratch, review the log, test DinoX and create the ZIP. “Detached HEAD” is
expected. Keep the logs and record the manual test results.

In the generated `build-info.txt`, `source_commit` must match the identifier
from A and `source_dirty` must be `false`. A previous build made before the
version change is not sufficient. If code corrections are needed, test and push
them on Linux, then repeat B with the new commit identifier.

### C. Linux: Release the tested version

Return to the Linux build computer after the Windows tests have passed. This
block asks again for the source folder and the commit tested on Windows:

```bash
(
  set -euo pipefail
  read -r -p 'Full path to the DinoX source folder on Linux: ' repo
  cd "$repo" || { echo "ERROR: The specified folder does not exist." >&2; exit 1; }
  if [[ ! -e .git || ! -f scripts/release.sh ]]; then
    echo "ERROR: This is not a DinoX source folder with Git history." >&2
    exit 1
  fi
  trap 'echo "STOP: This step failed. Do not continue." >&2' ERR
  test "$(git branch --show-current)" = master || { echo "STOP: Select the master development branch first." >&2; exit 1; }
  changes="$(git status --porcelain)"
  test -z "$changes" || { echo "STOP: Save or commit local changes first." >&2; git status --short; exit 1; }
  read -r -p 'Windows-checked source_commit (40 characters): ' release_commit
  [[ "$release_commit" =~ ^[0-9a-f]{40}$ ]] || { echo "ERROR: The commit identifier must have 40 characters." >&2; exit 1; }
  test "$(git rev-parse HEAD)" = "$release_commit" || { echo "STOP: This source does not match the Windows build." >&2; exit 1; }
  release_version="$(tr -d '[:space:]' < VERSION)"
  ./scripts/release.sh "$release_version" --finalize
)
```

The script checks the source and creates the release tag. Confirm its push
with `y` to start the Forgejo DEB, AppImage and Flatpak build. The tag identifies
the same commit as the completed Windows package, so adding it does not itself
require another Windows build.

The Forgejo run publishes the release after successful Linux checks. Do not
start a second manual package build. If the run fails, investigate and rerun
its failed jobs. Then follow **step 9** for the Windows ZIP and checksum.

Historical recovery cases are recorded in
[RELEASE_READINESS.md](RELEASE_READINESS.md#package-build-order).

## If something fails

- **`fatal: not a git repository`**: Git ran outside the source folder, or the folder is not a Git checkout. Start at step 3 in MINGW64. The complete blocks change to the correct folder themselves.
- **Local source changes**: The procedure stops to preserve your work. Save the changes separately or commit them first; do not discard them with a forced reset.
- **Access denied during cleanup**: Exit DinoX completely. If earlier Administrator builds created `build` and `dist`, remove those two generated folders once with the necessary rights or repair their permissions. Then reopen MINGW64 normally. Do not delete the source folder or your user profile.
- **Administrator build refused**: Close MINGW64 and reopen it without “Run as administrator”. The script checks this before deleting old build files.
- **Preparation or DLL check failed**: Read the full log. For missing dependencies, repeat step 4. Do not copy DLLs into the package speculatively.
- **ZIP does not match the source**: The source changed after the build. Build and test the desired version again, then package it.

Keep the complete `compile-…log` for troubleshooting. Investigate new unexplained
warnings before publication. A later “0 warnings” message from a short rebuild
does not describe the earlier full compilation. Previously reviewed warnings
are recorded in [WINDOWS_WARNING_TODO.md](WINDOWS_WARNING_TODO.md).

## Technical background

[Windows build technical details](WINDOWS_BUILD_DETAILS_EN.md) describes library
versions, Unicode paths, automated package checks, licenses, GnuPG, the tray
icon and rebuilding the separate WebRTC runtime. These details are intended
for development and troubleshooting.

For targeted call diagnostics after a successful build, run in MINGW64:

```bash
DINOX_GOOGLE_WEBRTC_CALL_DEBUG=1 "$HOME/dinox/dist/dinox.exe" \
  > "$HOME/dinox-build-logs/webrtc-debug.log" 2>&1
```

See [DEBUG.md](DEBUG.md) for more diagnostic guidance.
