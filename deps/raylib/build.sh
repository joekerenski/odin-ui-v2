#!/bin/sh
# Build this platform's libraylib.a from the raylib commit these bindings
# match. The results are committed; rerun this only to change the raylib
# version or build flags, then update README.md here.
#
#   macOS  macos/libraylib.a, universal (arm64 + x86_64), macOS 11+.
#          Needs the Xcode command line tools and git.
#   Linux  linux/libraylib.a (x86_64), GLFW's X11 and Wayland backends: GLFW
#          picks Wayland when WAYLAND_DISPLAY is set and falls back to X11.
#          Needs a C compiler, make, git, wayland-scanner, and the X11 and
#          Wayland dev headers (Arch: base-devel wayland libxkbcommon libx11
#          libxrandr libxinerama libxcursor libxi mesa).
set -eu
cd "$(dirname "$0")"

# raylib master after the 6.2 release: a pinned commit, not a tag. To move
# it, change it here, rebuild on both platforms, and check the bindings
# against the new headers (README.md).
VERSION=6.5-dev
COMMIT=debc1f6b1f86ca12119824f15974758d2d875394
MIN_MACOS=11.0

SRC=$(mktemp -d)
trap 'rm -rf "$SRC"' EXIT

# Exactly that commit, without the history: GitHub serves a commit by id.
git -C "$SRC" init --quiet
git -C "$SRC" fetch --quiet --depth 1 https://github.com/raysan5/raylib "$COMMIT"
git -C "$SRC" checkout --quiet FETCH_HEAD

case "$(uname -s)" in
Darwin)
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
	;;
Linux)
	make -C "$SRC/src" -j"$(nproc)" \
		PLATFORM=PLATFORM_DESKTOP \
		RAYLIB_LIBTYPE=STATIC \
		RAYLIB_BUILD_MODE=RELEASE \
		GLFW_LINUX_ENABLE_X11=TRUE \
		GLFW_LINUX_ENABLE_WAYLAND=TRUE
	mkdir -p linux
	cp "$SRC/src/libraylib.a" linux/libraylib.a
	echo "linux/libraylib.a: raylib $VERSION ($COMMIT), X11 + Wayland, $(cc --version | head -1)"
	sha256sum linux/libraylib.a
	;;
*)
	echo "build.sh runs on macOS or Linux" >&2
	exit 1
	;;
esac
