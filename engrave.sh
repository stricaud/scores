#!/bin/sh
#
# engrave.sh
# scores - a shelf of music, built as a web page
#
# (C) Copyright 2026 Sebastien Tricaud
#
# Permission is hereby granted, free of charge, under the terms of the MIT
# licence; see the LICENSE file at the root of this repository.
#
# Puts one score on the shelf: the file itself, its cover, a page that plays
# it, a recording if it gets one, and the row the shelf lists it by.
#
# build.sh runs this once for every score, several at a time, and gathers
# the rows afterwards. It is the half of the build that costs anything, and
# it is kept apart from the other half for a reason beyond tidiness: the hash
# of this file is part of the key an engraved score is cached under. Change
# how a score is engraved, here, and every score is engraved again, which is
# right. Change how the shelf finds its scores or reports on them, over in
# build.sh, and nothing is.
#
# Usage: ./engrave.sh FILE
#
# Normally with the environment build.sh sets up, but it runs by itself with
# the same defaults build.sh has, so one score can be tried without building
# the shelf:
#
#     GSCORE=../gscore/gscore ./engrave.sh classical/bach/prelude.gscore
#
# What comes out, under $OUT/<slug>/:
#
#     <name>.gscore    the file, which is also the PDF
#     cover.png        the first page
#     play.html        the score, playable; with play.*.svg beside it when
#                      the drawing is too large to go in
#     audio.m4a        the recording, if one was made
#     .row             its line in scores.json, for build.sh to gather
#     .rel             where it came from, for build.sh to report by
#     .skipped         why it could not be read, if it could not
#     .kept            present when all of it came back from the cache
#
# Environment, all optional; build.sh works these out once and passes them
# down rather than have fifteen hundred copies of this work them out again:
#
#     HERE          the root of the repository. Default: where this file is.
#     OUT           where the shelf is built. Default $HERE/site.
#     GSCORE        the engraver. Default gscore, on the PATH.
#     GSCORE_ID     what the engraver hashes to. Worked out if unset.
#     RECIPE_ID     what this file hashes to. Worked out if unset.
#     SOUNDFONT     the .sf2 to record through. Unset or empty: no recording.
#     AUDIO_CACHE   where recordings are kept. Default $HERE/.audio-cache.
#     BUILD_CACHE   where engraved pages are kept. Default $HERE/.build-cache;
#                   set empty to keep nothing.
#     BIG           how many shapes make a score a large one. Default 50000.
#     SYNTH         folders holding a bulk import, whose scores are left to
#                   synthesise unless they are large. Default "OpenScore-Lieder PDMX".

set -eu

