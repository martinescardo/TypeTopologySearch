#!/usr/bin/env python3
"""Generate an index of TypeTopology from its html rendering.

Usage:

    agda-index.py --typetopology /path/to/TypeTopology

It runs agda --html itself, into <typetopology>/html, and skips doing so
when that rendering is newer than every source file. The index is written
beside this script. To index a rendering you already have, and never invoke
agda, pass it:

    agda-index.py --typetopology /path/to/TypeTopology --html <dir>

This writes TypeTopologySearch.html, a self-contained interactive search
page, which is deployed by hand to

    https://martinescardo.github.io/TypeTopologySearch.html

With --markdown it also writes the book-style indexes that came first: the
concepts of concepts.tsv in ConceptIndex.md and Concept-A.md ..., and every
definition alphabetically in IdentifierIndex.md, A.md ...

The html is the input rather than the sources because Agda anchors every
definition there. A defining occurrence is an anchor whose id equals the
fragment of its own href,

    <a id="3787" href="TypeTopology.CompactTypes.html#3787" ...>is-Σ-compact</a>

and every use elsewhere is an anchor with a different id but the same href,
which is what makes both deep links and reference counts possible.

What is indexed: top-level definitions, members of submodules however deeply
indented, members of anonymous modules, record types and their fields, and
data types and their constructors.

What is not: definitions in where and let clauses, definitions in private
blocks, the name _ of an anonymous module, and single- or double-letter names
used as local variables, except two-letter uppercase acronyms such as EM, DC
and AC, and the short names listed in NOTIONS, such as ap, J and W, which are
notions rather than variables.
"""

import argparse, bisect, collections, datetime, glob, html, json, os, re
import subprocess, unicodedata

KIND = r"(Function|Datatype|Record|Postulate|Primitive|Field|Module|Macro|" \
       r"InductiveConstructor)( Operator)?"
GREEK_LOWER = {chr(c) for c in range(0x3B1, 0x3CA)}
MARKS = set("₀₁₂₃₄₅₆₇₈₉'′⁻⁺0123456789")
# Short names that are notions rather than local variables, and so are kept.
NOTIONS = {"ap", "J", "K", "W", "Id", "Ω", "ℕ", "ℚ", "ℝ", "ℤ", "𝟘", "𝟙", "𝟚"}

# A concept lists definitions that may be defined in several modules, and one
# of them has to be linked. True prefers a site whose module name carries a
# word of the concept; False takes the most used site wherever it is. Either
# way a --safe module is preferred to an unsafe one. Set to False to go back.
LINK_IN_OWN_AREA = True


# ---------------------------------------------------------------- scopes

def scopes(text, literate=True):
    """For each line, the stack of enclosing scopes.

    A scope is ('module', indent, name, header) for anything whose members
    stay accessible from outside -- module, record, data, field,
    constructor -- and ('local', indent, None, '') or ('private', ...) for
    anything whose members do not. In literate files only code blocks are
    inspected, since prose may well contain a line ending in the word
    "where". `header` is the declaration's own parameter list -- for a
    `module M (fe : Fun-Ext) where`, everything between the name and
    "where" -- which a defining line further in never repeats, so a
    hypothesis introduced this way (a common pattern here) is otherwise
    invisible to anything reading only each definition's own signature.
    The declaration's own NAME is deliberately excluded: a module or
    record can be named almost anything, and a name like
    `Univalent-Choice` would otherwise look, to a check for whether
    "univalence" or "choice" occurs in the text, exactly like actually
    taking one as a parameter.
    """
    out, stack, pending = [], [], None
    incode = not literate
    for raw in text.split("\n"):
        if literate:
            if raw.startswith("\\begin{code}"): incode = True;  out.append(list(stack)); continue
            if raw.startswith("\\end{code}"):   incode = False; out.append(list(stack)); continue
            if not incode:                                      out.append(list(stack)); continue
        line = raw.rstrip(); stripped = line.strip()
        indent = len(line) - len(line.lstrip()) if stripped else 0
        if stripped:
            while stack and indent <= stack[-1][1]:
                stack.pop()
        out.append(list(stack))
        if not stripped:
            continue
        # A module header can span several lines before its own "where";
        # every line until then, this one included, is part of it.
        if pending is not None and not re.match(r"module\b", stripped):
            pending = (pending[0], pending[1], pending[2] + " " + stripped)
        if re.match(r"(record|data)\b", stripped) and re.search(r"(^|\s)where$", stripped):
            parts = stripped.split()
            header = re.sub(r"^(record|data)\s+\S+\s*", "", stripped)
            header = re.sub(r"(^|\s)where\s*$", "", header)
            stack.append(("module", indent, parts[1] if len(parts) > 1 else None, header)); continue
        if re.match(r"(field|constructor)\b", stripped):
            stack.append(("module", indent, None, "")); continue
        if re.match(r"module\b", stripped):
            parts = stripped.split()
            rest = re.sub(r"^module\s+\S+\s*", "", stripped)
            pending = (indent, parts[1] if len(parts) > 1 else "_", rest)
        if re.match(r"private\b", stripped):
            stack.append(("private", indent, None, ""))
        if re.search(r"(^|\s)where$", stripped):
            if pending is not None:
                header = re.sub(r"(^|\s)where\s*$", "", pending[2])
                stack.append(("module", pending[0], pending[1], header)); pending = None
            else:
                stack.append(("local", indent, None, ""))
    return out


def fragment(name):
    """A definition's name as a url fragment.

    Only the characters that would end the fragment or break the markdown
    and html around it are escaped; the mathematical notation is left as it
    is, since browsers accept it and it keeps the links readable.
    """
    return "".join("%%%02X" % ord(c) if c in ' "#%&<>[]^`{|}\\' else c
                   for c in name)


def clean_text(piece):
    "Markup stripped, entities decoded, whitespace collapsed to single spaces."
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", "", piece))).strip()


def skip_params(page_text, pos, limit=4000):
    """Past zero or more {..} / (..) parameter groups straight after POS, as
    in `record R (X : 𝓤 ̇ ) (Y : 𝓥 ̇ ) : ... where` -- a record or datatype
    can take arguments before its own ":", unlike a Function or Postulate.
    Tag-aware: brackets are matched by their own Symbol-classed anchors, not
    by the raw text, since a name inside a parameter can itself contain "("
    or "{". Gives back POS unchanged, safely, if a group never balances
    within `limit` characters.
    """
    end_limit = pos + limit
    opener = re.compile(r'\s*<a[^>]*class="Symbol">([{(])</a>')
    bracket = re.compile(r'<a[^>]*class="Symbol">([{}()])</a>')
    while True:
        m = opener.match(page_text, pos)
        if not m:
            return pos
        depth, p = 1, m.end()
        while depth > 0:
            m2 = bracket.search(page_text, p, end_limit)
            if not m2:
                return pos
            depth += 1 if m2.group(1) in "({" else -1
            p = m2.end()
        pos = p


def signature_of(page_text, end, raw_name, col, cap=8000, shown=180):
    """A Function, Postulate, Record, Datatype or Field's type, read off the
    rendering right after its defining anchor, or None for a name with no
    signature of its own, such as an alias (is-compact = is-Σ-compact).

    The signature runs from the ":" up to wherever the next thing begins:
    the name repeating (most Function/Postulate definitions), a bare "="
    (mixfix operators, whose equation never repeats the underscored name
    literally -- TypeTopology's own equality relation is the distinct
    character "＝", so a plain "=" is unambiguously that operator, never
    part of a type), a sibling declaration at COL or less (Agda's own
    layout rule requires a genuine continuation line to indent further
    than the declaration it continues, so a line back at or before COL is
    always the start of the next thing, not more type -- this is what
    catches a mixfix operator's own left-hand side, as in `_♯_`'s `x ♯ y =
    ...`, which the bare "=" alone would still have found, but only after
    already sweeping "x ♯ y" into the signature), the keyword "where" or
    an "infix" fixity declaration (ends a Record or Datatype's own
    signature, or trails a field block), a blank line, the next
    definition's own named anchor, or a sibling field or constructor's
    numbered-but-unnamed one (four fifths of definitions get a named
    anchor; record fields and constructors are the exception, so they need
    this fallback too). Whichever fires earliest wins; capped at `cap` raw
    characters of markup so one very long signature cannot scan the rest
    of the file, and trimmed back to the last complete tag if that cap is
    what ends up cutting it off.

    A Record or Datatype can take parameters before its own ":", which
    `skip_params` looks past to find it; when it does, those parameters are
    kept in the result (`{X : 𝓤 ̇ } (Y : 𝓥 ̇ ) : 𝓤 ⊔ 𝓥 ̇`) rather than
    discarded, since they are the interesting part of what it takes as
    input. A plain Function or Postulate never has this shape, so its
    result is unchanged: just the type, as before.
    """
    pos = skip_params(page_text, end)
    m = re.match(r'\s*<a[^>]*class="Symbol">:</a>', page_text[pos:pos + 60])
    if not m:
        return None
    prefix = clean_text(page_text[end:pos])
    start = pos + m.end()
    window = page_text[start:start + cap]
    clause = re.search(r'\n[ \t]*(?:<a[^>]*>)*' + re.escape(raw_name) + r'</a>', window)
    # A bare "=" ends the signature (it's a mixfix operator's own defining
    # equation, which never repeats the name for `clause` to catch) --
    # except when the signature itself contains a "let ... = ... in", whose
    # own "=" binds a local and does not end anything, as in
    # `cale-lo-lemma`'s `let ε = 1/5 * (q - p) in ...`.
    depth, equals = 0, None
    for lm in re.finditer(r'<a[^>]*class="Keyword">(let|in)</a>'
                          r'|<a[^>]*class="Symbol">=</a>', window):
        if lm.group(1) == "let":
            depth += 1
        elif lm.group(1) == "in":
            depth = max(depth - 1, 0)
        elif depth == 0:
            equals = lm
            break
    blank = re.search(r'\n[ \t]*\n', window)
    keyword = re.search(r'<a[^>]*class="Keyword">(where|infix[lr]?)</a>', window)
    nextanchor = re.search(r'\n[ \t]*<a id="[^"0-9][^"]*"></a>', window)
    nextfield = re.search(r'\n[ \t]*<a id="(\d+)" href="[^"]*#\1" '
                          r'class="(?:Field|InductiveConstructor)', window)
    sibling = next((lm for lm in re.finditer(r'\n([ \t]*)', window)
                    if len(lm.group(1)) <= col), None)
    ends = [x.start() for x in
            (clause, equals, blank, keyword, nextanchor, nextfield, sibling) if x]
    piece = window[:min(ends)] if ends else window
    lt, gt = piece.rfind("<"), piece.rfind(">")
    if lt > gt:
        piece = piece[:lt]
    sig = clean_text(piece)
    if prefix:
        sig = f"{prefix} : {sig}"
    if len(sig) > shown:
        sig = sig[:shown].rstrip() + "…"
    return sig or None


