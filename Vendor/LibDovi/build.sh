#!/usr/bin/env bash
# build.sh — cross-compile libdovi for the tvOS and macOS slices and package it as Dovi.xcframework
# Usage: ./build.sh
# Outputs: Dovi.xcframework next to this script (gitignored)
#
# Adapted from superuser404notfound/LibDovi 2.1.0's build.sh. Differences:
#   - the crate comes from dovi_tool tag 2.3.4 (commit 614c816) instead of libdovi-3.4.0. Its dolby_vision is
#     still versioned 3.4.0, plus the changelog's "Unreleased" entry: CM v4.0 level 253 blocks parse (the
#     published 3.4.0 rejects them, so Disney+-style v4.0 RPUs fail), and the C API's DoviDmData gains a
#     `level253` pointer.
#   - three slices only: tvos-arm64, tvos-arm64-simulator, macos-arm64_x86_64 (fat). iOS and visionOS
#     builds of the engine need the published LibDovi.
#   - the local patches in patches/ are applied on top of the pinned commit, in name order (see README.md).
#
# Requires Rust stable with the targets below and cargo-c (cargo-c 0.10.25 is the last for rustc 1.96).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
CARGO_DIR="$BUILD_DIR/cargo"
XCFW_OUT="$SCRIPT_DIR/Dovi.xcframework"

export PATH="$HOME/.cargo/bin:$PATH"

if ! command -v cargo &>/dev/null; then
    echo "ERROR: cargo not found. Install Rust via https://rustup.rs" >&2
    exit 1
fi
if ! command -v cargo-cbuild &>/dev/null; then
    echo "ERROR: cargo-c not found. Install with: cargo install cargo-c (0.10.25 --locked on rustc 1.96)" >&2
    exit 1
fi

echo "==> cargo version: $(cargo --version)"

echo "==> Adding rustup targets..."
rustup target add aarch64-apple-tvos aarch64-apple-tvos-sim x86_64-apple-darwin

DOVI_TAG="2.3.4"
DOVI_COMMIT="614c816"
DOVI_REPO_DIR="$BUILD_DIR/dovi_tool"

# A checkout at a different tag than the one asked for is stale: the clone below is skipped whenever the
# directory exists, so bumping DOVI_TAG alone would rebuild the old crate. Membership, not `git describe`:
# the repo carries two tag series on the same commits (the CLI's `2.3.x` and the library's `libdovi-3.x`).
if [ -d "$DOVI_REPO_DIR" ] && ! git -C "$DOVI_REPO_DIR" tag --points-at HEAD 2>/dev/null | grep -qx "$DOVI_TAG"; then
    echo "==> dovi_tool is not at $DOVI_TAG: discarding and re-cloning"
    rm -rf "$DOVI_REPO_DIR"
fi

if [ -d "$DOVI_REPO_DIR" ]; then
    echo "==> dovi_tool already cloned, skipping clone"
else
    mkdir -p "$BUILD_DIR"
    echo "==> Cloning dovi_tool at tag $DOVI_TAG..."
    git clone --depth 1 --branch "$DOVI_TAG" \
        https://github.com/quietvoid/dovi_tool.git \
        "$DOVI_REPO_DIR"
fi
case "$(git -C "$DOVI_REPO_DIR" rev-parse HEAD)" in
    "$DOVI_COMMIT"*) ;;
    *) echo "ERROR: dovi_tool tag $DOVI_TAG is not commit $DOVI_COMMIT (moved upstream?)" >&2; exit 1 ;;
esac

