#!/bin/sh
# Build the Linux libraylib.a for this machine's arch (linux/ for x86_64,
# linux-arm64/ for aarch64) from the raylib commit these bindings match,
# with GLFW's X11 and Wayland backends. GLFW picks Wayland when WAYLAND_DISPLAY
# is set and falls back to X11. The result is committed; rerun this only to
# change the raylib version or build flags, then update README.md here.
#
# Needs a C compiler, make, git, wayland-scanner, and the X11 and Wayland dev
# headers (Arch: base-devel wayland libxkbcommon libx11 libxrandr libxinerama
# libxcursor libxi mesa).
set -eu
cd "$(dirname "$0")"

# raylib master after the 6.2 release: a pinned commit, not a tag. To move
# it, change both scripts, update the bindings (see README.md), and rebuild.
VERSION=6.5-dev
COMMIT=debc1f6b1f86ca12119824f15974758d2d875394

case "$(uname -m)" in
	x86_64) OUT=linux ;;
	aarch64 | arm64) OUT=linux-arm64 ;;
	*) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

SRC=$(mktemp -d)
trap 'rm -rf "$SRC"' EXIT

# Exactly that commit, without the history: GitHub serves a commit by id.
git -C "$SRC" init --quiet
git -C "$SRC" fetch --quiet --depth 1 https://github.com/raysan5/raylib "$COMMIT"
git -C "$SRC" checkout --quiet FETCH_HEAD

make -C "$SRC/src" -j"$(nproc)" \
	PLATFORM=PLATFORM_DESKTOP \
	RAYLIB_LIBTYPE=STATIC \
	RAYLIB_BUILD_MODE=RELEASE \
	GLFW_LINUX_ENABLE_X11=TRUE \
	GLFW_LINUX_ENABLE_WAYLAND=TRUE
mkdir -p "$OUT"
cp "$SRC/src/libraylib.a" "$OUT/libraylib.a"
echo "$OUT/libraylib.a: raylib $VERSION ($COMMIT), X11 + Wayland, $(cc --version | head -1)"
sha256sum "$OUT/libraylib.a"