def definitions(page, src):
    "Every publicly visible definition of one module, with its source position."
    mod = os.path.basename(page)[:-5]
    text = open(src, encoding="utf-8").read()
    starts = [0] + [i + 1 for i, ch in enumerate(text) if ch == "\n"]
    sc = scopes(text, literate=src.endswith(".lagda"))
    # Agda writes a named anchor just before the numbered one, for every
    # definition reachable by name:
    #   <a id="is-prop-valued"></a><a id="541" href="M.html#541" ...>
    # The number is a character offset and so moves whenever the file is
    # edited; the name does not. Link by name where there is one.
    pat = re.compile(r'(?:<a id="([^"0-9][^"]*)"></a>)?'
                     r'<a id="(\d+)" href="' + re.escape(mod) +
                     r'\.html#\2" class="' + KIND + r'">([^<]+)</a>')
    page_text = open(page, encoding="utf-8").read()
    for m in pat.finditer(page_text):
        name = html.unescape(m.group(5))
        off = int(m.group(2)) - 1
        ln = bisect.bisect_right(starts, off) - 1
        enclosing = sc[ln] if ln < len(sc) else []
        if name == "_" or any(k in ("local", "private") for k, _, _, _ in enclosing):
            continue
        if m.group(3) in ("Function", "Postulate", "Record", "Datatype",
                          "Field", "InductiveConstructor"):
            line_start = page_text.rfind("\n", 0, m.start()) + 1
            col = m.start() - line_start
            sig = signature_of(page_text, m.end(), m.group(5), col)
        else:
            sig = None
        # A hypothesis such as funext is often a MODULE parameter, taken once
        # for everything inside rather than repeated in each signature, so
        # is otherwise invisible to whatever scans sig for one -- carried
        # along here, separately from sig, for exactly that purpose.
        scope_text = " ".join(h for k, _, _, h in enclosing if k == "module" and h)
        yield dict(module=mod, name=name, kind=m.group(3), anchor=m.group(2),
                   frag=fragment(html.unescape(m.group(1))) if m.group(1)
                        else m.group(2),
                   line=ln + 1, sig=sig, scope_text=scope_text, htmlpos=m.start(),
                   inner=[html.unescape(n) for k, _, n, _ in enclosing
                          if k == "module" and n not in (None, "_")])


def is_variable_name(n):
    "Single- and double-letter names used as local variables, but not acronyms."
    if "_" in n or n in NOTIONS:
        return False
    s = n.strip("_")
    if len(s) > 2:
        return False
    body = [c for c in s if c not in MARKS]
    if not body:
        return False
    if len(body) == 2 and all(c.isascii() and c.isupper() for c in body):
        return False
    return all((c.isascii() and c.isalpha()) or c in GREEK_LOWER for c in body)


# ---------------------------------------------------------------- gathering

def gather(htmldir, sourcedir):
    rows = []
    for page in sorted(glob.glob(f"{htmldir}/*.html")):
        base = os.path.join(sourcedir, os.path.basename(page)[:-5].replace(".", "/"))
        src = base + ".lagda" if os.path.exists(base + ".lagda") else \
              base + ".agda"  if os.path.exists(base + ".agda")  else None
        if src:
            rows += [r for r in definitions(page, src) if not is_variable_name(r["name"])]
    # Each module's own definitions, by html position, to attribute a use to
    # the definition it is written inside -- the nearest one starting at or
    # before the occurrence, since a use inside a `where` clause or an
    # anonymous-module member (neither of which is a row of its own) still
    # falls inside the nearest NAMED enclosing definition. Private and local
    # definitions are not rows either (definitions() already drops them), so
    # a use written inside one of those is attributed to whichever earlier
    # public definition happens to precede it instead -- rare, and a
    # reasonable enough approximation not to track private definitions just
    # for this.
    by_module = collections.defaultdict(list)
    for r in rows:
        by_module[r["module"]].append((r["htmlpos"], r["name"]))
    for lst in by_module.values():
        lst.sort()
    positions = {m: [p for p, _ in lst] for m, lst in by_module.items()}
    names = {m: [n for _, n in lst] for m, lst in by_module.items()}

    def enclosing_def(here, pos):
        ps = positions.get(here)
        if not ps:
            return None
        i = bisect.bisect_right(ps, pos) - 1
        return names[here][i] if i >= 0 else None

    # usage[(module, anchor)][using_module] is a Counter of the enclosing
    # definitions of using_module that refer to (module, anchor), each
    # mapped to how many times (None when the use falls outside every
    # tracked definition, e.g. directly in a private one) -- the raw
    # material for both the plain "N uses" count and the two-level "used
    # in" drill-down a definition's use-count expands to: first by module,
    # then, within a chosen module, by definition. Kept at module
    # granularity when merely counting, since hundreds of thousands of
    # individual call sites across the library are no easier to browse than
    # the definitions containing them, but the definitions themselves are
    # worth keeping, one level down, once a specific module is chosen.
    usage = collections.defaultdict(lambda: collections.defaultdict(collections.Counter))
    pat = re.compile(r'<a id="(\d+)" href="([A-Za-z0-9_.\-]+)\.html#(\d+)"')
    for page in glob.glob(f"{htmldir}/*.html"):
        here = os.path.basename(page)[:-5]
        for m in pat.finditer(open(page, encoding="utf-8").read()):
            own_id, mod, anchor = m.group(1), m.group(2), m.group(3)
            if mod == here and own_id == anchor:
                continue   # the definition's own anchor, not a use of it
            usage[(mod, anchor)][here][enclosing_def(here, m.start())] += 1
    for r in rows:
        used_by = []
        for using_module, defcounts in usage.get((r["module"], r["anchor"]), {}).items():
            total = sum(defcounts.values())
            if total:
                by_def = sorted(defcounts.items(), key=lambda x: (x[0] is None, x[0]))
                used_by.append([using_module, total, by_def])
        used_by.sort()
        r["uses"] = sum(t for _, t, _ in used_by)
        r["used_by"] = used_by
    return rows


def comments_of(t):
    "The comments of a non-literate module, which are all the prose it has."
    t = re.sub(r"\{-(.*?)-\}", r"\n\1\n", t, flags=re.S)
    return "\n".join(m.group(1) for m in re.finditer(r"--+(.*)$", t, re.M))


def paragraphs_of(lines):
    """LINES (prose only, code stripped) split into paragraphs on blank-line
    boundaries, each reflowed to one line -- for showing a comment as a
    self-contained search hit (see write_search_page's COMS), which a single
    long body-of-text per module (BODY above) is too coarse for."""
    paras, cur = [], []
    for l in lines:
        if l.strip() == "":
            if cur: paras.append(" ".join(cur)); cur = []
        else:
            cur.append(l.strip())
    if cur: paras.append(" ".join(cur))
    return paras


def prose_of(sourcedir):
    "The commentary of each module, and its header, with urls removed."
    files = subprocess.run(["git", "ls-files", "*.lagda", "*.agda"], cwd=sourcedir,
                           capture_output=True, text=True).stdout.split()
    head, body, paras = {}, {}, {}
    for f in files:
        t = open(os.path.join(sourcedir, f), encoding="utf-8", errors="replace").read()
        if f.endswith(".agda"):
            # Not literate, so the comments are the whole of the commentary.
            m = f[:-5].replace("/", ".")
            head[m] = prose = comments_of(t)
            paras[m] = paragraphs_of(prose.split("\n"))
        else:
            m = f[:-6].replace("/", ".")
            head[m] = t.split("\\begin{code}")[0]
            incode, buf = False, []
            for l in t.split("\n"):
                if l.startswith("\\begin{code}"): incode = True;  continue
                if l.startswith("\\end{code}"):   incode = False; continue
                if not incode: buf.append(l)
            prose = "\n".join(buf)
            paras[m] = paragraphs_of(buf)
        t = re.sub(r"https?://\S+", " ", prose)
        # The commentary names concepts in three spellings -- as English,
        # "totally separated", as a module, "TotallySeparated", and as an
        # identifier, "free-group-construction". Splitting the CamelCase,
        # and letting a space in a pattern match a hyphen or nothing in
        # prose_rx below, makes one pattern find all three. Both spellings
        # are kept, as splitting JoinSemiLattice would otherwise hide it
        # from the pattern "semilattice".
        body[m] = t + "\n" + re.sub(r"(?<=[a-z])(?=[A-Z])", " ", t)
    return head, body, paras


def unsafe_modules(sourcedir):
    """The modules that do not declare --safe.

    A name defined in several places is linked in a safe module where there
    is one, so that the identity type leads to MLTT.Id rather than to
    Unsafe.Type-in-Type-False, whose _＝_ happens to be referred to more.
    """
    files = subprocess.run(["git", "ls-files", "*.lagda", "*.agda"], cwd=sourcedir,
                           capture_output=True, text=True).stdout.split()
    out = set()
    for f in files:
        t = open(os.path.join(sourcedir, f), encoding="utf-8", errors="replace").read()
        if not re.search(r"\{-#\s*OPTIONS[^#]*--safe", t):
            out.add(re.sub(r"\.lagda$|\.agda$", "", f).replace("/", "."))
    return out


def unaccented(s):
    "Escardó and Escardo, Opršal and Oprsal, are the same person."
    return "".join(c for c in unicodedata.normalize("NFKD", s)
                   if not unicodedata.combining(c))


