# Porting this to other Agda developments

This tool was built for TypeTopology. Most of what makes it work,
though, has nothing to do with TypeTopology in particular; only a few
parts do.

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

There is only one program here, `agda-index.py`, and it does
the indexing just once. The search page and the Emacs command are
simply the two things it writes out afterwards.

It begins by rendering the development with `agda --html`, unless a
rendering is already there and newer than every source file, in which
case that step is skipped. From here on the program needs the source
as much as the rendering, since several of the steps below read the
raw `.lagda`/`.agda` text directly rather than the HTML.

Most of the real work happens in gathering the definitions, done by
`gather()`. Agda anchors every definition in its own HTML output, so a
single pass over the rendering already yields both defining and using
occurrences; the anchor convention itself is described in [How the
search is implemented](README.md#how-the-search-is-implemented). The
HTML alone cannot say whether a definition sits inside a `private`
block or an anonymous module, though, nor what hypothesis some
enclosing module took as a parameter without repeating it in the
signature. For that, `gather()` calls a second function, `scopes()`,
to go back to the definition's own line in the source, using the
anchor's character offset to find it. This is why the rendering and
the source must be exactly the same version: if that offset ends up
pointing at the wrong line, nothing here would notice.

The commentary gets a second, separate reading of the same files, this
time for the prose rather than the code, done by `prose_of()`. This is
where a module's discussion of a concept, or its mention of a
contributor, comes from, and, now that comment search has been added,
where each searchable paragraph comes from too, provided the file
follows a literate convention this script actually recognises (see
[Literate Agda variants](#literate-agda-variants) if it does not).
Three further passes over the same material collect the contributors
(`people_of()`), the concepts (`concepts_of()`), and which modules are
not `--safe` (`unsafe_modules()`).

By the time all this is done, everything is just Python data, and two
writers turn it into what people actually use. `write_search_page()`
embeds all of it as JSON inside a single self-contained HTML page,
with the matching and ranking done in JavaScript, in the browser.
`write_emacs_index()` writes the same information out as a
tab-separated file, one row per definition, contributor, concept, or
comment paragraph, with the exact columns listed in [The generated
index files](README.md#the-generated-index-files); the Emacs command
reads that file once and does its own matching and ranking against it,
entirely independently of the browser page. A few further writers,
`write_defs_index()`, `write_identifier_index()`, and
`write_concept_index()`, produce a plain-text index and some
book-style markdown pages that neither front end needs.

Matching, ranking, and the special search syntax are implemented
twice: once in the JavaScript this script writes, and once in the
Emacs command's own Lisp. The two never communicate at runtime, so
there is no single search engine to port once and have both front ends
follow along. Whoever ports this is maintaining two implementations by
hand, kept in step only by care.

Finally, a point about layout rather than code. This tool and the
development it searches live in two separate repositories. Everything
that makes the tool lives here: the indexing script (`agda-index.py`),
the Emacs command (`typetopology-search.el`), the concept vocabulary
(`concepts.tsv`), the Unicode table (`agda-input-escapes.json`). The
development itself is pointed to by `--typetopology`, or, from Emacs,
by `typetopology-search-checkout-root`, and either way it is only ever
read, except for a small scratch directory left inside it when a
rendering has to be produced. Nothing this tool writes ever lands
anywhere near the development it searches.

<sub>[Table of contents](#table-of-contents)</sub>

## What already works for any Agda repository unchanged

Most of what actually does the work does not know or care that it is
TypeTopology. Gathering depends only on how Agda itself writes HTML
and structures a file, since it reads the rendering for anchors and
the source for scope and hypotheses, nothing more. The command-line
options already point wherever they are told to: `--typetopology`,
`--source`, `--html`, and `--entry` all take an arbitrary development,
source directory, and entry module, and a `source/` subdirectory is
only the default guess for `--source`, not something the tool insists
on, so it can simply be given explicitly for a development laid out
differently. `Definitions.tsv`'s own columns, name, module, file,
line, use count, signature, assumed hypotheses, kind, are just as
generic, since nothing ties them to what they happen to contain today.
Comment search works the same way on any `.lagda` file laid out the
usual way, with no configuration needed, provided it follows the
literate convention this script recognises (more on that below). And
the matching itself, wildcards, several words at once, relevance
ranking, restricting a search to one directory, is all plain text and
name matching, so none of it reads anything specific to this library.
The Emacs side is no different: `typetopology-search-checkout-root`
and `typetopology-search-file` already point wherever they are set to,
and the minor mode attaches itself to Agda's own mode hook, which has
never heard of TypeTopology either.

<sub>[Table of contents](#table-of-contents)</sub>

## Literate Agda variants

`prose_of()` knows only one convention, the LaTeX-flavoured `.lagda`
file, where `\begin{code}`/`\end{code}` mark the code and everything
else is prose. A development written in `.lagda.md` instead, using
fenced Markdown code blocks tagged `agda` the way agda-categories and
the cubical library both do, or in `.lagda.rst`, would have neither
marker recognised at all. The whole file would then read as one
undifferentiated block of prose, which would throw off both the
concept search and, now, comment search, since `paragraphs_of()`
depends on the prose being split into paragraphs correctly in the
first place. Supporting either convention means teaching `prose_of()`
a second way to split a file, chosen by its extension, using that
convention's own fence or directive syntax instead of `\begin{code}`.

Plain `.agda` files, with no literate wrapper at all, are already
handled by `comments_of()`, but only line comments starting with `--`
actually make it through: the delimiters of a block comment are
stripped out, but what is left inside is kept only where each
individual line also happens to start with `--`. Write commentary as
a block comment without doing that, and it simply disappears. This is
not a concern for TypeTopology, which has no plain `.agda` files at
all, but it is worth knowing if the development being ported to does.

<sub>[Table of contents](#table-of-contents)</sub>

## The area-demotion lists

Three directories sink to the bottom of the ranking before relevance
is even considered, `Unsafe`, `deprecated`, and `MGS`, in that order,
and the browser page additionally leaves `gist` and `TWA` out of its
own guess at which module a concept is at home in. All five
names are written directly into the code, in three different places:
`AREA` and `SIDELINE` in `agda-index.py`, and
`typetopology-search--entry-area` in `typetopology-search.el`.

None of the reasons behind them travel anywhere else. `Unsafe` relies
on principles the rest of the library gets by without; `deprecated` is
code kept around only for compatibility; `MGS` redevelops, from
scratch, names the library already has, under lecture notes that
happen to live in the same repository. A port inherits none of that
reasoning, so the sensible thing is to turn all three lists into a
small, per-repository list of directories and ranks, and start it
empty, so that every module shares the same rank until told otherwise.

<sub>[Table of contents](#table-of-contents)</sub>

## The one-off name disambiguation

There is exactly one entry in the browser page's own lookup table,
`HOME`, sending the name `is-compact` to the module
`TypeTopology.CompactTypes`, because that one name is defined four
separate times, for four genuinely different notions of compactness,
close enough in how often each is used that nothing else could tell
them apart. This is not something to port so much as something to
build again the same way it was built here, by running a search
against a real development and noticing an ambiguous, popular name. It
starts empty for anyone else, and will probably stay that way for a
while.

`AXIOM_CONCEPTS`, the curated hypotheses shown as assumption badges
(funext, univalence, excluded middle, and so on), and `GENERIC`, the
list of words too ordinary to say where a concept lives, are the same
kind of thing: this library's own vocabulary, not a general mechanism.
`SHOW_AXIOM_BADGES` is already switched off by default, so none of
this needs touching at all unless a port specifically wants the
badges back, in which case it will need its own curated list, built
the same patient way.

<sub>[Table of contents](#table-of-contents)</sub>

## Contributors

`people_of()` finds contributors by reading a README file for a
heading whose text mentions the word "contributor," then collecting
the bulleted list right underneath it, stopping at the next heading.
Which README to read is already a configurable option, `--readme`;
what cannot be changed without editing `people_of()` itself is the
heading-and-bullet convention.

This already fails gracefully, the same way a missing concept
vocabulary does: no matching heading simply means no contributors, not
an error. So there are three ways to handle this in a port:
format the target repository's own README the same way, adjust
`people_of()` to whatever convention it already uses, or simply live
without contributor search.

<sub>[Table of contents](#table-of-contents)</sub>

## Concepts

The format of `concepts.tsv`, five tab-separated columns for the
concept, a prose pattern, an identifier pattern, its landmark
definitions, and an optional alias, travels perfectly well, and is
already written up in the main README, under [The concept
vocabulary](README.md#the-concept-vocabulary). What does not travel is
what is actually in the file: a vocabulary of a library's own
mathematical notions can only be curated by someone who knows that
library, which is exactly how this one was written, a row at a time,
over a long while. Concepts stay entirely optional throughout, since
`concepts_of` simply returns nothing when the file is missing, so
there is no reason a port cannot start without one and grow it later,
the same way this one did.

<sub>[Table of contents](#table-of-contents)</sub>

## Branding and defaults

A handful of strings say "TypeTopology" outright: the search page's own
title and heading, a few Emacs status messages, and the two
command-line options `--typetopology` and `--site`, along with their
defaults, the latter pointing at the live search page,
`https://martinescardo.github.io/TypeTopology/`. None of this changes
what the tool actually does, since pointing `--typetopology` or
`typetopology-search-checkout-root` at some other development already
works today. But all of it would still say "TypeTopology" regardless of
what is actually being searched, which would read as a mistake to
anyone who did not already know why.

Renaming the tool itself is a different, much bigger job:
`typetopology-search.el`, the `typetopology-search-` prefix used by
every symbol inside it, `agda-index.py`, `Definitions.tsv`. This is
bigger, and purely mechanical, and not something correctness requires.
It would only stop the tool from visibly claiming to be about a
library it no longer is.

<sub>[Table of contents](#table-of-contents)</sub>

## Pitfalls

A few things are worth knowing before starting.

If the rendering and the source fall out of step, nothing will tell
you. `gather()` looks up a source line from an anchor's own character
offset, purely to work out what scope and what hypotheses a definition
sits inside (see [Architecture](#architecture)). If the rendering was
made from a different version of the source than the one sitting next
to it, there is no error for this: a definition simply gets attributed
to the wrong scope, or a jump lands on the wrong line. If the two
might have drifted apart, the fix is simply to delete the old
rendering and let `render()` build it again.

A single hole anywhere stops the whole index from being built, and
there is no way around this on a development that uses `--safe`
throughout. `render()` treats any failure from Agda as fatal, whether
it comes from a hole or from an ordinary type error, and Agda's usual
advice for an open interaction point, `--allow-unsolved-metas`, cannot
be combined with `--safe` at all. TypeTopology never runs into this,
because its own convention is complete, safe proofs throughout. A
development still being actively worked on, with the odd hole left in,
or a mix of safe and unsafe files, would find that this tool simply
refuses to build an index until everything type checks.

`NOTIONS`, a short, fixed list, decides which one- and two-letter
names count as real definitions rather than local variables, things
like `ap`, `J`, `K`, `W`, and a handful more, plus any two-letter
uppercase acronym. Anything short that is not on that list, in someone
else's development, is not merely ranked lower for this; it is simply
missing from the index altogether, with nothing printed anywhere to
say so.

This points at something larger: a lot of what can go wrong here goes
wrong quietly. A missing `concepts.tsv`, a README in the wrong shape,
a literate convention `prose_of()` does not recognise, a name that
never made it into `NOTIONS`: none of these stop the index from being
built, and all of them can leave it looking complete when it is not.
The one place this script already checks itself is an incompletely
rendered development, and the comment next to that check states the
general principle well:
it looks fine until the counts are actually read closely. That is the
discipline the rest of a port needs too. A clean run is not evidence
of a complete index. Only reading the counts printed at the end,
definitions, names, modules, contributors, concepts, against something
known independently, such as a rough sense of how many definitions
there ought to be, is.

<sub>[Table of contents](#table-of-contents)</sub>

## A suggested order

 1. Point `--typetopology` (or `typetopology-search-checkout-root`) at
    the development being ported to, and check that Agda's own HTML
    rendering succeeds and that `gather()` actually finds definitions.
    Nothing past this point matters if this does not work.
 1. If the development is written in `.lagda.md` or `.lagda.rst`,
    teach `prose_of()` about it before relying on comment search or
    concept discovery, since both depend on what it produces.
 1. Empty out, or replace, `AREA`, `SIDELINE`,
    `typetopology-search--entry-area`, and `HOME`. This is a few
    minutes' work, and everything above already works correctly
    without them, simply undifferentiated by area.
 1. Decide whether contributors and concepts are worth curating for
    this development. Both stay optional, and neither has to happen
    now; they can be added later, without touching anything else.
 1. Leave every occurrence of the word "TypeTopology" alone until
    everything above actually works, then go through them in one pass
    at the end. They are purely cosmetic, and doing them first would
    only mean testing a half-working index twice.

<sub>[Table of contents](#table-of-contents)</sub>
