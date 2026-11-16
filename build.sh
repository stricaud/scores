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
# This file is the shelf: it finds the scores, puts each through engrave.sh,
# several at a time, and gathers what comes back into one list. Everything
# that is done to a single score — its cover, its page, its recording, what
# makes it a large one — is in engrave.sh, and the split is deliberate: the
# engraved pages are cached against a hash of the recipe that made them, so a
# change here redraws nothing, and a change there redraws everything. See
# the top of engrave.sh.
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
# Needs: gscore, and pdftoppm and pdfinfo from poppler-utils. For the
# recordings, a soundfont and ffmpeg; without either, the pages synthesise.
#
# Usage: ./build.sh [path-to-gscore]
#
# Environment:
#
#     GSCORE_SOUNDFONT   the .sf2 to record through. Unset looks in the
#                        usual places; set to "none" turns recording off.
#     AUDIO_CACHE        where recordings are kept between builds.
#                        Default .audio-cache here.
#     BIG                how many shapes make a score a large one: the ones
#                        whose drawing is fetched a piece at a time and whose
#                        sound is recorded in advance. Default 50000.
#     BUILD_CACHE        where engraved pages are kept between builds.
#                        Default .build-cache here. NO_CACHE=1 turns it off.
#     SYNTH              folders holding a bulk import, whose scores are left
#                        to make their own sound, however large. Space
#                        separated. Default "OpenScore-Lieder PDMX".
#     JOBS               how many scores to engrave at once. Default: as
#                        many as there are processors.
#
# On the caches. Engraving is most of the work and recording is the slow
# part by a long way — the ninth symphony is about three quarters of an hour
# of audio and takes about as long to render as it does to play — and a score
# that is on the shelf does not change. So both are kept between builds, the
# recordings under AUDIO_CACHE against the score and the soundfont, the pages
# under BUILD_CACHE against the score, the gscore and the recipe; what has
# not changed is copied back and not made again. In CI both directories are
# caches, and the gscore is pinned (see GSCORE_REV) so that the key does not
# move under them: the first build after adding a symphony is a long one and
# every build after it is not.

set -eu

GSCORE="${1:-gscore}"
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/site"

have() { command -v "$1" >/dev/null 2>&1 || [ -x "$1" ]; }
have "$GSCORE" || { echo "build.sh: cannot run '$GSCORE' — pass the path to it" >&2; exit 1; }
# Checked before anything is written, because a build that lays down
# twenty pages and then stops is worse than one that does not start.
have pdftoppm || { echo "build.sh: pdftoppm is not here — it is in poppler-utils" >&2; exit 1; }
have pdfinfo || { echo "build.sh: pdfinfo is not here — it is in poppler-utils" >&2; exit 1; }

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
		if [ -f "$cand" ]; then SOUNDFONT=$cand; break; fi
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

# How many shapes make a score a large one.
#
# One number, because the two things that follow from it follow together: a
# drawing too big for a page to hold is also music too big for the page's own
# player to make a decent noise of. Beethoven's ninth is 955,074 shapes and a
# song from the Lieder corpus about 5,000, so anything in the tens of
# thousands separates them; 50,000 is a few times the largest song and a
# twentieth of the smallest symphony, which is a comfortable place to sit.
BIG="${BIG:-50000}"

# The folders a bulk import drops its scores in. Scores under these are left
# to make their own sound, however large, because there are thousands of them
# and nobody chose them one at a time. Space separated, matched
# against the path from here.
SYNTH="${SYNTH:-OpenScore-Lieder PDMX}"

AUDIO_CACHE="${AUDIO_CACHE:-$HERE/.audio-cache}"
[ -n "$SOUNDFONT" ] && mkdir -p "$AUDIO_CACHE"

BUILD_CACHE="${BUILD_CACHE:-$HERE/.build-cache}"
if [ "${NO_CACHE:-0}" = 1 ]; then
	BUILD_CACHE=""
else
	mkdir -p "$BUILD_CACHE"
fi

# How many at once. gscore engraves on one processor, and a runner has four
# and a laptop more, so the shelf is built that many scores at a time.
JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)}"

# The hash of whatever is fed in. sha256sum on Linux, shasum on a Mac.
digest() {
	if have sha256sum; then
		sha256sum | cut -d' ' -f1
	else
		shasum -a 256 | cut -d' ' -f1
	fi
}

