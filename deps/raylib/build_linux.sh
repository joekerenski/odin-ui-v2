#!/bin/sh
# Build the Linux libraylib.a for this machine's arch (linux/ for x86_64,
# linux-arm64/ for aarch64) from raylib 6.0, the version these bindings match,
# with GLFW's X11 and Wayland backends. GLFW picks Wayland when WAYLAND_DISPLAY
# is set and falls back to X11. The result is committed; rerun this only to
# change the raylib version or build flags, then update README.md here.
#
# Needs a C compiler, make, git, wayland-scanner, and the X11 and Wayland dev
# headers (Arch: base-devel wayland libxkbcommon libx11 libxrandr libxinerama
# libxcursor libxi mesa).
set -eu
cd "$(dirname "$0")"

TAG=6.0
COMMIT=dbc56a87da87d973a9c5baa4e7438a9d20121d28

case "$(uname -m)" in
	x86_64) OUT=linux ;;
	aarch64 | arm64) OUT=linux-arm64 ;;
	*) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

SRC=$(mktemp -d)
trap 'rm -rf "$SRC"' EXIT

git clone --quiet --depth 1 --branch "$TAG" https://github.com/raysan5/raylib "$SRC"
got=$(git -C "$SRC" rev-parse HEAD)
if [ "$got" != "$COMMIT" ]; then
	echo "raylib $TAG is $got, expected $COMMIT" >&2
	exit 1
fi

make -C "$SRC/src" -j"$(nproc)" \
	PLATFORM=PLATFORM_DESKTOP \
	RAYLIB_LIBTYPE=STATIC \
	RAYLIB_BUILD_MODE=RELEASE \
	GLFW_LINUX_ENABLE_X11=TRUE \
	GLFW_LINUX_ENABLE_WAYLAND=TRUE
mkdir -p "$OUT"
cp "$SRC/src/libraylib.a" "$OUT/libraylib.a"
echo "$OUT/libraylib.a: raylib $TAG ($COMMIT), X11 + Wayland, $(cc --version | head -1)"
sha256sum "$OUT/libraylib.a"
