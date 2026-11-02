#!/bin/sh
#
# build.sh
# scores - a shelf of music, built as a web page
#
# (C) Copyright 2026 Sebastien Tricaud
#
# Permission is hereby granted, free of charge, under the terms of the MIT
# licence; see the LICENSE file at the root of this repository.
#
# Turns this repository of .gscore files into a site anybody can open.
#
# Everything here is static, which is why this can live on GitHub Pages
# with no server behind it: gscore writes a page that plays the music by
# itself, and a .gscore file is also a valid PDF, so one file is both the
# score and its printable copy.
#
# Scores are found wherever they are. Put them in folders that mean
# something to you; the folder travels with the score to the shelf and can
# be searched for, and nothing here needs telling about it.
#
# If there is a soundfont to record through, each score is also recorded —
# by gscore, here, once — and its page plays that instead of synthesising
# the music in the browser. The page's own player is one oscillator a note:
# fine for a minuet, and nothing like an orchestra. A recording is the
# instruments, and it is streamed rather than parsed, so a symphony starts
# before it has finished arriving. Without a soundfont the shelf is built
# exactly as it was, with pages that make their own sound.
#
# What comes out:
#
#     site/index.html              the shelf
#     site/scores.json             what is on it
#     site/font.otf, player.js     fetched once for the whole site
#     site/<path>/cover.png        the first page
#     site/<path>/play.html        the score, playable
#     site/<path>/audio.m4a        the recording, if one was made
#     site/<path>/<name>.gscore    the file, which is also the PDF
#
# Needs: gscore, and pdftoppm from poppler-utils. For the recordings, a
# soundfont and ffmpeg; without either, the pages synthesise as before.
#
# Usage: ./build.sh [path-to-gscore]
#
# Environment:
#
#     GSCORE_SOUNDFONT   the .sf2 to record through. Unset looks in the
#                        usual places; set to "none" turns recording off.
#     AUDIO_CACHE        where recordings are kept between builds.
#                        Default .audio-cache here.
#
# Recording is the slow part by a long way — the ninth symphony is about
# three quarters of an hour of audio and takes about as long to render as it
# does to play — so a recording is kept under AUDIO_CACHE against a hash of
# the score that produced it, and a score that has not changed since the
# last build is not recorded again. In CI that directory wants to be a
# cache; the first build after adding a symphony is a long one and every
# build after it is not.

set -eu

GSCORE="${1:-gscore}"
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/site"

have() { command -v "$1" >/dev/null 2>&1 || [ -x "$1" ]; }
have "$GSCORE" || { echo "build.sh: cannot run '$GSCORE' — pass the path to it" >&2; exit 1; }
# Checked before anything is written, because a build that lays down
# twenty pages and then stops is worse than one that does not start.
have pdftoppm || { echo "build.sh: pdftoppm is not here — it is in poppler-utils" >&2; exit 1; }

# ── the soundfont to record through, if there is one ────────────────────────
#
# Looked for rather than required. A shelf with no soundfont about is a shelf
# of pages that make their own sound, which is what this was before and is
# still worth publishing; it is not a reason to refuse to build.
SOUNDFONT="${GSCORE_SOUNDFONT-}"
if [ "$SOUNDFONT" = none ]; then
	SOUNDFONT=""
elif [ -z "$SOUNDFONT" ]; then
	# Where a soundfont is on the machines this runs on: the Debian and
	# Ubuntu packages first, because that is what CI installs, then the
	# places gscore itself looks on a desktop.
	for cand in \
		/usr/share/sounds/sf2/FluidR3_GM.sf2 \
		/usr/share/sounds/sf2/TimGM6mb.sf2 \
		/usr/share/soundfonts/default.sf2 \
		"$HOME/Library/Application Support/Gscore/soundfonts/GeneralUser GS.sf2" \
		"$HOME/.local/share/soundfonts/GeneralUser GS.sf2"
	do
		[ -f "$cand" ] && { SOUNDFONT=$cand; break; }
	done
fi
# ffmpeg too: gscore records FLAC, which is right for keeping and far too
# large to serve — three quarters of an hour of orchestra is 230 MB of it,
# and 56 MB once encoded. Without something to encode with there is nothing
# worth publishing, so the recording is skipped rather than half done.
if [ -n "$SOUNDFONT" ] && ! have ffmpeg; then
	echo "build.sh: no ffmpeg, so the scores will not be recorded" >&2
	SOUNDFONT=""
fi
if [ -n "$SOUNDFONT" ]; then
	echo "recording through $(basename "$SOUNDFONT")"
else
	echo "no soundfont: the pages will synthesise their own sound"
