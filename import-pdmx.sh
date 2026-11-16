#!/bin/sh
#
# import-pdmx.sh
# scores - a shelf of music, built as a web page
#
# (C) Copyright 2026 Sebastien Tricaud
#
# Permission is hereby granted, free of charge, under the terms of the MIT
# licence; see the LICENSE file at the root of this repository.
#
# Converts a slice of PDMX to .gscore, in folders by genre, with its tags.
#
# PDMX is a quarter of a million scores taken off musescore.com by Long,
# Novack, McAuley and Berg-Kirkpatrick (UC San Diego) for training models
# on, published at zenodo.org/records/15571083 under CC BY 4.0 and described
# in arxiv.org/abs/2409.10831. Every score in it was marked public domain or
# CC0 on musescore.com — by whoever uploaded it, which is the thing to know
# about it. The uploader owns their engraving and can give that away; they do
# not own the tune, and a good part of what is marked CC0 there is Nintendo,
# Disney and Game of Thrones, which the shelf should not publish however the
# arrangement was licensed.
#
# So this takes a slice, chosen to be defensible, and the slice is the
# default of PDMX_SUBSET and PDMX_PUBLIC_DOMAIN below:
#
#   - the dataset's own no_license_conflict subset, where what musescore.com
#     showed and what the file said about its licence agree;
#   - deduplicated, one arrangement per piece, and rated, so that somebody
#     other than the uploader thought it worth having;
#   - and, on top of what the dataset offers, only scores musescore.com
#     itself flags as public domain works — which is the flag that separates
#     Bach, Mozart and Wagner from Toby Fox, Koji Kondo and Billie Eilish.
#
# That is about 3,600 scores; the whole set is about 254,000 and would not
# fit in this repository, on GitHub Pages or in a build. Widen the slice by
# the environment below.
#
# Folders are by genre, as musescore.com had them, then by composer:
#
#     PDMX/classical/Johann_Sebastian_Bach/Prelude_in_C_Major.gscore
#     PDMX/folk/Traditional/Greensleeves.gscore
#     PDMX/other/...                 no genre was given
#
# A score with several genres sits under the first and carries the rest as
# tags. Every score is tagged PDMX, its genres, how hard musescore.com
# rated it (beginner, intermediate, advanced), and whatever tags its
# uploader gave it.
#
# Needs: gscore, python3, curl, tar. The archives come to about two gigabytes
# and are fetched once into PDMX_SRC.
#
# Usage: ./import-pdmx.sh [path-to-gscore]
#
# Environment:
#
#     PDMX_SRC            where to keep the archives. Default .pdmx here,
#                         which .gitignore leaves alone.
#     PDMX_OUT            where the .gscore files go. Default PDMX here.
#     PDMX_SUBSET         which of the dataset's subsets to take: all, rated,
#                         deduplicated, rated_deduplicated, or all_valid.
#                         Default rated_deduplicated. no_license_conflict is
#                         always required on top; see above.
#     PDMX_PUBLIC_DOMAIN  1 to keep only what musescore.com flags as a public
#                         domain work, 0 to take the uploader's word for it.
#                         Default 1.
#     PDMX_GENRES         keep only these genres, space separated, matched
#                         against the first genre of a score; "other" is a
#                         score with none. Default: all of them.
#     PDMX_MIN_RATING     keep only scores rated at least this. Default 0.
#     PDMX_LIMIT          convert at most this many, for trying it out.
#     PDMX_NOPDF          1 to write the music alone, 0 to put a PDF of it in
#                         front as the other importers do. Default 1: a PDF
#                         is half a megabyte a score, and three and a half
#                         thousand of them is more than the repository
#                         should carry. The shelf draws the cover itself
#                         when there is no PDF to take it from.
#     PDMX_JOBS           how many to convert at once. Default: as many as
#                         there are processors.

set -eu

GSCORE="${1:-gscore}"
HERE=$(cd "$(dirname "$0")" && pwd)
SRC="${PDMX_SRC:-$HERE/.pdmx}"
OUT="${PDMX_OUT:-$HERE/PDMX}"
RECORD=https://zenodo.org/api/records/15571083
SUBSET="${PDMX_SUBSET:-rated_deduplicated}"
PUBLIC_DOMAIN="${PDMX_PUBLIC_DOMAIN:-1}"
GENRES="${PDMX_GENRES-}"
MIN_RATING="${PDMX_MIN_RATING:-0}"
LIMIT="${PDMX_LIMIT:-0}"
NOPDF="${PDMX_NOPDF:-1}"
JOBS="${PDMX_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)}"

have() { command -v "$1" >/dev/null 2>&1 || [ -x "$1" ]; }
have "$GSCORE" || { echo "import-pdmx.sh: cannot run '$GSCORE' — pass the path to it" >&2; exit 1; }
for tool in python3 curl tar; do
	have $tool || { echo "import-pdmx.sh: $tool is not here" >&2; exit 1; }
