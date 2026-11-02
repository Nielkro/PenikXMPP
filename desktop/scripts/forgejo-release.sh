#!/bin/bash
set -euo pipefail

usage() {
    cat <<EOF
Usage:
  $0 create <tag> <name> <body-file>
  $0 upload <tag> <file> [file...]
  $0 publish <tag>
  $0 --self-test
  $0 -h|--help
EOF
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

validate_release_body_file() {
    local body_file="$1"
    if [ ! -f "$body_file" ]; then
        echo "ERROR: release body file not found: $body_file" >&2
        exit 1
    fi
}

validate_upload_assets() {
    local file
    for file in "$@"; do
        if [ ! -s "$file" ]; then
            echo "ERROR: release asset not found or empty: $file" >&2
            exit 1
        fi
        if [[ "$file" == *.sha256 ]]; then
            local dir
            local name
            dir="$(dirname "$file")"
            name="$(basename "$file")"
            if ! (cd "$dir" && sha256sum -c "$name"); then
                exit 1
            fi
        fi
    done

    for file in "$@"; do
        case "$file" in
            *.tar.gz|*.tar.xz|*.zip|*.deb|*.AppImage|*.flatpak)
                local sidecar="${file}.sha256"
                local found=false
                local candidate
                for candidate in "$@"; do
                    if [ "$candidate" = "$sidecar" ]; then
                        found=true
                        break
                    fi
                done
                if [ "$found" != "true" ]; then
                    echo "ERROR: release asset requires matching checksum sidecar: $sidecar" >&2
                    exit 1
                fi
                ;;
            *.sha256)
                local asset="${file%.sha256}"
                local found=false
                local candidate
                for candidate in "$@"; do
                    if [ "$candidate" = "$asset" ]; then
                        found=true
                        break
                    fi
                done
                if [ "$found" != "true" ]; then
                    echo "ERROR: checksum sidecar requires matching release asset: $asset" >&2
                    exit 1
                fi
                ;;
        esac
    done
}

