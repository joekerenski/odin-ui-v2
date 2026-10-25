#!/bin/sh
# Build macos/libraylib.a on a Mac from the raylib commit these bindings
# match, universal (arm64 + x86_64), macOS 11+. The result is committed;
# rerun this only to change the raylib version or build flags, then update
# README.md here.
#
# Needs the Xcode command line tools (clang, make, lipo) and git.
set -eu
cd "$(dirname "$0")"

# raylib master after the 6.2 release: a pinned commit, not a tag. To move
# it, change both scripts, update the bindings (see README.md), and rebuild.
VERSION=6.5-dev
COMMIT=debc1f6b1f86ca12119824f15974758d2d875394
MIN_MACOS=11.0

if [ "$(uname -s)" != Darwin ]; then
	echo "build_macos.sh runs on macOS" >&2
	exit 1
fi

SRC=$(mktemp -d)
trap 'rm -rf "$SRC"' EXIT

# Exactly that commit, without the history: GitHub serves a commit by id.
git -C "$SRC" init --quiet
git -C "$SRC" fetch --quiet --depth 1 https://github.com/raysan5/raylib "$COMMIT"
git -C "$SRC" checkout --quiet FETCH_HEAD

for arch in arm64 x86_64; do
	make -C "$SRC/src" clean >/dev/null
	make -C "$SRC/src" -j"$(sysctl -n hw.ncpu)" \
		PLATFORM=PLATFORM_DESKTOP \
		RAYLIB_LIBTYPE=STATIC \
		RAYLIB_BUILD_MODE=RELEASE \
		CUSTOM_CFLAGS="-arch $arch -mmacosx-version-min=$MIN_MACOS"
	cp "$SRC/src/libraylib.a" "$SRC/libraylib-$arch.a"
done

mkdir -p macos
lipo -create "$SRC/libraylib-arm64.a" "$SRC/libraylib-x86_64.a" -output macos/libraylib.a
echo "macos/libraylib.a: raylib $VERSION ($COMMIT), $(lipo -archs macos/libraylib.a), macOS $MIN_MACOS+, $(cc --version | head -1)"
shasum -a 256 macos/libraylib.a
