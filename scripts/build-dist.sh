#!/bin/sh
# Cross-compile the release binaries into dist/ and write SHA256SUMS.
#
# Both halves of the release run this: the job that opens the release PR, to
# get the checksums it pins into the bootstraps, and the job that publishes,
# to prove those pins still describe the binaries it is about to upload. That
# only holds while the toolchain is identical in both runs, so the workflow
# pins an exact Go version — the one printed below is what makes the build
# reproducible.
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
    # -buildvcs=false: Go otherwise stamps the commit and a dirty-tree flag
    # into the binary, which would change every checksum between the run that
    # pins them (tree dirty from the version bump) and the run that publishes.
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
