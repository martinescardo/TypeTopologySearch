# TypeTopologySearch

We provide a [search
page](https://martinescardo.github.io/TypeTopologySearch.html) and an
[Emacs search command](#installing-the-emacs-command) for
[TypeTopology](https://github.com/martinescardo/TypeTopology).

## Table of contents

 1. [Installing the Emacs command](#installing-the-emacs-command)
 1. [Compiling it](#compiling-it)
 1. [Using the Emacs command](#using-the-emacs-command)
 1. [What you can search for in Emacs](#what-you-can-search-for-in-emacs)
 1. [The Emacs command in detail](#the-emacs-command-in-detail)
 1. [Finding agda-index.py](#finding-agda-indexpy)
 1. [Acting on a result](#acting-on-a-result)
 1. [Regenerating the index](#regenerating-the-index)
 1. [Using the browser search page](#using-the-browser-search-page)
 1. [What you can search for in the browser page](#what-you-can-search-for-in-the-browser-page)
 1. [Browsing the concept list](#browsing-the-concept-list)
 1. [Selecting and sharing a result](#selecting-and-sharing-a-result)
 1. [Buttons on each result](#buttons-on-each-result)
 1. [Typing Unicode in the browser page](#typing-unicode-in-the-browser-page)
 1. [Generating it yourself](#generating-it-yourself)
 1. [The generated index files](#the-generated-index-files)
 1. [Adding a concept](#adding-a-concept)
 1. [The Unicode escape table](#the-unicode-escape-table)
 1. [How the search is implemented](#how-the-search-is-implemented)
 1. [Makefile](#makefile)

## Installing the Emacs command

See the [Makefile](#makefile) for a `make install` command that does
everything below automatically, with nothing left to configure by
hand. What follows is the manual equivalent.

    (add-to-list 'load-path "/path/to/TypeTopologySearch")
    (setq typetopology-search-checkout-root "/path/to/TypeTopology")
    (require 'typetopology-search)

Make sure you have clones of this repository and TypeTopology, and point
`typetopology-search-checkout-root` at the TypeTopology directory before
requiring the file. The command `typetopology-search`
builds its own index the first time it is used. See
[The Emacs command in detail](#the-emacs-command-in-detail) for how this
works.

<sub>[Table of contents](#table-of-contents)</sub>

## Compiling it

`make install` (see the [Makefile](#makefile)) does this too.
Byte-compiling is optional on its own. Run

    ./compile-emacs-command

once after cloning or pulling, and Emacs picks up the resulting
`typetopology-search.elc` automatically from then on. It makes search
significantly faster.

<sub>[Table of contents](#table-of-contents)</sub>

## Using the Emacs command

`M-x typetopology-search`, or its shorthand `M-x ttsearch`, bound to
`C-c C-g` in Agda buffers, looks a name or a piece of a type signature up
against the whole library. Type to filter the results, shown in their
own window. The arrow keys move a highlighted selection over them, and
RET acts on it, inserting the name at point, jumping to its definition,
or inserting `open import Module` for it, whichever you last chose, or
asking the first time. TAB always asks. See
[The Emacs command in detail](#the-emacs-command-in-detail) for more.

<sub>[Table of contents](#table-of-contents)</sub>

## What you can search for in Emacs

Several words take the intersection of the results, case-insensitively,
against a substring of a definition's name, type signature or module.
`*` stands for any run of characters and `?` for one, and `\*` for a
literal star, since `*` occurs in names such as `ℤ*-assoc`, the same
wildcard syntax the [browser-based
search](#what-you-can-search-for-in-the-browser-page) uses.

<sub>[Table of contents](#table-of-contents)</sub>

## The Emacs command in detail

Requiring `typetopology-search.el` also defines `typetopology-mode`, a
minor mode that attaches itself to every agda2-mode buffer automatically,
via `agda2-mode-hook`, and binds `C-c C-g` there to the search command.
On first use, this command builds a TypeTopology index.

`typetopology-search` looks a name or a piece of a type signature up
against the whole library, not just what the current buffer happens to
have imported.

Compared to Agda's `agda2-search-about-toplevel`, bound by agda2-mode
to `C-c C-z`, we index to make search both faster and more relevant,
and we also search for names that are not necessarily in scope.

A match is any entry whose text contains each word typed so far, in any
order, case-insensitively. We rank them most relevant first, namely an
exact name match, then a name starting with a word, then a word starting
a hyphenated part of the name, then anywhere else in the name, then a
word found only in the signature or module, ties broken by use count.
This is the identical two-level ranking the browser search uses, so the
two never disagree about which result comes first.

Up and down arrows move a highlighted selection over that list.  Each
result shows an "(assumes: ...)" clause, an enclosing-module
hypothesis, such as `funext` or a whole record's worth of structure,
that never shows up in a definition's own signature.

<sub>[Table of contents](#table-of-contents)</sub>

## Acting on a result

Plain RET repeats whatever action was chosen last, except the very
first time in a session, when a menu offers the choices. TAB always
opens the action menu for the currently selected result.

<sub>[Table of contents](#table-of-contents)</sub>

## Finding agda-index.py

We look for the file `agda-index.py` in the same directory as
`typetopology-search.el` first. If `typetopology-search.el` was copied
somewhere else on its own, with no such sibling, we fall back to
whatever `agda-index.py` is found on `$PATH` instead. Adding this
repository to `$PATH`, or just a symlink to `agda-index.py` there,
both work.

<sub>[Table of contents](#table-of-contents)</sub>

## Regenerating the index

The index is not kept in sync with the source automatically after that
first build. Run `M-x typetopology-search-regenerate-index` after
adding, renaming, or removing definitions, to pick up the difference.

<sub>[Table of contents](#table-of-contents)</sub>

## Using the browser search page

The search page is at

<https://martinescardo.github.io/TypeTopologySearch.html>

It is a self-contained file with no server behind it, so it works just
as well from a local copy, opened directly in a browser. [Generate
your own copy](#generating-it-yourself) if you want. The page's footer
has a build time stamp.

<sub>[Table of contents](#table-of-contents)</sub>

## What you can search for in the browser page

* **Definitions.** We index every publicly visible name in the
  library, including records, datatypes, fields and
  constructors. Each links to where it is defined in the rendered
  Agda, and, when it has one, shows its type too, so most of the time
  you can tell whether a hit is the one you want without leaving the
  page. We keep a record or datatype's own parameters in the preview.

  With "search within type signatures too", a word can also match
  inside that type rather than the name. A hypothesis taken once as a
  module parameter, rather than repeated in each individual signature,
  never appears in any individual definition's own type at all. "List
  every enclosing assumption" shows the parameter list of every module
  enclosing a definition.

* **Concepts.** We list a vocabulary of mathematical notions in
  `concepts.tsv`, each naming the definitions that are the concept and
  the modules whose commentary discusses it. This was first
  constructed automatically by a heuristic matching comments to Agda
  code, number of occurrences etc., and then some concepts were added
  manually. These play the role of the concepts listed in a
  mathematical textbook.

* **Contributors.** We list the people of TypeTopology's own top-level
  `README.md`, with the modules that name them.

Several words all have to match, so `compact ordinal` asks for compactness
within the ordinals, matching a word against either a definition or its
module. `*` stands for any run of characters and `?` for one, and `\*` for
a literal star, since `*` occurs in names such as `ℤ*-assoc`.

A word followed by `in` followed by another word restricts the search
to one directory or file. For instance, `compact in Ordinals.Comp`
looks for `compact` only within files matching `Ordinals.Comp`. Every
segment but the last has to match in full, but the last segment is a
prefix, so it also narrows the results while still being typed, which
is why `Ordinals.Comp` already reaches
`Ordinals.CompactnessOfSuprema`. This scopes definitions, concepts,
and contributors alike, so a concept only survives `in` if one of its
own definitions or one of its discussing modules lies within the path,
and only those matching modules are then shown.

<sub>[Table of contents](#table-of-contents)</sub>

## Browsing the concept list

We also list the concepts alphabetically as clickable links to allow
browsing the concepts, like in a textbook index. Once a concept is
clicked, it is entered into the search box and the search is run
immediately.

<sub>[Table of contents](#table-of-contents)</sub>

## Selecting and sharing a result

The arrow keys move a selection through the results without leaving the
box, and Enter follows it, so a search can be typed and its result opened
without ever touching the mouse.

A search is also a link. Typing one puts it in the URL as `#q=...`, so
the address bar itself can be bookmarked or sent to someone else and
lands on the same results. A search replaces this fragment rather than
piling one up per keystroke, so the back button has nothing to undo.

<sub>[Table of contents](#table-of-contents)</sub>

## Buttons on each result

The ⧉ next to a result's module copies `open import` for that module to
the clipboard.

A result's use-count is itself a button. Clicking it opens the modules
it is used from, each with how many times there, counted per module
rather than per call site. A module's own count in that list is a
second such button, opening which definitions of that module use the
result, each linking to that definition.

<sub>[Table of contents](#table-of-contents)</sub>

## Typing Unicode in the browser page

The search box also takes Unicode the way the Agda emacs mode does. `\to`
and `\MCU` become "→" and "𝓤" as you type them, and a key with several
candidates, such as `\:`, takes a following digit to pick among them.
`\:4` reaches "꞉", the library's own binder colon, the fourth of the
eleven ways `\:` alone knows how to type a colon.

<sub>[Table of contents](#table-of-contents)</sub>

## Generating it yourself

    ./generate-search-page /path/to/TypeTopology
    ./generate-definitions /path/to/TypeTopology

We provide two thin wrapper scripts for the common case, also runnable
as `make search-page` and `make definitions` (see the
[Makefile](#makefile)). The first writes `search.html`. The second
writes `Definitions.tsv`, the same way `typetopology-search.el`'s
bootstrap does. Both call `agda-index.py` with `--typetopology` set to
their one argument. Read on for what that script takes directly, for
anything these two do not cover.

When running the script `agda-index.py`, the option `--typetopology
<path/to/TypeTopology>` must be given.

The script runs `agda --html`, into a temporary directory, and skips
doing so when that rendering is already newer than every source
file. Useful options:

    --html <dir>    index a rendering you already have, and never run agda
    --source <dir>  the source directory, if not simply <typetopology>/source
    --readme <file> the readme whose contributor list names the people, if
                    not simply <typetopology>/README.md
    --markdown      also write the book-style concept and identifier indexes
    --json          also write definitions.json, for other tools
    --defs-index    also write Definitions.txt, a flat plain-text index
    --emacs-index   also write Definitions.tsv, for typetopology-search.el
    --no-html       skip search.html
                    concepts.tsv and agda-input-escapes.json are then
                    not needed; typetopology-search.el's bootstrap
                    uses this.

<sub>[Table of contents](#table-of-contents)</sub>

## The generated index files

`Definitions.txt` is for grep rather than browsing. There is no HTML,
no pagination, everything on one line, namely a name, its signature
where one could be read off the rendering, the module and use count it
was found with, and any hypothesis, such as `fe : funext 𝓤 𝓥` or a
whole record's worth of structure, taken by an enclosing module rather
than repeated in the signature itself, since that never shows up any
other way. We sort it by name, so several definitions sharing one name
sit together. It serves the same purpose the browser page does, aimed
instead at a terminal and a text editor, for looking up an exact name
and type before writing code against it, or for checking whether
TypeTopology already has what is needed rather than reproving it.
Regenerate it before relying on it. Like everything else here, it is
not kept up to date automatically.

`Definitions.tsv` serves the same purpose again, this time for a program
rather than a person, namely one definition per line, the same fields as
`Definitions.txt` plus source file and line, for jumping to a
definition, which `Definitions.txt` has no need of. It is tab-separated
rather than folded into one pretty-printed line, since a signature can
itself contain `[` or `]`, as in `ℤ[1/2]`, which would make
Definitions.txt's own format awkward to parse back out reliably. It is
what `typetopology-search.el` reads. Nothing about it is specific to
that one script.

The concept vocabulary belongs to `concepts.tsv` instead, already in a
form suited to being read directly.

<sub>[Table of contents](#table-of-contents)</sub>

## Adding a concept

Append a line to `concepts.tsv`, which has five tab-separated columns,
namely the concept, a pattern for finding it in the commentary, a
pattern for finding the definitions that carry its name, the few
definitions that *are* the concept, shown first and in bold, and an
optional search alias.

    injective type <TAB> injectiv <TAB> ainjectiv|... <TAB> ainjective-type, injective-type <TAB>

The alias is for a word that should find the concept in the search box
without being fit to widen the commentary scan, unlike the second
column, which does feed that scan to decide which modules are
"discussed in" a concept. Leave it empty when the second column already
covers the word, which is the common case.

Two things are worth checking before adding a row. The pattern should be
cut back to the point where every variant of the notion is caught but no
unrelated word is. And the named definitions should be checked to exist,
since a name that seems obvious is often not the one the library uses.

<sub>[Table of contents](#table-of-contents)</sub>

## The Unicode escape table

`agda-input-escapes.json` powers the `\to`/`\MCU` typing
described above. It is the emacs Agda input method's key table, dumped
from a running Emacs rather than hand-copied, since large parts of it,
accented Latin letters, and every spelled-out Greek letter such as
`\Sigma`, alongside the terser `\GS` form Agda's own file defines
directly, only exist once Emacs's own Quail machinery has resolved them
at load time, not as literal text anywhere in Agda's own `agda-input.el`.
To regenerate it, also runnable as `make agda-input-dump` (see the
[Makefile](#makefile)):

    ./generate-agda-input-dump

This needs `latin-ltx.el` on Emacs's `load-path`, or simply sitting in
the same directory as `agda-input.el`, which is on the path by default
when both are in the current directory. The dump has one key per line,
`KEY<TAB>VALUE`, its own leading backslash included in KEY. VALUE is a
single Unicode codepoint, a literal character, or a bracketed
space-separated list of either when a key has several candidates. From
there we strip the backslash, decode each numeric candidate to its
character, drop any candidate that is itself plain ASCII, offered by
Quail as a do-nothing choice, such as `\eq`'s first candidate being a
bare `=`, and keep the first surviving candidate as the key's value,
or the whole list when more than one survives, so that the search
page's own digit-selection can reach the rest.

<sub>[Table of contents](#table-of-contents)</sub>

## How the search is implemented

We use the Agda-generated html rendering as input rather than the Agda
source files, because Agda anchors every definition there. A defining
occurrence is an anchor whose id is the fragment of its own href,

    <a id="3787" href="TypeTopology.CompactTypes.html#3787" ...>is-Σ-compact</a>

and every use elsewhere is an anchor with a different id and the same
href, so one pass gives us both the links and a count of how often each
definition is used. Agda also writes a named anchor just before the
numbered one, and links use the name where there is one, since the
number is a character offset that moves whenever the file is edited
while the name does not. This holds for four fifths of the definitions;
the rest are members of anonymous modules and record fields, for which
Agda writes no named anchor.

We index top-level definitions, members of submodules however deeply
indented, members of anonymous modules, record types and their fields,
and data types and their constructors. We do not index definitions in
`where` and `let` clauses, definitions in `private` blocks, the name `_`,
and one- and two-letter names used as variables, except for acronyms such
as `EM` and `AC` and for the short names that are notions rather than
variables, such as `ap`, `J` and `W`.

<sub>[Table of contents](#table-of-contents)</sub>

## Makefile

    make all TYPETOPOLOGY=/path/to/TypeTopology

runs every script above. Each is also its own target, so

    make definitions TYPETOPOLOGY=/path/to/TypeTopology

runs just that one.

* `search-page` and `definitions` need `TYPETOPOLOGY` set, the same
  path `./generate-search-page` and `./generate-definitions` take.
* `agda-input-dump` and `compile` need nothing.

To set the Emacs command up with nothing left to configure by hand, run

    make install TYPETOPOLOGY=/path/to/TypeTopology EMACSDIR=/path/to/emacs/configuration/directory

* It symlinks `typetopology-search.el`, its byte-compiled form if
  `compile` has been run, and `agda-index.py` into
  `EMACSDIR/typetopology-search`, so a later `git pull` here needs no
  reinstalling.
* It builds the index there for `TYPETOPOLOGY`.
* It appends a load-path, checkout-root, and `require` snippet to
  `EMACSDIR/init.el`, or `~/.emacs` if that does not exist, unless it
  looks like this has already been done. This is the same file
  Agda's own `agda --emacs-mode setup` would use.

Neither has to be given:

* `TYPETOPOLOGY` defaults to `~/TypeTopology`.
* `EMACSDIR` defaults to `~/.emacs.d`.

`TT` and `E` are shorter aliases for `TYPETOPOLOGY` and `EMACSDIR`, so

    make install TT=/path/to/TypeTopology E=/path/to/emacs/configuration/directory

is the same command.

<sub>[Table of contents](#table-of-contents)</sub>
