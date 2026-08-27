#!/bin/sh
# Bootstrap for the TrustGuard Codex plugin (macOS/Linux).
#
# Codex invokes this script on each hook event. It executes trustguard-codex
# from the PATH when present (manual/MDM installs win); otherwise it installs
# the pinned release for this OS/arch into ~/.trustguard/bin in the background,
# verifying its SHA-256 against the table below, and evaluates from the next
# event on. Every bootstrap failure fails open (Codex must never brick) with a
# warning on stderr.
#
# The VERSION and SHA256_* table are updated per release.
set -u

VERSION="0.1.0"
BASE_URL="${TRUSTGUARD_CODEX_DOWNLOAD_BASE:-https://github.com/NeuralTrust/trustguard-codex-plugin/releases/download}"
BIN_DIR="${TRUSTGUARD_CODEX_BIN_DIR:-$HOME/.trustguard/bin}"

# Per-platform SHA-256 of the release binaries (filled per release).
SHA256_darwin_amd64="6c48976b5e14a88207441ee5d2080ab515c6f13d75a6a3e8f388f32e836b9fee"
SHA256_darwin_arm64="f033a013e5e2f3ba0cf92b2f8d58ccc1167f460cd1e5cf72b09734d79b5cb2f7"
SHA256_linux_amd64="910bcf9898beb2e031c121c773e1bb2e53ad25f2fcc346edf8bcf6c78bb440c5"
SHA256_linux_arm64="7b6121f20032815d37c997d28ba2f5e8a058152bc19f3a6f40c51d5dae30d6b6"
SHA256_windows_amd64="5d15192f331ecea483b74ad70f50985d77ddb938251010680a06d4f9243873c0"
SHA256_windows_arm64="585d803f6b60522f961bb0e25bbbfcfda4419c74723028e391001287811a98f3"

fail_open() {
    echo "trustguard-codex bootstrap: $1 — allowing without evaluation" >&2
    # Empty allow: Codex continues when stdout is empty / exit 0.
    printf '{}\n'
    exit 0
}

if command -v trustguard-codex >/dev/null 2>&1; then
    exec trustguard-codex hook
fi

EXT=""
case "$(uname -s)" in
    Darwin) OS="darwin" ;;
    Linux) OS="linux" ;;
    MINGW* | MSYS* | CYGWIN*) OS="windows" EXT=".exe" ;;
    *) OS="" ;;
esac

# Local and MDM installs use the stable, unversioned filename.
LOCAL_BIN="$BIN_DIR/trustguard-codex$EXT"
if [ -x "$LOCAL_BIN" ]; then
    exec "$LOCAL_BIN" hook
fi

BIN="$BIN_DIR/trustguard-codex-$VERSION$EXT"
if [ -x "$BIN" ]; then
    exec "$BIN" hook
fi

if [ -z "$OS" ]; then
    fail_open "unsupported OS $(uname -s); install trustguard-codex manually"
fi
case "$(uname -m)" in
    x86_64 | amd64) ARCH="amd64" ;;
    arm64 | aarch64) ARCH="arm64" ;;
    *) fail_open "unsupported arch $(uname -m); install trustguard-codex manually" ;;
esac

WANT_SHA=$(eval "printf '%s' \"\${SHA256_${OS}_${ARCH}:-}\"")
if [ -z "$WANT_SHA" ]; then
    fail_open "no pinned checksum for ${OS}/${ARCH} (release ${VERSION} not published yet?); install trustguard-codex manually"
fi

URL="$BASE_URL/v$VERSION/trustguard-codex_${VERSION}_${OS}_${ARCH}${EXT}"
mkdir -p "$BIN_DIR" 2>/dev/null || fail_open "cannot create $BIN_DIR"

install_binary() {
    TMP="$BIN.download.$$"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 5 --max-time 300 -o "$TMP" "$URL" || { rm -f "$TMP"; return 1; }
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 300 -O "$TMP" "$URL" || { rm -f "$TMP"; return 1; }
    else
        return 1
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        GOT_SHA=$(sha256sum "$TMP" | cut -d' ' -f1)
    elif command -v shasum >/dev/null 2>&1; then
        GOT_SHA=$(shasum -a 256 "$TMP" | cut -d' ' -f1)
    else
        rm -f "$TMP"
        return 1
    fi
    if [ "$GOT_SHA" != "$WANT_SHA" ]; then
        rm -f "$TMP"
        return 1
    fi

    chmod 0755 "$TMP" || { rm -f "$TMP"; return 1; }
    mv -f "$TMP" "$BIN" || { rm -f "$TMP"; return 1; }
}

LOCK="$BIN_DIR/install-codex-$VERSION.lock"
if [ -d "$LOCK" ] && [ -n "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
    rmdir "$LOCK" 2>/dev/null || :
fi
if mkdir "$LOCK" 2>/dev/null; then
    ( install_binary; rmdir "$LOCK" 2>/dev/null ) >/dev/null 2>&1 &
fi
fail_open "trustguard-codex $VERSION not installed yet; fetching it in the background"
