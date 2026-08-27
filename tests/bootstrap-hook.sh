#!/bin/sh
set -eu

ROOT=$(cd -- "$(dirname "$0")/.." && pwd)
HOOK="$ROOT/trustguard/hooks/trustguard-hook.sh"
POWERSHELL_HOOK="$ROOT/trustguard/hooks/trustguard-hook.ps1"
FIXTURE="$ROOT/tests/fixtures/fake-trustguard-codex.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/trustguard-bootstrap.XXXXXX")
BIN_DIR="$TEST_ROOT/bin"
PAYLOAD='{"hook_event_name":"PreToolUse","tool_name":"Bash"}'

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

VERSION=$(sed -n 's/^VERSION="\([^"]*\)"/\1/p' "$HOOK")
[ -n "$VERSION" ] || fail 'bootstrap VERSION is missing'

run_case() {
    binary_name=$1
    mkdir -p "$BIN_DIR"
    cp "$FIXTURE" "$BIN_DIR/$binary_name"
    chmod 0755 "$BIN_DIR/$binary_name"

    actual=$(
        printf '%s\n' "$PAYLOAD" |
            env PATH=/usr/bin:/bin TRUSTGUARD_CODEX_BIN_DIR="$BIN_DIR" sh "$HOOK"
    )
    expected=$(printf 'binary=%s\nargs=hook\nstdin=%s' "$binary_name" "$PAYLOAD")

    [ "$actual" = "$expected" ] || fail "$binary_name was not executed with the hook payload"
    rm -f "$BIN_DIR/$binary_name"
}

run_case trustguard-codex
run_case "trustguard-codex-$VERSION"

if command -v pwsh >/dev/null 2>&1; then
    powershell=$(command -v pwsh)
    cp "$FIXTURE" "$BIN_DIR/trustguard-codex.exe"
    chmod 0755 "$BIN_DIR/trustguard-codex.exe"

    actual=$(
        printf '%s\n' "$PAYLOAD" |
            env PATH=/usr/bin:/bin TRUSTGUARD_CODEX_BIN_DIR="$BIN_DIR" \
                "$powershell" -NoProfile -File "$POWERSHELL_HOOK"
    )
    expected=$(printf 'binary=trustguard-codex.exe\nargs=hook\nstdin=%s' "$PAYLOAD")

    [ "$actual" = "$expected" ] || fail 'trustguard-codex.exe was not executed with the hook payload'
fi

printf 'bootstrap hook tests passed\n'
