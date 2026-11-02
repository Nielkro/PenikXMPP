#!/usr/bin/env bash
# Optional local-only build; never installs into /usr or enables a Tor route.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOR_VERSION="0.4.9.12"
TOR_SHA256="c0d307c9dcdaee4848a8ca53e9d6c4ec92823e4f30be12790b0fbddfc6515f5b"
LYREBIRD_VERSION="0.8.1"
LYREBIRD_SHA256="05d87533c66562baae8a0adac6ae7f7401aa08516ea0dfd192a367d2f8645092"
VENDOR_URL="https://git.dinox.im/dinoxim/dinox/releases/download/vendor-deps"
RUNTIME_FILES=(bin/tor bin/lyrebird share/tor/geoip share/tor/geoip6 dinox-tor-runtime.json)

fail() { echo "ERROR: $*" >&2; return 1; }

verify_hash() {
    [[ -f "$1" && ! -L "$1" ]] || return 1
    [[ "$(sha256sum "$1" | cut -d ' ' -f 1)" == "$2" ]]
}

verify_repository_pins() {
    local name expected actual
    while read -r name expected; do
        actual="$(sed -nE "s/^${name}=\"?([^\"[:space:]]+)\"?$/\\1/p" "$PROJECT_ROOT/scripts/ci-build-deps.sh")"
        [[ "$actual" == "$expected" ]] || {
            fail "local Tor helper disagrees with ci-build-deps.sh: $name"
            return 1
        }
    done <<EOF
TOR_VER $TOR_VERSION
TOR_SHA256 $TOR_SHA256
LYREBIRD_VER $LYREBIRD_VERSION
LYREBIRD_SHA256 $LYREBIRD_SHA256
EOF
}

