# TypeTopologySearch

We provide a [search
page](https://martinescardo.github.io/TypeTopologySearch.html) and an
[Emacs search command](#installing-the-emacs-command) for
[TypeTopology](https://github.com/martinescardo/TypeTopology).

## Table of contents

 1. [Installing the Emacs command](#installing-the-emacs-command)
    1. [Using the Makefile](#using-the-makefile)
    1. [Manually](#manually)
    1. [Compiling it](#compiling-it)
 1. [Using the Emacs command](#using-the-emacs-command)
    1. [Overview](#overview)
    1. [Acting on a result](#acting-on-a-result)
    1. [What you can search for in Emacs](#what-you-can-search-for-in-emacs)
    1. [In detail](#in-detail)
 1. [Using the search page](#using-the-search-page)
    1. [Overview](#overview-1)
    1. [What you can search for in the search page](#what-you-can-search-for-in-the-search-page)
    1. [Buttons on each result](#buttons-on-each-result)
    1. [Typing Unicode](#typing-unicode)
 1. [Further details](#further-details)
    1. [Generating the search page and index](#generating-the-search-page-and-index)
    1. [The generated index files](#the-generated-index-files)
    1. [Finding agda-index.py](#finding-agda-indexpy)
    1. [Updating the index](#updating-the-index)
    1. [The concept vocabulary](#the-concept-vocabulary)
    1. [The Unicode escape table](#the-unicode-escape-table)
    1. [How the search is implemented](#how-the-search-is-implemented)
    1. [Other Makefile targets](#other-makefile-targets)
 1. [Porting this to other Agda developments](#porting-this-to-other-agda-developments)

## Installing the Emacs command

Clone this repository first, with one of the following commands:

    git clone git@github.com:martinescardo/TypeTopologySearch.git

or

    git clone https://github.com/martinescardo/TypeTopologySearch.git

or

    gh repo clone martinescardo/TypeTopologySearch

### Using the Makefile

To install the Emacs command after cloning this repository, run

    make install TYPETOPOLOGY=/path/to/TypeTopology EMACSDIR=/path/to/emacs/configuration/directory

or the shorthand

    make install TT=/path/to/TypeTopology E=/path/to/emacs/configuration/directory

Neither has to be given:

* `TYPETOPOLOGY` defaults to `~/TypeTopology`.
* `EMACSDIR` defaults to `~/.emacs.d`.

This sets everything up with nothing left to configure by hand, and
remembers both paths, so a later

    make update

needs no arguments.

<sub>[Table of contents](#table-of-contents)</sub>

### Manually

    (add-to-list 'load-path "/path/to/TypeTopologySearch")
    (setq typetopology-search-checkout-root "/path/to/TypeTopology")
    (require 'typetopology-search)

Make sure you have clones of this repository and `TypeTopology`, and point
`typetopology-search-checkout-root` at the `TypeTopology` directory before
requiring the file. The command `typetopology-search`
builds its own index the first time it is used. See
[The Emacs command in detail](#in-detail) for how this
works.

<sub>[Table of contents](#table-of-contents)</sub>

### Compiling it

`make install` (see [Using the Makefile](#using-the-makefile)) does
this too. Byte-compiling is optional on its own. Run

    ./compile-emacs-command

once after cloning or pulling, and Emacs picks up the resulting
`typetopology-search.elc` automatically from then on. It makes search
significantly faster.

<sub>[Table of contents](#table-of-contents)</sub>

## Using the Emacs command

### Overview

`M-x typetopology-search`, or its shorthand `M-x ttsearch`, bound to
`C-c C-g` in Agda buffers, looks a name or a piece of a type signature up
against the whole library. Type to filter the results, shown in their
own window. The arrow keys move a highlighted selection over them, and
RET acts on it, inserting the name at point, jumping to its definition,
or inserting `open import Module` for it, whichever you last chose, or
asking the first time. TAB always asks. `C-h` shows a brief syntax
cheatsheet without leaving the search. See
[In detail](#in-detail) for more.

<sub>[Table of contents](#table-of-contents)</sub>

### Acting on a result

Plain RET repeats whatever action was chosen last, except the very
first time in a session, when a menu offers the choices. TAB always
opens the action menu for the currently selected result. The menu's
last choice, updating the index, is not about the result at all, and
so never becomes what plain RET repeats afterward.

A contributor, a concept, or a comment has only one action, jumping to
the module it was found in, so both RET and TAB go straight there with
no menu step at all -- and, for a comment, with no "which module?"
prompt either, since a paragraph is only ever found in exactly one.

<sub>[Table of contents](#table-of-contents)</sub>

### What you can search for in Emacs

Several words take the intersection of the results, case-insensitively,
against a substring of a definition's name, type signature or module.
`*` stands for any run of characters and `?` for one, and `\*` for a
literal star, since `*` occurs in names such as `ℤ*-assoc`.

The same three kinds of entries as the [search
page](#what-you-can-search-for-in-the-search-page) -- definitions,
concepts, and contributors -- are searched together here too, and a
word followed by `in` followed by another word restricts the search to
one directory or file the same way. The one difference: only a
definition's own module is scoped this way in Emacs. A contributor or
concept has no source file of its own, so neither ever survives an
`in` query here, unlike on the search page, where a concept's or
contributor's mentioning modules count for `in` too.

A query starting `--` (Agda's own comment marker; no space needed
after it, so `--compact` and `-- compact` both work) searches the
library's prose commentary instead, excluding every definition,
contributor, and concept -- and, the other way round, an ordinary
query never matches a paragraph of commentary. This is the Emacs
equivalent of the search page's own "search within commentary instead"
checkbox (see [below](#what-you-can-search-for-in-the-search-page)),
written as a query prefix since there is no minibuffer checkbox to
tick. Unlike a contributor or concept, a paragraph belongs to exactly
one module, so it is scoped by `in PATH` exactly like a definition:
`-- compact in Ordinals` composes the two. Set
`typetopology-search-include-comments` to nil to drop these entries
at load time if they turn out to make filtering noticeably slower on
a real library.

<sub>[Table of contents](#table-of-contents)</sub>

### In detail

Requiring `typetopology-search.el` also defines `typetopology-mode`, a
minor mode that attaches itself to every agda2-mode buffer automatically,
via `agda2-mode-hook`, and binds `C-c C-g` there to the search command.
On first use, this command builds a `TypeTopology` index if it isn't
already built.

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

Everything in `Unsafe` comes last of all, everything in `deprecated`
comes just above it, and everything in `MGS` comes above that, since
those lecture note files redevelop from scratch names the library
already has, so an unqualified search for one of them means the
library's own. Every other directory shares the top rank and is
ordered by relevance alone.  This outranks relevance itself: an exact
name match in `Unsafe` or `deprecated` still comes after a mere
substring match in a live module. Searching `in Unsafe`, `in
deprecated` or `in MGS` explicitly is unaffected.

Up and down arrows move a highlighted selection over that list.  Each
result shows an "(assumes: ...)" clause, an enclosing-module
hypothesis, such as `funext` or a whole record's worth of structure,
that never shows up in a definition's own signature.

<sub>[Table of contents](#table-of-contents)</sub>

## Using the search page

### Overview

The search page is at

<https://martinescardo.github.io/TypeTopologySearch.html>

It is a self-contained file with no server behind it, so it works just
as well from a local copy, opened directly in a browser. [Generate
your own copy](#generating-the-search-page-and-index) if you want. The
page's footer has a build time stamp.

The arrow keys move a selection through the results without leaving the
box, and Enter follows it, so a search can be typed and its result opened
without ever touching the mouse.

A search is also a link. Typing one puts it in the URL as `#q=...`, so
the address bar itself can be bookmarked or sent to someone else and
lands on the same results. A search replaces this fragment rather than
piling one up per keystroke, so the back button has nothing to undo.

<sub>[Table of contents](#table-of-contents)</sub>

### What you can search for in the search page

* **Definitions.** We index every publicly visible name in the
  `TypeTopology` repository, including records, datatypes, fields and
  constructors. Each links to where it is defined in the rendered
  Agda, and, when it has one, shows its type too, so most of the time
  you can tell whether a hit is the one you want without leaving the
  page. We keep a record or datatype's own parameters in the preview.

  With "search within type signatures too", a word can also match
  inside that type rather than just the name. A hypothesis taken once as a
  module parameter, rather than repeated in each individual signature,
  never appears in any individual definition's own type at all. "List
  every enclosing assumption" shows the parameter list of every module
  enclosing a definition.

* **Concepts.** We list a vocabulary of mathematical notions in
  `concepts.tsv`, each naming the definitions that are the concept and
  the modules whose commentary discusses it. This was first
  constructed automatically by a heuristic matching comments to Agda
  code and counting occurrences, and then some concepts were added
  manually. These play the role of the concepts listed in a
  mathematical textbook index.

* **Contributors.** We list the people of `TypeTopology`'s own top-level
  `README.md`, with the modules that name them.

* **Comments.** With "search within commentary instead" ticked, the
  search becomes one over the library's prose commentary alone, one
  paragraph per result, in place of definitions, concepts, and
  contributors rather than alongside them. Off by default: prose is
  both the single biggest chunk of text in the index and the likeliest
  to hit a plain word by accident. A comment is scoped by `in PATH`
  (below) exactly like a definition, since each paragraph belongs to
  exactly one module.

Several words all have to match, so `compact ordinal` asks to match
both compact and ordinal, matching a word against either a definition
or its module. `*` stands for any run of characters and `?` for one,
and `\*` for a literal star, since `*` occurs in names such as
`ℤ*-assoc`.

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

Results are ranked the same way the Emacs command ranks them, `Unsafe`
last, `deprecated` next to last and `MGS` above those, described in
[The Emacs command in detail](#in-detail).

We also list the concepts alphabetically as clickable links to allow
browsing the concepts, like in a textbook index. Once a concept is
clicked, it is entered into the search box and the search is run
immediately.

<sub>[Table of contents](#table-of-contents)</sub>

### Buttons on each result

The ⧉ next to a result's module copies `open import` for that module to
the clipboard.

A result's use-count is itself a button. Clicking it opens the modules
it is used from, each with how many times there, counted per module
rather than per call site. A module's own count in that list is a
second such button, opening which definitions of that module use the
result, each linking to that definition.

<sub>[Table of contents](#table-of-contents)</sub>

### Typing Unicode

The search box also takes Unicode the way the Agda emacs mode does. `\to`
and `\MCU` become "→" and "𝓤" as you type them, and a key with several
candidates, such as `\:`, takes a following digit to pick among them.
`\:4` reaches "꞉", the library's own binder colon, the fourth of the
eleven ways `\:` alone knows how to type a colon.

<sub>[Table of contents](#table-of-contents)</sub>

## Further details

### Generating the search page and index

    ./generate-search-page /path/to/TypeTopology
    ./generate-definitions /path/to/TypeTopology

We provide two thin wrapper scripts for the common case, also runnable
as `make search-page` and `make definitions` (see [Other Makefile
targets](#other-makefile-targets)). The first writes
`TypeTopologySearch.html`. The second writes `Definitions.tsv`, the
same way `typetopology-search.el`'s bootstrap does. Both call
`agda-index.py` with `--typetopology` set to their one argument; the
script itself takes several more options than either wrapper exposes.

When running the script `agda-index.py`, the option `--typetopology
<path/to/TypeTopology>` must be given.

The script runs `agda --html`, into `<typetopology>/html`, and skips
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
    --no-html       skip TypeTopologySearch.html
                    concepts.tsv and agda-input-escapes.json are then
                    not needed; typetopology-search.el's bootstrap
                    uses this.

<sub>[Table of contents](#table-of-contents)</sub>

### The generated index files

`Definitions.txt` is for `grep` rather than browsing. There is no
HTML, no pagination. Each line has a name, its signature, the module
and use count it was found with, and any hypothesis, such as `fe :
funext 𝓤 𝓥` or a whole record's worth of structure, taken by an
enclosing module. We sort it by name, so several definitions sharing
one name sit together. It serves the same purpose the search page
does, aimed instead at a terminal and a text editor, for looking up an
exact name and type before writing code against it, or for checking
whether `TypeTopology` already has what is needed rather than
reproving it.  Regenerate it before relying on it. Like everything
else here, it is not kept up to date automatically.

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

### Finding agda-index.py

We look for the file `agda-index.py` in the same directory as
`typetopology-search.el` first. If `typetopology-search.el` was copied
somewhere else on its own, with no such sibling, we fall back to
whatever `agda-index.py` is found on `$PATH` instead. Adding this
repository to `$PATH`, or just a symbolic link to `agda-index.py`
there, both work.

<sub>[Table of contents](#table-of-contents)</sub>

### Updating the index

`typetopology-search-warn-when-stale`, on by default, notices whenever
the source has a definition newer than the index and shows a bold
reminder right alongside the results -- search still works regardless,
just possibly missing recent definitions. Press `C-c C-u` during the
search to update it right there, or run `M-x
typetopology-search-update-index` at any other time. Set the
variable to nil to turn off the check and the reminder.

The index cannot be updated when there are holes or files that don't
type check, because the option `--allow-unsolved-metas` is
incompatible with `--safe`, which is used by the vast majority of the
`TypeTopology` files.

<sub>[Table of contents](#table-of-contents)</sub>

### The concept vocabulary

To add a new concept, append a line to `concepts.tsv`. Each row has five tab-separated
columns: the concept, a pattern for finding it in the commentary, a
pattern for finding the definitions that carry its name, the few
definitions that *are* the concept (shown first and in bold), and an
optional search alias.

    injective type <TAB> injectiv <TAB> ainjectiv|... <TAB> ainjective-type, injective-type <TAB>

The alias is for a word that should find the concept in the search box
without being fit to widen the commentary scan, unlike the second
column, which does feed that scan to decide which modules are
"discussed in" a concept. Leave it empty when the second column already
covers the word, which is the common case.

The pattern should be cut back to the point where every variant of the
notion is caught but no unrelated word is, and the named definitions
should be checked to exist, since a name that seems obvious is often
not the one the library uses.

<sub>[Table of contents](#table-of-contents)</sub>

### The Unicode escape table

`agda-input-escapes.json` powers the unicode typing described
above. It is the emacs Agda input method's key table, dumped from a
running Emacs rather than hand-copied. That is because large parts of
it -- accented Latin letters, and every spelled-out Greek letter such
as `\Sigma`, alongside the terser `\GS` form Agda's own file defines
directly -- only exist once Emacs's own Quail machinery has resolved
them at load time, not as literal text anywhere in Agda's own
`agda-input.el`.  To regenerate it, also runnable as `make
agda-input-dump` (see [Other Makefile
targets](#other-makefile-targets)):

    ./generate-agda-input-dump

This needs `latin-ltx.el` on Emacs's `load-path`, or simply sitting in
the same directory as `agda-input.el`, which is on the path by default
when both are in the current directory. The dump has one key per line,
`KEY<TAB>VALUE`, its own leading backslash included in KEY. VALUE is a
single Unicode codepoint, a literal character, or a bracketed
space-separated list of either when a key has several candidates. From
there we strip the backslash, decode each numeric candidate to its
character, and drop any candidate that is itself plain ASCII, offered
by Quail as a do-nothing choice, such as `\eq`'s first candidate being
a bare `=`. We then keep the first surviving candidate as the key's
value, or the whole list when more than one survives, so that the
search page's own digit-selection can reach the rest.

<sub>[Table of contents](#table-of-contents)</sub>

### How the search is implemented

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

### Other Makefile targets

* `install` also builds `search-page`, `definitions` and `compile`.
* `all` builds those three plus `agda-input-dump` too.
* Each of the above is also a build target on its own.

See the [Makefile](Makefile) itself for further details.

<sub>[Table of contents](#table-of-contents)</sub>

## Porting this to other Agda developments

This was built for TypeTopology, but most of what we have here should
work for any repository. Reading Agda's own HTML rendering, ranking
results, and handling wildcards are not about TypeTopology at all;
what is, is a handful of names fixed in the code, plus a couple of
things specific to how TypeTopology itself is organised. [Porting.md](Porting.md)
goes through all of it, for anyone who wants to port this to another
Agda development.

<sub>[Table of contents](#table-of-contents)</sub>
