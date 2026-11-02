# Scores

A shelf of music, published as a web page.

Drop `.gscore` files anywhere in this repository — in folders that mean
something to you — push, and the shelf rebuilds itself. Each score gets
its first page as a picture, a page that plays it, and the file to
download.

## How it works

There is no server. [gscore](https://github.com/stricaud/gscore) writes a
page that plays the music by itself: the sound is synthesised in the
browser, so there is no soundfont to fetch and nothing to keep running.
The music font and the player are fetched once for the whole site rather
than carried in every page, which is the difference between a shelf that
loads and one that does not.

A `.gscore` file is also a valid PDF. One file is both the score and its
printable copy — download it and rename it to `.pdf` if that is what you
want it for.

## What a score says about itself

The shelf is built from what is in the files, so there is no list to keep
up to date. In gscore, **Score ▸ Title and composer…** asks for:

- the **title** and **composer**, which are printed on the page;
- a **description**, a few words for somebody deciding whether to open it;
- **tags**, separated by commas — `advent, flute duet, grade 3` — which
  the shelf lets you filter by.

All of it is saved inside the score, so a file carries its own description
wherever it is copied to.

## Building it yourself

    ./build.sh                 # with gscore on your PATH
    ./build.sh ../gscore/gscore  # or point at a build of it

Needs `gscore` and `pdftoppm` (in `poppler-utils`). The result is in
`site/`, which is not kept in the repository — open `site/index.html`.

A score gscore cannot read is reported and stepped over, so one bad file
does not take the shelf down with it.