validate_target() {
    local path="$1"
    [[ "$path" == /*/.vendor-deps/linux-tor-runtime && "$path" != *'/../'* && "$path" != *'/./'* ]] || return 1
    while [[ "$path" != / ]]; do
        [[ ! -L "$path" ]] || return 1
        [[ ! -e "$path" || -d "$path" ]] || return 1
        path="$(dirname "$path")"
    done
}

validate_payload() {
    local root="$1" file version directory
    for directory in "$root" "$root/bin" "$root/share" "$root/share/tor"; do
        [[ -d "$directory" && ! -L "$directory" ]] || return 1
    done
    for file in "${RUNTIME_FILES[@]}"; do
        [[ -s "$root/$file" && -f "$root/$file" && ! -L "$root/$file" ]] || return 1
    done
    [[ -x "$root/bin/tor" && -x "$root/bin/lyrebird" ]] || return 1
    version="$(timeout 10s "$root/bin/tor" --version)" || return 1
    [[ "$version" == "Tor version $TOR_VERSION."* ]] || return 1
    version="$(timeout 10s "$root/bin/lyrebird" --version)" || return 1
    [[ "$version" == "lyrebird $LYREBIRD_VERSION" ]] || return 1
    python3 - "$root" "$TOR_VERSION" "$TOR_SHA256" "$LYREBIRD_VERSION" "$LYREBIRD_SHA256" <<'PY'
import hashlib, json, sys
from pathlib import Path
root = Path(sys.argv[1])
try:
    metadata = json.loads((root / 'dinox-tor-runtime.json').read_text())
    for name, version, source_hash in [('tor', sys.argv[2], sys.argv[3]), ('lyrebird', sys.argv[4], sys.argv[5])]:
        entry = metadata[name]
        if entry['version'] != version or entry['source_sha256'] != source_hash:
            raise ValueError('runtime source pins do not match')
        if entry['sha256'] != hashlib.sha256((root / 'bin' / name).read_bytes()).hexdigest():
            raise ValueError('runtime executable hash does not match')
    for name in ['geoip', 'geoip6']:
        if metadata[name + '_sha256'] != hashlib.sha256((root / 'share' / 'tor' / name).read_bytes()).hexdigest():
            raise ValueError('runtime GeoIP hash does not match')
except (OSError, ValueError, KeyError, TypeError) as error:
    print('ERROR: invalid private Tor runtime: ' + str(error), file=sys.stderr)
    sys.exit(1)
PY
}

replace_runtime_file() { mv -T -- "$1" "$2"; }

require_no_pending_install() {
    local root="$1"
    if [[ -d "$root" ]] && find "$root" -maxdepth 1 -name '.tor-runtime-install.*' -print -quit | grep -q .; then
        fail "unfinished local Tor installation found in $root; inspect its retained rollback files first"
        return 1
    fi
}

install_payload() (
    # The caller owns the build lock. Back up only this helper's five files;
    # never rename/delete the prefix itself or unrelated vendor files.
    local stage="$1" target="$2" transaction="" file parent
    local -a changed=()
    validate_target "$target" || exit 1
    validate_payload "$stage" || { fail "staged runtime is incomplete or has the wrong versions"; exit 1; }
    mkdir -p -- "$target" || exit 1
    require_no_pending_install "$target" || exit 1
    for parent in bin share share/tor; do
        [[ ! -L "$target/$parent" ]] || exit 1
        mkdir -p -- "$target/$parent" || exit 1
    done
    for file in "${RUNTIME_FILES[@]}"; do
        [[ ! -L "$target/$file" ]] || exit 1
        [[ ! -e "$target/$file" || -f "$target/$file" ]] || exit 1
    done
    transaction="$(mktemp -d "$target/.tor-runtime-install.XXXXXX")" || exit 1
    finish_install() {
        local status=$? index rollback_failed=0
        trap - EXIT INT TERM
        if ((status != 0)); then
            for ((index=${#changed[@]}-1; index>=0; index--)); do
                file="${changed[index]}"
                if [[ -f "$transaction/old/$file" ]]; then
                    mv -T -- "$transaction/old/$file" "$target/$file" || rollback_failed=1
                else
                    rm -f -- "$target/$file" || rollback_failed=1
                fi
            done
        fi
        if ((rollback_failed)); then
            fail "rollback incomplete; retained recovery files: $transaction"
            exit 1
        fi
        # Exact transaction directory created above, not the target directory.
        rm -rf -- "$transaction"
        exit "$status"
    }
    trap finish_install EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    for file in "${RUNTIME_FILES[@]}"; do
        mkdir -p -- "$transaction/new/$(dirname "$file")" "$transaction/old/$(dirname "$file")" || exit 1
        cp -p -- "$stage/$file" "$transaction/new/$file" || exit 1
        if [[ -f "$target/$file" ]]; then
            cp -p -- "$target/$file" "$transaction/old/$file" || exit 1
        fi
    done
    for file in "${RUNTIME_FILES[@]}"; do
        changed+=("$file")
        replace_runtime_file "$transaction/new/$file" "$target/$file" || exit 1
    done
    validate_payload "$target" || exit 1
)

download_source() {
    local name="$1" digest="$2" destination="$3"
    curl --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --location \
        --show-error --retry 2 --connect-timeout 20 --max-time 300 \
        "$VENDOR_URL/$name" --output "$destination" || return 1
    verify_hash "$destination" "$digest" || { fail "source checksum mismatch: $name"; return 1; }
}

write_metadata() {
    local stage="$1"
    printf '{\n  "purpose": "Local source-built Tor helpers; no system fallback",\n  "tor": {"version": "%s", "source_sha256": "%s", "sha256": "%s"},\n  "lyrebird": {"version": "%s", "source_sha256": "%s", "sha256": "%s"},\n  "geoip_sha256": "%s",\n  "geoip6_sha256": "%s"\n}\n' \
        "$TOR_VERSION" "$TOR_SHA256" "$(sha256sum "$stage/bin/tor" | cut -d ' ' -f 1)" \
        "$LYREBIRD_VERSION" "$LYREBIRD_SHA256" "$(sha256sum "$stage/bin/lyrebird" | cut -d ' ' -f 1)" \
        "$(sha256sum "$stage/share/tor/geoip" | cut -d ' ' -f 1)" \
        "$(sha256sum "$stage/share/tor/geoip6" | cut -d ' ' -f 1)" \
        > "$stage/dinox-tor-runtime.json"
}

main() (
    case "$#:${1:-}" in
        1:--help|1:-h)
            echo "Usage: bash scripts/prepare-linux-tor-runtime.sh [--self-test|--help]"
            echo "Prepares private Tor $TOR_VERSION and Lyrebird $LYREBIRD_VERSION under .vendor-deps/linux-tor-runtime."
            echo "Reuses a verified runtime; a missing runtime requires C compiler, make, pkg-config, libevent/OpenSSL/zlib development files, Go >= 1.22, curl, tar, ldd, Python 3 and flock."
            echo "No sudo, system Tor, application settings or network bootstrap. Downloads occur only on explicit invocation."
            exit 0 ;;
        1:--self-test)
            exec bash "$PROJECT_ROOT/scripts/test-prepare-linux-tor-runtime.sh" ;;
        0:) ;;
        *) fail "unsupported arguments; use --help"; exit 2 ;;
    esac
    [[ "$(uname -s)" == Linux && "$EUID" != 0 ]] || { fail "run as a normal Linux user, not root"; exit 1; }
    verify_repository_pins
    for tool in python3 flock sha256sum timeout; do
        command -v "$tool" >/dev/null || { fail "missing runtime verification prerequisite: $tool"; exit 1; }
    done
    local target="$PROJECT_ROOT/.vendor-deps/linux-tor-runtime" legacy="$PROJECT_ROOT/build/release-deps"
    local work="" stage libraries
    validate_target "$target" || { fail "unsafe local runtime target"; exit 1; }
    mkdir -p -- "$PROJECT_ROOT/.vendor-deps"
    [[ ! -L "$PROJECT_ROOT/.vendor-deps/.tor-runtime.lock" ]] || exit 1
    exec 9>"$PROJECT_ROOT/.vendor-deps/.tor-runtime.lock"
    flock -n 9 || { fail "another local Tor preparation is running"; exit 1; }
    require_no_pending_install "$target" || exit 1
    require_no_pending_install "$legacy" || exit 1
    if validate_payload "$target" >/dev/null 2>&1; then
        echo "Reusing verified Tor $TOR_VERSION and Lyrebird $LYREBIRD_VERSION in $target"
        exit 0
    fi
    if [[ ! -L "$legacy" ]] && validate_payload "$legacy" >/dev/null 2>&1; then
        install_payload "$legacy" "$target"
        echo "Preserved the verified legacy Tor helpers in $target (outside the Meson build tree)"
        exit 0
    fi
    for tool in cc make pkg-config go curl tar ldd flock sha256sum timeout; do
        command -v "$tool" >/dev/null || { fail "missing build prerequisite: $tool (see docs/internal/BUILD.md)"; exit 1; }
    done
    pkg-config --exists libevent openssl zlib || {
        fail "libevent, OpenSSL and zlib development files are required; no packages were installed"
        exit 1
    }
    local go_version
    go_version="$(GOTOOLCHAIN=local go env GOVERSION)"
    [[ "$go_version" =~ ^go([0-9]+)\.([0-9]+) ]] && \
        ((BASH_REMATCH[1] > 1 || (BASH_REMATCH[1] == 1 && BASH_REMATCH[2] >= 22))) || {
        fail "Go >= 1.22 is required; automatic toolchain downloads are disabled"
        exit 1
    }
    work="$(mktemp -d /tmp/dinox-tor-runtime.XXXXXX)"
    cleanup_build() { local status=$?; trap - EXIT; rm -rf -- "$work"; exit "$status"; }
    trap cleanup_build EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    stage="$work/stage"
    mkdir -p "$work/tor" "$work/lyrebird" "$stage/bin" "$stage/share/tor"
    download_source "tor-$TOR_VERSION.tar.gz" "$TOR_SHA256" "$work/tor.tar.gz"
    download_source "lyrebird-$LYREBIRD_VERSION-vendored.tar.gz" "$LYREBIRD_SHA256" "$work/lyrebird.tar.gz"
    tar -xzf "$work/tor.tar.gz" --no-same-owner --strip-components=1 -C "$work/tor"
    tar -xzf "$work/lyrebird.tar.gz" --no-same-owner --strip-components=1 -C "$work/lyrebird"
    (
        cd "$work/tor"
        ./configure --prefix="$stage" --disable-asciidoc --disable-manpage \
            --disable-system-torrc --disable-module-relay --disable-unittests
        make -j2
        install -m 0755 src/app/tor "$stage/bin/tor"
        install -m 0644 src/config/geoip src/config/geoip6 "$stage/share/tor/"
    )
    (
        cd "$work/lyrebird"
        CGO_ENABLED=0 GOENV=off GOTOOLCHAIN=local GOPROXY=off GOSUMDB=off \
            GOPATH="$work/gopath" GOCACHE="$work/go-cache" \
            GOFLAGS='-mod=vendor -p=2' go build -trimpath \
            -ldflags "-s -w -X main.lyrebirdVersion=$LYREBIRD_VERSION" \
            -o "$stage/bin/lyrebird" ./cmd/lyrebird
    )
    libraries="$(timeout 15s ldd "$stage/bin/tor")"
    if [[ "$libraries" == *'not found'* ]]; then
        fail "new Tor has unresolved shared libraries; previous helpers are unchanged"
        exit 1
    fi
    write_metadata "$stage"
    validate_payload "$stage"
    install_payload "$stage" "$target"
    echo "Prepared Tor $TOR_VERSION and Lyrebird $LYREBIRD_VERSION in $target"
    echo "No Tor connection was started and no application settings changed."
    echo "Start with DINOX_TOR_DATA_DIR=\"$target/share/tor\" \"$PROJECT_ROOT/build/main/dinox\""
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
