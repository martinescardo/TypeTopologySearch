# Porting this to other Agda developments

This tool was built for TypeTopology, and TypeTopology is still the
only thing it has ever really been tested against. But most of what
makes it work has nothing to do with TypeTopology in particular, and
the parts that do are few enough, and small enough, to list. That's
what this file is: a walk through what's already general, what's fixed
in the code and why, and what you'd actually have to touch to port it
to another one.

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

There's really only one program here, `agda-index.py`. The search page
and the Emacs command are just two different things it writes out, not
two separate implementations of indexing.

It starts by rendering the development with `agda --html` (`render()`),
or reusing a rendering you already have via `--html`, skipping this
step when what's already there is newer than every source file. From
this point on it needs the source as much as the rendering: several of
the steps below read the raw `.lagda`/`.agda` text directly, not just
the HTML.

Most of the real work happens next, in gathering (`gather()`,
`definitions()`, `scopes()`). Agda anchors every definition in its own
HTML, so one pass over the rendering already gives you defining and
using occurrences for free -- the anchor convention itself is
described in [How the search is
implemented](README.md#how-the-search-is-implemented). But the HTML
alone can't say everything: whether a definition sits inside a
`private` block or an anonymous module, say, or what hypothesis some
*enclosing* module took as a parameter and never repeated in the
signature. For that, `gather()` goes back to the definition's own line
in the source, via `scopes()`, using the anchor's character offset to
find it. Which is also why the rendering and the source have to be
exactly the same version: get that offset pointing at the wrong line,
and nothing here would notice.

Prose gets a second, separate pass over the same files (`prose_of()`,
`paragraphs_of()`, `comments_of()`), this time for the commentary
rather than the code. This is where a module's discussion of a concept,
or its mention of a contributor, comes from -- and, since comment
search was added, where each searchable paragraph comes from too,
assuming the file's own literate convention is one this script
actually recognises (see [Literate Agda
variants](#literate-agda-variants) if it isn't). Contributors, concepts,
and which modules aren't `--safe` are three more passes over the same
material (`people_of()`, `concepts_of()`, `unsafe_modules()`), each
producing one more small table.

By the time all of that is done, everything is just plain Python data
-- `rows`, `body`, `paras`, `people`, `concepts`, `unsafe` -- and two
writers turn it into the two things anyone actually uses.
`write_search_page()` embeds all of it as JSON directly inside a
`<script>` tag in `TypeTopologySearch.html`: one self-contained file,
no server, matching and ranking done client-side by the JavaScript
sitting right there next to the data. `write_emacs_index()` writes the
same information out as `Definitions.tsv` instead, one row per
definition, contributor, concept, or comment paragraph (see [The
generated index files](README.md#the-generated-index-files) for the
columns), and `typetopology-search.el` reads that file once and does
its own matching and ranking against it, entirely separately from the
browser page. (Three further writers -- `write_defs_index()`,
`write_identifier_index()`, `write_concept_index()` -- produce
`Definitions.txt` and the book-style markdown indexes; neither front
end needs them, so they don't come up again here.)

The one thing worth actually remembering before touching anything:
matching, ranking, and the `in PATH`/`--` syntax are implemented
*twice*, once in the JavaScript this script writes and once in
`typetopology-search.el`'s own Elisp, and the two never talk to each
other at runtime. There's no single search engine to port once and get
both front ends working for free -- you'd be changing two
implementations, kept in sync only by hand, not one.

And one thing about layout rather than code: this tool and the
development it searches live in two separate repositories. Everything
that makes the tool -- `agda-index.py`, `typetopology-search.el`,
`concepts.tsv`, `agda-input-escapes.json` -- lives here, in
`TypeTopologySearch`; `--typetopology` (or
`typetopology-search-checkout-root`) only ever points *at* the
development being searched, to read it, and, when rendering, to leave
a scratch `html/` directory inside it. Nothing this tool writes -- the
search page, `Definitions.tsv`, any of it -- ever lands anywhere near
the development itself.

<sub>[Table of contents](#table-of-contents)</sub>

## What already works for any Agda repository unchanged

Most of what actually does the work doesn't know or care that it's
TypeTopology. Gathering -- reading the rendering for anchors, the
source for scope and hypotheses -- depends only on how Agda itself
writes HTML and structures a file. The command-line options already
point wherever you tell them to: `--typetopology`, `--source`,
`--html`, and `--entry` all take an arbitrary development, source
directory, and entry module, and a `source/` subdirectory is only the
*default* guess for `--source`, not something the tool insists on --
give it explicitly for a development laid out differently. `Definitions.tsv`'s
own columns (name, module, file, line, uses, signature, assumes, kind)
are just as generic; nothing ties them to what they happen to contain
today. Comment search works the same way on any `.lagda` file laid out
the usual way, no configuration needed, so long as it's the literate
convention this script actually recognises (more on that just below).
And the matching itself -- wildcards, several words at once, relevance
ranking, `in PATH` scoping -- is all plain text and name matching;
none of it reads anything specific to this library. The Emacs side is
no different: `typetopology-search-checkout-root` and
`typetopology-search-file` already point wherever you set them, and
the minor mode attaches itself to `agda2-mode-hook`, which has never
heard of TypeTopology either.

<sub>[Table of contents](#table-of-contents)</sub>

## Literate Agda variants

`prose_of()` only knows one convention: the LaTeX-flavoured `.lagda`
file, where `\begin{code}`/`\end{code}` mark the code and everything
else is prose. A repository written in `.lagda.md` instead -- fenced
Markdown code blocks tagged `agda`, the convention agda-categories and
the cubical library both use -- or in `.lagda.rst`, would have neither
marker recognised at all. The whole file would just read as one
undifferentiated block of prose, which would throw off both the
concept scan and, now, comment search, which depends on the prose
being split into paragraphs correctly in the first place. Supporting
either convention means teaching `prose_of()` a second way to split a
file, chosen by extension, using that convention's own fence or
directive syntax instead of `\begin{code}`.

Plain `.agda` files, with no literate wrapper at all, are already
handled by `comments_of()`, but only line comments starting with `--`
actually make it through: a `{- ... -}` block comment has its
delimiters stripped out, but what's left inside is kept only where
each individual line also happens to start with `--`. Write your
commentary as a block comment without doing that, and it just
disappears, silently. Not a concern for TypeTopology, which has no
plain `.agda` files at all -- but worth knowing if the repository
you're porting to does.

<sub>[Table of contents](#table-of-contents)</sub>

## The area-demotion lists

Three directories sink to the bottom of the ranking before relevance
is even considered -- `Unsafe`, `deprecated`, `MGS`, in that order --
and the browser page additionally leaves `gist` and `TWA` out of its
own guess at which module a concept is really at home in. All five
names are written directly into the code, in three different places:
`AREA` and `SIDELINE`, both inside `agda-index.py`'s own
`SEARCH_TEMPLATE`, and `typetopology-search--entry-area` in the Elisp.

None of the three reasons behind them travel anywhere else. `Unsafe`
relies on principles the rest of the library gets by without;
`deprecated` is code kept around only for compatibility; `MGS`
redevelops, from scratch, names the library already has, under lecture
notes that just happen to live in the same repository. A port doesn't
inherit any of that, so the sensible thing is to turn all three lists
into a small, per-repository list of (directory, rank) pairs and start
it empty -- every module then shares the same rank, exactly as if none
of this demotion existed, until you decide otherwise.

<sub>[Table of contents](#table-of-contents)</sub>

## The one-off name disambiguation

There's exactly one entry in the browser page's `HOME` map --
`is-compact -> TypeTopology.CompactTypes` -- because that one name is
defined four separate times, for four genuinely different notions of
compactness, close enough in how often each is used that nothing else
could tell them apart. This isn't something you port so much as
something you eventually build yourself, the same way it got built
here: by running a real search against a real development and noticing
an ambiguous, popular name. It starts empty for anyone else, and will
probably stay that way for a while.

`AXIOM_CONCEPTS` (the curated hypotheses shown as "assumes" badges --
funext, univalence, excluded middle, and so on) and `GENERIC` (words
too ordinary to say where a concept actually lives) are the same kind
of thing: this library's own vocabulary, not a general mechanism.
`SHOW_AXIOM_BADGES` is already off by default, so none of this needs
touching at all unless you specifically want the axiom badges back --
in which case you'll need your own curated list, built the same
patient way.

<sub>[Table of contents](#table-of-contents)</sub>

## Contributors

`people_of()` finds contributors by reading a README (`--readme`,
defaulting to `<typetopology>/README.md`) for a `## ` heading that
mentions "contributor" somewhere in its text, then collecting the
bulleted list right underneath it, stopping at the next heading. You
can already point `--readme` at a different file; what you can't do is
change the heading-and-bullet convention itself without editing the
two-line check inside `people_of()` by hand.

It already fails gracefully, the same way a missing `concepts.tsv`
does: no matching heading just means no contributors, not an error.
So there are really three ways to handle this in a port -- format the
target repository's own README the same way, adjust `people_of()` to
whatever convention it already uses, or just live without contributor
search.

<sub>[Table of contents](#table-of-contents)</sub>

## Concepts

The *format* of `concepts.tsv` -- five tab-separated columns: the
concept, a prose pattern, an identifier pattern, its landmark
definitions, and an optional alias -- travels perfectly well, and it's
already written up properly in the main README, under [The concept
vocabulary](README.md#the-concept-vocabulary). What doesn't travel is
what's actually *in* the file: a vocabulary of a library's own
mathematical notions can only be curated by someone who knows that
library, which is exactly how this one got written, a row at a time,
over a long while. Concepts stay entirely optional throughout --
`concepts_of` just returns nothing when the file is missing -- so
there's no reason a port can't start without one and grow it later,
the same way this one did.

<sub>[Table of contents](#table-of-contents)</sub>

## Branding and defaults

A handful of strings say "TypeTopology" outright: the search page's own
`<title>` and `<h1>`, a few Emacs status messages, and the two
command-line options `--typetopology` and `--site`, along with their
defaults (the latter pointing at
`https://martinescardo.github.io/TypeTopology/`). None of it changes
what the tool actually does -- pointing `--typetopology` or
`typetopology-search-checkout-root` at some other development already
works today -- but all of it would still say "TypeTopology" regardless
of what's actually being searched, which would read as a mistake to
anyone who didn't already know why.

Renaming the tool itself is a different, much bigger job:
`typetopology-search.el`, the `typetopology-search-` prefix on every
symbol inside it, `agda-index.py`, `Definitions.tsv`. Bigger, and
purely mechanical, and not something correctness requires -- only
something that would stop the tool visibly claiming to be about a
library it no longer is.

<sub>[Table of contents](#table-of-contents)</sub>

## Pitfalls

A few things are worth knowing before you start, found by actually
reading the failure paths rather than assuming them.

Get the rendering and the source out of sync, and nothing tells you.
`gather()` looks up a source line from an anchor's own character
offset, purely to work out what scope and what hypotheses a definition
sits inside (see [Architecture](#architecture)). If the rendering in
`html/` was made from a different version of the source than the one
sitting next to it, you don't get an error for it -- you get a definition
quietly attributed to the wrong scope, or a jump that lands on the
wrong line. If the two might have drifted apart, the fix is just to
delete `html/` and let `render()` build it again.

One hole, anywhere, and the whole index build stops -- and there's no
way around it on a repository that uses `--safe`. `render()` treats any
non-zero exit from `agda --html` as fatal, holes included, and Agda's
usual advice for an open interaction point, `--allow-unsolved-metas`,
can't be combined with `--safe` at all. TypeTopology gets away with
this because its own convention is complete, `--safe` proofs
throughout; a repository still being actively worked on, with the odd
hole left in or a mix of safe and unsafe files, would find this tool
simply refuses to build an index until everything type-checks clean.

`NOTIONS` is a short, fixed list of the one- and two-letter names
that are real definitions rather than local variables -- `ap`, `J`,
`K`, `W`, `Id`, `ℕ`, and a handful more, plus any two-letter uppercase
acronym. Anything short that isn't on that list, in someone else's
repository, doesn't get down-ranked or pushed aside -- it's simply
absent from the index, with nothing printed anywhere to say so.

Which points at something bigger than any one of these three: a lot of
what can go wrong here goes wrong quietly. A missing `concepts.tsv`, a
README in the wrong shape, a literate convention this script doesn't
recognise, a name that never made it into `NOTIONS` -- none of it
stops the build, and all of it can leave you with an index that looks
complete and isn't. The one place this script already checks itself is
a half-built `html/` directory, and the comment sitting next to that
check puts it well: it "indexes quietly and looks fine until the
counts are read closely." That's the discipline the rest of a port
needs too. A clean run isn't evidence of a complete index -- only
actually reading the counts it prints at the end (definitions, names,
modules, contributors, concepts) against something you know
independently, a `grep` over the source, a rough sense of how many
definitions there ought to be, is.

<sub>[Table of contents](#table-of-contents)</sub>

## A suggested order

 1. Point `--typetopology` (or `typetopology-search-checkout-root`) at
    the repository you're porting to, and check that `agda --html`
    renders it and `gather()` actually finds definitions. Nothing past
    this point matters if this doesn't work.
 1. If the repository is written in `.lagda.md` or `.lagda.rst`, teach
    `prose_of()` about it before relying on comment search or concept
    discovery -- both read what it produces.
 1. Empty out, or replace, the area-demotion lists and the `HOME`
    table. A few minutes' work, and everything above already works
    correctly without them -- just undifferentiated by area, which is
    a perfectly fine place to start from.
 1. Decide whether contributors and concepts are worth curating for
    this repository. Both stay optional, and neither has to happen now
    -- add them later, without touching anything else.
 1. Leave every "TypeTopology" string alone until all of the above
    actually works, then go through them in one pass at the end.
    They're cosmetic, and doing them first only means testing a
    half-working index twice.

<sub>[Table of contents](#table-of-contents)</sub>
