#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
    cat <<EOF
Usage: $0 [script...]
       $0 --self-test

Checks shell script syntax with bash -n.
Without arguments, checks Git-tracked shell scripts under scripts/:
files ending in .sh or starting with a sh/bash shebang.
EOF
}

check_script() {
    local script="$1"

    if [[ "$script" = /* ]]; then
        bash -n "$script"
    else
        bash -n "$PROJECT_DIR/$script"
    fi
}

run_isolated_git() {
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git "$@"
}

run_isolated_shell_check() {
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE "$tmp_dir/scripts/check-shell-syntax.sh"
}

run_self_test() {
    local tmp_dir=""
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' RETURN

    mkdir -p "$tmp_dir/scripts"
    cp "$0" "$tmp_dir/scripts/check-shell-syntax.sh"
    chmod +x "$tmp_dir/scripts/check-shell-syntax.sh"

    cat > "$tmp_dir/scripts/valid.sh" <<'EOF'
#!/bin/bash
echo "valid"
EOF

    cat > "$tmp_dir/scripts/suffix-only.sh" <<'EOF'
echo "valid by suffix"
EOF

    cat > "$tmp_dir/scripts/extensionless-hook" <<'EOF'
#!/usr/bin/env bash
echo "valid hook"
EOF

    cat > "$tmp_dir/scripts/not-shell.py" <<'EOF'
#!/usr/bin/env python3
def intentionally_not_bash(:
EOF

    run_isolated_git -C "$tmp_dir" init -q
    run_isolated_git -C "$tmp_dir" add scripts

    run_isolated_shell_check

    # A tracked file may be intentionally deleted in the current worktree
    # before the deletion is committed. Default discovery must not turn that
    # normal review state into a bogus bash syntax failure.
    rm "$tmp_dir/scripts/valid.sh"
    run_isolated_shell_check

    cat > "$tmp_dir/scripts/broken-hook" <<'EOF'
#!/usr/bin/env bash
if
EOF
    run_isolated_git -C "$tmp_dir" add scripts/broken-hook

    if run_isolated_shell_check >/dev/null 2>&1; then
        echo "Self-test failed: default discovery missed a broken extensionless bash script" >&2
        return 1
    fi

    cat > "$tmp_dir/scripts/broken-suffix-only.sh" <<'EOF'
if
EOF
    run_isolated_git -C "$tmp_dir" add scripts/broken-suffix-only.sh

    if run_isolated_shell_check >/dev/null 2>&1; then
        echo "Self-test failed: default discovery missed a broken .sh script" >&2
        return 1
    fi

    cat > "$tmp_dir/scripts/broken-suffix-only.sh" <<'EOF'
echo "fixed suffix script"
EOF

    cat > "$tmp_dir/scripts/broken-hook" <<'EOF'
#!/usr/bin/env fish
if
EOF

    run_isolated_shell_check
    echo "Self-test OK"
}

is_default_shell_script() {
    local script="$1"
    local first_line=""

    if [[ "$script" == *.sh ]]; then
        return 0
    fi

    if IFS= read -r first_line < "$script"; then
        if [[ "$first_line" =~ ^#!.*(^|[[:space:]/])bash([[:space:]]|$) ]] ||
            [[ "$first_line" =~ ^#!.*(^|[[:space:]/])sh([[:space:]]|$) ]]; then
            return 0
        fi
    fi

    return 1
}

if [ "$#" -eq 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
    usage
    exit 0
fi

if [ "$#" -eq 1 ] && [ "$1" = "--self-test" ]; then
    run_self_test
    exit 0
fi

if [ "$#" -gt 0 ]; then
    for script in "$@"; do
        check_script "$script"
    done
    exit 0
fi

cd "$PROJECT_DIR"
while IFS= read -r script; do
    [[ -f "$script" ]] || continue
    if is_default_shell_script "$script"; then
        check_script "$script"
    fi
done < <(git ls-files scripts | sort -u)