[ $# -eq 1 ] || { echo "usage: engrave.sh FILE" >&2; exit 64; }
file=$1

HERE=${HERE:-$(cd "$(dirname "$0")" && pwd)}
OUT=${OUT:-$HERE/site}
GSCORE=${GSCORE:-gscore}
SOUNDFONT=${SOUNDFONT-}
AUDIO_CACHE=${AUDIO_CACHE:-$HERE/.audio-cache}
BUILD_CACHE=${BUILD_CACHE-$HERE/.build-cache}
BIG=${BIG:-50000}
SYNTH=${SYNTH:-OpenScore-Lieder PDMX}

have() { command -v "$1" >/dev/null 2>&1 || [ -x "$1" ]; }

# The hash of whatever is fed in. sha256sum on Linux, shasum on a Mac.
digest() {
	if have sha256sum; then
		sha256sum | cut -d' ' -f1
	else
		shasum -a 256 | cut -d' ' -f1
	fi
}

# Which gscore, and which recipe, when run by hand. See build.sh for why the
# engraver is the hash of the binary and not the version it prints.
if [ -z "${GSCORE_ID-}" ]; then
	bin=$(command -v "$GSCORE" 2>/dev/null || printf '%s' "$GSCORE")
	if [ -f "$bin" ]; then
		GSCORE_ID=$(digest < "$bin")
	else
		GSCORE_ID=$("$GSCORE" -version 2>/dev/null || echo unknown)
	fi
fi
RECIPE_ID=${RECIPE_ID:-$(digest < "$0")}

# imported says whether a score came out of a bulk import.
imported() {
	for _d in $SYNTH; do
		case "$1" in "$_d"/*) return 0 ;; esac
	done
	return 1
}

# What a score hashes to, which is what its recording is filed under. The
# soundfont is in the key as well: changing it should change the sound, and a
# cache that ignored it would serve yesterday's instruments for ever.
sumof() {
	{ cat "$1"; printf '%s' "$(basename "$SOUNDFONT")"; } | digest
}

# record makes the recording for one score, or finds it already made.
#   record <score file> <where to put the .m4a> <its key, from sumof>
record() {
	_src=$1
	_dst=$2
	_kept="$AUDIO_CACHE/$3.m4a"

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
	# unless told not to. It once ate the list of scores still to build.
	if ! ffmpeg -nostdin -v error -y -i "$_flac" -c:a aac -b:a 128k \
		-movflags +faststart "$_dst" </dev/null >/dev/null 2>&1; then
		echo "    encoding failed; the page will synthesise instead" >&2
		rm -f "$_flac" "$_dst"
		return 1
	fi
	rm -f "$_flac"
	mkdir -p "$AUDIO_CACHE"
	cp "$_dst" "$_kept"
	return 0
}

esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# place puts every file in one folder into another, as hard links where the
# file system allows and as copies where it does not.
#
# Links, because the cache and the shelf are the same bytes twice, and on a
# runner with fourteen gigabytes of disk the second copy of a four-gigabyte
# shelf was the difference between a build and a dead runner. A link costs
# nothing, and nothing here writes into a file once it is made: the shelf is
# cleared and written afresh each build, and the cache only ever gains or
# loses whole entries.
#   place <from> <to>
place() {
	for _f in "$1"/* "$1"/.[!.]*; do
		[ -f "$_f" ] || continue
		ln "$_f" "$2/" 2>/dev/null || cp "$_f" "$2/"
	done
}

# ── where it goes ───────────────────────────────────────────────────────────

case $file in /*) ;; *) file=$(pwd)/$file ;; esac
rel=${file#"$HERE"/}                   # classical/bach/prelude.gscore
dir=$(dirname "$rel")                  # classical/bach
[ "$dir" = "." ] && dir=""
name=$(basename "$rel" .gscore)        # prelude

# The folders are kept, so two pieces called "prelude" in different folders
# are two pieces and not one overwriting the other.
#
# slugof is what one folder or file name becomes in an address: lower case,
# ASCII, nothing a browser would need to escape. A name with no ASCII in
# it — 黄河颂, Золушка — would come out as nothing at all, and two of
# those are one address, which put two scores through one folder at once
# and left neither whole. Such a name goes by a short hash of itself
# instead: not readable, but its own.
slugof() {
	_s=$(printf '%s' "$1" | tr 'A-Z ' 'a-z-' | tr -cd 'a-z0-9._-')
	if [ -z "$_s" ]; then
		_s=$(printf '%s' "$1" | digest | cut -c1-8)
	fi
	printf '%s' "$_s"
}
slugdir=""
if [ -n "$dir" ]; then
	_ifs=$IFS
	IFS=/
	for _part in $dir; do
		slugdir="${slugdir:+$slugdir/}$(slugof "$_part")"
	done
	IFS=$_ifs
fi
slugname=$(slugof "$name")
slug=${slugdir:+$slugdir/}$slugname
# How far back up to the shared font and player from inside it.
up=$(printf '%s' "$slug" | tr -cd '/' | sed 's#/#../#g')../

out="$OUT/$slug"
mkdir -p "$out"
rm -f "$out/.row" "$out/.rel" "$out/.skipped" "$out/.kept" "$out/.audio"
printf '%s' "$rel" > "$out/.rel"
echo "  $rel"

if imported "$rel"; then bulk=1; else bulk=0; fi

# ── what was built last time ────────────────────────────────────────────────
#
# Everything written for a score follows from a handful of things: the score
# itself, the gscore that engraves it, this recipe, where the score sits on
# the shelf — the page reaches back up to the shared font and player, so its
# depth is in it — what it would be recorded through, how many shapes make a
# score large, and whether it came out of a bulk import. Nothing else can
# change what comes out, so that handful is the whole of the key, and it can
# be worked out before any of the work is done — which is what lets the work
# be skipped.
#
# Not in the key: the gscore version string, which does not change between
# builds of changed code, and build.sh, which does not touch what is written.
key=""
kept=""
if [ -n "$BUILD_CACHE" ] && [ -s "$file" ]; then
	key=$({ cat "$file"
		printf '\0%s\0%s\0%s\0%s\0%s\0%s' "$GSCORE_ID" "$RECIPE_ID" "$rel" \
			"${SOUNDFONT:+$(basename "$SOUNDFONT")}" "$BIG" "$bulk"
	} | digest)
	kept="$BUILD_CACHE/$key.page"
fi

# What the score said about itself last time, kept by score and by gscore;
# see below. Named here because a page that comes back from the cache wants
# it kept too: build.sh lets go of whatever a build did not touch.
said=""
if [ -n "$BUILD_CACHE" ] && [ -s "$file" ]; then
	said="$BUILD_CACHE/$({ cat "$file"; printf '%s' "$GSCORE_ID"; } | digest).said"
fi

# The recording is not kept with the page. It has a cache of its own, keyed
# on the score and the soundfont and nothing else, so that a new gscore
# redraws the pages without re-recording three quarters of an hour of
# orchestra. The page remembers which recording it was made for, in .audio,
# and that recording has to be there too for the page to come back.
#
# An entry that is used is touched, so that build.sh can tell it from one
# nothing has asked for since some earlier shelf, and let that one go.
if [ -n "$kept" ] && [ -f "$kept/.row" ]; then
	back=1
	if [ -f "$kept/.audio" ] && [ ! -f "$AUDIO_CACHE/$(cat "$kept/.audio").m4a" ]; then
		echo "    its page is kept but its recording is gone: engraving again"
		back=0
	fi
	if [ "$back" = 1 ]; then
		place "$kept" "$out"
		if [ -f "$out/.audio" ]; then
			cp "$AUDIO_CACHE/$(cat "$out/.audio").m4a" "$out/audio.m4a"
		fi
		cp "$file" "$out/$name.gscore"
		touch "$kept"
		if [ -n "$said" ] && [ -f "$said" ]; then
			touch "$said"
		fi
		: > "$out/.kept"
		echo "    from the cache"
		exit 0
	fi
fi

# ── what the score says about itself ────────────────────────────────────────
#
# -describe saves the shelf opening the archive, which is why gscore prints
# the description and the tags there — and how many shapes the music comes
# to, which is the one thing it has to engrave the score to answer and the
# reason this step takes minutes on a symphony. So the answer is kept, by
# score and by gscore: what it says cannot change while neither of those
# does.
#
# A score gscore cannot read is reported and stepped over, not a reason to
# stop. A shelf of thirty pieces must not be undone by one file that was
# still copying when the build began — which is how this was found: an
# empty file, dropped in and picked up a moment too early.
info=""
if [ -n "$said" ] && [ -f "$said" ]; then
	info=$(cat "$said")
	touch "$said"
fi
if [ -n "$info" ]; then
	:
elif ! info=$("$GSCORE" -describe "$file" 2>&1); then
	why=$(printf '%s' "$info" | sed 's/^gscore: //' | head -1)
	# A file that is not there and a file with nothing in it are different
	# problems, and saying "empty" for both once hid a real one.
	if [ ! -e "$file" ]; then
		why="there is no file at $file"
	elif [ ! -s "$file" ]; then
		why="the file is empty"
	fi
	echo "    skipped: $why" >&2
	printf '%s' "$why" > "$out/.skipped"
	exit 0
elif [ -n "$said" ]; then
	printf '%s\n' "$info" > "$said"
fi
field() { printf '%s\n' "$info" | sed -n "s/^$1  *//p" | head -1; }
title=$(field title); [ -n "$title" ] || title="$name"

# The score itself, which is also its PDF: one file, two uses.
cp "$file" "$out/$name.gscore"

# ── the drawing: in the page, or beside it ──────────────────────────────────
#
# A score the browser can hold goes in, which is one file and nothing to
# fetch. A large one cannot: Beethoven's ninth inline is seventy-four
# megabytes and nine hundred thousand shapes, and a browser given all of them
# spends seconds laying them out and then has nothing left to animate with —
# the music played with the page frozen behind it. In pieces of four systems
# it is about nine thousand shapes at a time and the page opens in a second.
#
# Asked of gscore, not guessed at here. Not from the size of the file: a
# .gscore carries a PDF of itself, so its size says how many pages it is
# rather than how many shapes. And not from staves times bars either, which
# was the first try and is wrong by a factor of seven on the ninth — fifty-
# three staves, most of them resting most of the time, and a bar's rest is
# one shape where a beamed chord is a dozen. gscore engraves it and counts
# what it drew, which is the number a browser will actually be handed.
shapes=$(field shapes)
big=0
[ "${shapes:-0}" -gt "$BIG" ] && big=1

bands=""
if [ "$big" = 1 ]; then
	bands="4"
	echo "    $shapes shapes: the drawing goes beside the page, not in it"
fi

# ── the recording, for the scores that need one ─────────────────────────────
#
# Not for all of them. The player in a page is one oscillator a note, which
# is what it was written to be and is fine for a song: a flute and a piano
# for three minutes comes out as a flute and a piano, near enough. It is a
# symphony it cannot do — fifty-three staves of it sound like a telephone
# exchange, and that is what the recordings are for.
#
# And they are not cheap. A song is five and a half seconds to render and
# encode and a megabyte and a half of audio. An imported corpus is fourteen
# hundred songs, which is two hours of recording and over two gigabytes to
# publish — more than GitHub Pages will serve at all, for music that would
# have played by itself.
#
# So two things get a recording. Anything large, because the page's player
# cannot do it at any quality. And anything you put on the shelf by hand,
# wherever it did not come out of a bulk import: those are the scores
# somebody chose, and they are few enough to be worth the minutes. See SYNTH.
audio=""
akey=""
retry=0
if [ -n "$SOUNDFONT" ] && { [ "$big" = 1 ] || [ "$bulk" = 0 ]; }; then
	akey=$(sumof "$file")
	if record "$file" "$out/audio.m4a" "$akey"; then
		audio="audio.m4a"
	else
		# Not kept, so that it is tried again next time rather than
		# remembered as a page that synthesises.
		rm -f "$out/audio.m4a"
		retry=1
	fi
fi

# ── the cover ───────────────────────────────────────────────────────────────
#
# The first page, as the picture the shelf is read by. A .gscore is a PDF
# with the music inside it, so the first page is already drawn and poppler
# reads it straight from the file — the same picture, to the byte, as
# engraving the score to PDF again and reading that, at none of the cost. On
# a symphony that was most of a minute per score and the slowest of the three
# things gscore was asked to do.
#
# It is the page as the gscore that saved the file drew it, rather than as
# this one would; so is the file the visitor downloads, which is the thing
# the cover is a picture of. A score written without its PDF — an import
# with OPENSCORE_NOPDF set — has nothing to read, and is engraved as before.
pages=$(pdfinfo "$file" 2>/dev/null | sed -n 's/^Pages: *//p')
if [ -n "$pages" ] &&
	pdftoppm -r 80 -f 1 -l 1 -png -singlefile "$file" "$out/cover" 2>/dev/null &&
	[ -f "$out/cover.png" ]
then
	:
else
	"$GSCORE" -o "$out/.cover.pdf" "$file" >/dev/null
	pdftoppm -r 80 -f 1 -l 1 -png -singlefile "$out/.cover.pdf" "$out/cover"
	pages=$(pdfinfo "$out/.cover.pdf" 2>/dev/null | sed -n 's/^Pages: *//p')
	rm -f "$out/.cover.pdf"
fi

# ── the page ────────────────────────────────────────────────────────────────
#
# With the font and the player left outside it. With a recording the page
# plays that; without one it synthesises, as it always did. An empty -audio
# or -bands is the same as not passing it, so this is one call however the
# answers came out.
"$GSCORE" -o "$out/play.html" \
	-font "${up}font.otf" -script "${up}player.js" \
	-audio "$audio" ${bands:+-bands "$bands"} "$file" >/dev/null

# ── the row ─────────────────────────────────────────────────────────────────
#
# The tags and the instruments, each as a JSON list. Both are written by
# gscore as one comma-separated line, so both are cut up the same way.
aslist() {
	field "$1" | tr ',' '\n' | sed 's/^ *//; s/ *$//' |
		grep -v '^$' | sed 's/"/\\"/g; s/.*/"&"/' | paste -sd, -
}
taglist=$(aslist tags)
instlist=$(aslist instruments)
printf '{"slug":"%s","file":"%s","folder":"%s","title":"%s","composer":"%s","description":"%s","pages":%s,"tags":[%s],"instruments":[%s]}\n' \
	"$(esc "$slug")" "$(esc "$name.gscore")" "$(esc "$dir")" \
	"$(esc "$title")" "$(esc "$(field composer)")" \
	"$(esc "$(field description)")" "${pages:-0}" "$taglist" "$instlist" \
	> "$out/.row"

# ── kept for next time ──────────────────────────────────────────────────────
#
# Everything but the score, which is copied from where it lives, and the
# recording, which has its own cache and is named here instead. As links to
# the shelf's files, not copies; see place.
if [ -n "$kept" ] && [ "$retry" = 0 ]; then
	rm -rf "$kept"
	mkdir -p "$kept"
	for made in "$out/cover.png" "$out/play.html" "$out"/play.*.svg "$out/.row"; do
		if [ -f "$made" ]; then
			ln "$made" "$kept/" 2>/dev/null || cp "$made" "$kept/"
		fi
	done
	if [ -n "$audio" ]; then
		printf '%s' "$akey" > "$kept/.audio"
	fi
fi
exit 0