fi

AUDIO_CACHE="${AUDIO_CACHE:-$HERE/.audio-cache}"
[ -n "$SOUNDFONT" ] && mkdir -p "$AUDIO_CACHE"

# What a score hashes to, which is what its recording is filed under. The
# soundfont is in the key as well: changing it should change the sound, and a
# cache that ignored it would serve yesterday's instruments for ever.
sumof() {
	if have sha256sum; then
		{ cat "$1"; printf '%s' "$(basename "$SOUNDFONT")"; } | sha256sum | cut -d' ' -f1
	else
		{ cat "$1"; printf '%s' "$(basename "$SOUNDFONT")"; } | shasum -a 256 | cut -d' ' -f1
	fi
}

# record makes the recording for one score, or finds it already made.
#   record <score file> <where to put the .m4a>
record() {
	_src=$1
	_dst=$2
	_key=$(sumof "$_src")
	_kept="$AUDIO_CACHE/$_key.m4a"

	if [ -f "$_kept" ]; then
		cp "$_kept" "$_dst"
		echo "    recording: from the cache"
		return 0
	fi

	# FLAC first because that is what gscore writes, then encoded for
	# serving. AAC rather than Opus: every browser plays it, Safari
	# included, and a recording nobody can hear is not an improvement.
	# +faststart puts the index at the front, so playing can begin on the
	# first part of the file instead of waiting for all of it.
	_flac=$(mktemp "${TMPDIR:-/tmp}/gscore-rec.XXXXXX") || return 1
	mv "$_flac" "$_flac.flac"
	_flac="$_flac.flac"
	echo "    recording (this is the slow part)…"
	if ! "$GSCORE" -o "$_flac" -soundfont "$SOUNDFONT" "$_src" \
		</dev/null >/dev/null 2>&1; then
		echo "    recording failed; the page will synthesise instead" >&2
		rm -f "$_flac"
		return 1
	fi
	# -nostdin, and stdin closed, because ffmpeg reads it for keystrokes
	# unless told not to. See the note on the list of scores below: it ate
	# them.
	if ! ffmpeg -nostdin -v error -y -i "$_flac" -c:a aac -b:a 128k \
		-movflags +faststart "$_dst" </dev/null >/dev/null 2>&1; then
		echo "    encoding failed; the page will synthesise instead" >&2
		rm -f "$_flac" "$_dst"
		return 1
	fi
	rm -f "$_flac"
	cp "$_dst" "$_kept"
	return 0
}

rm -rf "$OUT"
mkdir -p "$OUT"

# The font and the player once for the whole site rather than inside every
# page. The font is most of a megabyte and a page is tens of kilobytes, so
# this is the difference between a shelf that loads and one that does not.
"$GSCORE" -o "$OUT/font.otf" >/dev/null
"$GSCORE" -o "$OUT/player.js" >/dev/null

esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

: > "$OUT/.rows"
: > "$OUT/.skipped"

# Everywhere but the build's own output and git's. read -r so that a folder
# or a piece with a space in its name is one name and not two, which is most
# of them.
#
# The list goes into a file and the loop reads it on a descriptor of its own,
# rather than coming down a pipe into the loop's stdin.
#
# Down a pipe, the scores not yet read are the loop's standard input, and
# anything inside the loop that reads standard input eats them. ffmpeg does:
# it watches stdin for keystrokes unless told not to. So every score that was
# recorded swallowed the line after it, and the build then looked for a score
# at half a path — "me/runner/work/..." with the front of it gone. No such
# file, and the report for a file that is not there is that it is empty, so
# the shelf quietly came out with Beethoven's ninth and Chopin's nocturne
# missing and said both files were empty. They were 8 MB and 597 KB.
#
# ffmpeg is told not to as well, below. This is the half of the fix that does
# not have to be remembered again the next time something is added here.
list="$OUT/.list"
find "$HERE" -name '*.gscore' -type f \
	-not -path "$OUT/*" -not -path "$HERE/.git/*" -print |
	LC_ALL=C sort > "$list"

