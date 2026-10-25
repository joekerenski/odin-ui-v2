#!/bin/sh
# Build Clay's static libraries from the commit clay.odin matches, the way
# Clay's own bindings/odin/build-clay-lib.sh does, for every target at once
# (Clay is freestanding C, so one clang cross-compiles them all). The
# results are committed; rerun this only to move Clay, then update
# clay.odin from the same commit's bindings/odin/clay-odin/clay.odin and
# reapply the local addition at its end (exported OpenElementWithId and
# CloseElement).
#
# Needs clang, ar and git. linux/clay.a also needs llvm-ar (LLVM_AR): GNU ld
# wants a GNU-format archive with its own symbol index, and macOS's ar writes
# a BSD one. Without it the committed linux/clay.a, Clay's own build of this
# commit byte for byte, is left as it is.
set -eu
cd "$(dirname "$0")"

COMMIT=e6cc36941ab2af5d81107617039d6f527a1c660b
CLANG=${CLANG:-clang}
LLVM_AR=${LLVM_AR:-$(command -v llvm-ar || true)}

SRC=$(mktemp -d)
trap 'rm -rf "$SRC"' EXIT

git -C "$SRC" init --quiet
git -C "$SRC" fetch --quiet --depth 1 https://github.com/nicbarker/clay "$COMMIT"
git -C "$SRC" checkout --quiet FETCH_HEAD
cp "$SRC/clay.h" "$SRC/clay.c"

build() { # target, output, ar
	"$CLANG" -c -DCLAY_IMPLEMENTATION -ffreestanding -static -fPIC -O3 -target "$1" "$SRC/clay.c" -o "$SRC/clay.o"
	mkdir -p "$(dirname "$2")"
	rm -f "$2"
	"${3:-ar}" rcs "$2" "$SRC/clay.o"
}

build x86_64-apple-macos11 macos/clay.a
build arm64-apple-macos11 macos-arm64/clay.a
if [ -n "$LLVM_AR" ]; then
	build x86_64-unknown-linux-gnu linux/clay.a "$LLVM_AR"
else
	echo "no llvm-ar: linux/clay.a left as it is"
fi

echo "Clay $COMMIT, $("$CLANG" --version | head -1)"
shasum -a 256 macos/clay.a macos-arm64/clay.a linux/clay.a
