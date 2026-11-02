#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "Usage: $0 <tag>|--self-test"
}

validate_tag_format() {
    local tag="$1"
    if [[ "$tag" != v* ]]; then
        echo "ERROR: tag must start with v, for example v1.2.3" >&2
        usage >&2
        exit 2
    fi

    if ! [[ "${tag#v}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        echo "ERROR: invalid tag format: $tag" >&2
        echo "Expected: vX.Y.Z or vX.Y.Z.W" >&2
        exit 2
    fi
}

require_local_tag() {
    local tag="$1"
    local tag_ref="refs/tags/${tag}"

    if ! git -c safe.directory="$PWD" rev-parse --verify --quiet "${tag_ref}^{commit}" >/dev/null; then
        echo "ERROR: release tag does not exist locally: $tag" >&2
        exit 1
    fi
}

require_exact_tag_metadata() {
    local tag="$1"
    local tag_commit checkout_commit path
    tag_commit="$(git -c safe.directory="$PWD" rev-parse "refs/tags/${tag}^{commit}")"
    checkout_commit="$(git -c safe.directory="$PWD" rev-parse HEAD)"
    [ "$tag_commit" = "$checkout_commit" ] || {
        echo "ERROR: check out the exact release tag before preparing its assets: $tag" >&2
        exit 1
    }
    for path in docs/internal/CHANGELOG.md dino.doap main/data/im.dinox.dinox.appdata.xml; do
        git -c safe.directory="$PWD" cat-file -e "refs/tags/${tag}:$path" || {
            echo "ERROR: release tag has no required metadata: $path" >&2
            exit 1
        }
        git -c safe.directory="$PWD" diff --quiet "refs/tags/${tag}" -- "$path" || {
            echo "ERROR: release metadata differs from the archived tag: $path" >&2
            exit 1
        }
    done
}

run_self_test() {
    local tmp_dir=""
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' RETURN

    if ! "$0" --help >/dev/null; then
        echo "Self-test failed: --help did not succeed" >&2
        return 1
    fi

    if "$0" >/dev/null 2>&1; then
        echo "Self-test failed: accepted a missing release tag" >&2
        return 1
    fi

    if "$0" v1.2.3 extra >/dev/null 2>&1; then
        echo "Self-test failed: accepted too many arguments" >&2
        return 1
    fi

    validate_tag_format v1.2.3
    validate_tag_format v1.2.3.4

    if (validate_tag_format 1.2.3) >/dev/null 2>&1; then
        echo "Self-test failed: accepted a tag without v prefix" >&2
        return 1
    fi

    if (validate_tag_format v1.2) >/dev/null 2>&1; then
        echo "Self-test failed: accepted an incomplete tag" >&2
        return 1
    fi

    if (validate_tag_format v1.2.3.4.5) >/dev/null 2>&1; then
        echo "Self-test failed: accepted too many tag components" >&2
        return 1
    fi

    (
        unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
        cd "$tmp_dir"
        git init -q
        if (require_local_tag v9.9.9) >/dev/null 2>&1; then
            echo "Self-test failed: accepted a missing local tag" >&2
            exit 1
        fi

        echo "test" > README.md
        git add README.md
        git -c user.name="DinoX Test" -c user.email="test@dinox.local" commit -q -m "test"
        git tag v1.2.3
        require_local_tag v1.2.3

        mkdir -p docs/internal main/data scripts
        printf '## [Unreleased]\n\n## [1.2.3] - Unreleased\n\nRelease notes.\n' \
            > docs/internal/CHANGELOG.md
        cat > dino.doap <<'DOAP'
<rdf:RDF xmlns="http://usefulinc.com/ns/doap#" xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><Project><release><Version><name>1.2.3 (Unreleased)</name><created>Unreleased</created><revision>1.2.3</revision></Version></release></Project></rdf:RDF>
DOAP
        cat > main/data/im.dinox.dinox.appdata.xml <<'APPSTREAM'
<component><releases><release version="1.2.3" type="development"><description><p>Release notes.</p></description></release></releases></component>
APPSTREAM
        # Stop at the next boundary. Neither fixture can reach archive/upload.
        cat > scripts/run_all_tests.sh <<'GATE'
#!/bin/bash
touch stable-gate-reached
exit 91
GATE
        chmod +x scripts/run_all_tests.sh
        git add docs/internal/CHANGELOG.md dino.doap main/data/im.dinox.dinox.appdata.xml scripts/run_all_tests.sh
        git -c user.name="DinoX Test" -c user.email="test@dinox.local" commit -q -m "pending metadata"
        git tag -f v1.2.3 >/dev/null
        local result=0
        "$SCRIPT_DIR/prepare-forgejo-release.sh" v1.2.3 > pending.log 2>&1 || result=$?
        [ "$result" -eq 1 ] && [ ! -e stable-gate-reached ] || {
            echo "Self-test failed: pending release reached the external-action boundary" >&2
            exit 1
        }
        python3 "$SCRIPT_DIR/release-metadata.py" prepare 1.2.3 --date 2026-10-12
        git add docs/internal/CHANGELOG.md dino.doap main/data/im.dinox.dinox.appdata.xml
        git -c user.name="DinoX Test" -c user.email="test@dinox.local" commit -q -m "stable metadata"
        result=0
        "$SCRIPT_DIR/prepare-forgejo-release.sh" v1.2.3 > stale-tag.log 2>&1 || result=$?
        [ "$result" -eq 1 ] && [ ! -e stable-gate-reached ] || {
            echo "Self-test failed: stable checkout published metadata from a different tag commit" >&2
            exit 1
        }
        git tag -f v1.2.3 >/dev/null
        result=0
        "$SCRIPT_DIR/prepare-forgejo-release.sh" v1.2.3 > stable.log 2>&1 || result=$?
        [ "$result" -eq 91 ] && [ -e stable-gate-reached ] || {
            echo "Self-test failed: stable release did not pass the metadata boundary" >&2
            exit 1
        }
        rm -f stable-gate-reached
        python3 "$SCRIPT_DIR/release-metadata.py" prepare 1.2.3 --date 2026-10-13
        result=0
        "$SCRIPT_DIR/prepare-forgejo-release.sh" v1.2.3 > changed-metadata.log 2>&1 || result=$?
        [ "$result" -eq 1 ] && [ ! -e stable-gate-reached ] || {
            echo "Self-test failed: changed checkout metadata reached release preparation" >&2
            exit 1
        }
    )

    echo "Self-test OK"
}

if [ "$#" -eq 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
    usage
    exit 0
fi

if [ "$#" -eq 1 ] && [ "$1" = "--self-test" ]; then
    run_self_test
    exit 0
fi

if [ "$#" -ne 1 ]; then
    usage >&2
    exit 2
fi

validate_tag_format "$1"

TAG="$1"
VERSION="${TAG#v}"
TAG_REF="refs/tags/${TAG}"

require_local_tag "$TAG"
require_exact_tag_metadata "$TAG"

# A manually created tag must not publish a locally prepared development entry.
python3 "$SCRIPT_DIR/release-metadata.py" check-stable "$VERSION"

./scripts/run_all_tests.sh --static

WORK_DIR="$(mktemp -d)"
BODY_FILE="${WORK_DIR}/RELEASE_BODY.md"
SOURCE_TARBALL="${WORK_DIR}/dinox-${VERSION}.tar.gz"
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

extract_changelog() {
    local version="$1"
    awk -v ver="[${version}]" '
        /^## / { if (p) { exit }; if ($2 == ver) { p=1; next } }
        p { print }
    ' docs/internal/CHANGELOG.md
}

{
    echo "## DinoX v${VERSION}"
    echo
    echo "Modern XMPP client with extended features."
    echo
    echo "### Choose your Linux download"
    echo
    echo "- **Ubuntu 24.04 / Linux Mint 22.x (64-bit Intel/AMD):** use the \`.deb\`, AppImage or Flatpak."
    echo "- **Debian 13 (Trixie), including SparkyLinux 8.x (64-bit Intel/AMD):** use AppImage or Flatpak. The Ubuntu-built \`.deb\` requires different system libraries."
    echo "- **Missing \`libgpgme11t64\` or \`libicu74\`?** Check the supported system first. Development (\`-dev\`) packages do not fix a binary compatibility mismatch."
    echo
    echo "[Installation help](https://git.dinox.im/dinoxim/dinox/src/tag/${TAG}/docs/internal/BUILD.md#deb-installation-troubleshooting)"
    echo
    echo "### What's New"
    echo
} > "$BODY_FILE"

notes="$(extract_changelog "$VERSION")"
if [ -z "${notes//[[:space:]]/}" ] && echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    base_version="$(echo "$VERSION" | sed -E 's/\.[0-9]+$//')"
    notes="$(extract_changelog "$base_version")"
    if [ -n "${notes//[[:space:]]/}" ]; then
        {
            echo "(Release notes from v${base_version})"
            echo
        } >> "$BODY_FILE"
    fi
fi

if [ -n "${notes//[[:space:]]/}" ]; then
    echo "$notes" >> "$BODY_FILE"
else
    echo "No changelog entry was found for this release." >> "$BODY_FILE"
fi

CB='```'
{
    echo
    echo "---"
    echo
    echo "### Installation"
    echo
    echo "#### Ubuntu 24.04 / Linux Mint 22 (.deb)"
    echo "${CB}bash"
    echo "sha256sum -c dinox_${VERSION}_amd64.deb.sha256"
    echo "sudo apt update"
    echo "sudo apt install ./dinox_${VERSION}_amd64.deb"
    echo "${CB}"
    echo
    echo "Run in the download folder. APT installs the required runtime dependencies from your configured Ubuntu/Mint repositories."
    echo "This package is not a Debian Trixie binary; use AppImage or Flatpak there. Do not force installation or add Ubuntu repositories to Debian."
    echo
    echo "#### AppImage"
    echo "${CB}bash"
    echo "sha256sum -c DinoX-${VERSION}-x86_64.AppImage.sha256"
    echo "chmod +x DinoX-${VERSION}-x86_64.AppImage"
    echo "./DinoX-${VERSION}-x86_64.AppImage"
    echo "${CB}"
    echo
    echo "The matching \`.AppImage.sources.tar.xz\` file is a separate compliance download."
    echo "It is not required to install or run DinoX."
    echo
    echo "#### Flatpak"
    echo "${CB}bash"
    echo "sha256sum -c dinox-${VERSION}-x86_64.flatpak.sha256"
    echo "# Required runtimes are resolved automatically from the bundle metadata."
    echo "flatpak install --user ./dinox-${VERSION}-x86_64.flatpak"
    echo "flatpak run im.dinox.dinox"
    echo "${CB}"
    echo
    echo "#### Build from Source"
    echo "${CB}bash"
    echo "("
    echo "set -e"
    echo "sha256sum -c dinox-${VERSION}.tar.gz.sha256"
    echo "tar xf dinox-${VERSION}.tar.gz"
    echo "cd dinox-${VERSION}"
    echo "# Install the normal distribution development packages from docs/internal/BUILD.md."
    echo "test \"\$(uname -m)\" = x86_64"
    echo "bash scripts/prepare-linux-source-build-deps.sh"
    echo "export DINOX_LIBWEBRTC_RUNTIME_ROOT=\$PWD/.vendor-deps/libwebrtc-m152-linux-x86_64-runtime"
    echo "export DINOX_LOCAL_LIBOMEMO_C_ROOT=\$PWD/.vendor-deps/linux-source-deps"
    echo "export PKG_CONFIG_PATH=\$DINOX_LOCAL_LIBOMEMO_C_ROOT/lib/pkgconfig\${PKG_CONFIG_PATH:+:\$PKG_CONFIG_PATH}"
    echo "./scripts/check-libwebrtc-linux-runtime.sh \"\$DINOX_LIBWEBRTC_RUNTIME_ROOT\""
    echo "meson setup --wipe --buildtype=debugoptimized --prefix=/usr build -Dlocal-libomemo-c-root=\"\$DINOX_LOCAL_LIBOMEMO_C_ROOT\" -Dplugin-mqtt=enabled -Dplugin-rtp=disabled -Dplugin-google-webrtc=enabled -Dgoogle-libwebrtc-wrapper=enabled -Dgoogle-libwebrtc-runtime-root=\"\$DINOX_LIBWEBRTC_RUNTIME_ROOT\" -Dgoogle-libwebrtc-test-oracle=false -Dgoogle-libwebrtc-tests=false -Dlocation-sharing=enabled -Dplugin-http-files=enabled -Dplugin-ice=enabled -Dplugin-omemo=enabled -Dplugin-openpgp=enabled -Dplugin-notification-sound=enabled"
    echo "./scripts/build.sh"
    echo "./build/main/dinox --version"
    echo "# For Tor/obfs4/WebTunnel, first follow the optional private Tor runtime section in BUILD.md."
    echo "DINOX_TOR_DATA_DIR=\"\$PWD/.vendor-deps/linux-tor-runtime/share/tor\" ./build/main/dinox"
    echo ")"
    echo "${CB}"
} >> "$BODY_FILE"

git -c safe.directory="$PWD" archive --format=tar.gz --output="$SOURCE_TARBALL" --prefix="dinox-${VERSION}/" "$TAG_REF"
(
    cd "$WORK_DIR"
    sha256sum "$(basename "$SOURCE_TARBALL")" > "$(basename "$SOURCE_TARBALL").sha256.tmp"
    mv "$(basename "$SOURCE_TARBALL").sha256.tmp" "$(basename "$SOURCE_TARBALL").sha256"
    sha256sum -c "$(basename "$SOURCE_TARBALL").sha256"
)

chmod +x scripts/forgejo-release.sh
scripts/forgejo-release.sh create "$TAG" "DinoX v${VERSION}" "$BODY_FILE"
scripts/forgejo-release.sh upload "$TAG" "$SOURCE_TARBALL" "${SOURCE_TARBALL}.sha256"