def people_of(readme, body):
    """The contributors of the README, and the modules that mention them.

    A contributor is matched by full name, and also by surname alone, which
    is how citations and acknowledgements read. The surname is not taken
    when another capitalised word follows it, since that is somebody else
    whose given name it happens to be -- "Ray Mines" is not Ian Ray.
    """
    names, inside = [], False
    for line in open(readme, encoding="utf-8"):
        if line.startswith("## "):
            inside = "contributor" in line.lower()
        elif inside and line.startswith("* "):
            names.append(line[2:].split(" (")[0].strip())
    plain = {m: unaccented(t) for m, t in body.items()}
    out = []
    for n in names:
        full = re.escape(unaccented(n)).replace(r"\ ", r"\s+")
        sur = re.escape(unaccented(n.split()[-1]))
        rx = re.compile(rf"{full}|\b{sur}\b(?!\s+[A-Z])", re.I)
        out.append((n, sorted(m for m, t in plain.items() if rx.search(t))))
    return out


def concepts_of(table, body):
    """Each concept's label and the modules whose commentary discusses
    it, matched by its own prose pattern alone -- never its alias, for
    the same reason `write_search_page' never lets alias feed this scan
    either: an alias such as "choice" is ordinary English and would
    flood this with unrelated modules. [] when TABLE (concepts.tsv)
    does not exist, rather than an error, since concepts are optional
    for the Emacs bootstrap the way contributors are not -- that
    bootstrap already needs the README for nothing else, but concepts
    additionally need concepts.tsv, which it is documented to run
    without.

    Deliberately a second, small pass over concepts.tsv rather than a
    shared refactor of write_search_page's own per-concept loop
    (landmarks, the search-box alias, axiom badges, and more all live
    there too) -- keeping this self-contained means dropping it later,
    if it turns out to make Emacs's own filtering noticeably slower on
    a real concept list, only touches this function and its one caller,
    never that already-tuned, more heavily-relied-upon code path.
    """
    if not os.path.exists(table):
        return []
    out = []
    for line in open(table, encoding="utf-8"):
        if line.startswith("#") or not line.strip():
            continue
        c, pp = (line.rstrip("\n").split("\t") + ["", "", "", ""])[:2]
        rx = prose_rx(pp)
        out.append((c, sorted(m for m, t in body.items() if rx.search(t))))
    return out


def prose_rx(pattern):
    "A concept's prose pattern, made blind to hyphenation and word joining."
    # The whitespace matters as much as the hyphen: the commentary is hard
    # wrapped, so "function extensionality" is split over two lines often
    # enough that a pattern which cannot cross a newline misses a sixth of
    # the modules that discuss it.
    return re.compile(re.sub(r"[ -]", r"[\\s-]*", pattern), re.I)


# ---------------------------------------------------------------- output

def norm(n): return unicodedata.normalize("NFKD", n.lstrip("_").lstrip("⟨[({｢"))
def sortkey(n):
    s = norm(n); return (0 if s[:1].isalpha() else 1, s.lower(), n)
def initial(n):
    c = norm(n)[:1].upper()
    return c if (c.isalpha() and c.isascii()) else "Symbols"


def write_identifier_index(rows, out, site, ntotal):
    groups = collections.defaultdict(list)
    for r in rows: groups[r["name"]].append(r)
    pages, symbols = [], sorted([n for n in groups if initial(n) == "Symbols"], key=sortkey)
    for L in sorted({initial(n) for n in groups} - {"Symbols"}):
        pages.append((L, L, sorted([n for n in groups if initial(n) == L], key=sortkey)))
    chunks = [symbols[i:i + 700] for i in range(0, len(symbols), 700)]
    for i, ch in enumerate(chunks, 1):
        pages.append((f"Symbols-{i}", f"Symbols {i} of {len(chunks)}  ({ch[0]} … {ch[-1]})", ch))
    nav = " · ".join(f"[{f}]({f}.md)" for f, _, _ in pages)

    def entry(n):
        links = [f"[{r['module']}" + ("." + ".".join(r["inner"]) if r["inner"] else "") +
                 f"]({site}{r['module']}.html#{r['frag']})"
                 for r in sorted(groups[n], key=lambda r: (r["module"], r["line"]))]
        return f"- `{n}` — " + ", ".join(links)

    for f, title, ns in pages:
        open(f"{out}/{f}.md", "w", encoding="utf-8").write(
            "\n".join([f"# {title}", "", nav, "", f"{len(ns)} names.", ""] +
                      [entry(n) for n in ns]) + "\n")
    toc = ["# Index of TypeTopology", "",
           f"{len(groups)} names and {len(rows)} definitions, drawn from "
           f"{len({r['module'] for r in rows})} of the {ntotal} modules. The "
           "others, index modules for the most part, define no name of their "
           "own.", "", nav, ""]
    toc += [f"- [{t}]({f}.md) — {len(ns)} names" for f, t, ns in pages]
    open(f"{out}/IdentifierIndex.md", "w", encoding="utf-8").write("\n".join(toc) + "\n")


def write_concept_index(rows, out, site, table, body):
    byname = collections.defaultdict(list)
    for r in rows: byname[r["name"]].append(r)

    def sites(n):
        "Every definition site of a name, most-referenced first. A name may be\n"
        "defined in several modules -- is-compact is a different notion for types,\n"
        "for domain elements and for locales -- so all of them are listed."
        return sorted(byname[n], key=lambda r: (-r["uses"], len(r["module"])))
    def link(r):
        return f"[`{r['name']}`]({site}{r['module']}.html#{r['frag']})"
    def mlink(m): return f"[{m}]({site}{m}.html)"

    concepts = []
    for line in open(table, encoding="utf-8"):
        if line.startswith("#") or not line.strip(): continue
        c, pp, ip, lm = (line.rstrip("\n").split("\t") + ["", ""])[:4]
        concepts.append((c, pp, ip, [x.strip() for x in lm.split(",") if x.strip()]))

    entries = collections.defaultdict(list)   # initial letter -> lines
    for c, pp, ip, lm in sorted(concepts, key=lambda x: x[0].lower()):
        out_lines = entries[initial(c)]
        names = sorted({r["name"] for r in rows if ip and re.search(ip, r["name"])})
        rx = prose_rx(pp)
        mods = sorted(m for m, t in body.items() if rx.search(t))
        lm = [n for n in lm if n in byname]
        key = [w for w in re.split(r"[ -]", c.lower()) if len(w) > 3]
        rest = sorted([n for n in names if n not in lm],
                      key=lambda n: (-sites(n)[0]["uses"], len(n)))[:8]
        mods = sorted(mods, key=lambda m: (not any(k in m.lower() for k in key), m))
        out_lines.append(f"### {c}")
        out_lines.append("")
        if not lm and not rest:
            out_lines.append("*No definition carries this name; it is a notion of the"
                             " commentary rather than of the code.*")
        for n in lm + rest:
            ss = sites(n)[:3]
            bold = "**" if n in lm else ""
            where = ", ".join(f"{mlink(r['module'])}"
                              + (f" ({r['uses']})" if r["uses"] else "") for r in ss)
            out_lines.append(f"- {bold}{link(ss[0])}{bold} — {where}"
                             + (f" and {len(byname[n])-3} more" if len(byname[n]) > 3 else ""))
        if mods:
            # One module per line, with the tail folded away. Github renders
            # <details>, so the long lists stay readable without hiding
            # anything: the whole of it is a click away.
            out_lines += ["", "*discussed in*:", ""]
            out_lines += [f"- {mlink(m)}" for m in mods[:6]]
            if len(mods) > 6:
                out_lines += ["", f"<details><summary>and {len(mods)-6} more"
                                  "</summary>", ""]
                out_lines += [f"- {mlink(m)}" for m in mods[6:]]
                out_lines += ["", "</details>"]
        out_lines.append("")

    # A page per initial letter, as the identifier index does, since the whole
    # of it in one file is close to the size at which Github stops rendering
    # markdown and shows the source instead.
    letters = sorted(entries, key=lambda L: (L == "Symbols", L))
    nav = " · ".join(f"[{L}](Concept-{L}.md)" for L in letters)
    counts = collections.Counter(initial(c) for c, _, _, _ in concepts)
    for L in letters:
        open(f"{out}/Concept-{L}.md", "w", encoding="utf-8").write(
            "\n".join([f"# Concepts: {L}", "", nav, "",
                       f"{counts[L]} concept{'s'[:counts[L]^1]}.", ""]
                      + entries[L]) + "\n")
    toc = ["# Concept index of TypeTopology", "",
           f"{len(concepts)} concepts, over the {len(body)} modules.", "",
           "Each entry names in bold the definitions that *are* the concept and",
           "where they live, then the other definitions carrying its name, most",
           "referenced first with its reference count, then the modules whose",
           "commentary discusses it.", "", nav, ""]
    toc += [f"- [{L}](Concept-{L}.md) — {counts[L]} "
            f"concept{'s'[:counts[L]^1]}" for L in letters]
    open(f"{out}/ConceptIndex.md", "w", encoding="utf-8").write("\n".join(toc) + "\n")


def write_defs_index(rows, out):
    # A flat, plain-text index for grep rather than browsing: every
    # definition on one line, name first since that is what a search
    # usually starts from, its signature where one was read off the
    # rendering, and its module and use count as trailing context -- no
    # HTML, no pagination, nothing to render. The concept vocabulary (which
    # name a mathematical notion actually has in this library) lives in
    # concepts.tsv instead, already in a form suited to being read directly
    # rather than through this generator.
    lines = []
    for r in sorted(rows, key=lambda r: sortkey(r["name"])):
        mod = r["module"] + ("." + ".".join(r["inner"]) if r["inner"] else "")
        tail = f"  [{mod}" + (f", {r['uses']} uses" if r["uses"] else "") + "]"
        sig = r.get("sig") or ""
        # A hypothesis taken once as a module parameter (funext, univalence,
        # a whole record's worth of structure) never appears in a
        # definition's own signature, only here -- unfiltered, exactly the
        # raw parameter list of every enclosing module, the same as the
        # search page's "list every enclosing assumption" view, since
        # silently needing an assumption the caller doesn't have is a worse
        # failure mode here than a line that says more than strictly novel.
        scope_text = r.get("scope_text") or ""
        assumes = f"  (assumes: {scope_text})" if scope_text else ""
        lines.append(r["name"] + (f" : {sig}" if sig else "") + tail + assumes)
    header = ["# TypeTopology definitions index -- name, signature where "
              "known, module and use count, and any hypothesis taken by an",
              "# enclosing module rather than repeated in the signature "
              "itself.",
              "# One line each, for grep. Concepts (which name a notion "
              "actually has) are in concepts.tsv, not here.",
              f"# {len(lines)} definitions. Regenerated by "
              "'agda-index.py --defs-index'; not kept automatically in "
              "sync, so re-run first.", ""]
    open(f"{out}/Definitions.txt", "w", encoding="utf-8").write(
        "\n".join(header + lines) + "\n")


