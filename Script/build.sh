#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .root ]; then
    echo "[*] malformed project structure"
    exit 1
fi

usage() {
    cat <<'EOF'
Usage: ./build.sh [options]

Options:
  --source <path>          Use an existing Ghostty checkout.
  --ref <tag-or-commit>    Checkout the given ref in the source checkout.
  --platforms <csv>        Build platform groups. Default: macos
  --download-url <url>     Generate Package.swift from Package.swift.template.
  --custom-shaders         Build with GLSL shader support (glslang/spirv-cross).
                           This is the default; the flag is accepted for clarity.
  --no-custom-shaders      Build without it, matching upstream libghostty-spm.
                           Drops ~110 MB per architecture and the glslang /
                           SPIRV-Cross redistribution notices along with it.
  --skip-tests             Skip local xcodebuild and swift test verification.
  -h, --help               Show this help.

Notes:
  - Default source path is ./References/ghostty-upstream
  - This builds real per-target static archives, then assembles
    BinaryTarget/GhosttyKit.xcframework and build/GhosttyKit.xcframework.zip
  - Upstream Ghostty patches from ./Patches/ghostty are applied automatically
  - This fork ships macOS only. ios and maccatalyst still build, but the
    shader path is unverified there and no release carries them.
EOF
}

ROOT_DIR=$(pwd)
SOURCE_DIR="$ROOT_DIR/References/ghostty-upstream"
PLATFORMS="macos"
DOWNLOAD_URL=${DOWNLOAD_URL:-}
CUSTOM_SHADERS=${GHOSTTY_CUSTOM_SHADERS:-true}
GHOSTTY_REF=
SKIP_TESTS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --source)
            SOURCE_DIR="$2"
            shift 2
            ;;
        --ref)
            GHOSTTY_REF="$2"
            shift 2
            ;;
        --platforms)
            PLATFORMS="$2"
            shift 2
            ;;
        --download-url)
            DOWNLOAD_URL="$2"
            shift 2
            ;;
        --custom-shaders)
            CUSTOM_SHADERS=true
            shift
            ;;
        --no-custom-shaders)
            CUSTOM_SHADERS=false
            shift
            ;;
        --skip-tests)
            SKIP_TESTS=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "[!] unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

if ! command -v zig >/dev/null 2>&1; then
    echo "[!] zig not found"
    exit 1
fi

if [ ! -d "$SOURCE_DIR" ]; then
    echo "[*] ghostty source not found, cloning into $SOURCE_DIR"
    mkdir -p "$(dirname "$SOURCE_DIR")"
    git clone https://github.com/ghostty-org/ghostty "$SOURCE_DIR"
fi

if [ -n "$GHOSTTY_REF" ]; then
    echo "[*] checking out ghostty ref: $GHOSTTY_REF"
    git -C "$SOURCE_DIR" fetch --tags origin
    git -C "$SOURCE_DIR" checkout "$GHOSTTY_REF"
fi

ARTIFACTS_DIR="$ROOT_DIR/build/artifacts"
XCFRAMEWORK_PATH="$ROOT_DIR/BinaryTarget/GhosttyKit.xcframework"
XCFRAMEWORK_ZIP="$ROOT_DIR/build/GhosttyKit.xcframework.zip"

rm -rf "$ARTIFACTS_DIR" "$XCFRAMEWORK_PATH" "$XCFRAMEWORK_ZIP"
mkdir -p "$ARTIFACTS_DIR" "$(dirname "$XCFRAMEWORK_PATH")"

export GHOSTTY_CUSTOM_SHADERS="$CUSTOM_SHADERS"

echo "[*] zig version: $(zig version)"
echo "[*] ghostty source: $SOURCE_DIR"
echo "[*] platform groups: $PLATFORMS"
echo "[*] custom shaders: $CUSTOM_SHADERS"

OLD_IFS=$IFS
IFS=','
set -- $PLATFORMS
IFS=$OLD_IFS

for platform_group in "$@"; do
    platform_group=$(echo "$platform_group" | xargs)
    [ -n "$platform_group" ] || continue
    ./Script/build-platform.sh "$SOURCE_DIR" "$platform_group" "$ARTIFACTS_DIR"
done

./Script/merge-xcframework.sh \
    "$ARTIFACTS_DIR" \
    "$XCFRAMEWORK_PATH" \
    "$XCFRAMEWORK_ZIP"

if [ -n "$DOWNLOAD_URL" ]; then
    ./Script/build-manifest.sh "$XCFRAMEWORK_ZIP" "$DOWNLOAD_URL"
fi

if [ "$SKIP_TESTS" -eq 0 ]; then
    ./Script/test.sh
    swift test
fi

echo "[*] xcframework: $XCFRAMEWORK_PATH"
echo "[*] zip: $XCFRAMEWORK_ZIP"