# The patches are one series, checked as a whole: a later patch can change lines an earlier one wrote, so an earlier
# patch alone no longer reverses on a checkout that carries the series. The working tree is staged into a scratch
# index and the series reversed there, newest first; if that lands exactly on the pinned commit, the checkout already
# carries the series and a rebuild is a no-op. Otherwise the series is applied, to a clean checkout only, so a build
# never mixes the series with other edits.
PATCHES=()
for patch in "$SCRIPT_DIR"/patches/*.patch; do
    [ -e "$patch" ] && PATCHES+=("$patch")
done
series_applied() {
    local scratch
    scratch=$(mktemp -d)
    local index="$scratch/index"
    local ok=1
    if GIT_INDEX_FILE="$index" git -C "$DOVI_REPO_DIR" read-tree HEAD \
        && GIT_INDEX_FILE="$index" git -C "$DOVI_REPO_DIR" add -A; then
        ok=0
        for (( i = ${#PATCHES[@]} - 1; i >= 0; i-- )); do
            GIT_INDEX_FILE="$index" git -C "$DOVI_REPO_DIR" apply --cached --reverse "${PATCHES[$i]}" 2>/dev/null \
                || { ok=1; break; }
        done
        [ "$ok" -eq 0 ] && { GIT_INDEX_FILE="$index" git -C "$DOVI_REPO_DIR" diff --cached --quiet HEAD || ok=1; }
    fi
    rm -f "$index"
    rmdir "$scratch"
    return "$ok"
}
if [ ${#PATCHES[@]} -eq 0 ]; then
    echo "==> No local patches"
elif series_applied; then
    echo "==> Patch series already applied: $(for p in "${PATCHES[@]}"; do basename "$p"; done | tr '\n' ' ')"
elif [ -z "$(git -C "$DOVI_REPO_DIR" status --porcelain)" ]; then
    for patch in "${PATCHES[@]}"; do
        echo "==> Applying $(basename "$patch")"
        git -C "$DOVI_REPO_DIR" apply "$patch"
    done
else
    echo "ERROR: $DOVI_REPO_DIR carries changes that are not exactly the patch series in patches/." >&2
    echo "       Write them into a patch (see README.md) or restore the checkout, then build again." >&2
    exit 1
fi

CRATE_DIR="$DOVI_REPO_DIR/dolby_vision"
if [ ! -f "$CRATE_DIR/Cargo.toml" ]; then
    echo "ERROR: dolby_vision crate not found at $CRATE_DIR" >&2
    exit 1
fi
grep -q "level253" "$CRATE_DIR/src/c_structs/extension_metadata.rs" || {
    echo "ERROR: this dolby_vision has no level 253 support" >&2; exit 1; }

# build_slice <triple> <sdk-or-empty> <min-cflag-or-empty>
build_slice() {
    local triple="$1" sdk="$2" mincflag="$3"
    echo "==> Building $triple..."
    if [ -z "$sdk" ]; then
        ( cd "$CRATE_DIR"
          cargo cbuild --release --features capi \
            --target "$triple" --target-dir "$CARGO_DIR" )
    else
        local sdkpath cc
        sdkpath="$(xcrun --sdk "$sdk" --show-sdk-path)"
        cc="$(xcrun --sdk "$sdk" --find clang)"
        ( cd "$CRATE_DIR"
          CC="$cc" CFLAGS="-isysroot $sdkpath $mincflag" \
          cargo cbuild --release --features capi \
            --target "$triple" --target-dir "$CARGO_DIR" )
    fi
}

build_slice aarch64-apple-tvos     appletvos        "-mtvos-version-min=17.0"
build_slice aarch64-apple-tvos-sim appletvsimulator "-mtvos-simulator-version-min=17.0"
build_slice aarch64-apple-darwin   ""               ""
build_slice x86_64-apple-darwin    ""               ""

# Locate a built static library for a triple.
find_lib() {
    local triple="$1"
    local candidate="$CARGO_DIR/$triple/release/libdovi.a"
    if [ -f "$candidate" ]; then echo "$candidate"; return; fi
    echo "ERROR: libdovi.a not found for $triple" >&2
    exit 1
}

# cargo-c's generated header (cbindgen, under include/), the same for every slice; staged as dovi.h so
# `import Dovi` resolves the module's umbrella header.
find_header() {
    local base="$CARGO_DIR/aarch64-apple-tvos/release" found
    found="$(find "$base" -name "*.h" 2>/dev/null | grep -iE 'rpu_parser|dovi' | head -1)"
    if [ -z "$found" ]; then echo "ERROR: cargo-c header (*.h) not found under $base" >&2; exit 1; fi
    echo "$found"
}

HEADER="$(find_header)"
echo "==> Header: $HEADER"

STAGE_DIR="$BUILD_DIR/xcfw_stage"
rm -rf "$STAGE_DIR"

# stage_slice <slice-name> <.a path>
stage_slice() {
    local name="$1" lib="$2"
    mkdir -p "$STAGE_DIR/$name/Headers"
    cp "$lib" "$STAGE_DIR/$name/libdovi.a"
    cp "$HEADER" "$STAGE_DIR/$name/Headers/dovi.h"
    cat > "$STAGE_DIR/$name/Headers/module.modulemap" << 'MODULEMAP'
module Dovi {
    header "dovi.h"
    export *
}
MODULEMAP
}

mkdir -p "$STAGE_DIR/fat"
lipo -create "$(find_lib aarch64-apple-darwin)" "$(find_lib x86_64-apple-darwin)" -output "$STAGE_DIR/fat/macos.a"

stage_slice macos    "$STAGE_DIR/fat/macos.a"
stage_slice tvos     "$(find_lib aarch64-apple-tvos)"
stage_slice tvos-sim "$(find_lib aarch64-apple-tvos-sim)"

rm -rf "$XCFW_OUT"
echo "==> Assembling Dovi.xcframework..."
xcodebuild -create-xcframework \
    -library "$STAGE_DIR/macos/libdovi.a"    -headers "$STAGE_DIR/macos/Headers" \
    -library "$STAGE_DIR/tvos/libdovi.a"     -headers "$STAGE_DIR/tvos/Headers" \
    -library "$STAGE_DIR/tvos-sim/libdovi.a" -headers "$STAGE_DIR/tvos-sim/Headers" \
    -output "$XCFW_OUT"

echo ""
echo "==> Done. XCFramework at: $XCFW_OUT"
ls "$XCFW_OUT"
for a in "$XCFW_OUT"/*/libdovi.a; do echo "  $a:"; lipo -info "$a" 2>/dev/null | sed 's/^/    /'; done