def write_emacs_index(rows, out, sourcedir, people, concepts):
    # A tab-separated sibling of Definitions.txt, for a program to read
    # rather than a person -- the emacs-mode search in this directory,
    # typetopology-search.el, though nothing here is specific to it.
    # Definitions.txt's own format is deliberately human-shaped (one line,
    # signature and module folded together with brackets and commas), which
    # is exactly what makes it awkward to parse back out reliably -- a
    # signature can itself contain "[" or "]" (`ℤ[1/2]`), so a program
    # would have to out-guess its own pretty-printing. Plain fields
    # side-step that. File and line, neither of which Definitions.txt
    # carries, are what a jump-to-source action needs; module and
    # signature alone were enough for grep.
    #
    # Contributors and concepts (from the same README-derived list and
    # concepts.tsv the search page shows) are rows here too, told apart
    # by the trailing "kind" column ("def", "person", or "concept") --
    # neither a person nor a concept has a module, file, line, or
    # signature of their own, so those columns are simply empty; the use
    # count column is repurposed to hold how many modules mention them,
    # and the assumes column to hold which ones, semicolon-separated (a
    # module's dotted name never contains one), since none of the three
    # row kinds needs both meanings of either column at once.
    src_of = {}
    def source_file(mod):
        if mod not in src_of:
            base = os.path.join(sourcedir, mod.replace(".", "/"))
            src_of[mod] = mod.replace(".", "/") + (
                ".lagda" if os.path.exists(base + ".lagda") else
                ".agda"  if os.path.exists(base + ".agda")  else "")
        return src_of[mod]
    def field(s):
        return re.sub(r"[\t\n]+", " ", s) if s else ""
    entries = []
    for r in rows:
        inner = "." + ".".join(r["inner"]) if r["inner"] else ""
        entries.append((r["name"], [
            r["name"], r["module"] + inner, r["module"],
            source_file(r["module"]), str(r["line"]), str(r["uses"]),
            field(r.get("sig") or ""), field(r.get("scope_text") or ""), "def"]))
    for name, mods in people:
        entries.append((name, [name, "", "", "", "0", str(len(mods)),
                                "", ";".join(mods), "person"]))
    for name, mods in concepts:
        entries.append((name, [name, "", "", "", "0", str(len(mods)),
                                "", ";".join(mods), "concept"]))
    entries.sort(key=lambda e: sortkey(e[0]))
    lines = ["\t".join(fields) for _, fields in entries]
    header = ["# TypeTopology definitions, contributors, and concepts "
              "index for programs, tab-separated. Columns: name, module",
              "# (with any inner submodule), module alone (what \"open "
              "import\" wants), source file relative to the source",
              "# directory, source line, use count (a contributor's or "
              "concept's: how many modules mention them), signature",
              "# where known, any hypothesis taken by an enclosing "
              "module (a contributor's or concept's: which modules",
              "# mention them, semicolon-separated instead), and kind "
              "(\"def\", \"person\", or \"concept\" -- neither a person",
              "# nor a concept has a module, file, line, or signature).",
              "# Every line below is data, none of them this header -- a "
              "reader just drops lines starting with \"#\"",
              f"# and splits the rest on tabs. {len(rows)} definitions, "
              f"{len(people)} contributors, {len(concepts)} concepts.",
              "# Regenerated by 'agda-index.py --emacs-index'; not kept "
              "automatically in sync, so re-run first."]
    text = "\n".join(header + lines) + "\n"
    path = f"{out}/Definitions.tsv"
    if os.path.exists(path) and open(path, encoding="utf-8").read() == text:
        print(f"{path} already up to date")
    else:
        open(path, "w", encoding="utf-8").write(text)
        print(f"{path} updated")


# ---------------------------------------------------------------- search page

