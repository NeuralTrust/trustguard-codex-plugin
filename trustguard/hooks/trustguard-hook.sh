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

VERSION="0.1.2"
BASE_URL="${TRUSTGUARD_CODEX_DOWNLOAD_BASE:-https://github.com/NeuralTrust/trustguard-codex-plugin/releases/download}"
BIN_DIR="${TRUSTGUARD_CODEX_BIN_DIR:-$HOME/.trustguard/bin}"

# Per-platform SHA-256 of the release binaries (filled per release).
SHA256_darwin_amd64="5ec468648588b5b9d3083232b322c433efcd80959213530c9d1a08086b241751"
SHA256_darwin_arm64="d503daf64e9e2fc297bd86d33772f145b8be8aa60891de1d72190772cb29393d"
SHA256_linux_amd64="d11fd2bbf508b22aaa52efb9b39a70d586d17447ce47e5b91555dab5207ad09f"
SHA256_linux_arm64="78070b359bb9c687ee6194296d15a08603e807172290a2b9e61d13161e7ed815"
SHA256_windows_amd64="00692f7997cbab01dd4a2eeffb6b17f453e4a5f606609191837fc599c828520e"
SHA256_windows_arm64="ec5838635ffec8ef1eff374a95367cfffc5a0c8eaee3e7e8eaf3bcf49e31b653"

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