validate_tag_format() {
    local tag="$1"
    if [ "$tag" = "vendor-deps" ]; then
        return 0
    fi
    if [[ "$tag" != v* ]]; then
        echo "ERROR: tag must be vendor-deps or start with v, for example v1.2.3" >&2
        exit 2
    fi

    if ! [[ "${tag#v}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        echo "ERROR: invalid tag format: $tag" >&2
        echo "Expected: vX.Y.Z or vX.Y.Z.W" >&2
        exit 2
    fi
}

validate_release_asset_inventory() {
    local tag="$1"
    local assets_json
    assets_json="$(cat)"

    if [ "$tag" = "vendor-deps" ]; then
        fail "vendor-deps is an infrastructure release and cannot be published by the product release gate"
    fi

    ASSETS_JSON="$assets_json" python3 - "$tag" <<'PY'
import json
import os
import re
import sys

tag = sys.argv[1]
version = tag.removeprefix("v")
assets = json.loads(os.environ["ASSETS_JSON"])
if not isinstance(assets, list):
    print("ERROR: Forgejo release assets response is not a list", file=sys.stderr)
    sys.exit(1)

names = {
    str(asset.get("name", ""))
    for asset in assets
    if isinstance(asset, dict) and asset.get("name")
}

def require_exact(name, label):
    if name not in names:
        print(f"ERROR: draft release is missing {label}: {name}", file=sys.stderr)
        return False
    if f"{name}.sha256" not in names:
        print(
            f"ERROR: draft release is missing checksum for {label}: {name}.sha256",
            file=sys.stderr,
        )
        return False
    return True

def require_pattern(pattern, label):
    matches = sorted(name for name in names if re.fullmatch(pattern, name))
    if not matches:
        print(f"ERROR: draft release is missing {label}", file=sys.stderr)
        return False
    ok = True
    for name in matches:
        if f"{name}.sha256" not in names:
            print(
                f"ERROR: draft release is missing checksum for {label}: {name}.sha256",
                file=sys.stderr,
            )
            ok = False
    return ok

def require_appimage_source_pairs():
    appimage_pattern = re.compile(
        rf"DinoX-{re.escape(version)}-[A-Za-z0-9._+~-]+\.AppImage"
    )
    source_suffix = ".sources.tar.xz"
    source_pattern = re.compile(
        rf"DinoX-{re.escape(version)}-[A-Za-z0-9._+~-]+"
        rf"\.AppImage{re.escape(source_suffix)}"
    )
    appimages = sorted(name for name in names if appimage_pattern.fullmatch(name))
    source_bundles = sorted(name for name in names if source_pattern.fullmatch(name))
    ok = True

    if len(appimages) != 1:
        print(
            "ERROR: draft release must contain exactly one AppImage; "
            f"found {len(appimages)}: {', '.join(appimages) or 'none'}",
            file=sys.stderr,
        )
        ok = False
    for appimage in appimages:
        if not require_exact(appimage, "AppImage"):
            ok = False

    if len(source_bundles) != 1:
        print(
            "ERROR: draft release must contain exactly one AppImage "
            f"corresponding-source bundle; found {len(source_bundles)}: "
            f"{', '.join(source_bundles) or 'none'}",
            file=sys.stderr,
        )
        ok = False
    for source_bundle in source_bundles:
        if not require_exact(
            source_bundle,
            "AppImage corresponding-source bundle",
        ):
            ok = False

    if len(appimages) == 1:
        expected_source = f"{appimages[0]}{source_suffix}"
        if source_bundles != [expected_source]:
            print(
                "ERROR: draft release AppImage corresponding-source bundle "
                f"must be exactly {expected_source}",
                file=sys.stderr,
            )
            ok = False

    return ok

escaped = re.escape(version)
checks = [
    require_exact(f"dinox-{version}.tar.gz", "source archive"),
    require_pattern(rf"dinox_{escaped}_[A-Za-z0-9._+~-]+\.deb", "Debian package"),
    require_appimage_source_pairs(),
    require_exact(f"dinox-{version}-x86_64.flatpak", "Flatpak bundle"),
]
if not all(checks):
    sys.exit(1)

print("Release asset inventory complete.")
PY
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
        echo "Self-test failed: accepted a missing command" >&2
        return 1
    fi

    if "$0" invalid >/dev/null 2>&1; then
        echo "Self-test failed: accepted an unknown command" >&2
        return 1
    fi

    if "$0" create v1.2.3 "DinoX v1.2.3" >/dev/null 2>&1; then
        echo "Self-test failed: accepted create without a body file" >&2
        return 1
    fi

    if "$0" upload v1.2.3 >/dev/null 2>&1; then
        echo "Self-test failed: accepted upload without assets" >&2
        return 1
    fi

    if "$0" publish >/dev/null 2>&1; then
        echo "Self-test failed: accepted publish without a tag" >&2
        return 1
    fi

    if "$0" publish v1.2.3 extra >/dev/null 2>&1; then
        echo "Self-test failed: accepted publish with extra arguments" >&2
        return 1
    fi

    local asset="$tmp_dir/dinox-test.tar.gz"
    local checksum="$asset.sha256"
    local body_file="$tmp_dir/body.md"

    echo "release asset" > "$asset"
    echo "release body" > "$body_file"
    (cd "$tmp_dir" && sha256sum "$(basename "$asset")" > "$(basename "$checksum")")

    validate_release_body_file "$body_file"
    validate_upload_assets "$asset" "$checksum"
    local packaged_asset
    for packaged_asset in \
        "$tmp_dir/dinox-test.zip" \
        "$tmp_dir/dinox-test.deb" \
        "$tmp_dir/DinoX-test.AppImage" \
        "$tmp_dir/DinoX-test.AppImage.sources.tar.xz" \
        "$tmp_dir/dinox-test.flatpak"; do
        echo "release asset" > "$packaged_asset"
        (cd "$tmp_dir" && sha256sum "$(basename "$packaged_asset")" > "$(basename "$packaged_asset").sha256")
        validate_upload_assets "$packaged_asset" "$packaged_asset.sha256"
    done
    validate_tag_format v1.2.3
    validate_tag_format v1.2.3.4
    validate_tag_format vendor-deps

    local release_assets
    release_assets="$(cat <<'EOF'
[
  {"name":"dinox-1.2.3.tar.gz"},
  {"name":"dinox-1.2.3.tar.gz.sha256"},
  {"name":"dinox_1.2.3_amd64.deb"},
  {"name":"dinox_1.2.3_amd64.deb.sha256"},
  {"name":"DinoX-1.2.3-x86_64.AppImage"},
  {"name":"DinoX-1.2.3-x86_64.AppImage.sha256"},
  {"name":"DinoX-1.2.3-x86_64.AppImage.sources.tar.xz"},
  {"name":"DinoX-1.2.3-x86_64.AppImage.sources.tar.xz.sha256"},
  {"name":"dinox-1.2.3-x86_64.flatpak"},
  {"name":"dinox-1.2.3-x86_64.flatpak.sha256"}
]
EOF
)"
    validate_release_asset_inventory v1.2.3 <<<"$release_assets" >/dev/null

    if (validate_release_body_file "$tmp_dir/missing-body.md") >/dev/null 2>&1; then
        echo "Self-test failed: accepted a missing release body file" >&2
        return 1
    fi

    if (validate_upload_assets "$tmp_dir/missing-asset.tar.gz") >/dev/null 2>&1; then
        echo "Self-test failed: accepted a missing release asset" >&2
        return 1
    fi

    if (validate_upload_assets "$asset") >/dev/null 2>&1; then
        echo "Self-test failed: accepted an upload without checksum sidecar" >&2
        return 1
    fi

    if (validate_upload_assets "$checksum") >/dev/null 2>&1; then
        echo "Self-test failed: accepted a checksum sidecar without asset" >&2
        return 1
    fi

    echo "0000000000000000000000000000000000000000000000000000000000000000  $(basename "$asset")" > "$checksum"
    if (validate_upload_assets "$asset" "$checksum") >/dev/null 2>&1; then
        echo "Self-test failed: accepted a broken checksum sidecar" >&2
        return 1
    fi

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

    if (validate_tag_format arbitrary-deps) >/dev/null 2>&1; then
        echo "Self-test failed: accepted an arbitrary infrastructure tag" >&2
        return 1
    fi

    if (validate_release_asset_inventory vendor-deps <<<"$release_assets") >/dev/null 2>&1; then
        echo "Self-test failed: accepted vendor-deps for product publication" >&2
        return 1
    fi

    if (sed '/DinoX-1.2.3-x86_64.AppImage.sha256/d' <<<"$release_assets" \
            | validate_release_asset_inventory v1.2.3) >/dev/null 2>&1; then
        echo "Self-test failed: accepted an incomplete release asset inventory" >&2
        return 1
    fi

    if (sed '/DinoX-1.2.3-x86_64.AppImage.sources.tar.xz/d' <<<"$release_assets" \
            | validate_release_asset_inventory v1.2.3) >/dev/null 2>&1; then
        echo "Self-test failed: accepted release without AppImage corresponding-source bundle" >&2
        return 1
    fi

    local mismatched_appimage_assets
    mismatched_appimage_assets="$(
        sed \
            's/DinoX-1.2.3-x86_64\.AppImage\.sources\.tar\.xz/DinoX-1.2.3-aarch64.AppImage.sources.tar.xz/g' \
            <<<"$release_assets"
    )"
    if (validate_release_asset_inventory v1.2.3 <<<"$mismatched_appimage_assets") >/dev/null 2>&1; then
        echo "Self-test failed: accepted an AppImage with a different-architecture source sidecar" >&2
        return 1
    fi

    local stale_appimage_assets
    stale_appimage_assets="${release_assets%$'\n]'}"
    stale_appimage_assets+=$',\n  {"name":"DinoX-1.2.3-aarch64.AppImage"},\n  {"name":"DinoX-1.2.3-aarch64.AppImage.sha256"},\n  {"name":"DinoX-1.2.3-aarch64.AppImage.sources.tar.xz"},\n  {"name":"DinoX-1.2.3-aarch64.AppImage.sources.tar.xz.sha256"}\n]'
    if (validate_release_asset_inventory v1.2.3 <<<"$stale_appimage_assets") >/dev/null 2>&1; then
        echo "Self-test failed: accepted a stale extra AppImage/source-sidecar pair" >&2
        return 1
    fi

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

if [ "$#" -lt 1 ]; then
    usage >&2
    exit 2
fi

COMMAND="$1"
shift

case "$COMMAND" in
    create)
        if [ "$#" -ne 3 ]; then
            usage >&2
            exit 2
        fi
        validate_tag_format "$1"
        validate_release_body_file "$3"
        ;;
    upload)
        if [ "$#" -lt 2 ]; then
            usage >&2
            exit 2
        fi
        validate_tag_format "$1"
        validate_upload_assets "${@:2}"
        ;;
    publish)
        if [ "$#" -ne 1 ]; then
            usage >&2
            exit 2
        fi
        validate_tag_format "$1"
        if [ "$1" = "vendor-deps" ]; then
            fail "vendor-deps cannot be published by the product release gate"
        fi
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