done
case $SUBSET in
	all|rated|deduplicated|rated_deduplicated|all_valid) ;;
	*) echo "import-pdmx.sh: PDMX_SUBSET must be all, rated, deduplicated, rated_deduplicated or all_valid" >&2; exit 1 ;;
esac

# An absolute path to gscore, since the workers do not run from here.
GSCORE_BIN=$(command -v "$GSCORE" 2>/dev/null || printf '%s' "$GSCORE")
case $GSCORE_BIN in /*) ;; *) GSCORE_BIN=$(pwd)/$GSCORE_BIN ;; esac
[ -f "$GSCORE_BIN" ] && GSCORE=$GSCORE_BIN

# ── the archives ────────────────────────────────────────────────────────────
#
# Three of the seven on Zenodo: the table of what is in the dataset, the
# page musescore.com showed for each score (where the tags and the public
# domain flag are), and the MusicXML. Not the PDFs, nine gigabytes of them,
# nor the MIDI nor the dataset's own JSON. Fetched once; a second run finds
# them here.
mkdir -p "$SRC"
fetch() {
	if [ -s "$SRC/$1" ]; then
		return 0
	fi
	echo "fetching $1 ($2)…"
	if ! curl -L --fail --retry 3 -o "$SRC/$1.part" "$RECORD/files/$1/content"; then
		rm -f "${SRC:?}/${1:?}.part"
		echo "import-pdmx.sh: could not fetch $1" >&2
		exit 1
	fi
	mv "$SRC/$1.part" "$SRC/$1"
}
fetch PDMX.csv "215 MB"
fetch metadata.tar.gz "152 MB"
fetch mxl.tar.gz "1.8 GB"
if [ ! -d "$SRC/metadata" ]; then
	echo "unpacking the metadata…"
	tar xzf "$SRC/metadata.tar.gz" -C "$SRC"
fi

# ── which gscore converted what is here ─────────────────────────────────────
#
# A score already converted is left alone, which is what makes this safe to
# run again — but "already converted" has to mean by this gscore. A new
# reader that reads the same file better produces a different .gscore from
# the same source, and without this the run would find every target newer
# than its source and do nothing at all, quietly. See import-openscore.sh.
digest() {
	if have sha256sum; then
		sha256sum | cut -d' ' -f1
	else
		shasum -a 256 | cut -d' ' -f1
	fi
}
GSCORE_ID=$(digest < "$GSCORE_BIN")
mkdir -p "$OUT"
STAMP="$OUT/.gscore-id"
fresh=1
if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$GSCORE_ID" ]; then
	fresh=0
fi
if [ "$fresh" = 1 ] && [ -f "$STAMP" ]; then
	echo "a different gscore than last time: everything will be converted again"
fi

# ── the slice ───────────────────────────────────────────────────────────────
#
# Python reads the table and the metadata and writes one record a score:
# where its MusicXML is in the archive, where its .gscore goes, and its tags,
# tab-separated and NUL-terminated so that xargs can hand them out. Nothing
# below this needs the table again.
list="$OUT/.list"
echo "choosing the scores…"
python3 -I - "$SRC" "$OUT" "$SUBSET" "$PUBLIC_DOMAIN" "$GENRES" "$MIN_RATING" "$LIMIT" > "$list" <<'PY'
import csv, json, os, re, sys, collections

src, out, subset, public_domain, genres, min_rating, limit = sys.argv[1:8]
genres = set(genres.split())
min_rating = float(min_rating)
limit = int(limit)
csv.field_size_limit(10**9)

# Some of what musescore.com holds was UTF-8 read as Latin-1 and saved
# again, so "Lulajże" arrives as "LulajÅ¼e" and a Russian title as a row
# of Ð and Ñ. Read back the same way it was broken, it is whole again; a
# string that was never broken does not survive the round trip and is
# left as it is.
def fix(s):
    if not s or s == 'NA':
        return ''
    if re.search(r'[À-ÿ][\u0080-¿]', s):
        for was in ('cp1252', 'latin-1'):
            try:
                return s.encode(was).decode('utf-8')
            except (UnicodeEncodeError, UnicodeDecodeError):
                pass
    return s

# How a name becomes a file or folder name. Letters of any alphabet are
# kept, which is what makes "Holmès" and "Dvořák" findable on the shelf;
# whitespace becomes "_", as the other imports have it; and what a file
# system or a shell would mind is dropped.
def clean(s):
    s = re.sub(r'\s+', '_', s.strip())
    s = re.sub(r'[/\\:*?"<>|\x00-\x1f\x7f-\x9f]+', '', s)
    s = re.sub(r'_+', '_', s).strip('_.')
    return s[:100]

# musescore.com's composer field is whatever was typed on the score, and
# some of it is a paragraph: "Music: X, 1831 / Lyrics: Y", "Composed by X,
# arranged by Y, full playthrough at…". The composer is the first name in
# it, before any of that, and without a date after it.
def composer_of(s):
    s = s.split('\n', 1)[0]
    s = re.sub(r'(?i)^\s*(?:(?:composed|music|musik|musique|composer|written)\b\s*)?(?:by\b)?\s*:?\s*', '', s)
    s = re.split(r'(?i)\s*(?:,|;|/|&|\(|\s[-–—]\s|\sand\s|arr\.|arranged|transcri|perform|realiz|revised|harm\.|orch\.|edited|lyrics|words|http)', s, maxsplit=1)[0]
    s = re.sub(r'(?i)\s*\b(op\.?\s*\d+|\d{3,4}(\s*[-–]\s*\d{3,4})?)\s*$', '', s)
    return s.strip(' .')

# "Title - Composer" is how musescore.com titles a score whose title it
# knows; the composer is already a folder.
def title_of(cands, composer):
    for t in cands:
        t = fix(t).strip()
        if t:
            break
    if composer and t.lower().endswith(' - ' + composer.lower()):
        t = t[:-(len(composer) + 3)]
    return t.strip()

# musescore.com's difficulty, as the dataset carries it. 0 is the most
# common value by far and is taken to mean "not set"; 1, 2 and 3 are the
# three levels its search offers.
LEVEL = {'1': 'beginner', '2': 'intermediate', '3': 'advanced'}

# Words that are not tags, in the languages the uploaders mostly wrote in.
STOP = set('''the a an and or of in on at to for by with from no not is as
    le la les un une des du de et en au aux der die das ein eine und von im
    zum zur il lo gli el los las y del al op no. nr sheet music score
    musescore'''.split())

rows = []
with open(os.path.join(src, 'PDMX.csv'), newline='', encoding='utf-8') as f:
    for r in csv.DictReader(f):
        if r['mxl'] == 'NA' or r['subset:no_license_conflict'] != 'True':
            continue
        if r['subset:' + subset] != 'True':
            continue
        if float(r['rating'] or 0) < min_rating:
            continue
        rows.append(r)

items = []
n = 0
for r in rows:
    try:
        with open(os.path.join(src, r['metadata'][2:]), encoding='utf-8') as f:
            d = json.load(f)['data']
    except (OSError, ValueError, KeyError):
        continue
    score = d.get('score') or {}
    if public_domain == '1' and not score.get('is_public_domain'):
        continue
    names = [g['name'] for g in d.get('genres') or [] if g.get('name')]
    genre = clean(names[0]).lower() if names else 'other'
    if genres and genre not in genres:
        continue

    # The metadata's strings first, since they keep the line breaks the
    # table flattened; the table's where the metadata has none.
    composer = ''
    for cand in (score.get('composer_name'), r['composer_name'], score.get('artist_name'), r['artist_name']):
        cand = fix(cand or '')
        if cand:
            composer = composer_of(cand)
            if composer:
                break
    title = title_of((score.get('song_name'), r['song_name'], score.get('title'), r['title'],
                      score.get('file_score_title')), composer) or os.path.basename(r['mxl'])

    tags = ['PDMX'] + names
    level = LEVEL.get(str(score.get('complexity', '')))
    if level:
        tags.append(level)
    # The uploader's tags, less the noise. A good many uploaders tagged a
    # score with every word of its title — "bwv, 663, allein, gott, in,
    # der, höh" — which says nothing the title does not and fills the
    # shelf's filter with articles. A tag that is one word already in the
    # title or the composer, a bare number, or a word like "the" is left
    # out; "chorale", "christmas" and "string quartet" stay. All in lower
    # case, as the shelf's own tags are, so that "Piano" and "piano" are
    # one thing to filter by.
    said = set(re.findall(r'\w+', (title + ' ' + composer).lower()))
    for t in score.get('tags') or []:
        t = re.sub(r'\s+', ' ', fix(str(t))).strip().replace(',', ' ').lower()
        if not t or t in (x.lower() for x in tags):
            continue
        if ' ' not in t and (t in said or t in STOP or t.isdigit() or len(t) < 3):
            continue
        tags.append(t)

    items.append((r['mxl'][2:], genre, clean(composer), clean(title) or 'Untitled', tags))
    n += 1
    if limit and n >= limit:
        break

# One folder a composer, however the uploaders spelt them. "SCOTT JOPLIN",
# "Scott Joplin" and "scott joplin" are one composer; on a Mac they are one
# folder whether this agrees or not, and fourteen scores went missing into
# each other's folders before it did. A spelling in mixed case is kept over
# one all in capitals or none; among those, the one most uploaders used;
# and among those, the one with the fewest capitals.
spelt = collections.Counter(c for _, _, c, _, _ in items if c)
def shouted(s):
    return (s.isupper() or s.islower(), -spelt[s], sum(c.isupper() for c in s))
canon = {}
for composer in spelt:
    have = canon.get(composer.lower())
    if have is None or shouted(composer) < shouted(have):
        canon[composer.lower()] = composer

# What a name becomes in the shelf's addresses — see slugof in engrave.sh.
# Two scores whose names differ only in what the shelf drops, "Adoramus
# Te Christe" and "Adoramus te, Christe" under one composer, are one
# address there, and were one folder with two scores fighting over it.
def shelf(s):
    return re.sub(r'[^a-z0-9._-]', '', s.lower().replace(' ', '-'))

seen = collections.Counter()
for mxl, genre, composer, base, tags in items:
    composer = canon.get(composer.lower(), '')
    folder = os.path.join(out, genre, composer) if composer else os.path.join(out, genre)
    # Two scores of the same name under the same composer are two scores.
    key = (shelf(folder), shelf(base) or base.lower())
    seen[key] += 1
    if seen[key] > 1:
        base = '%s_(%d)' % (base, seen[key])
    target = os.path.join(folder, base + '.gscore')
    sys.stdout.write('%s\t%s\t%s\0' % (mxl, target, ', '.join(tags)))
sys.stderr.write('%d scores chosen\n' % n)
PY

total=$(tr -cd '\0' < "$list" | wc -c | tr -d ' ')
if [ "$total" -eq 0 ]; then
	echo "import-pdmx.sh: nothing matched" >&2
	rm -f "${list:?}"
	exit 1
fi

# ── the MusicXML, out of the archive ────────────────────────────────────────
#
# Only the scores chosen, which is a few hundred megabytes out of the
# archive's five once unpacked. tar still reads the whole archive to find
# them, which is a minute or so; a second run finds them already here and
# skips it.
want="$OUT/.want"
tr '\0' '\n' < "$list" | cut -f1 > "$want"
missing=0
while IFS= read -r m; do
	[ -f "$SRC/$m" ] || { missing=1; break; }
done < "$want"
if [ "$missing" = 1 ]; then
	echo "unpacking the MusicXML of $total scores…"
	tar xzf "$SRC/mxl.tar.gz" -C "$SRC" -T "$want"
fi
rm -f "${want:?}"

# ── converting ──────────────────────────────────────────────────────────────
#
# Several at a time, with stdin closed on the way in so that nothing in a
# worker can read the list out from under xargs. A score that would not
# convert is noted and the rest carry on.
: > "$OUT/.failed"
: > "$OUT/.count"
echo "converting $total scores, $JOBS at a time…"
export GSCORE SRC OUT NOPDF fresh
xargs -0 -n 1 -P "$JOBS" sh -c '
	IFS=$(printf "\t")
	set -f
	set -- $1
	src="$SRC/$1"; target=$2; tags=${3-}
	rel=${target#"$OUT"/}

	# Converted once; see import-openscore.sh for the shape of the test.
	if [ "$fresh" = 0 ] && [ -f "$target" ] && [ "$target" -nt "$src" ]; then
		if [ "$(head -c 4 "$target" 2>/dev/null || true)" = "%PDF" ]; then has=1; else has=0; fi
		if [ "$NOPDF" = 1 ]; then want=0; else want=1; fi
		if [ "$has" = "$want" ]; then echo skipped >> "$OUT/.count"; exit 0; fi
	fi

	mkdir -p "$(dirname "$target")"
	if [ "$NOPDF" = 1 ]; then set -- -convert "$target" -nopdf; else set -- -convert "$target"; fi
	if "$GSCORE" "$@" -tag "$tags" "$src" </dev/null >/dev/null 2>&1; then
		echo converted >> "$OUT/.count"
	else
		why=$("$GSCORE" "$@" -tag "$tags" "$src" </dev/null 2>&1 | sed "s/^gscore: //" | head -1)
		printf "%s\t%s\n" "$rel" "${why:-would not convert}" >> "$OUT/.failed"
		rm -f "${target:?}"
	fi
' _ < "$list" || true
rm -f "${list:?}"

printf '%s\n' "$GSCORE_ID" > "$STAMP"

n=$(grep -c '^converted$' "$OUT/.count" || true)
skipped=$(grep -c '^skipped$' "$OUT/.count" || true)
failed=$(wc -l < "$OUT/.failed" | tr -d ' ')
rm -f "${OUT:?}/.count"
echo "converted $n score(s) into $OUT"
[ "$skipped" -gt 0 ] && echo "$skipped already there and up to date"
if [ "$failed" -gt 0 ]; then
	echo "$failed could not be converted:" >&2
	sed 's/^/  /; s/\t/: /' "$OUT/.failed" >&2
fi
rm -f "${OUT:?}/.failed"