while IFS= read -r file <&3; do
	rel=${file#"$HERE"/}                   # classical/bach/prelude.gscore
	dir=$(dirname "$rel")                  # classical/bach
	[ "$dir" = "." ] && dir=""
	name=$(basename "$rel" .gscore)        # prelude

	# The folders are kept, so two pieces called "prelude" in different
	# folders are two pieces and not one overwriting the other.
	slugdir=$(printf '%s' "$dir" | tr 'A-Z ' 'a-z-' | tr -cd 'a-z0-9._/-')
	slugname=$(printf '%s' "$name" | tr 'A-Z ' 'a-z-' | tr -cd 'a-z0-9._-')
	slug=${slugdir:+$slugdir/}$slugname
	# How far back up to the shared font and player from inside it.
	up=$(printf '%s' "$slug" | tr -cd '/' | sed 's#/#../#g')../

	mkdir -p "$OUT/$slug"
	echo "  $rel"

	# What the score says about itself. -describe reads the file without
	# the shelf having to open the archive, which is why gscore prints
	# the description and the tags there.
	#
	# A score gscore cannot read is reported and stepped over, not a
	# reason to stop. A shelf of thirty pieces must not be undone by one
	# file that was still copying when the build began — which is how
	# this was found: an empty file, dropped in and picked up a moment
	# too early.
	if ! info=$("$GSCORE" -describe "$file" 2>&1); then
		why=$(printf '%s' "$info" | sed 's/^gscore: //' | head -1)
		# A file that is not there and a file with nothing in it are
		# different problems, and saying "empty" for both hid a real one:
		# the loop was being handed half a path, and the shelf reported two
		# perfectly good scores as empty files for an afternoon.
		if [ ! -e "$file" ]; then
			why="there is no file at $file"
		elif [ ! -s "$file" ]; then
			why="the file is empty"
		fi
		echo "    skipped: $why" >&2
		printf '%s\t%s\n' "$rel" "$why" >> "$OUT/.skipped"
		rm -rf "$OUT/$slug"
		continue
	fi
	field() { printf '%s\n' "$info" | sed -n "s/^$1  *//p" | head -1; }
	title=$(field title); [ -n "$title" ] || title="$name"

	# The score itself, which is also its PDF: one file, two uses.
	cp "$file" "$OUT/$slug/$name.gscore"

	# The first page, as the picture the shelf is read by.
	"$GSCORE" -o "$OUT/$slug/.cover.pdf" "$file" >/dev/null
	pdftoppm -r 80 -f 1 -l 1 -png -singlefile "$OUT/$slug/.cover.pdf" "$OUT/$slug/cover"
	pages=$(pdfinfo "$OUT/$slug/.cover.pdf" 2>/dev/null | sed -n 's/^Pages: *//p')
	rm -f "$OUT/$slug/.cover.pdf"

	# The recording, if there is a soundfont to make one through. It sits
	# beside the page rather than inside it, so the page is small and the
	# sound is streamed.
	audio=""
	if [ -n "$SOUNDFONT" ]; then
		if record "$file" "$OUT/$slug/audio.m4a"; then
			audio="audio.m4a"
		else
			rm -f "$OUT/$slug/audio.m4a"
		fi
	fi

	# The playable page, with the font and the player left outside it.
	#
	# With a recording the page plays that; without one it synthesises, as
	# it always did. -audio "" is the same as not passing it, so this is one
	# call either way.
	"$GSCORE" -o "$OUT/$slug/play.html" \
		-font "${up}font.otf" -script "${up}player.js" \
		-audio "$audio" "$file" >/dev/null

	taglist=$(field tags | tr ',' '\n' | sed 's/^ *//; s/ *$//' |
		grep -v '^$' | sed 's/"/\\"/g; s/.*/"&"/' | paste -sd, -)
	printf '{"slug":"%s","file":"%s","folder":"%s","title":"%s","composer":"%s","description":"%s","pages":%s,"tags":[%s]}\n' \
		"$(esc "$slug")" "$(esc "$name.gscore")" "$(esc "$dir")" \
		"$(esc "$title")" "$(esc "$(field composer)")" \
		"$(esc "$(field description)")" "${pages:-0}" "$taglist" \
		>> "$OUT/.rows"
done 3< "$list"
rm -f "$list"

# The shelf's own list, sorted the way a shelf is read. The page can sort
# it again any way it likes.
{
	printf '[\n'
	LC_ALL=C sort "$OUT/.rows" | sed '$ !s/$/,/'
	printf ']\n'
} > "$OUT/scores.json"
rm -f "$OUT/.rows"

cp "$HERE/index.html" "$OUT/index.html"
n=$(grep -c '"slug"' "$OUT/scores.json" || true)
skipped=$(wc -l < "$OUT/.skipped" | tr -d ' ')
echo "built $n score(s) into $OUT"
if [ "$skipped" -gt 0 ]; then
	echo "$skipped could not be read:" >&2
	sed 's/^/  /; s/\t/: /' "$OUT/.skipped" >&2
fi
rm -f "$OUT/.skipped"
[ "$n" -gt 0 ] || echo "build.sh: no .gscore files found under $HERE" >&2
