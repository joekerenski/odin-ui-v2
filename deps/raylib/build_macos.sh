#!/bin/sh
# Build macos/libraylib.a on a Mac: raylib 6.0, the version these bindings
# match, universal (arm64 + x86_64), macOS 11+. The bindings link it once it
# exists, and the compiler's vendor:raylib lib until then. Commit the result
# and update README.md here.
#
# Needs the Xcode command line tools (clang, make, lipo) and git.
set -eu
cd "$(dirname "$0")"

TAG=6.0
COMMIT=dbc56a87da87d973a9c5baa4e7438a9d20121d28
MIN_MACOS=11.0

if [ "$(uname -s)" != Darwin ]; then
	echo "build_macos.sh runs on macOS" >&2
	exit 1
fi

SRC=$(mktemp -d)
trap 'rm -rf "$SRC"' EXIT

git clone --quiet --depth 1 --branch "$TAG" https://github.com/raysan5/raylib "$SRC"
got=$(git -C "$SRC" rev-parse HEAD)
if [ "$got" != "$COMMIT" ]; then
	echo "raylib $TAG is $got, expected $COMMIT" >&2
	exit 1
fi

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
echo "macos/libraylib.a: raylib $TAG ($COMMIT), $(lipo -archs macos/libraylib.a), macOS $MIN_MACOS+, $(cc --version | head -1)"
shasum -a 256 macos/libraylib.a
