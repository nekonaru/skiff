#!/usr/bin/env bash
# Cross-compile Skiff for all release targets, print each binary size,
# and fail if any of them is 1 MiB or larger.
#
# Usage:
#   scripts/release.sh             # build into dist/, check sizes
#   scripts/release.sh --artifacts # also copy final binaries to artifacts/ + SHA256SUMS
set -euo pipefail
cd "$(dirname "$0")/.."

ZIG_VERSION="${ZIG_VERSION:-0.17.1}"
LIMIT_BYTES=$((1024 * 1024))

targets=(
    x86_64-linux-musl:skiff
    aarch64-linux-musl:skiff
    x86_64-windows:skiff.exe
    x86_64-macos:skiff
    aarch64-macos:skiff
)
artifact_names=(
    skiff-x86_64-linux
    skiff-aarch64-linux
    skiff-x86_64-windows.exe
    skiff-x86_64-macos
    skiff-aarch64-macos
)

fail=0
for i in "${!targets[@]}"; do
    target="${targets[$i]%%:*}"
    binary="${targets[$i]##*:}"
    echo "== Building $target"
    zig build -Doptimize=ReleaseSmall -Dtarget="$target" --prefix "dist/$target"
    bin="dist/$target/bin/$binary"
    size=$(stat -c%s "$bin" 2>/dev/null || stat -f%z "$bin")
    printf '   %-28s %10d bytes\n' "$bin" "$size"
    if [ "$size" -ge "$LIMIT_BYTES" ]; then
        echo "   ERROR: $bin is $size bytes, limit is $LIMIT_BYTES"
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "Release aborted: at least one binary is too large" >&2
    exit 1
fi

if [ "${1:-}" = "--artifacts" ]; then
    rm -rf artifacts
    mkdir -p artifacts
    for i in "${!targets[@]}"; do
        target="${targets[$i]%%:*}"
        binary="${targets[$i]##*:}"
        cp "dist/$target/bin/$binary" "artifacts/${artifact_names[$i]}"
    done
    ( cd artifacts && sha256sum * > SHA256SUMS )
    echo "Artifacts in ./artifacts:"
    ( cd artifacts && sha256sum -c SHA256SUMS && ls -l )
fi

echo "All release binaries are below 1 MiB"
