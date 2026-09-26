#!/bin/sh
# Build the app into a standalone binary (the font is embedded).
#
#   ./build.sh          optimized: ./graph
#   ./build.sh debug    symbols, no optimization: ./graph-debug (for gdb/lldb)
set -eu
cd "$(dirname "$0")"

case "${1:-release}" in
	release) odin build app -out:graph -o:speed ;;
	debug)   odin build app -out:graph-debug -debug -o:none ;;
	*)       echo "usage: $0 [release|debug]" >&2; exit 1 ;;
esac
