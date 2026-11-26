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

VERSION="0.1.6"
BASE_URL="${TRUSTGUARD_CODEX_DOWNLOAD_BASE:-https://github.com/NeuralTrust/trustguard-codex-plugin/releases/download}"
BIN_DIR="${TRUSTGUARD_CODEX_BIN_DIR:-$HOME/.trustguard/bin}"

# Per-platform SHA-256 of the release binaries (filled per release).
SHA256_darwin_amd64="eff7f09d6a4b0c42cd1689e4c96744a56ad9c751f9265cc1c54904865271aa3b"
SHA256_darwin_arm64="ddc407af37b1def27b4d33597bc1e6a72d6b015cfa65b11e3686bff5e6652660"
SHA256_linux_amd64="9b4c2ba3eee6f071fb1eb11ed1f722794d3edf452e76212f38d466c02274912c"
SHA256_linux_arm64="9ef8ae60da506545177a66e1acb228f93d736ef6ba06ccc4ba9c2af11b5687a7"
SHA256_windows_amd64="262ac81c235570c641c573b8205daab1047359ffd1543b021b631c0a0cbdd01f"
SHA256_windows_arm64="3d82a0e37aa3a640a9042c37013e20351cdfd9643e58a12133b7da85d9f25f12"

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
