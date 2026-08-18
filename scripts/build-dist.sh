#!/bin/sh
# Cross-compile the release binaries into dist/ and write SHA256SUMS.
set -eu

VERSION="${1:?usage: build-dist.sh VERSION [OUTDIR]}"
OUT="${2:-dist}"

go version

rm -rf "$OUT"
mkdir -p "$OUT"

for platform in darwin/amd64 darwin/arm64 linux/amd64 linux/arm64 windows/amd64 windows/arm64; do
    GOOS="${platform%/*}"
    GOARCH="${platform#*/}"
    case "$GOOS" in
        windows) ext=".exe" ;;
        *) ext="" ;;
    esac
    artifact="$OUT/trustguard-codex_${VERSION}_${GOOS}_${GOARCH}${ext}"
    echo "building $artifact"
    CGO_ENABLED=0 GOOS="$GOOS" GOARCH="$GOARCH" \
        go build -buildvcs=false -trimpath -ldflags "-s -w" -o "$artifact" ./cli
done

cd "$OUT"
if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- * > SHA256SUMS
else
    shasum -a 256 -- * > SHA256SUMS
fi
cat SHA256SUMS
