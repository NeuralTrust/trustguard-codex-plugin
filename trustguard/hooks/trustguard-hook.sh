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

VERSION="0.1.5"
BASE_URL="${TRUSTGUARD_CODEX_DOWNLOAD_BASE:-https://github.com/NeuralTrust/trustguard-codex-plugin/releases/download}"
BIN_DIR="${TRUSTGUARD_CODEX_BIN_DIR:-$HOME/.trustguard/bin}"

# Per-platform SHA-256 of the release binaries (filled per release).
SHA256_darwin_amd64="8dcedbfa6b9e179b444a85218400dc56da9406561b2b3fabca53f252137ec032"
SHA256_darwin_arm64="c0247a96ddb81b3519ef3b8221fa850660c40fab84b6c62963198fd65f12f213"
SHA256_linux_amd64="7254f2ebbb026cd89f2dbc3a8d58a211b7abebc338187083e24ca0a18689c2b9"
SHA256_linux_arm64="1638435052350f9837e4af81b6af6360384a04f5c7a5b3d7de87400975c3e79f"
SHA256_windows_amd64="1872c3a140d502cedeef1ad2f4bc1755b8e6cfe36448e047cfd264a1b3d3c3b0"
SHA256_windows_arm64="742fb53d51d85d9d2f95f5a0766a49abe56ea1e25c04a55e683678018bd13922"

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
