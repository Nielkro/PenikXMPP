#!/usr/bin/env bash
# Offline fixtures: no downloads, compiler invocation, or real Tor process.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/prepare-linux-tor-runtime.sh"
fixture_root="$(mktemp -d /tmp/dinox-tor-runtime-test.XXXXXX)"
trap 'rm -rf -- "$fixture_root"' EXIT

expect_failure() {
    if "$@" >/dev/null 2>&1; then fail "self-test accepted: $*"; exit 1; fi
}
make_fixture() {
    local root="$1"
    mkdir -p "$root/bin" "$root/share/tor"
    printf '#!/bin/sh\nprintf "Tor version %s.\\n"\n' "$TOR_VERSION" > "$root/bin/tor"
    printf '#!/bin/sh\nprintf "lyrebird %s\\n"\n' "$LYREBIRD_VERSION" > "$root/bin/lyrebird"
    chmod 0755 "$root/bin/tor" "$root/bin/lyrebird"
    printf 'IPv4 fixture\n' > "$root/share/tor/geoip"
    printf 'IPv6 fixture\n' > "$root/share/tor/geoip6"
    write_metadata "$root"
}

verify_repository_pins
source_root="$fixture_root/Build ä with spaces"
target="$source_root/.vendor-deps/linux-tor-runtime"
stage="$fixture_root/stage"
make_fixture "$stage"
validate_target "$target"
expect_failure validate_target /
expect_failure validate_target "$HOME"
expect_failure validate_target "$fixture_root/build/release-deps"
expect_failure validate_target "$fixture_root/.vendor-deps/../.vendor-deps/linux-tor-runtime"
mkdir -p "$fixture_root/real"
ln -s "$fixture_root/real" "$fixture_root/alias"
expect_failure validate_target "$fixture_root/alias/.vendor-deps/linux-tor-runtime"

hash="$(sha256sum "$stage/bin/tor" | cut -d ' ' -f 1)"
verify_hash "$stage/bin/tor" "$hash"
expect_failure verify_hash "$stage/bin/tor" "$(printf '%064d' 0)"
ln -s "$stage/bin/tor" "$fixture_root/linked-tor"
expect_failure verify_hash "$fixture_root/linked-tor" "$hash"

install_payload "$stage" "$target"
cmp "$stage/bin/tor" "$target/bin/tor"
cmp "$stage/dinox-tor-runtime.json" "$target/dinox-tor-runtime.json"
mkdir -p "$source_root/build/main"
printf 'disposable compiler output\n' > "$source_root/build/main/dinox"
before_wipe="$(sha256sum "$target"/bin/* "$target"/share/tor/* "$target/dinox-tor-runtime.json")"
rm -rf -- "$source_root/build"
validate_payload "$target"
[[ "$before_wipe" == "$(sha256sum "$target"/bin/* "$target"/share/tor/* "$target/dinox-tor-runtime.json")" ]]
printf 'modified executable without matching metadata\n' >> "$target/bin/lyrebird"
expect_failure validate_payload "$target"
install_payload "$stage" "$target"
printf 'unrelated build output\n' > "$target/unrelated.txt"
before="$(sha256sum "$target"/bin/* "$target"/share/tor/* "$target/dinox-tor-runtime.json")"
printf '# changed replacement binary\n' >> "$stage/bin/tor"
printf 'new data\n' > "$stage/share/tor/geoip"
write_metadata "$stage"
replace_runtime_file() {
    [[ "$2" != */share/tor/geoip ]] || return 1
    mv -T -- "$1" "$2"
}
expect_failure install_payload "$stage" "$target"
after="$(sha256sum "$target"/bin/* "$target"/share/tor/* "$target/dinox-tor-runtime.json")"
[[ "$before" == "$after" ]] || { fail "rollback did not restore the previous runtime"; exit 1; }
[[ "$(< "$target/unrelated.txt")" == 'unrelated build output' ]]
empty_target="$fixture_root/empty/.vendor-deps/linux-tor-runtime"
expect_failure install_payload "$stage" "$empty_target"
for file in "${RUNTIME_FILES[@]}"; do
    [[ ! -e "$empty_target/$file" ]] || { fail "failed first install left a partial runtime"; exit 1; }
done
replace_runtime_file() { mv -T -- "$1" "$2"; }

printf '#!/bin/sh\necho "Tor version 0.4.8.0."\n' > "$stage/bin/tor"
expect_failure install_payload "$stage" "$target"
[[ "$before" == "$(sha256sum "$target"/bin/* "$target"/share/tor/* "$target/dinox-tor-runtime.json")" ]]
make_fixture "$stage"
: > "$stage/share/tor/geoip6"
expect_failure install_payload "$stage" "$target"
make_fixture "$stage"
ln -s "$fixture_root/real" "$fixture_root/linked-build"
expect_failure install_payload "$stage" "$fixture_root/linked-build/.vendor-deps/linux-tor-runtime"
mkdir "$target/.tor-runtime-install.interrupted"
expect_failure require_no_pending_install "$target"
expect_failure install_payload "$stage" "$target"
rmdir "$target/.tor-runtime-install.interrupted"
require_no_pending_install "$target"
legacy="$source_root/build/release-deps"
mkdir -p "$legacy/.tor-runtime-install.interrupted"
expect_failure require_no_pending_install "$legacy"
rmdir "$legacy/.tor-runtime-install.interrupted"
require_no_pending_install "$legacy"
install_payload "$stage" "$target"
validate_payload "$target"
[[ "$(< "$target/unrelated.txt")" == 'unrelated build output' ]]
echo "Self-test OK: matching CI pins, hashes, safe paths, versions, persistent prefix after build wipe, isolated install and rollback"
