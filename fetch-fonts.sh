#!/bin/sh
# Download the optional fonts into fonts/ (they are not committed: all are
# SIL OFL from Google Fonts). raylib draws only a variable font's default
# instance (Cormorant's is a faint Light), so variable families are cut into
# static instances with fonttools (pip install fonttools). Files already in
# fonts/ are kept, so this is cheap to run before every build.
#
#   ./fetch-fonts.sh
set -eu
cd "$(dirname "$0")/fonts"

BASE=https://raw.githubusercontent.com/google/fonts/main/ofl

# fetch DIR FILE OUT: one file from google/fonts, unless OUT exists.
fetch() {
	[ -f "$3" ] && return 0
	echo "fetch $3"
	curl -fsSL "$BASE/$1/$2" -o "$3.part" && mv "$3.part" "$3"
}

# cut VARIABLE OUT AXIS=VALUE...: a static instance, unless OUT exists.
cut() {
	src=$1 out=$2
	shift 2
	[ -f "$out" ] && return 0
	if ! command -v fonttools >/dev/null 2>&1; then
		echo "fetch-fonts: $out needs fonttools (pip install fonttools)" >&2
		return 1
	fi
	echo "cut   $out"
	fonttools varLib.instancer -q --static --update-name-table "$src" "$@" -o "$out" 2>/dev/null ||
		fonttools varLib.instancer -q --static "$src" "$@" -o "$out"
}

# family DIR NAME: the license, saved as NAME-LICENSE.txt.
license() {
	fetch "$1" OFL.txt "$2-LICENSE.txt"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# variable FAMILY_DIR FILE: download a variable font into the temp dir once.
variable() {
	[ -f "$tmp/$2" ] || curl -fsSL "$BASE/$1/$(printf '%s' "$2" | sed 's/\[/%5B/; s/\]/%5D/')" -o "$tmp/$2"
	echo "$tmp/$2"
}

need() {
	for f in "$@"; do [ -f "$f" ] || return 0; done
	return 1
}

license spectral Spectral
fetch spectral Spectral-Regular.ttf Spectral-Regular.ttf
fetch spectral Spectral-Medium.ttf Spectral-Medium.ttf

license ebgaramond EBGaramond
if need EBGaramond-Regular.ttf EBGaramond-Medium.ttf; then
	v=$(variable ebgaramond 'EBGaramond[wght].ttf')
	cut "$v" EBGaramond-Regular.ttf wght=400
	cut "$v" EBGaramond-Medium.ttf wght=500
fi

license cormorantgaramond CormorantGaramond
if need CormorantGaramond-Medium.ttf CormorantGaramond-SemiBold.ttf; then
	v=$(variable cormorantgaramond 'CormorantGaramond[wght].ttf')
	cut "$v" CormorantGaramond-Medium.ttf wght=500
	cut "$v" CormorantGaramond-SemiBold.ttf wght=600
fi

license newsreader Newsreader
if need Newsreader-Regular.ttf Newsreader-Medium.ttf Newsreader-SemiBold.ttf; then
	v=$(variable newsreader 'Newsreader[opsz,wght].ttf')
	cut "$v" Newsreader-Regular.ttf wght=400 opsz=16
	cut "$v" Newsreader-Medium.ttf wght=500 opsz=16
	cut "$v" Newsreader-SemiBold.ttf wght=600 opsz=16
fi
if need Newsreader-Italic.ttf Newsreader-SemiBoldItalic.ttf; then
	v=$(variable newsreader 'Newsreader-Italic[opsz,wght].ttf')
	cut "$v" Newsreader-Italic.ttf wght=400 opsz=16
	cut "$v" Newsreader-SemiBoldItalic.ttf wght=600 opsz=16
fi

license jetbrainsmono JetBrainsMono
if need JetBrainsMono-Regular.ttf JetBrainsMono-Medium.ttf; then
	v=$(variable jetbrainsmono 'JetBrainsMono[wght].ttf')
	cut "$v" JetBrainsMono-Regular.ttf wght=400
	cut "$v" JetBrainsMono-Medium.ttf wght=500
fi