SEARCH_TEMPLATE = r"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Search TypeTopology</title>
<style>
 :root { color-scheme: light dark; --fg:#111; --bg:#fff; --dim:#666; --line:#ddd; --hi:#0a5; }
 @media (prefers-color-scheme: dark) {
   :root { --fg:#ddd; --bg:#151515; --dim:#999; --line:#333; --hi:#5d8; } }
 body { font: 15px/1.5 -apple-system, "Segoe UI", sans-serif; margin: 0 auto; padding: 1rem;
        max-width: 60rem; color: var(--fg); background: var(--bg); }
 h1 { font-size: 1.2rem; font-weight: 600; margin: 0 0 .6rem; }
 p.sub { color: var(--dim); margin: .2rem 0 .4rem; }
 ul.sub { color: var(--dim); margin: 0 0 1rem; padding-left: 1.1rem; }
 ul.sub li { margin: .15rem 0; }
 ul.sub a { text-decoration: underline; }
 .box { position: relative; }
 .box svg { position: absolute; left: .7rem; top: 50%%; transform: translateY(-50%%);
            width: 1.05rem; height: 1.05rem; color: var(--dim); pointer-events: none; }
 /* #q, not input, or the rule lands on the checkboxes as well and knocks
    them out of line with their labels. */
 #q { width: 100%%; box-sizing: border-box; font: inherit; font-size: 1.1rem;
      padding: .5rem 2.3rem .5rem 2.3rem; border: 1px solid var(--line);
      border-radius: .4rem; background: var(--bg); color: var(--fg); }
 .clear { position: absolute; right: .45rem; top: 50%%; transform: translateY(-50%%);
          border: 0; background: none; color: var(--dim); cursor: pointer;
          font: inherit; line-height: 1; padding: .3rem .4rem; border-radius: .3rem; }
 .clear:hover { color: var(--fg); }
 #q:focus { outline: none; border-color: var(--hi); }
 #q:focus ~ svg, .box:focus-within svg { color: var(--hi); }
 .opts { color: var(--dim); margin: .5rem 0 .8rem;
         display: flex; flex-wrap: wrap; gap: .35rem 1.2rem; }
 .opts label { display: inline-flex; align-items: center; gap: .4rem; }
 .opts input { margin: 0; }
 table { width: 100%%; border-collapse: collapse; }
 td { padding: .25rem .5rem .25rem 0; border-bottom: 1px solid var(--line);
      vertical-align: baseline; }
 td.n { font-family: ui-monospace, Menlo, monospace; white-space: nowrap; }
 td.m { color: var(--dim); font-size: .9em; }
 td.u { color: var(--dim); text-align: right; white-space: nowrap; font-size: .9em; }
 a { color: inherit; text-decoration: none; } a:hover { text-decoration: underline; }
 h1 a { color: var(--hi); text-decoration: underline; text-underline-offset: 3px; }
 h1 a::after { content: " ↗"; text-decoration: none; display: inline-block; }
 .concept { background: color-mix(in srgb, var(--hi) 12%%, transparent); }
 .concept td.n { color: var(--hi); font-weight: 600; }
 .person { background: color-mix(in srgb, var(--hi) 6%%, transparent); }
 .person td.n { font-weight: 600; }
 .comment { background: color-mix(in srgb, var(--dim) 10%%, transparent); }
 .comment td.n { font-family: inherit; white-space: normal; }
 .disc { color: var(--dim); margin-top: .35rem; line-height: 1.5; }
 .f { padding-left: 1rem; }
 .tog { color: var(--hi); cursor: pointer; display: inline-block; margin-left: 1rem; }
 .none { color: var(--dim); padding: 1rem 0; }
 .sel td { background: color-mix(in srgb, var(--hi) 22%%, transparent) !important; }
 .copy { border: 0; background: none; color: var(--dim); cursor: pointer;
         font-size: 1em; padding: 0 .2rem; vertical-align: -.1em; }
 .copy:hover { color: var(--hi); }
 .ucount { border: 0; background: none; color: inherit; cursor: pointer;
           font: inherit; padding: 0; text-decoration: underline dotted; }
 .ucount:hover { color: var(--hi); }
 td.u:has(.used:not([hidden])) { white-space: normal; text-align: left; }
 .copy.done { color: var(--hi); }
 #browse-label { color: var(--hi); font-weight: 600; }
 .hl { color: var(--hi); font-weight: 600; }
 .sig { color: var(--dim); font-size: .85em; white-space: normal; margin-top: .1rem; }
 .axioms { color: var(--dim); font-size: .85em; white-space: normal; margin-top: .1rem; }
 .axioms a { color: var(--dim); } .axioms a:hover { color: var(--hi); }
 #browse { display: flex; flex-wrap: wrap; gap: .4rem .9rem; }
 #browse a { color: var(--dim); }
 #browse a:hover { color: var(--hi); }
 footer { color: var(--dim); font-size: .85em; margin-top: 2rem; }
</style></head><body>
<h1>Search <a href=%(site)s title="Go to the TypeTopology web pages"
   >TypeTopology</a></h1>
<div class="box">
<input id="q" autofocus autocomplete="off" spellcheck="false"
       placeholder="compact, ainjective, is-*-compact, compact in Ordinals ...">
<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="2"
     aria-hidden="true"><circle cx="8.5" cy="8.5" r="5.5"/><path d="M12.8 12.8 18 18"
     stroke-linecap="round"/></svg>
<button id="clr" class="clear" type="button" aria-label="Clear the search" hidden>✕</button>
</div>
<div class="opts">
 <label><input type="checkbox" id="mods" checked> search module names too</label>
 <label><input type="checkbox" id="sigs"> search within type signatures too</label>
 <label><input type="checkbox" id="coms"> search within commentary instead</label>
 <label><input type="checkbox" id="allscope" checked> list every enclosing assumption</label>
 <label><input type="checkbox" id="exact"> whole word</label>
</div>
<div id="help">
<ul class="sub">
<li>Type a <b>name</b>, a <b>fragment</b> of one, a <b>concept</b>, or a
    <b>contributor</b>.</li>
<li>Once a search term is entered, <b>↑/↓</b> move a selection
    through the results, and Enter opens it.</li>
<li><b>Several words</b> must all match, so "compact ordinal" asks for both.</li>
<li><b>Wildcards</b>: <code>*</code> for any run of characters, <code>?</code> for one,
    <code>\*</code> for a literal star.</li>
<li>"compact <b>in</b> Ordinals.Comp", using the keyword <b>in</b>, searches
    inside a directory or file.</li>
<li><b>Unicode</b> is entered the way it is in the Agda emacs mode, so
    <code>\to</code> and <code>\MCU</code> are "→" and "𝓤",
    though <code>\to</code> itself needs a space right after it, since
    <code>\top</code> could still follow.</li>
<li>Search is also
    <a href="https://github.com/martinescardo/TypeTopologySearch#installing-the-emacs-command">available from Emacs</a>.</li>
</ul>
<p class="sub">%(ndefs)s definitions and %(ncons)s concepts in %(ntotal)s modules
   (%(ncoms)s comments).</p>
<p id="browse-label" class="sub">Concept index</p>
<div id="browse"></div>
</div>
<div id="out"></div>
<footer>Index built on %(builddate)s.</footer>
<script>
const SITE=%(site)s, MODS=%(mods)s, DEFS=%(defs)s, CONS=%(cons)s,
      PEOPLE=%(people)s, OWN_AREA=%(ownarea)s, AXIOMS=%(axioms)s,
      SCOPE_TEXTS=%(scopetexts)s, SHOW_AXIOM_BADGES=%(showaxioms)s,
      USED_BY_NAMES=%(usedbynames)s, COMS=%(coms)s;
const UNSAFE=new Set(%(unsafe)s);
// The emacs Agda input method's own key -> character table (or, for a key
// with several candidates, key -> [character, ...]), unrelated to
// TypeTopology -- see README.md for where it comes from.
const ESC=%(esc)s;
const ESC_KEYS=Object.keys(ESC);
// Words too common in module names to say where a concept lives.
const GENERIC=new Set(["type","types","space","spaces","theory","principle",
  "element","elements","structure","structures","number","numbers","order",
  "logic","function","functions","relation","relations","family"]);
// Lecture notes, scratch files and superseded code: real definitions, but
// not where a concept should be said to live.
const SIDELINE=/^(MGS|gist|deprecated|Unsafe|TWA)\./;
// How far down a result sinks for the area it lives in, before relevance is
// looked at at all: Unsafe last of all, since what it defines relies on
// principles the rest of the library does without, deprecated just above it,
// since a superseded definition is never the one being looked for, and MGS
// above that, since those lecture notes redevelop from scratch names the
// library already has, so an unqualified search for one of them means the
// library's own. Everything else shares the top rank and is ordered by
// relevance alone, as before.
const AREA=m=>/^Unsafe\./.test(m)?3:/^deprecated\./.test(m)?2
             :/^MGS\./.test(m)?1:0;
const q=document.getElementById("q"), out=document.getElementById("out"),
      useMods=document.getElementById("mods"), useSigs=document.getElementById("sigs"),
      useComs=document.getElementById("coms"),
      useAllScope=document.getElementById("allscope"),
      exact=document.getElementById("exact"),
      clr=document.getElementById("clr"), help=document.getElementById("help"),
      browse=document.getElementById("browse");
const esc=s=>s.replace(/[&<>]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;"}[c]));
let selRow=-1;   // which result row the arrow keys have moved to, if any
// The concepts, alphabetically, as a browsable list: since #browse sits
// inside #help it hides on the first keystroke exactly like the bullets do,
// and clicking one runs it as a search, which is a gentle way to learn what
// terms the page answers to.
const CNAMES=CONS.map(c=>c[0]).sort((a,b)=>a.localeCompare(b));
browse.innerHTML=CNAMES.map((n,i)=>'<a href="#" data-i="'+i+'">'+esc(n)+'</a>').join("");
browse.addEventListener("click",e=>{
  if(e.target.tagName!=="A") return;
  e.preventDefault();
  q.value=CNAMES[e.target.dataset.i];
  search();
  q.focus();
});
// Every site of every name, so that a concept's definitions can be linked.
// DEFS is ordered by use, so a name's sites come most-used first.
const SITEOF=new Map();
for(const r of DEFS){ const s=SITEOF.get(r[0]); if(s) s.push(r); else SITEOF.set(r[0],[r]); }
// A very small number of names are defined for genuinely unrelated notions
// that both mention the concept and are close in usage, so nothing below
// can tell them apart -- checked against what actually imports the name,
// not against usage or spelling. is-compact is defined four times: domain
// theory's way-below compactness (149 uses), locale compactness (32), the
// general exhaustibility notion (30), and locale regularity (15); the
// second edges out the third on both counts, but Ordinals.CompactnessOfSuprema
// and Ordinals.InfProperty both open TypeTopology.CompactTypes for it, not
// Locales.Compactness.
const HOME=new Map([["is-compact","TypeTopology.CompactTypes"]]);
function deflink(n,label,inPath){
  let ss=SITEOF.get(n); const code='<code>'+esc(n)+'</code>';
  if(!ss) return code;
  // With a path, link within it if the name has any site there, rather
  // than the best site anywhere -- "compact in TypeTopology" should not
  // send is-compact to Locales.Compactness.
  if(inPath){ const within=ss.filter(x=>inPath(x[1])); if(within.length) ss=within; }
  if(HOME.has(n)){
    const home=ss.find(x=>MODS[x[1]]===HOME.get(n));
    if(home) return '<a href="'+SITE+MODS[home[1]]+'.html#'+home[2]+'">'+code+'</a>';
  }
  // The most used site, but a --safe one in preference to an unsafe one.
  const safe=x=>!UNSAFE.has(x[1]);
  let r=ss.find(safe) || ss[0];
  // With OWN_AREA, prefer a site whose MODULE NAME carries a word of the
  // concept, so that egroup leads to a module about EGroups rather than to
  // whichever egroup happens to be used most. Three guards, each of which
  // a plainer version of this rule got wrong: generic words like "type" are
  // ignored, since "identity" alone would send ap to
  // FalseWithoutIdentityTypes; lecture notes, gists and superseded code are
  // not homes; and a candidate needs a tenth of the leading site's use, which
  // is what keeps ap in MLTT.Id. If nothing qualifies, nothing moves.
  if(OWN_AREA && label && ss.length>1){
    const keys=label.toLowerCase().split(/[ -]+/)
                    .filter(w=>w.length>3 && !GENERIC.has(w));
    const home=x=>safe(x) && !SIDELINE.test(MODS[x[1]]) && x[3]*10>=r[3]
                  && keys.some(k=>MODS[x[1]].toLowerCase().includes(k));
    r=ss.find(home) || r;
  }
  return '<a href="'+SITE+MODS[r[1]]+'.html#'+r[2]+'">'+code+'</a>';
}
// * stands for any run of characters and ? for a single one. Everything
// else the user types is literal, so that a search for _∘_ or [_] is not
// read as a regular expression.
function wildcard(needle,whole){
  if(!/[*?\\]/.test(needle)) return null;    // plain text, matched by indexOf
  let body="";
  for(let i=0;i<needle.length;i++){
    const c=needle[i];
    if(c==="\\" && "*?\\".includes(needle[i+1])) body+="\\"+needle[++i];
    else if(c==="*") body+=".*";
    else if(c==="?") body+=".";
    else body+=/[.+^${}()|[\]\\]/.test(c)?"\\"+c:c;
  }
  try { return new RegExp(whole?"^"+body+"$":body,"i"); } catch(e) { return null; }
}
function score(name,needle,rx){
  const lc=name.toLowerCase();
  let i,len;
  if(rx){ const m=rx.exec(lc); if(!m) return -1; i=m.index; len=m[0].length; }
  else  { i=lc.indexOf(needle); if(i<0) return -1; len=needle.length; }
  if(i===0 && len===lc.length) return 0;
  if(i===0) return 1;
  if(/[-_.\[]/.test(name[i-1])) return 2;   // start of a word within the name
  return 3;
}
// Marks, within a displayed name, the span each search word matched -- the
// same position score() found, so what lights up is exactly what counted,
// wildcards included. Several words landing in the same name is why spans
// are merged rather than wrapped one at a time.
function highlight(name,terms){
  const lc=name.toLowerCase();
  const spans=[];
  for(const t of terms){
    let i,len;
    if(t.rx){ const m=t.rx.exec(lc); if(!m) continue; i=m.index; len=m[0].length; }
    else     { i=lc.indexOf(t.w); if(i<0) continue; len=t.w.length; }
    if(len>0) spans.push([i,i+len]);
  }
  if(!spans.length) return esc(name);
  spans.sort((a,b)=>a[0]-b[0]);
  const merged=[spans[0]];
  for(const s of spans.slice(1)){
    const last=merged[merged.length-1];
    if(s[0]<=last[1]) last[1]=Math.max(last[1],s[1]); else merged.push(s);
  }
  let out="", pos=0;
  for(const [s,e] of merged){
    out+=esc(name.slice(pos,s))+'<b class="hl">'+esc(name.slice(s,e))+'</b>';
    pos=e;
  }
  return out+esc(name.slice(pos));
}
// The modules of a concept or of a contributor, one per line, the tail of
// the list folded away.
function modules(idx,label){
  if(!idx.length) return '';
  const link=i=>'<div class="f"><a href="'+SITE+MODS[i]+'.html">'
               +esc(MODS[i])+'</a></div>';
  let d='<div class="disc">'+label+idx.slice(0,6).map(link).join("");
  if(idx.length>6)
    d+='<div class="rest" hidden>'+idx.slice(6).map(link).join("")+'</div>'
      +'<a class="tog" href="#">and '+(idx.length-6)+' more</a>';
  return d+'</div>';
}
// A module in a "used in" list is itself an index into DEFS, found by a
// linear scan -- cheap enough on a single click (21k rows), not worth a
// second lookup table just for this.
function findDef(mi,name){
  for(const d of DEFS) if(d[1]===mi && d[0]===name) return d;
  return null;
}
// One module's own contribution to a use-count, clicked open in turn into
// which definitions of that module it is -- module-level, None (-1) when a
// use falls inside a private or local definition, neither of which gets a
// row of its own to attribute it to (see gather() in agda-index.py).
function usedInDefs(mi,byDef){
  if(!byDef.length) return '';
  const link=([ni,c])=>{
    const inner=ni<0
      ? '<a href="'+SITE+MODS[mi]+'.html">(module level)</a>'
      : (d=>d?'<a href="'+SITE+MODS[mi]+'.html#'+d[2]+'">'+esc(USED_BY_NAMES[ni])+'</a>'
             :esc(USED_BY_NAMES[ni]))(findDef(mi,USED_BY_NAMES[ni]));
    return '<div class="f">'+inner+' ('+c+')</div>';
  };
  let d='<div class="disc defs" hidden>'+byDef.slice(0,6).map(link).join("");
  if(byDef.length>6)
    d+='<div class="rest" hidden>'+byDef.slice(6).map(link).join("")+'</div>'
      +'<a class="tog" href="#">and '+(byDef.length-6)+' more</a>';
  return d+'</div>';
}
// A definition's own use-count, clicked open into the modules it is used
// from, each with how many times -- collapsed to modules rather than
// individual call sites, since a handful of core lemmas are each used from
// several hundred of them, at which point which MODULE is still useful to
// browse but which of the thousands of individual definitions no longer
// is. Starts hidden; the count itself is the toggle (see the click handler
// below), the same fold-after-6 as modules() once open -- and so, one
// level down, is a module's own count, sharing the same "ucount" class and
// so the same toggle handling, into usedInDefs() above.
function usedIn(triples){
  if(!triples.length) return '';
  const row=([mi,total,byDef])=>'<div class="f"><a href="'+SITE+MODS[mi]+'.html">'
      +esc(MODS[mi])+'</a> <button class="ucount" type="button" '
      +'title="Show which definitions in '+esc(MODS[mi])+' use this">'+total+'</button>'
      +usedInDefs(mi,byDef)+'</div>';
  let d='<div class="disc used" hidden>'+triples.slice(0,6).map(row).join("");
  if(triples.length>6)
    d+='<div class="rest" hidden>'+triples.slice(6).map(row).join("")+'</div>'
      +'<a class="tog" href="#">and '+(triples.length-6)+' more</a>';
  return d+'</div>';
}
// A definition's type may name a hypothesis rather than an everyday
// constructive notion -- funext, univalence, choice, excluded middle and
// its taboo cousins -- shown as small links that run the concept as a
// search, the same click-through the browse list already offers.
function axiomBadges(idxs){
  if(!idxs.length) return '';
  return '<div class="axioms">assumes '
        +idxs.map(i=>'<a href="#" data-ax="'+i+'">'+esc(AXIOMS[i])+'</a>').join(", ")
        +'</div>';
}
// The raw parameter list of every module enclosing a definition, however
// many levels deep, unfiltered -- unlike axiomBadges, not just the nine
// curated hypotheses, so this also shows a plain type variable or a
// development-specific structure (X : 𝓤 ̇ , G : Group) that never gets a
// concept row of its own.
function scopeBadge(idx){
  return idx<0 ? '' : '<div class="axioms">assumptions: '+esc(SCOPE_TEXTS[idx])+'</div>';
}
function render(rows,concepts,people,coms,inPath,terms,wantMods,wantSigs,wantAllScope){
  if(!rows.length && !concepts.length && !people.length && !coms.length){
    out.innerHTML='<p class="none">Nothing found.</p>'; return; }
  let h='<table>';
  for(const c of concepts){
    h+='<tr class="concept"><td class="n">'+highlight(c[0],terms)+'</td><td class="m">concept — '
      +c[1].map(n=>deflink(n,c[0],inPath)).join(", ")
      +modules(c[2],"discussed in")+'</td><td class="u"></td></tr>';
  }
  for(const p of people){
    h+='<tr class="person"><td class="n">'+esc(p[0])+'</td>'
      +'<td class="m">contributor'+modules(p[2],"named in")
      +'</td><td class="u">'+p[2].length+'</td></tr>';
  }
  for(const r of rows){
    const m=MODS[r[1]];
    h+='<tr><td class="n"><a href="'+SITE+m+'.html#'+r[2]+'">'+highlight(r[0],terms)+'</a>'
      +(r[4]?'<div class="sig">'+(wantSigs?highlight(r[4],terms):esc(r[4]))+'</div>':'')
      +(SHOW_AXIOM_BADGES?axiomBadges(r[5]):'')+(wantAllScope?scopeBadge(r[6]):'')+'</td>'
      +'<td class="m"><a href="'+SITE+m+'.html">'+(wantMods?highlight(m,terms):esc(m))+'</a>'
      +' <button class="copy" type="button" data-mod="'+r[1]+'" '
      +'title="Copy open import '+esc(m)+'">⧉</button></td>'
      +'<td class="u">'+(r[3]
        ? '<button class="ucount" type="button" title="Show which modules use this">'
          +r[3]+'</button>'+usedIn(r[7])
        : '')+'</td></tr>';
  }
  for(const c of coms){
    const link=SITE+MODS[c[1]]+'.html';
    h+='<tr class="comment"><td class="n"><a href="'+link+'">'
      +highlight(snippet(c[0],terms),terms)+'</a></td>'
      +'<td class="m"><a href="'+link+'">'+esc(MODS[c[1]])+'</a></td>'
      +'<td class="u"></td></tr>';
  }
  out.innerHTML=h+'</table>';
}
// Around the earliest matched term, not just the start of the paragraph, so
// a hit buried in a long comment is still visible without reading past it.
function snippet(text,terms){
  const lc=text.toLowerCase();
  let pos=-1;
  for(const t of terms){
    const i=t.rx?(t.rx.exec(lc)||{index:-1}).index:lc.indexOf(t.w);
    if(i>=0 && (pos<0||i<pos)) pos=i;
  }
  if(pos<0) pos=0;
  const width=220;
  let start=Math.max(0,pos-60);
  let end=Math.min(text.length,start+width);
  start=Math.max(0,end-width);
  let s=text.slice(start,end);
  if(start>0) s="…"+s;
  if(end<text.length) s+="…";
  return s;
}
function search(){
  const raw=q.value.trim();
  clr.hidden=!q.value;
  help.hidden=!!raw;   // the counts and the instructions give way to results
  selRow=-1;           // a fresh set of rows, so any keyboard selection resets
  // Kept in the URL so a search is itself a link -- #q=... rather than
  // ?q=..., since a hash change never asks the server for anything.
  const newHash=raw?"#q="+encodeURIComponent(raw):"";
  if((location.hash||"")!==newHash){
    if(newHash) history.replaceState(null,"",newHash);
    else history.replaceState(null,"",location.pathname+location.search);
  }
  if(!raw){ out.innerHTML=''; return; }
  const whole=exact.checked, wantMods=useMods.checked, wantSigs=useSigs.checked,
        wantComs=useComs.checked, wantAllScope=useAllScope.checked;
  // "compact in Ordinals" stays inside one directory or file: the word
  // after a standalone "in" is a dotted module path, matched segment by
  // segment against the front of a module's own dotted name. Every
  // segment but the last has to match in full, since a dot means the user
  // has moved on to the next one, but the last is a prefix, so it also
  // narrows while still being typed -- "TypeT" already reaches TypeTopology.
  const inMatch=raw.match(/^(.*?)\s+in\s+(\S+)$/i);
  const needle=(inMatch?inMatch[1]:raw).toLowerCase();
  const pathParts=inMatch?inMatch[2].toLowerCase().split("."):null;
  const inPath=pathParts?i=>{
    const mp=MODS[i].toLowerCase().split(".");
    if(mp.length<pathParts.length) return false;
    for(let j=0;j<pathParts.length-1;j++) if(mp[j]!==pathParts[j]) return false;
    return mp[pathParts.length-1].startsWith(pathParts[pathParts.length-1]);
  }:null;
  // Several words intersect: every one of them must match, each on its own.
  // An Agda name never contains a space, so splitting on whitespace loses
  // nothing, and it lets a query name a definition and its home at once --
  // "compact ordinal" asks for compactness within the ordinals.
  const terms=needle.split(/\s+/).map(w=>({w:w, rx:wildcard(w,whole)}));
  const has=(s,t)=>t.rx?t.rx.test(s):s.includes(t.w);
  const all=s=>terms.every(t=>has(s,t));
  // "search within commentary instead" swaps the whole result set for one
  // over prose paragraphs, rather than piling them on top of the usual
  // definitions/concepts/contributors -- prose is both the biggest single
  // piece of text in the index and the likeliest to hit a plain word by
  // accident, so a combined list would mean scrolling through everything
  // else first. "compact in Ordinals" still scopes it exactly like anything
  // else, since inPath above does not depend on which mode this is.
  if(wantComs){
    const coms=COMS.filter(c=>all(c[0].toLowerCase()) && (!inPath || inPath(c[1])))
                   .map(c=>[AREA(MODS[c[1]]),c]).sort((a,b)=>a[0]-b[0])
                   .slice(0,400).map(x=>x[1]);
    render([],[],[],coms,inPath,terms,wantMods,wantSigs,wantAllScope);
    return;
  }
  const hits=[];
  for(const r of DEFS){
    if(inPath && !inPath(r[1])) continue;
    const mod=MODS[r[1]].toLowerCase();
    const sig=wantSigs && r[4] ? r[4].toLowerCase() : null;
    let worst=0;
    for(const t of terms){
      let s=score(r[0],t.w,t.rx);
      if(whole && !t.rx && s>2) s=-1;
      if(s<0 && wantMods && has(mod,t)) s=4;   // this word matched the module
      if(s<0 && sig && has(sig,t)) s=5;        // this word matched the type
      if(s<0){ worst=-1; break; }
      if(s>worst) worst=s;                     // a hit is only as good as its weakest word
    }
    if(worst>=0) hits.push([AREA(MODS[r[1]]),worst,-(r[3]||0),r]);
  }
  hits.sort((a,b)=>a[0]-b[0]||a[1]-b[1]||a[2]-b[2]);
  // A concept also answers to the words its prose pattern knows, so that
  // "exhaustible" finds compactness even though no label says it.
  let cons=CONS.filter(c=>all(c[0].toLowerCase())
                          || (c[3] && new RegExp(c[3],"i").test(needle)));
  let ppl=PEOPLE.filter(p=>all(p[1]));
  // With a path, a concept or contributor only survives if one of its own
  // definitions or one of its modules lies within it, and only those names
  // and modules are shown -- a bold name with no site in the path would
  // otherwise still link outside it, which is not what was asked for.
  if(inPath){
    const ownSiteInPath=n=>{
      const ss=SITEOF.get(n);
      return !!ss && ss.some(x=>inPath(x[1]));
    };
    cons=cons.filter(c=>c[1].some(ownSiteInPath) || c[2].some(inPath))
             .map(c=>[c[0],c[1].filter(ownSiteInPath),c[2].filter(inPath),c[3]]);
    ppl=ppl.filter(p=>p[2].some(inPath)).map(p=>[p[0],p[1],p[2].filter(inPath)]);
  }
  render(hits.slice(0,400).map(h=>h[3]),cons,ppl,[],inPath,terms,wantMods,wantSigs,wantAllScope);
}
// Emacs Agda-mode style escape sequences, e.g. \to for "→" and \MCU for
// "𝓤". Runs on every keystroke rather than waiting for a trigger key,
// since a plain textbox has no "pending input method" state of its own to
// hook into. Finds the last "\" before the cursor and takes the longest
// prefix of what follows it that is a complete key -- exactly SEQ itself
// when nothing longer extends it, otherwise the run is left alone until a
// later character breaks the tie, at which point that later character is
// replayed as ordinary text (or, for a key with several candidates,
// consumed instead as a 1-9 pick, so \:4 reaches ꞉ among the ten ways
// this method knows to type ":").
function escapeExpand(){
  if(q.selectionStart!==q.selectionEnd) return false;
  const pos=q.selectionStart, raw=q.value;
  const bs=raw.lastIndexOf("\\",pos-1);
  if(bs<0) return false;
  const seq=raw.slice(bs+1,pos);
  if(!seq) return false;
  const has=k=>Object.prototype.hasOwnProperty.call(ESC,k);
  // Waiting is about whether a LONGER key could still be built from here,
  // regardless of whether seq itself is already one -- "Om" is not itself
  // a key, but is a prefix of "Omega", so still has to wait; checking
  // has(seq) here as well as before under-triggered the fallback below and
  // resolved \Om as \O ("Ø") plus a literal "m" before "Omega" was typed.
  if(ESC_KEYS.some(k=>k.length>seq.length && k.startsWith(seq)))
    return false;                          // still ambiguous -- wait
  let cut=seq.length;
  while(cut>0 && !has(seq.slice(0,cut))) cut--;
  if(cut===0) return false;                // no escape anywhere in this run
  const val=ESC[seq.slice(0,cut)], extra=seq.slice(cut);
  let insert=val, used=0;
  if(Array.isArray(val)){
    const d=/^[1-9]/.test(extra) ? +extra[0] : null;
    if(d && d<=val.length){ insert=val[d-1]; used=1; } else insert=val[0];
  }
  const tail=extra.slice(used);
  q.value=raw.slice(0,bs)+insert+tail+raw.slice(pos);
  const newPos=bs+insert.length+tail.length;
  q.setSelectionRange(newPos,newPos);
  return true;
}
// The clipboard API needs a secure context, which a plain file:// page (see
// README.md -- opening TypeTopologySearch.html directly is a supported way
// to use it) is not, so a hidden-textarea fallback covers that case too.
function copyText(s){
  if(navigator.clipboard && navigator.clipboard.writeText)
    return navigator.clipboard.writeText(s);
  const ta=document.createElement("textarea");
  ta.value=s; ta.style.position="fixed"; ta.style.opacity="0";
  document.body.appendChild(ta); ta.select();
  try{ document.execCommand("copy"); } catch(e){}
  document.body.removeChild(ta);
  return Promise.resolve();
}
out.addEventListener("click",e=>{
  if(e.target.classList.contains("tog")){
    e.preventDefault();
    e.target.previousElementSibling.hidden=false;
    e.target.remove();
    return;
  }
  if(e.target.classList.contains("ucount")){
    const d=e.target.nextElementSibling;
    if(d) d.hidden=!d.hidden;
    return;
  }
  if(e.target.dataset.ax!==undefined){
    e.preventDefault();
    q.value=AXIOMS[e.target.dataset.ax];
    search();
    q.focus();
  }
  if(e.target.classList.contains("copy")){
    const btn=e.target, mod=MODS[btn.dataset.mod];
    copyText("open import "+mod).then(()=>{
      const prevTitle=btn.title;
      btn.textContent="✓"; btn.classList.add("done");
      btn.title="Copied";
      setTimeout(()=>{ btn.textContent="⧉"; btn.classList.remove("done");
                        btn.title=prevTitle; },1200);
    });
  }
});
clr.addEventListener("click",()=>{ q.value=""; q.focus(); search(); });
q.addEventListener("input",()=>{ escapeExpand(); search(); });
// Arrow keys move a selection through the result rows without leaving the
// box, Enter follows it -- the first real link in the row, skipping the
// href="#" ones used for "and N more" and the click-to-search links, which
// go nowhere on their own.
q.addEventListener("keydown",e=>{
  if(e.key!=="ArrowDown" && e.key!=="ArrowUp" && e.key!=="Enter") return;
  const rows=out.querySelectorAll("tr");
  if(!rows.length) return;
  if(e.key==="Enter"){
    const row=rows[selRow];
    if(!row) return;
    const a=row.querySelector('a[href]:not([href="#"])');
    if(a){ e.preventDefault(); location.href=a.href; }
    return;
  }
  e.preventDefault();
  if(rows[selRow]) rows[selRow].classList.remove("sel");
  selRow=e.key==="ArrowDown" ? Math.min(selRow+1,rows.length-1)
                             : Math.max(selRow-1,0);
  rows[selRow].classList.add("sel");
  rows[selRow].scrollIntoView({block:"nearest"});
});
useMods.addEventListener("change",search);
useSigs.addEventListener("change",search);
useComs.addEventListener("change",search);
useAllScope.addEventListener("change",search);
exact.addEventListener("change",search);
// A search updates the URL (see above), so it can be bookmarked or sent to
// someone else; this is the other half, reading it back on arrival --
// including a plain #q=... link typed or pasted while the page is already
// open, which fires "hashchange" rather than a fresh load.
function loadFromHash(){
  const m=location.hash.match(/^#q=(.*)$/);
  const raw=m?decodeURIComponent(m[1]):"";
  if(raw===q.value) return;
  q.value=raw;
  search();
}
window.addEventListener("hashchange",loadFromHash);
loadFromHash();
</script></body></html>
"""


# Concepts that are themselves a hypothesis a proof can take, rather than an
# everyday constructive notion -- shown as "assumes" badges under a
# definition's type. Their own curated identifier pattern (concepts.tsv
# column 3, otherwise used only for the --markdown outputs) doubles as how a
# signature is checked for mentioning them, since it is already validated
# against real signatures the same way the prose pattern is validated
# against real commentary.
AXIOM_CONCEPTS = ["function extensionality", "propositional extensionality",
                  "univalence", "excluded middle", "weak excluded middle",
                  "axiom of choice", "LPO", "WLPO", "LLPO"]

# The curated "assumes" badges above are switched off, by his request, now
# that "list every enclosing assumption" (unfiltered, all nine of these
# included) covers the same ground without the nine-item cutoff. Everything
# that computes and could render them is left in place -- only this flag
# changed -- so it is a one-word revert if he wants the curated view back,
# with or without a tickbox of its own.
SHOW_AXIOM_BADGES = False


def write_search_page(rows, out, site, table, body, paras, people, unsafe, escapes, htmldir):
    # Every module with a rendered page, not just the ~90% that define at
    # least one indexed name -- a concept's best prose is often in a pure
    # overview/index module that defines nothing of its own (import
    # statements and commentary only), and such a module was previously
    # invisible to "discussed in" and to a contributor's "named in", even
    # though it renders a perfectly good page to link to. Intersected with
    # the modules that actually HAVE a rendered page: prose_of reads every
    # tracked .lagda regardless, but one file in this repository is
    # unreachable from AllModulesIndex and so Agda never renders it.
    rendered = {os.path.basename(p)[:-5] for p in glob.glob(f"{htmldir}/*.html")}
    mods = sorted((set(body) | {r["module"] for r in rows}) & rendered)
    mi = {m: i for i, m in enumerate(mods)}
    # One entry per prose paragraph, [text, module index] -- unlike BODY,
    # which folds a whole module's commentary into one string only ever
    # tested for membership (see concepts_of), this is granular enough to be
    # a search result in its own right, only ever shown for a query ending
    # "in comment(s)" (see the SEARCH_TEMPLATE's own search()), since it is
    # both the biggest single piece of text in the index (~1.7 MB) and the
    # one a plain word is likeliest to hit by accident in ordinary prose.
    coms = [[p, mi[m]] for m in mods for p in paras.get(m, [])]
    cons = []
    axiom_patterns = []   # [(index into AXIOM_CONCEPTS, compiled ip), ...]
    for line in open(table, encoding="utf-8"):
        if line.startswith("#") or not line.strip(): continue
        c, pp, ip, lm, alias = (line.rstrip("\n").split("\t") + ["", "", "", ""])[:5]
        # The modules whose commentary discusses the concept. Without these a
        # concept is only as findable as the names curated for it, and in
        # TypeTopology the commentary often uses a word the code does not:
        # CompactTypes says "searchable" in its prose and is-compact∙ in its
        # code. Built from pp ALONE, never alias -- a fifth column exists
        # exactly for words too ordinary to scan the prose for (see below).
        key = [w for w in re.split(r"[ -]", c.lower()) if len(w) > 3]
        rx = prose_rx(pp)
        disc = sorted((m for m, t in body.items() if rx.search(t)),
                      key=lambda m: (not any(k in m.lower() for k in key), m))
        # The page answers to pp OR alias, but alias never feeds disc above:
        # "choice" alone would find the axiom of choice concept just as
        # "searchable" finds compactness, but unlike "searchable" it is also
        # ordinary English ("our choice of notion", "for some choice of D"),
        # so letting it widen the prose scan the way pp does would flood
        # "discussed in" with modules that are not about the axiom at all.
        answers_to = pp + ("|" + alias if alias else "")
        cons.append([c, [x.strip() for x in lm.split(",") if x.strip()],
                     [mi[m] for m in disc if m in mi],
                     re.sub(r"[ -]", "[ -]*", answers_to)])
        if c in AXIOM_CONCEPTS and ip:
            axiom_patterns.append((AXIOM_CONCEPTS.index(c), re.compile(ip)))
    # Sibling definitions in the same enclosing module(s) share an identical
    # scope_text, so it is worth interning the same way MODS is: 985 distinct
    # strings across 21,332 definitions, not 21,332 copies.
    scope_texts = sorted({r.get("scope_text") for r in rows if r.get("scope_text")})
    sti = {t: i for i, t in enumerate(scope_texts)}
    # The definitions named in a "used in" drill-down repeat heavily -- the
    # same handful of proof-shaped names (an equational chain's own local
    # lemmas, say) keep showing up as whoever calls whatever they call --
    # so interning them the same way cuts what was measured as 4.4 of 4.9
    # MB of raw, undeduplicated name text down to the size of one name
    # table (17,673 distinct names across 183,460 call-site attributions).
    used_by_names = sorted({n for r in rows for _, _, by_def in r.get("used_by", [])
                            for n, _ in by_def if n is not None})
    uni = {n: i for i, n in enumerate(used_by_names)}
    defs = []
    for r in rows:
        sig = r.get("sig") or ""
        # A hypothesis taken once as a module parameter never appears in the
        # signature of a definition inside it, so scope_text is checked too
        # -- but ONLY when the hypothesis is not ALREADY visible in sig
        # itself, since a badge repeating what the type already says (EM in
        # `EM-gives-DNE : EM 𝓤 → DNE 𝓤`) adds nothing; the badge earns its
        # place exactly when it says something the printed type does not.
        scope_text = r.get("scope_text", "")
        axioms = [i for i, rx in axiom_patterns
                  if not rx.search(sig) and rx.search(scope_text)]
        used_by = [[mi[m], total, [[uni[n] if n is not None else -1, c] for n, c in by_def]]
                  for m, total, by_def in r.get("used_by", []) if m in mi]
        defs.append([r["name"], mi[r["module"]], r["frag"], r["uses"], sig, axioms,
                     sti.get(scope_text, -1), used_by])
    defs.sort(key=lambda d: -d[3])
    page = SEARCH_TEMPLATE % dict(
        ndefs=f"{len(defs):,}", ncons=len(cons), ntotal=f"{len(body):,}",
        ncoms=f"{len(coms):,}",
        site=json.dumps(site), mods=json.dumps(mods, ensure_ascii=False),
        defs=json.dumps(defs, ensure_ascii=False, separators=(",", ":")),
        cons=json.dumps(cons, ensure_ascii=False, separators=(",", ":")),
        coms=json.dumps(coms, ensure_ascii=False, separators=(",", ":")),
        ownarea=json.dumps(LINK_IN_OWN_AREA),
        unsafe=json.dumps(sorted(mi[m] for m in unsafe if m in mi)),
        people=json.dumps([[n, unaccented(n).lower(), [mi[m] for m in ms if m in mi]]
                           for n, ms in people],
                          ensure_ascii=False, separators=(",", ":")),
        axioms=json.dumps(AXIOM_CONCEPTS, ensure_ascii=False),
        scopetexts=json.dumps(scope_texts, ensure_ascii=False),
        usedbynames=json.dumps(used_by_names, ensure_ascii=False),
        showaxioms=json.dumps(SHOW_AXIOM_BADGES),
        esc=open(escapes, encoding="utf-8").read(),
        builddate=datetime.date.today().strftime("%-d %B %Y"))
    open(f"{out}/TypeTopologySearch.html", "w", encoding="utf-8").write(page)


def render(source, entry, htmldir, agda):
    "Run agda --html, unless the rendering is already there and up to date."
    newest = max((os.path.getmtime(os.path.join(source, f))
                  for f in subprocess.run(["git", "ls-files", "*.lagda", "*.agda"],
                                          cwd=source, capture_output=True,
                                          text=True).stdout.split()), default=0)
    pages = glob.glob(f"{htmldir}/*.html")
    if pages and min(os.path.getmtime(p) for p in pages) > newest:
        print(f"{len(pages)} html pages in {htmldir} are up to date")
        return
    print(f"{agda} --html --html-dir={htmldir} {entry}   (this may take a while)")
    try:
        proc = subprocess.Popen([agda, "--html", f"--html-dir={htmldir}", entry],
                                cwd=source, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True)
    except FileNotFoundError:
        raise SystemExit(f"{agda} not found; install it or pass --html <dir>")
    # Streamed rather than captured outright, so the "Checking Foo.Bar"
    # progress lines (a cold run is a minute or two) still appear live as
    # they always have; Agda's own diagnostic -- which file, which line --
    # is still visible above the summary message below, for whichever of
    # the two this turns out to be.
    for line in proc.stdout:
        print(line, end="")
    proc.wait()
    if proc.returncode != 0:
        # No fix on this script's own side for the most common cause, an
        # open interaction point (a "?", mid-proof): the command-line flag
        # Agda's own error suggests, --allow-unsolved-metas, is itself
        # incompatible with --safe, which TypeTopology uses throughout, so
        # it fails the SAME way on the very next --safe module checked,
        # hole or not (confirmed the hard way before settling on this
        # message instead). An ordinary type checking error is the other
        # possibility, equally fatal to the whole render either way -- one
        # message covers both, since this script cannot tell them apart
        # from the exit status alone, and either way nothing past this
        # point runs, so whatever index already existed is untouched.
        raise SystemExit(
            "the index cannot be updated when there are holes or "
            "type checking errors in the Agda files; the previous index, "
            "if any, has been left as is")


def main():
    # realpath rather than abspath, so this still finds concepts.tsv and
    # agda-input-escapes.json correctly when invoked through a symlink on
    # $PATH rather than run in place -- abspath would resolve those
    # relative to the symlink itself, not to where the real file (and its
    # siblings) actually live.
    here = os.path.dirname(os.path.realpath(__file__))
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    # The rendering is 118 MB and is not worth committing, so it goes to
    # <typetopology>/html rather than beside this script -- already
    # gitignored there (html/*, in TypeTopology's own .gitignore) -- and
    # kept between runs, rather than a temporary directory that would lose
    # it and force a full re-render (a minute or so) the next time round.
    p.add_argument("--html", help="an existing html rendering; the default is to "
                                  "run agda into <typetopology>/html")
    p.add_argument("--typetopology", default=os.path.dirname(here),
                   help="a TypeTopology checkout -- its own source/ "
                        "directory and top-level README.md are found under "
                        "here, unless --source or --readme override either "
                        "individually")
    p.add_argument("--source", default=None,
                   help="the source directory, if not simply "
                        "<typetopology>/source")
    p.add_argument("--out", default=here, help="where to write the index")
    p.add_argument("--entry", default="AllModulesIndex.lagda",
                   help="the module agda is pointed at, within the source directory")
    p.add_argument("--agda", default="agda", help="the agda to run")
    p.add_argument("--json", action="store_true",
                   help="also write definitions.json, 4 MB, for other tools")
    p.add_argument("--markdown", action="store_true",
                   help="also write the concept and identifier indexes, 57 markdown "
                        "files; the search page alone is the default")
    p.add_argument("--defs-index", action="store_true",
                   help="also write Definitions.txt, a flat plain-text index for "
                        "grep rather than browsing")
    p.add_argument("--emacs-index", action="store_true",
                   help="also write Definitions.tsv, a tab-separated index for "
                        "typetopology-search.el (or any other program)")
    p.add_argument("--no-html", action="store_true",
                   help="skip writing TypeTopologySearch.html -- concepts.tsv and "
                        "agda-input-escapes.json are then not needed at all, only "
                        "this script and the source itself, which is what "
                        "typetopology-search.el's own self-bootstrap uses")
    p.add_argument("--concepts", default=os.path.join(here, "concepts.tsv"))
    p.add_argument("--escapes", default=os.path.join(here, "agda-input-escapes.json"),
                   help="the emacs Agda input method's own key -> character table, "
                        "for typing unicode by escape sequence on the search page; "
                        "unrelated to TypeTopology and not regenerated by this script "
                        "-- see README.md for how it was produced")
    p.add_argument("--readme", default=None,
                   help="the readme whose contributor list names the "
                        "people, if not simply <typetopology>/README.md")
    p.add_argument("--site", default="https://martinescardo.github.io/TypeTopology/")
    a = p.parse_args()
    if a.source is None:
        a.source = os.path.join(a.typetopology, "source")
    if a.readme is None:
        a.readme = os.path.join(a.typetopology, "README.md")
    if not os.path.isdir(a.source):
        raise SystemExit(
            f"--source {a.source!r} is not a directory. This script needs "
            "a TypeTopology checkout; the default guess (this script's own "
            "parent directory) is right only by coincidence -- pass "
            "--typetopology /path/to/TypeTopology explicitly.")
    if not os.path.exists(os.path.join(a.source, a.entry)):
        raise SystemExit(
            f"{a.entry} not found under --source {a.source!r} -- this "
            "does not look like a TypeTopology source directory.")
    os.makedirs(a.out, exist_ok=True)
    htmldir = a.html or os.path.join(a.typetopology, "html")
    if not a.html:
        os.makedirs(htmldir, exist_ok=True)
        render(a.source, a.entry, htmldir, a.agda)
    rows = gather(htmldir, a.source)
    _, body, paras = prose_of(a.source)
    if a.markdown:
        write_identifier_index(rows, a.out, a.site, len(body))
        write_concept_index(rows, a.out, a.site, a.concepts, body)
    people = (people_of(a.readme, body) if (not a.no_html or a.emacs_index)
              and os.path.exists(a.readme) else [])
    # concepts_of degrades to [] by itself when concepts.tsv is missing, the
    # same as people above does for a missing README -- concepts stay
    # optional for the emacs-index-only bootstrap this way, matching
    # --no-html's own documented "concepts.tsv ... not needed" (see the
    # --no-html help text above and README.md).
    concepts = concepts_of(a.concepts, body) if (not a.no_html or a.emacs_index) else []
    if not a.no_html:
        write_search_page(rows, a.out, a.site, a.concepts, body, paras, people,
                          unsafe_modules(a.source), a.escapes, htmldir)
    if a.json:
        json.dump(rows, open(os.path.join(a.out, "definitions.json"), "w"))
    if a.defs_index:
        write_defs_index(rows, a.out)
    if a.emacs_index:
        write_emacs_index(rows, a.out, a.source, people, concepts)
    print(f"{len(rows)} definitions, {len({r['name'] for r in rows})} names, "
          f"{len({r['module'] for r in rows})} of {len(body)} modules, "
          f"{len(people)} contributors, {len(concepts)} concepts -> {a.out}")
    # A half-emptied html directory indexes quietly and looks fine until the
    # counts are read closely, so say so here.
    pages = len(glob.glob(f"{htmldir}/*.html"))
    if pages < 0.9 * len(body):
        print(f"warning: only {pages} html pages for {len(body)} modules; "
              f"the rendering in {htmldir} looks incomplete")


if __name__ == "__main__":
    main()