REPOSITORY="${FORGEJO_REPOSITORY:-${GITHUB_REPOSITORY:-dinoxim/dinox}}"
SERVER_URL="${FORGEJO_SERVER_URL:-${GITHUB_SERVER_URL:-https://git.dinox.im}}"
API_URL="${FORGEJO_API_URL:-${SERVER_URL%/}/api/v1}"
TOKEN="${FORGEJO_TOKEN:-${DINOX_REGISTRY_TOKEN:-${GITHUB_TOKEN:-}}}"

if [ -z "$TOKEN" ]; then
    echo "ERROR: FORGEJO_TOKEN is not set; compatible DINOX_REGISTRY_TOKEN and GITHUB_TOKEN fallbacks are also empty." >&2
    exit 1
fi

api_url() {
    printf '%s/repos/%s%s' "$API_URL" "$REPOSITORY" "$1"
}

url_encode() {
    python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$1"
}

get_release_json() {
    local tag="$1"
    curl -fsS \
        -H "Authorization: token ${TOKEN}" \
        "$(api_url "/releases/tags/${tag}")"
}

release_is_draft() {
    python3 -c 'import json,sys; print("true" if json.load(sys.stdin).get("draft") is True else "false")'
}

create_release() {
    local tag="$1"
    local name="$2"
    local body_file="$3"

    validate_release_body_file "$body_file"

    local body
    body="$(cat "$body_file")"

    local payload
    payload="$(
        python3 - "$tag" "$name" "$body" <<'PY'
import json
import sys

tag, name, body = sys.argv[1], sys.argv[2], sys.argv[3]
print(json.dumps({
    "tag_name": tag,
    "target_commitish": "master",
    "name": name,
    "body": body,
    "draft": True,
    "prerelease": False,
}))
PY
    )"

    local release_json
    local release_id
    if release_json="$(get_release_json "$tag" 2>/dev/null)"; then
        if [ "$(release_is_draft <<<"$release_json")" != "true" ]; then
            fail "release ${tag} is already published; refusing to turn it back into a draft"
        fi
        release_id="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$release_json")"
        release_json="$(curl -fsS -X PATCH \
            -H "Authorization: token ${TOKEN}" \
            -H "Content-Type: application/json" \
            -d "$payload" \
            "$(api_url "/releases/${release_id}")")"
        if [ "$(release_is_draft <<<"$release_json")" != "true" ]; then
            fail "Forgejo release ${tag} was not kept as a draft"
        fi
        echo "Updated Forgejo draft release ${tag}."
    else
        release_json="$(curl -fsS -X POST \
            -H "Authorization: token ${TOKEN}" \
            -H "Content-Type: application/json" \
            -d "$payload" \
            "$(api_url "/releases")")"
        if [ "$(release_is_draft <<<"$release_json")" != "true" ]; then
            fail "Forgejo release ${tag} was not created as a draft"
        fi
        echo "Created Forgejo draft release ${tag}."
    fi
}

