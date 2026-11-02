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
# itself — the sound is synthesised in the browser, so there is no
# soundfont to fetch — and a .gscore file is also a valid PDF, so one file
# is both the score and its printable copy.
#
# Scores are found wherever they are. Put them in folders that mean
# something to you; the folder travels with the score to the shelf and can
# be searched for, and nothing here needs telling about it.
#
# What comes out:
#
#     site/index.html              the shelf
#     site/scores.json             what is on it
#     site/font.otf, player.js     fetched once for the whole site
#     site/<path>/cover.png        the first page
#     site/<path>/play.html        the score, playable
#     site/<path>/<name>.gscore    the file, which is also the PDF
#
# Needs: gscore, and pdftoppm from poppler-utils.
#
# Usage: ./build.sh [path-to-gscore]

set -eu

GSCORE="${1:-gscore}"
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/site"

have() { command -v "$1" >/dev/null 2>&1 || [ -x "$1" ]; }
have "$GSCORE" || { echo "build.sh: cannot run '$GSCORE' — pass the path to it" >&2; exit 1; }
# Checked before anything is written, because a build that lays down
# twenty pages and then stops is worse than one that does not start.
have pdftoppm || { echo "build.sh: pdftoppm is not here — it is in poppler-utils" >&2; exit 1; }

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

# Everywhere but the build's own output and git's. -print0 and read -r so
# that a folder or a piece with a space in its name is one name and not
# two, which is most of them.
find "$HERE" -name '*.gscore' -type f \
	-not -path "$OUT/*" -not -path "$HERE/.git/*" -print |
	LC_ALL=C sort |
while IFS= read -r file; do
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
		if [ ! -s "$file" ]; then
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

	# The playable page, with the font and the player left outside it.
	"$GSCORE" -o "$OUT/$slug/play.html" \
		-font "${up}font.otf" -script "${up}player.js" "$file" >/dev/null

	taglist=$(field tags | tr ',' '\n' | sed 's/^ *//; s/ *$//' |
		grep -v '^$' | sed 's/"/\\"/g; s/.*/"&"/' | paste -sd, -)
	printf '{"slug":"%s","file":"%s","folder":"%s","title":"%s","composer":"%s","description":"%s","pages":%s,"tags":[%s]}\n' \
		"$(esc "$slug")" "$(esc "$name.gscore")" "$(esc "$dir")" \
		"$(esc "$title")" "$(esc "$(field composer)")" \
		"$(esc "$(field description)")" "${pages:-0}" "$taglist" \
		>> "$OUT/.rows"
done

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