# Which gscore, and which recipe. Asked once: neither can change while a
# build is running, and there is no sense in fifteen hundred workers hashing
# the same forty megabytes.
#
# The gscore is the binary itself and not the version it prints. A gscore
# built from changed code reports the same version as the one before it —
# "dev" until somebody bumps it — so keying on the version hands back pages
# drawn by a gscore that no longer exists, which is the one mistake a cache
# must not make and precisely the thing this one is here to prevent.
GSCORE_BIN=$(command -v "$GSCORE" 2>/dev/null || printf '%s' "$GSCORE")
if [ -f "$GSCORE_BIN" ]; then
	GSCORE_ID=$(digest < "$GSCORE_BIN")
	# An absolute path, since the workers do not run from here.
	case $GSCORE_BIN in /*) ;; *) GSCORE_BIN=$(pwd)/$GSCORE_BIN ;; esac
	GSCORE=$GSCORE_BIN
else
	GSCORE_ID=$("$GSCORE" -version 2>/dev/null || echo unknown)
fi
RECIPE_ID=$(digest < "$HERE/engrave.sh")

rm -rf "$OUT"
mkdir -p "$OUT"

# When this build began, for the cache to be weighed against at the end:
# an entry older than this is one no score of this shelf asked for.
began="$OUT/.began"
: > "$began"

# The font and the player once for the whole site rather than inside every
# page. The font is most of a megabyte and a page is tens of kilobytes, so
# this is the difference between a shelf that loads and one that does not.
"$GSCORE" -o "$OUT/font.otf" >/dev/null
"$GSCORE" -o "$OUT/player.js" >/dev/null

# ── the scores, largest first ───────────────────────────────────────────────
#
# Everywhere but the build's own output and git's. NUL-separated throughout,
# so that a folder or a piece with a space in its name is one name and not
# two, which is most of them.
#
# Largest first because they are engraved several at a time: a symphony that
# takes twenty minutes wants to start at once, with the songs going through
# beside it, and not after fourteen hundred of them when nothing else is left
# to do and three of the four processors sit idle. The size of the file is a
# fair guess at the work, since a .gscore carries a PDF of itself.
#
# wc is given the files by the hundred rather than one at a time: five
# thousand of it, one by one, was half a minute before a single score was
# looked at. It prints a total after each batch, which is told from a score
# by not ending in .gscore, as every score does.
list="$OUT/.list"
find "$HERE" -name '*.gscore' -type f \
	-not -path "$OUT/*" -not -path "$HERE/.git/*" -print0 |
	xargs -0 wc -c | grep '\.gscore$' |
	sort -rn | sed 's/^ *[0-9]* //' | tr '\n' '\0' > "$list"

# ── one score at a time, several at a time ──────────────────────────────────
#
# Each score is engrave.sh's business; what it needs to know travels in the
# environment. Its output is caught and printed whole once it is done, so
# that four scores engraving at once do not say their lines over one another.
#
# stdin is closed on the way in. The list is on xargs's standard input, and
# anything in a worker that reads standard input would eat the scores still
# to come; ffmpeg does, for keystrokes, unless told not to. It is told not
# to as well, in engrave.sh, but this half of the fix does not have to be
# remembered the next time something is added there.
#
# A score engrave.sh could not finish is not a reason to stop the others, so
# xargs's own complaint about it is let go; the score is found afterwards by
# the row it did not write.
#
# Under nice, because this fills every processor for as long as it runs, and
# on a hosted runner the agent that reports back to GitHub has to get a
# word in now and then or the job is given up as lost.
export HERE OUT GSCORE GSCORE_ID RECIPE_ID SOUNDFONT AUDIO_CACHE BUILD_CACHE BIG SYNTH
nice -n 10 xargs -0 -n 1 -P "$JOBS" sh -c '
	log=$(mktemp "${TMPDIR:-/tmp}/gscore-log.XXXXXX") || exit 1
	"$HERE/engrave.sh" "$1" </dev/null >"$log" 2>&1 ||
		echo "    engraving failed (exit $?); see above" >>"$log"
	cat "$log"
	rm -f "$log"
' _ < "$list" || true
rm -f "$list"

# ── gathering ───────────────────────────────────────────────────────────────
#
# Every score left behind a folder with .rel in it, saying where it came
# from, and one of three things beside: .row, its line on the shelf; .skipped,
# why gscore could not read it; or neither, because something gave out
# partway. The last two come off the shelf, and are said.
kept=0
: > "$OUT/.skipped"
#
# Without starting a program per score: five thousand of dirname and cat
# were twenty seconds, and the shell can do both by itself.
find "$OUT" -name .rel | LC_ALL=C sort | while IFS= read -r relf; do
	d=${relf%/.rel}
	IFS= read -r rel < "$relf" || true
	if [ -f "$d/.row" ]; then
		if [ -f "$d/.kept" ]; then echo "$rel" >> "$OUT/.keptlist"; fi
	elif [ -f "$d/.skipped" ]; then
		printf '%s\t%s\n' "$rel" "$(cat "$d/.skipped")" >> "$OUT/.skipped"
		rm -rf "$d"
	else
		printf '%s\t%s\n' "$rel" "engraving failed; see the output above" >> "$OUT/.skipped"
		rm -rf "$d"
	fi
done
if [ -f "$OUT/.keptlist" ]; then
	kept=$(wc -l < "$OUT/.keptlist" | tr -d " ")
	rm -f "$OUT/.keptlist"
fi

# The shelf's own list, sorted the way a shelf is read. The page can sort
# it again any way it likes.
{
	printf '[\n'
	find "$OUT" -name .row -exec cat {} + | LC_ALL=C sort | sed '$ !s/$/,/'
	printf ']\n'
} > "$OUT/scores.json"

# What the workers left for this file to read is not for the shelf.
find "$OUT" \( -name .row -o -name .rel -o -name .kept -o -name .audio \) -type f -delete

# ── what the cache can let go of ────────────────────────────────────────────
#
# Every entry this build made or used was touched after $began, so an entry
# older than it belongs to a score that is gone, or to a gscore or a recipe
# that is. Left alone, those stay for ever: a cache of three shelves was
# eight gigabytes on a laptop and would not have fit on a runner at all.
if [ -n "$BUILD_CACHE" ]; then
	find "$BUILD_CACHE" -mindepth 1 -maxdepth 1 ! -newer "$began" -exec rm -rf {} +
fi
rm -f "$began"

cp "$HERE/index.html" "$OUT/index.html"
n=$(grep -c '"slug"' "$OUT/scores.json" || true)
skipped=$(wc -l < "$OUT/.skipped" | tr -d ' ')
echo "built $n score(s) into $OUT, $JOBS at a time"
if [ "$kept" -gt 0 ]; then
	echo "$kept of them came back from the cache, unchanged since the last build"
fi
if [ "$skipped" -gt 0 ]; then
	echo "$skipped could not be built:" >&2
	sed 's/^/  /; s/\t/: /' "$OUT/.skipped" >&2
fi
rm -f "$OUT/.skipped"
[ "$n" -gt 0 ] || echo "build.sh: no .gscore files found under $HERE" >&2
