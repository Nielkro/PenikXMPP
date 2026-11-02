#!/bin/bash
set -euo pipefail

if [[ "$#" -gt 1 ]]; then
    echo "ERROR: Unknown arguments: $*" >&2
    echo "Usage: $0 [output-tar]" >&2
    exit 2
fi

OUTPUT_TAR="${1:-$HOME/ci-deps-cache/deps.tar}"
CACHE_DIR="$(dirname "$OUTPUT_TAR")"
TMP_LIST="$(mktemp)"

cleanup() {
    rm -f "$TMP_LIST"
}
trap cleanup EXIT

{
    find usr/bin usr/local/bin \
        \( -name sqlcipher -o -name tor -o -name lyrebird \) \
        \( -type f -o -type l \) 2>/dev/null || true

    find usr/include usr/local/include \
        \( -path 'usr/include/sqlcipher*' \
        -o -path 'usr/include/nice*' \
        -o -path 'usr/include/stun*' \
        -o -path 'usr/include/protobuf-c*' \
        -o -path 'usr/include/google/protobuf-c*' \
        -o -path 'usr/include/omemo*' \
        -o -path 'usr/include/cjson*' \
        -o -name 'mosquitto*.h' \
        -o -name 'mqtt_protocol.h' \) \
        \( -type f -o -type l \) 2>/dev/null || true

    find usr/lib usr/lib64 usr/local/lib \
        \( -name 'libsqlcipher*' \
        -o -name 'libnice*' \
        -o -name 'libprotobuf-c*' \
        -o -name 'libomemo-c*' \
        -o -name 'libcjson*' \
        -o -name 'libmosquitto*' \) \
        \( -type f -o -type l \) 2>/dev/null || true

    find usr/lib usr/lib64 usr/local/lib usr/share \
        \( -path '*/pkgconfig/sqlcipher.pc' \
        -o -path '*/pkgconfig/nice.pc' \
        -o -path '*/pkgconfig/libprotobuf-c.pc' \
        -o -path '*/pkgconfig/libomemo-c.pc' \
        -o -path '*/pkgconfig/libcjson.pc' \
        -o -path '*/pkgconfig/libmosquitto.pc' \
        -o -path '*/pkgconfig/libmosquittopp.pc' \
        -o -path '*/gir-1.0/Nice-0.1.gir' \
        -o -path '*/girepository-1.0/Nice-0.1.typelib' \) \
        \( -type f -o -type l \) 2>/dev/null || true
} | sort -u > "$TMP_LIST"

if [[ ! -s "$TMP_LIST" ]]; then
    echo "ERROR: no custom dependency files found to cache." >&2
    exit 1
fi

missing_required=false

require_cached_path() {
    local description="$1"
    shift
    local pattern

    for pattern in "$@"; do
        if grep -Eq "$pattern" "$TMP_LIST"; then
            return 0
        fi
    done

    echo "ERROR: required CI dependency cache entry missing: $description" >&2
    missing_required=true
}

require_cached_path "SQLCipher binary" '^usr/bin/sqlcipher$'
require_cached_path "SQLCipher pkg-config metadata" '(^|/)pkgconfig/sqlcipher\.pc$'
require_cached_path "libnice pkg-config metadata" '(^|/)pkgconfig/nice\.pc$'
require_cached_path "libnice shared library" '(^|/)libnice\.so'
require_cached_path "protobuf-c pkg-config metadata" '(^|/)pkgconfig/libprotobuf-c\.pc$'
require_cached_path "protobuf-c shared library" '(^|/)libprotobuf-c\.so'
require_cached_path "libomemo-c pkg-config metadata" '(^|/)pkgconfig/libomemo-c\.pc$'
require_cached_path "libomemo-c shared library" '(^|/)libomemo-c\.so'
require_cached_path "cJSON pkg-config metadata" '(^|/)pkgconfig/libcjson\.pc$'
require_cached_path "cJSON shared library" '(^|/)libcjson\.so'
require_cached_path "libmosquitto pkg-config metadata" '(^|/)pkgconfig/libmosquitto\.pc$'
require_cached_path "libmosquitto shared library" '(^|/)libmosquitto\.so'
require_cached_path "Tor runtime binary" '^usr/local/bin/tor$'
require_cached_path "Lyrebird runtime binary" '^usr/local/bin/lyrebird$'

if $missing_required; then
    echo "ERROR: refusing to write incomplete CI dependency cache." >&2
    exit 1
fi

mkdir -p "$CACHE_DIR"
tar cf "$OUTPUT_TAR" -T "$TMP_LIST"
echo "Cached $(wc -l < "$TMP_LIST") custom dependency paths into $OUTPUT_TAR"
