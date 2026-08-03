# Porting this to other Agda developments

Everything here is written against TypeTopology specifically, but
most of it does not need to be. This sets out exactly what is
TypeTopology-specific, what already works against any Agda
development unchanged, and what a port would have to touch.

## Table of contents

 1. [Architecture](#architecture)
 1. [What already works for any Agda repository unchanged](#what-already-works-for-any-agda-repository-unchanged)
 1. [Literate Agda variants](#literate-agda-variants)
 1. [The area-demotion lists](#the-area-demotion-lists)
 1. [The one-off name disambiguation](#the-one-off-name-disambiguation)
 1. [Contributors](#contributors)
 1. [Concepts](#concepts)
 1. [Branding and defaults](#branding-and-defaults)
 1. [Pitfalls](#pitfalls)
 1. [A suggested order](#a-suggested-order)

## Architecture

One script, `agda-index.py`, is the whole pipeline. Both front ends --
the search page and the Emacs command -- are two different ways of
writing out what it computes, not two separate implementations of
indexing. In order:

1. **Render** (`render()`). Runs `agda --html` into
   `<typetopology>/html` (or reads a rendering already there, via
   `--html`), skipped when that rendering is already newer than every
   source file. This step, and everything below it, needs the source
   checkout as well as the rendering: several later steps re-read the
   raw `.lagda`/`.agda` text directly, not just the HTML.

1. **Gather** (`gather()`, `definitions()`, `scopes()`). Reads every
   rendered page for defining and using anchors -- see [How the search
   is implemented](README.md#how-the-search-is-implemented) for the
   anchor convention itself -- but for each definition found there,
   goes back to its own line in the *source*, via `scopes()`, purely to
   work out two things the HTML alone cannot say: whether it sits
   inside a `private`/`local`/anonymous-module scope (in which case it
   is not a definition of its own at all, only folded into whichever
   public definition encloses it, for use-count purposes), and what
   hypothesis some *enclosing* module took as a parameter
   (`scope_text`), since that never appears in any signature nested
   inside it. This is why the HTML directory and the source checkout
   have to be the same commit's: the anchor's own character offset is
   used to look up a source line number, and nothing here re-derives
   that mapping if the two have drifted apart.

1. **Prose** (`prose_of()`, `paragraphs_of()`, `comments_of()`). A
   second, independent read of the same source files, this time for
   the commentary rather than the code: `body`, one string per module,
   fed to regex membership tests ("does this module's prose mention
   concept X", "does it name contributor Y"); and `paras`, the same
   prose split into paragraphs, one comment-search entry per paragraph
   (see [Literate Agda variants](#literate-agda-variants) for where
   this can go wrong on an unfamiliar file convention).

1. **Contributors, concepts, safety** (`people_of()`, `concepts_of()`,
   `unsafe_modules()`). Three more passes, each folding `body` (or the
   README, or a `--safe` pragma check) into one further small table:
   who is named where, which modules discuss which concept, and which
   modules are not `--safe` (used only to prefer a safe definition site
   over an unsafe one when the same name is defined more than once).

1. **Write.** Everything gathered above -- `rows` (definitions),
   `body`/`paras` (prose), `people`, `concepts`, `unsafe` -- is plain
   Python data by this point, and entirely shared between what
   follows. Two writers turn it into the two actual products:

   * `write_search_page()` embeds all of it as JSON literals directly
     inside a `<script>` tag in `TypeTopologySearch.html` -- one
     self-contained file, no server, no separate data file to keep in
     sync, matching/ranking/rendering all done client-side by the
     JavaScript in that same script.

   * `write_emacs_index()` writes the same data out as
     `Definitions.tsv`, one row per definition, contributor, concept,
     or comment paragraph, a trailing `kind` column telling the four
     apart (see [The generated index
     files](README.md#the-generated-index-files) for the exact
     columns). `typetopology-search.el` reads this file once into a
     list of structs and does its own matching, ranking, and rendering
     against that list, entirely independently of the browser page.

   (`write_defs_index()`, `write_identifier_index()`, and
   `write_concept_index()` are three further, optional writers --
   `Definitions.txt` and the book-style markdown indexes -- needed by
   neither front end and not discussed further here.)

The one architectural point worth holding onto before touching
anything: matching, ranking, and the `in PATH`/`--` syntax are each
implemented *twice* -- once in the JavaScript `write_search_page()`
generates, once in `typetopology-search.el`'s own Elisp -- reading from
two different files built by the same Python data-gathering above, but
never sharing anything at runtime (`TypeTopologySearch.html` embeds its
data directly; `typetopology-search.el` reads `Definitions.tsv`
separately). There is no single shared search engine to port once and
get both front ends for free: the two hand-kept-in-sync
implementations are themselves part of what a port has to touch, and
every section below, and the [suggested order](#a-suggested-order) at
the end, applies to both of them in turn.

Finally, a point about layout rather than code: this tool and the
checkout it searches are two separate repositories. `agda-index.py`,
`typetopology-search.el`, `concepts.tsv`, and
`agda-input-escapes.json` all live here, in `TypeTopologySearch`;
`--typetopology` (or `typetopology-search-checkout-root`) only ever
points *at* a checkout, to read it -- and, for `render()`, to write a
scratch `html/` directory back into it -- nothing here needs write
access to the checkout being searched beyond that one scratch
directory. Everything this tool itself produces
(`TypeTopologySearch.html`, `Definitions.tsv`, and the rest) lands
beside this script, or wherever `--out`/`EMACSDIR` says, never inside
the checkout being searched.

<sub>[Table of contents](#table-of-contents)</sub>

## What already works for any Agda repository unchanged

* The whole of **Gather** (see [Architecture](#architecture)) --
  reading the HTML rendering for defining and using anchors, and the
  source for scope and hypothesis information -- depends only on how
  Agda itself writes HTML and structures a file, not on anything about
  TypeTopology's own code or commentary.

* `--typetopology`, `--source`, `--html`, and `--entry` already point
  at an arbitrary checkout, source directory, and entry module. A
  `source/` subdirectory is only the *default* guess for `--source`,
  not a requirement -- pass `--source` explicitly for a checkout laid
  out differently.

* `Definitions.tsv`'s own column layout (name, module, file, line,
  uses, signature, assumes, kind) is a generic schema; nothing about it
  is tied to what the columns happen to contain for TypeTopology.

* Comment/commentary search -- paragraph-splitting the literate prose,
  the `--`/`--compact` query marker, the "search within commentary
  instead" checkbox -- works on any `.lagda` file laid out the usual
  way, no extra configuration, modulo the one caveat in [Literate Agda
  variants](#literate-agda-variants) below.

* Wildcards, multi-word intersection, relevance ranking, and `in PATH`
  scoping are all plain text/name matching -- nothing here reads
  anything specific to this library.

* On the Emacs side, `typetopology-search-checkout-root` and
  `typetopology-search-file` already point at an arbitrary checkout;
  the minor mode attaches to `agda2-mode-hook`, which has nothing to
  do with which Agda project is open.

<sub>[Table of contents](#table-of-contents)</sub>

## Literate Agda variants

`prose_of()` (in `agda-index.py`) only recognises the LaTeX-flavoured
`.lagda` convention, splitting a file into code and prose on literal
`\begin{code}` / `\end{code}` lines. A repository using `.lagda.md`
(fenced Markdown code blocks tagged `agda` -- agda-categories and the
cubical library both do this) or `.lagda.rst` (`.. code-block:: agda`
directives) would have neither marker recognised at all, so the whole
file would be read as one block of undifferentiated prose, corrupting
both the concept prose-scan and, now, paragraph-level comment search.
Porting to either convention needs a second branch in `prose_of()`,
keyed on file extension, splitting on that convention's own fence or
directive syntax instead.

Plain `.agda` files (no literate wrapper at all) are already handled,
via `comments_of()`, but only `--` line comments are picked up: a
`{- ... -}` block comment has its own delimiters turned into
blank-line markers, but the text inside is only kept where it happens
to *also* start each line with `--` -- a block comment's own prose,
written without a `--` on every line, is silently dropped. A repository
whose `.agda` files carry real commentary in block comments, not line
comments, would need that extended too -- not a concern for
TypeTopology, since it has no plain `.agda` files at all.

<sub>[Table of contents](#table-of-contents)</sub>

## The area-demotion lists

`Unsafe.`, `deprecated.`, and `MGS.` sink to the bottom of the ranking,
in that order, before relevance is considered at all; the browser page
additionally excludes `gist.` and `TWA.` from its "own area" linking
heuristic. This is hardcoded in three places: `AREA` and `SIDELINE`
(both in `agda-index.py`'s `SEARCH_TEMPLATE`), and
`typetopology-search--entry-area` (`typetopology-search.el`).

These three directories mean something only inside TypeTopology:
`Unsafe` relies on principles the rest of the library does without,
`deprecated` is superseded code kept for compatibility, and `MGS`
redevelops from scratch names the library already has under lecture
notes that happen to share this repository. None of that transfers.
Porting this means turning each of the three lists into a small
per-repository config of (directory prefix, rank) pairs, defaulting to
empty -- every module then shares the top rank, exactly as if none of
this demotion existed.

<sub>[Table of contents](#table-of-contents)</sub>

## The one-off name disambiguation

The browser page's `HOME` map has exactly one entry:
`is-compact -> TypeTopology.CompactTypes`, because that one name is
defined four times over for genuinely different notions of
compactness, close enough in usage that nothing else could tell them
apart. This is not something to port at all: it is a table that can
only be built empirically, after a real search on a real checkout turns
up a popular, ambiguous name, and it starts empty for any other
repository until that happens there too.

`AXIOM_CONCEPTS` (the curated hypotheses -- funext, univalence,
excluded middle, and so on -- shown as "assumes" badges) and `GENERIC`
(words too ordinary to say where a concept lives, used by the "own
area" linking heuristic) are, similarly, this library's own vocabulary.
`SHOW_AXIOM_BADGES` is already off by default, so this can be left
exactly as it is unless a port specifically wants the axiom-badge
feature back, in which case it needs its own curated list the same way.

<sub>[Table of contents](#table-of-contents)</sub>

## Contributors

`people_of()` reads a target README (`--readme`, defaulting to
`<typetopology>/README.md`) for a `## ` heading whose text contains
"contributor" (case-insensitively), then collects a bulleted list
(`* Name (...)`) directly beneath it, until the next `## ` heading.
`--readme` already lets this point at a different file; the heading
and bullet convention itself is not configurable.

This already degrades gracefully: a missing README, or one with no
matching heading, yields an empty contributor list rather than an
error -- the same way a missing `concepts.tsv` yields no concepts.
Porting this means either formatting the target repository's own
README the same way, adjusting the two-line heading/bullet check in
`people_of()` to whatever convention it already uses, or simply
accepting no contributor search.

<sub>[Table of contents](#table-of-contents)</sub>

## Concepts

`concepts.tsv`'s own format -- five tab-separated columns: the concept,
a prose pattern, an identifier pattern, its landmark definitions, and
an optional search alias -- is entirely generic, and already documented
in [the main README's "The concept
vocabulary"](README.md#the-concept-vocabulary). What does not port is
the file's *content*: a vocabulary of a library's own mathematical
notions has to be curated by someone who knows that library, the same
way this one was. Concepts stay optional throughout -- `concepts_of`
degrades to `[]` when the file is missing -- so a port can simply start
without one and add it later, a row at a time, exactly as this one did.

<sub>[Table of contents](#table-of-contents)</sub>

## Branding and defaults

A handful of user-facing strings literally say "TypeTopology": the
search page's own `<title>` and `<h1>`; three Emacs status messages
(building the index, index built, index looks stale); and the CLI's
own flag names and defaults, `--typetopology` and `--site` (the latter
defaulting to
`https://martinescardo.github.io/TypeTopology/`). None of this affects
behaviour -- pointing `--typetopology` or
`typetopology-search-checkout-root` at a different checkout already
works today -- but every one of these strings would go on saying
"TypeTopology" regardless of what is actually being searched, which
reads as a bug to anyone not already in on why.

Renaming the tool itself -- `typetopology-search.el`, its
`typetopology-search-` symbol prefix throughout, `agda-index.py`,
`Definitions.tsv` -- is a separate, much larger, purely mechanical
undertaking, and not required for correctness. It only stops the tool
visibly claiming to be about a library it no longer is.

<sub>[Table of contents](#table-of-contents)</sub>

## Pitfalls

* **HTML and source out of sync.** `gather()` (see
  [Architecture](#architecture)) looks up a source line number from an
  anchor's own character offset, to work out a definition's enclosing
  scope and hypotheses. If the rendering in `html/` is from a different
  commit than the source checkout it is read alongside, this does not
  error -- it silently attributes the wrong scope or hypothesis to a
  definition, or points a jump at the wrong line. Regenerate the
  rendering (or delete `html/` and let `render()` redo it) whenever the
  two might have drifted apart.

* **A single hole or type error blocks the whole index, with no
  workaround under `--safe`.** `render()` aborts the entire build on
  any non-zero `agda --html` exit, holes included. Agda's usual
  suggestion for an open interaction point, `--allow-unsolved-metas`,
  is mutually exclusive with `--safe`, which is why nothing here tries
  it -- confirmed the hard way, per `render()`'s own comment.
  TypeTopology's own convention, complete `--safe` proofs throughout,
  means this rarely bites here; a repository still in progress, with
  routine holes or a mix of safe and unsafe files, would find the index
  simply unbuildable until everything type-checks clean.

* **`NOTIONS`, a hardcoded short-name allowlist.** A one- or
  two-letter name is dropped as a presumed local variable
  (`is_variable_name()`) unless it is in this fixed set (`ap`, `J`,
  `K`, `W`, `Id`, `ℕ`, ...) or a two-letter uppercase acronym. A real
  definition in another repository under an unlisted short name is not
  down-ranked by this -- it is simply absent from the index, with
  nothing printed to say so.

* **Several failure modes here are silent, not loud.** A missing or
  malformed `concepts.tsv` or README, an unrecognised literate variant
  (see [Literate Agda variants](#literate-agda-variants)), and the
  `NOTIONS` allowlist above all degrade by producing a plausible,
  error-free index that is nonetheless missing or misattributing
  something, never by stopping and saying so. The one place this
  script already checks itself is a half-emptied `html/` directory --
  "indexes quietly and looks fine until the counts are read closely",
  in its own words -- which is exactly the discipline the rest of a
  port needs too: running clean is not evidence of a complete index,
  only reading the counts it prints at the end of a run (definitions,
  names, modules, contributors, concepts) against something
  independently known -- a `grep` over the source, a rough sense of how
  many definitions there should be -- is.

<sub>[Table of contents](#table-of-contents)</sub>

## A suggested order

 1. Point `--typetopology` (or `typetopology-search-checkout-root`) at
    the target repository and confirm `agda --html` renders it and
    `gather()` finds definitions. If this step fails, nothing below it
    matters yet.
 1. If the repository uses `.lagda.md` or `.lagda.rst`, extend
    `prose_of()` before relying on comment search or concept discovery,
    both of which read its output.
 1. Empty out, or replace, the area-demotion lists and the `HOME`
    table -- a few minutes' work, and everything above already works
    correctly without them, just undifferentiated by area.
 1. Decide whether contributors and concepts are worth curating for the
    new repository; both stay optional, and can be added later without
    touching anything else.
 1. Leave the "TypeTopology" strings alone until everything above
    works, then sweep them in one pass. They are cosmetic, and doing
    this first only means re-testing against a half-working index.

<sub>[Table of contents](#table-of-contents)</sub>