delete_existing_asset() {
    local release_id="$1"
    local name="$2"
    local response
    response="$(curl -fsS \
        -H "Authorization: token ${TOKEN}" \
        "$(api_url "/releases/${release_id}/assets")")"

    local asset_id
    asset_id="$(
        RESPONSE="$response" python3 - "$name" <<'PY'
import json
import os
import sys

wanted = sys.argv[1]
for asset in json.loads(os.environ["RESPONSE"]):
    if asset.get("name") == wanted:
        print(asset["id"])
        break
PY
    )"

    if [ -n "$asset_id" ]; then
        curl -fsS -X DELETE \
            -H "Authorization: token ${TOKEN}" \
            "$(api_url "/releases/${release_id}/assets/${asset_id}")" >/dev/null
    fi
}

upload_assets() {
    local tag="$1"
    shift

    local release_json
    local release_id
    release_json="$(get_release_json "$tag")" || fail "Forgejo release does not exist: $tag"
    if [ "$tag" != "vendor-deps" ] && [ "$(release_is_draft <<<"$release_json")" != "true" ]; then
        fail "release ${tag} is already published; refusing to modify product release assets"
    fi
    release_id="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$release_json")"

    for file in "$@"; do
        local name
        name="$(basename "$file")"
        delete_existing_asset "$release_id" "$name"
        curl -fsS -X POST \
            -H "Authorization: token ${TOKEN}" \
            -F "attachment=@${file}" \
            "$(api_url "/releases/${release_id}/assets?name=$(url_encode "$name")")" >/dev/null
        echo "Uploaded release asset: $name"
    done
}

publish_release() {
    local tag="$1"
    local release_json
    local release_id
    local assets_json

    release_json="$(get_release_json "$tag")" || fail "Forgejo release does not exist: $tag"
    if [ "$(release_is_draft <<<"$release_json")" != "true" ]; then
        fail "release ${tag} is already published"
    fi
    release_id="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$release_json")"
    assets_json="$(curl -fsS \
        -H "Authorization: token ${TOKEN}" \
        "$(api_url "/releases/${release_id}/assets")")"
    validate_release_asset_inventory "$tag" <<<"$assets_json"

    release_json="$(curl -fsS -X PATCH \
        -H "Authorization: token ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{"draft":false}' \
        "$(api_url "/releases/${release_id}")")"

    if [ "$(release_is_draft <<<"$release_json")" != "false" ]; then
        fail "Forgejo release ${tag} remained a draft after publish request"
    fi
    echo "Published complete Forgejo release ${tag}."
}

case "$COMMAND" in
    create)
        create_release "$1" "$2" "$3"
        ;;
    upload)
        tag="$1"
        shift
        upload_assets "$tag" "$@"
        ;;
    publish)
        publish_release "$1"
        ;;
esac
