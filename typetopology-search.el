;;; typetopology-search.el --- Search TypeTopology while writing Agda  -*- lexical-binding: t; -*-

;; Part of TypeTopologySearch (see README.md). This file offers one
;; command, `typetopology-search', that looks a name or type fragment up
;; against the whole library -- not just what the current buffer happens
;; to have imported, which is the one thing Agda's own live
;; `agda2-search-about-toplevel' cannot do, since an unimported name is
;; not in scope for it to find. The two are meant to complement each
;; other, not compete: this is for "does something like this already
;; exist, and where", Agda's own command is for "given what I have
;; already imported, what exactly does this normalise to".
;;
;; Set `typetopology-search-checkout-root' to your TypeTopology directory
;; before requiring this file (see README.md for why this can't just be
;; guessed). From there, requiring it is the whole setup: it reads its
;; data from Definitions.tsv, next to it, and builds
;; that file itself (by running agda-index.py --emacs-index, also next
;; to it) the first time it is needed and is not there yet -- no
;; separate manual step. It is not, after that, kept in sync with the
;; source automatically; running `typetopology-search-regenerate-index'
;; after adding or renaming things is what picks up the difference.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup typetopology-search nil
  "Search the TypeTopology library while writing Agda."
  :group 'tools)

(defcustom typetopology-search-file
  (and load-file-name
       (expand-file-name "Definitions.tsv" (file-name-directory load-file-name)))
  "Where Definitions.tsv lives, as written by `agda-index.py --emacs-index'."
  :type 'file
  :group 'typetopology-search)

(defcustom typetopology-search-checkout-root
  (and load-file-name
       (expand-file-name ".." (file-name-directory load-file-name)))
  "Your TypeTopology directory. Its source/ subdirectory is where a
definition's own FILE column in Definitions.tsv (itself relative) is
resolved when jumping to source. The default guess (this file's own
parent directory) is right only by coincidence; set this explicitly,
before requiring this file, to your own TypeTopology directory."
  :type 'directory
  :group 'typetopology-search)

(defun typetopology-search--source-root ()
  "`typetopology-search-checkout-root', with source/ appended."
  (expand-file-name "source" typetopology-search-checkout-root))

(defun typetopology-search--default-generator ()
  "Where agda-index.py is, by default: right next to this file, if it is
there. Definitions.tsv's own column layout is tied to the exact
version of the script that wrote it, so a copy known to come from the
very same checkout as this file is preferred over any other one --
falling back to whatever \"agda-index.py\" is found on $PATH only when
there is no such sibling, which is the case exactly when this one file
was copied somewhere else on its own, separately from the rest of the
repository it came from."
  (or (and load-file-name
          (let ((sibling (expand-file-name
                          "agda-index.py" (file-name-directory load-file-name))))
            (and (file-exists-p sibling) sibling)))
      (executable-find "agda-index.py")))

(defcustom typetopology-search-generator
  (typetopology-search--default-generator)
  "The generator script, run as \"agda-index.py --emacs-index\" to
(re)produce `typetopology-search-file'. Run automatically when that
file does not exist yet, so that requiring this one file is the whole
setup; also what `typetopology-search-regenerate-index' runs by hand
afterwards. Set to nil to disable both and always require the file to
already exist, built some other way.

Defaults to a copy right next to this file if there is one, or
whatever \"agda-index.py\" is found on $PATH otherwise -- see
`typetopology-search--default-generator'. Since Definitions.tsv's own
format is tied to the exact script version that wrote it, keep
whichever one this points at in sync with this file's own version
(the same checkout, or the same commit) rather than pointing it at an
unrelated or older copy."
  :type '(choice file (const :tag "Never regenerate automatically" nil))
  :group 'typetopology-search)

;; ------------------------------------------------------------- data

(cl-defstruct (typetopology-search-entry
               (:constructor typetopology-search-entry-create))
  "One row of Definitions.tsv."
  name        ; bare identifier
  dispmod     ; module, with any inner submodule, for display
  importmod   ; module alone, what `open import' wants
  file        ; source file, relative to the TypeTopology source directory
  line        ; source line, 1-indexed
  uses        ; use count, an integer
  sig         ; signature, or ""
  assumes     ; enclosing-module hypotheses, or ""
  dtext)      ; lower-cased display text, cached -- see `typetopology-search--dtext'

(defvar typetopology-search--entries nil
  "All entries, most-recently loaded from `typetopology-search-file'.")
(defvar typetopology-search--loaded-mtime nil
  "The modification time Definitions.tsv had when last loaded, so an
edit-and-regenerate is picked up automatically on the next search
without needing an explicit reload command.")

(defun typetopology-search--display (e)
  "The candidate text shown for entry E, mirroring Definitions.txt's own
one-line-per-definition shape -- including, the same as there, a
trailing \"(assumes: ...)\" clause for any hypothesis (`funext', a
whole record's worth of structure, ...) taken once by an enclosing
module rather than repeated in E's own signature, which otherwise
never shows up anywhere at all."
  (concat (typetopology-search-entry-name e)
          (unless (string-empty-p (typetopology-search-entry-sig e))
            (concat " : " (typetopology-search-entry-sig e)))
          "  [" (typetopology-search-entry-dispmod e)
          (unless (zerop (typetopology-search-entry-uses e))
            (format ", %d uses" (typetopology-search-entry-uses e)))
          "]"
          (unless (string-empty-p (typetopology-search-entry-assumes e))
            (concat "  (assumes: " (typetopology-search-entry-assumes e) ")"))))

(defun typetopology-search--display-propertized (e)
  "Like `typetopology-search--display', but with faces applied so a
result is easy to pick out at a glance rather than lost among a page
of type signatures: the name in `bold', everything else -- signature,
module, use count, and any assumption clause -- in `shadow', the
standard Emacs face for de-emphasised text. Query-match highlighting
is a separate step, in `typetopology-search--render', since it depends
on what was actually typed, not on the entry alone."
  (let* ((name (typetopology-search-entry-name e))
         (sig (typetopology-search-entry-sig e))
         (assumes (typetopology-search-entry-assumes e))
         (rest (concat
                (unless (string-empty-p sig) (concat " : " sig))
                "  [" (typetopology-search-entry-dispmod e)
                (unless (zerop (typetopology-search-entry-uses e))
                  (format ", %d uses" (typetopology-search-entry-uses e)))
                "]"
                (unless (string-empty-p assumes)
                  (concat "  (assumes: " assumes ")")))))
    (concat (propertize name 'face 'bold)
            (propertize rest 'face 'shadow))))

(defun typetopology-search--parse-line (line)
  "One Definitions.tsv line -> an entry, or nil for a malformed line (left
lenient on purpose, so one bad line does not take the whole index down)."
  (let ((f (split-string line "\t" nil)))
    (when (>= (length f) 8)
      (let ((e (typetopology-search-entry-create
               :name (nth 0 f) :dispmod (nth 1 f) :importmod (nth 2 f)
               :file (nth 3 f) :line (string-to-number (nth 4 f))
               :uses (string-to-number (nth 5 f))
               :sig (nth 6 f) :assumes (nth 7 f))))
        ;; Computed once here rather than on every keystroke: filtering
        ;; 21,000 entries means building and lower-casing this string
        ;; 21,000 times per character typed, which measured at ~130ms --
        ;; noticeable on every keystroke. Paying that cost once at load
        ;; time instead (the whole file already takes a fraction of a
        ;; second to parse) is a straightforward trade.
        (setf (typetopology-search-entry-dtext e)
              (downcase (typetopology-search--display e)))
        e))))

(defun typetopology-search--load (file)
  "Parse FILE into `typetopology-search--entries'."
  (let ((entries nil))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (while (not (eobp))
        (let ((line (buffer-substring-no-properties
                     (line-beginning-position) (line-end-position))))
          (unless (or (string-empty-p line) (string-prefix-p "#" line))
            (let ((e (typetopology-search--parse-line line)))
              (when e (push e entries)))))
        (forward-line 1)))
    (setq typetopology-search--entries (nreverse entries))))

(defun typetopology-search--regenerate ()
  "Run `typetopology-search-generator' to (re)produce
`typetopology-search-file'. Blocks Emacs for however long that takes --
unavoidable the very first time, when there is nothing to search yet
without it; a cold run (agda has to render the whole library first) is
a minute or two, a warm one (the rendering is already up to date, only
Definitions.tsv itself is regenerated) closer to ten seconds."
  (unless (and typetopology-search-generator
              (file-exists-p typetopology-search-generator))
    (user-error "No TypeTopology index at %s, and no generator script to \
build it (typetopology-search-generator is %s) -- run \
agda-index.py --emacs-index by hand, or set typetopology-search-file \
to an index built elsewhere"
                typetopology-search-file typetopology-search-generator))
  (unless (and typetopology-search-checkout-root
              (file-directory-p (typetopology-search--source-root)))
    (user-error "typetopology-search-checkout-root (%s) has no source/ \
subdirectory -- set it to your TypeTopology directory"
                typetopology-search-checkout-root))
  (message "TypeTopology: building the search index (agda-index.py \
--emacs-index) -- this can take a minute or two the first time...")
  (with-temp-buffer
    ;; --source and --out are passed explicitly rather than left to
    ;; agda-index.py's own defaults (a directory relative to itself),
    ;; since typetopology-search.el, the generator, the source tree and
    ;; the index file need not all live under one directory together --
    ;; typetopology-search-checkout-root and typetopology-search-file are
    ;; each independently configurable, precisely for that case. --no-html
    ;; skips building the browser page this same script also produces,
    ;; which needs concepts.tsv and agda-input-escapes.json to exist --
    ;; this file has no use for either, so there is no reason to require
    ;; them just to build Definitions.tsv.
    ;;
    ;; `typetopology-search--source-root' returning an already-expanded
    ;; path is not optional here: call-process hands its argument strings
    ;; to the subprocess exactly as given, with none of the "~" expansion
    ;; Emacs's OWN file functions (file-directory-p above included) do
    ;; quietly on your behalf -- a "~" that survives into this argv is
    ;; just an ordinary character to Python, and `os.path.exists("~/...")'
    ;; is false, not "your home directory".
    (let ((status (call-process (expand-file-name typetopology-search-generator)
                                nil t nil
                                "--emacs-index" "--no-html"
                                "--source" (typetopology-search--source-root)
                                "--out" (expand-file-name
                                         (file-name-directory typetopology-search-file)))))
      (unless (zerop status)
        (error "typetopology-search: agda-index.py --emacs-index failed \
(exit %s):\n%s" status (buffer-string)))))
  (message "TypeTopology: search index built."))

;;;###autoload
(defun typetopology-search-regenerate-index ()
  "Rebuild the TypeTopology search index by hand -- after adding,
renaming, or removing definitions, say, since that is not picked up
automatically otherwise."
  (interactive)
  (typetopology-search--regenerate)
  (typetopology-search--load typetopology-search-file)
  (setq typetopology-search--loaded-mtime
        (file-attribute-modification-time
         (file-attributes typetopology-search-file))))

(defun typetopology-search--ensure-loaded ()
  "Load the index, regenerating it first if it does not exist yet and a
generator script is available (see `typetopology-search-generator'),
and reload it whenever the file's own mtime has changed since --
picking up a `typetopology-search-regenerate-index' or a by-hand rerun
of agda-index.py alike, with no separate reload step to remember."
  (unless (and typetopology-search-file (file-exists-p typetopology-search-file))
    (if typetopology-search-generator
        (typetopology-search--regenerate)
      (user-error "TypeTopology index not found (%s) -- run \
agda-index.py --emacs-index, or set typetopology-search-file"
                  typetopology-search-file)))
  (let ((mtime (file-attribute-modification-time
                (file-attributes typetopology-search-file))))
    (unless (and typetopology-search--entries
                 (equal mtime typetopology-search--loaded-mtime))
      (typetopology-search--load typetopology-search-file)
      (setq typetopology-search--loaded-mtime mtime))))

;; ------------------------------------------------------- picking a result

(defconst typetopology-search--actions
  '(("Insert the name at point"                      . insert-name)
    ("Jump to its definition in the source file"      . jump-to-source)
    ("Insert \"open import Module\" for its module"   . insert-import))
  "What a result can be turned into, in the order offered on the menu.
The labels are shown as-is in the action menu, so they are written to
stand alone without needing a separate description column.")

(defvar typetopology-search--last-action nil
  "The action last chosen from the menu, this Emacs session -- nil means
the menu has never been shown yet, which forces it once regardless of
RET or TAB, so the three choices are seen at least once before either
becomes an unexplained default.")

(defun typetopology-search--action-label (action)
  (car (rassq action typetopology-search--actions)))

(defun typetopology-search--activate-agda-input ()
  "Turn on Agda's own \\=\\to-style Unicode input method (`agda-input.el',
which agda2-mode already loads, registers it under the literal name
\"Agda\") for this one minibuffer read -- silently does nothing if it
is not available, rather than erroring, since this file does not
require agda2-mode to be loaded to work at all."
  (when (or (featurep 'agda-input) (assoc "Agda" input-method-alist))
    (activate-input-method "Agda")))

(defvar typetopology-search--history nil
  "This prompt's own minibuffer history (past searches, reachable with
M-p/M-n, not the arrow keys -- see `typetopology-search--minibuffer-map'
below), kept separate from the shared, global `minibuffer-history' for
the same reason as `typetopology-search--action-history' further down.")

(defun typetopology-search--no-default-completions ()
  "Defensive, though no longer load-bearing the way it once was: with no
`minibuffer-completion-table' in play any more (see below -- this
prompt stopped using `completing-read' entirely), Emacs has nothing to
fall back to here regardless. Kept in case M-p/M-n ever interact with
this some other way; costs nothing to set."
  (setq-local minibuffer-default-add-function nil))

;; --------------------------------------------------- filtering candidates

(defvar-local typetopology-search--matches nil
  "The entries currently matching what has been typed, most relevant
first. Buffer-local to the minibuffer of one
`typetopology-search--read-candidate' call.")
(defvar-local typetopology-search--selected 0
  "Index into `typetopology-search--matches' of the highlighted entry --
what the up/down arrow keys move, and what RET or TAB acts on.")
(defvar-local typetopology-search--display-fn #'typetopology-search--display
  "How to turn one of `typetopology-search--matches' into display text --
`typetopology-search--display' (entries) for the main search,
`identity' (plain strings) for the action menu; read by
`typetopology-search--select-move' when it redraws after moving the
selection, so that call site does not need to know which of the two
UIs it is currently running inside of.")
(defvar-local typetopology-search--query-active t
  "Whether the minibuffer's own text is a live, filterable query (the
main search) or not (the action menu, whose list is fixed regardless
of what -- if anything -- is typed) -- read by
`typetopology-search--select-move' to decide what to pass
`typetopology-search--render' as QUERY.")

(defconst typetopology-search--max-shown 30
  "How many matches to render at once. Filtering all ~21,000 entries on
every keystroke is cheap; rendering thousands of lines of results is
not worth it, and nothing past the first few dozen is ever what was
meant anyway -- narrowing the query further is always the way to reach
something further down, the same as with any search.")

(defun typetopology-search--wildcard-regexp (word)
  "WORD's regexp translation when it contains a `*' (any run of
characters), a `?' (any one character), or a literal one escaped as
`\\*', `\\?', or `\\\\' -- the same translation the browser search
page's own `wildcard()' does, so the two agree on what a wildcard
query means. Returns nil, for a plain substring match instead, when
WORD has none of `*', `?', or `\\' at all."
  (when (string-match-p "[*?\\]" word)
    (let ((body "") (i 0) (n (length word)))
      (while (< i n)
        (let ((c (aref word i)))
          (cond
           ((and (eq c ?\\) (< (1+ i) n) (memq (aref word (1+ i)) '(?* ?? ?\\)))
            (setq i (1+ i))
            (setq body (concat body (regexp-quote (string (aref word i))))))
           ((eq c ?*) (setq body (concat body ".*")))
           ((eq c ??) (setq body (concat body ".")))
           (t (setq body (concat body (regexp-quote (string c))))))
          (setq i (1+ i))))
      body)))

(defun typetopology-search--terms (query)
  "QUERY split into whitespace-separated, lower-cased terms, each a (WORD
. REGEXP) pair via `typetopology-search--wildcard-regexp' -- REGEXP nil
for a word matched by plain substring search instead. Shared by
filtering, scoring, and highlighting, so all three agree on what QUERY
means."
  (mapcar (lambda (w) (cons w (typetopology-search--wildcard-regexp w)))
          (split-string (downcase query))))

(defun typetopology-search--term-score (term text)
  "How well TERM (a (WORD . REGEXP) pair from
`typetopology-search--terms') matches within TEXT (already
lower-case) -- the same tiers the browser search page's own `score()'
uses, so the two agree on what \"most relevant\" means. Lower is
better: 0 exact (the match is the whole of TEXT), 1 prefix, 2 starts a
hyphen/underscore/dot/bracket-separated word within TEXT, 3 found
anywhere else, or nil when TERM does not match TEXT at all."
  (let ((word (car term)) (rx (cdr term)) i len)
    (if rx
        (when (string-match rx text)
          (setq i (match-beginning 0) len (- (match-end 0) (match-beginning 0))))
      (let ((p (string-search word text)))
        (when p (setq i p len (length word)))))
    (when i
      (cond
       ((and (= i 0) (= len (length text))) 0)
       ((= i 0) 1)
       ((and (> i 0) (string-match-p "[-_.[]" (substring text (1- i) i))) 2)
       (t 3)))))

(defun typetopology-search--entry-score (e terms)
  "How relevant E is to TERMS overall: the worst (numerically highest)
of each term's own best score against E's name, or, for a term not in
the name at all, a flat lower-priority tier for being found only
elsewhere (signature, module, assumptions) -- an exact name match
first, a name merely containing a term further down, a term that only
turned up in a signature or module last, exactly the order
`typetopology-search--filter''s own AND-of-matches already guarantees
a match exists in one of."
  (let ((name (downcase (typetopology-search-entry-name e)))
        (worst 0))
    (dolist (term terms)
      (let ((s (or (typetopology-search--term-score term name) 4)))
        (when (> s worst) (setq worst s))))
    worst))

(defun typetopology-search--entry-area (e)
  "How far down E sinks for the area it lives in, before relevance is
looked at at all -- the same `AREA' the browser search page uses, so
the two agree here too. Lower is better: 2 for `deprecated', since a
superseded definition is never the one being looked for, 1 for `MGS',
since those lecture notes redevelop from scratch names the library
already has, so an unqualified search for one of them means the
library's own, and 0 for every other directory, which is to say all of
them share the top rank and are ordered by relevance alone."
  (let ((mod (typetopology-search-entry-importmod e)))
    (cond ((string-prefix-p "deprecated." mod) 2)
          ((string-prefix-p "MGS." mod) 1)
          (t 0))))

(defun typetopology-search--term-match-p (term text)
  "Whether TERM (a (WORD . REGEXP) pair from
`typetopology-search--terms') matches somewhere in TEXT (already
lower-case)."
  (if (cdr term) (string-match-p (cdr term) text) (string-search (car term) text)))

(defun typetopology-search--filter (query)
  "Every entry whose display text matches each whitespace-separated term
of QUERY, case-insensitively, in any order -- simple and predictable
over clever, and enough to find a name, a piece of a signature, or a
module by any of their terms at once -- ranked by
`typetopology-search--entry-area' first, so that `deprecated' sinks
below everything and `MGS' just above it, then most relevant first by
`typetopology-search--entry-score', ties broken by use count
(descending), the identical three-key sort the browser search page
uses, so the two never disagree about which result is \"first\": without
this, \"is-prop\" landed on \"A-is-prop\" ahead of `is-prop' itself,
since nothing here ranked results at all before now -- entries simply
kept whatever order Definitions.tsv happened to list them in
(alphabetical), which has nothing to do with relevance. A term is
matched literally unless it contains `*', `?', or `\\', in which case
it is a wildcard pattern -- see `typetopology-search--wildcard-regexp'.
An empty query matches nothing: there is no value in a wall of all
21,000 definitions before anything has been typed."
  (if (string-blank-p query)
      nil
    (let* ((terms (typetopology-search--terms query))
           (matches (cl-remove-if-not
                     (lambda (e)
                       (let ((text (typetopology-search-entry-dtext e)))
                         (cl-every (lambda (term) (typetopology-search--term-match-p term text))
                                   terms)))
                     typetopology-search--entries)))
      (sort matches
           (lambda (a b)
             (let ((aa (typetopology-search--entry-area a))
                   (ab (typetopology-search--entry-area b)))
               (if (/= aa ab)
                   (< aa ab)
                 (let ((sa (typetopology-search--entry-score a terms))
                       (sb (typetopology-search--entry-score b terms)))
                   (if (= sa sb)
                       (> (typetopology-search-entry-uses a)
                          (typetopology-search-entry-uses b))
                     (< sa sb))))))))))

;; ------------------------------------------------------ showing the list

(defconst typetopology-search--results-buffer-name " *TypeTopology Search*")

(defun typetopology-search--highlight-matches (start end terms)
  "Add the standard `match' face over every occurrence of each of TERMS
(WORD . REGEXP pairs from `typetopology-search--terms') within
START..END of the current buffer, case-insensitively -- the same
matches `typetopology-search--filter' itself matched on, the same way
search.html already highlights a match within a result. A plain word
(REGEXP nil) is matched literally, not as a regexp, so a word
containing regexp-special characters -- and TypeTopology signatures
are full of them -- still highlights correctly; a wildcard term
matches as its own regexp instead. Layered with
`add-face-text-property' rather than set outright, so it combines with
whatever `typetopology-search--display-propertized' already applied (a
match inside the bold name stays bold, for instance) instead of
silently overwriting it."
  (dolist (term terms)
    (let ((word (car term)) (rx (cdr term)))
      (unless (string-empty-p word)
        (save-excursion
          (goto-char start)
          (let ((case-fold-search t))
            (if rx
                (while (re-search-forward rx end t)
                  (add-face-text-property (match-beginning 0) (match-end 0) 'match)
                  ;; A wildcard term such as a bare "*" can match zero
                  ;; characters -- re-search-forward would otherwise sit
                  ;; at the same position forever.
                  (when (= (match-beginning 0) (match-end 0)) (forward-char 1)))
              (while (search-forward word end t)
                (add-face-text-property (match-beginning 0) (match-end 0) 'match)))))))))

(defun typetopology-search--render (query matches selected &optional display-fn)
  "Redraw the results buffer for QUERY's MATCHES with SELECTED
highlighted, creating the buffer if this is the first call. Returns
the buffer. DISPLAY-FN turns one match into its display text, and
defaults to `typetopology-search--display' -- the action menu (see
`typetopology-search--choose-action') shares this same rendering and
selection machinery with plain strings and `identity' instead of
entries, rather than duplicating it for a second, smaller UI. QUERY
nil (as opposed to the empty string) means there is no typed-query
concept at all here -- the action menu's fixed, always-shown list --
so the \"nothing typed yet\" message never applies."
  (let ((buf (get-buffer-create typetopology-search--results-buffer-name))
        (display-fn (or display-fn #'typetopology-search--display)))
    (with-current-buffer buf
      (let ((inhibit-read-only t) (selected-pos nil))
        (erase-buffer)
        (cond
         ((and query (string-blank-p query)) (insert "Type to search..."))
         ((null matches) (insert "No matches."))
         (t
          (let ((shown (seq-take matches typetopology-search--max-shown))
                (terms (and query (not (string-blank-p query))
                           (typetopology-search--terms query)))
                (i 0))
            (dolist (e shown)
              (let ((start (point)))
                (insert (funcall display-fn e))
                (when terms
                  (typetopology-search--highlight-matches start (point) terms))
                (when (= i selected)
                  (setq selected-pos start)
                  (overlay-put (make-overlay start (point)) 'face 'highlight))
                (insert "\n"))
              (setq i (1+ i)))
            (when (> (length matches) typetopology-search--max-shown)
              (insert (format "... and %d more (keep typing to narrow)\n"
                              (- (length matches) typetopology-search--max-shown)))))))
        (goto-char (point-min))
        (let ((win (get-buffer-window buf)))
          (when (and win selected-pos)
            ;; Keeps the highlighted line on screen as selection moves
            ;; past whatever is currently visible -- ordinary redisplay
            ;; already does this for any window once its own point moves,
            ;; selected or not; no separate scrolling logic needed.
            (set-window-point win selected-pos)))))
    buf))

(defun typetopology-search--show-results ()
  "Display the results buffer (creating it first, via `get-buffer-create',
if it does not exist yet -- `display-buffer' requires an already-live
buffer and signals a plain \"Invalid buffer\" error otherwise, which is
exactly what a call to this function before the first
`typetopology-search--render' used to hit) in a modest window at the
bottom of the frame, once, for the duration of the read;
`typetopology-search--render' only ever updates its text afterward."
  (display-buffer (get-buffer-create typetopology-search--results-buffer-name)
                  '((display-buffer-at-bottom)
                    (window-height . 0.3))))

;; --------------------------------------------------------- moving around

(defun typetopology-search--select-move (delta)
  "Move the selection by DELTA (positive: later/down, negative:
earlier/up), clamped to the current matches -- clamped rather than
wrapped, so running off either end is a clear stop, not a surprise
jump back to the other end."
  (when typetopology-search--matches
    (setq typetopology-search--selected
          (max 0 (min (1- (length typetopology-search--matches))
                      (+ typetopology-search--selected delta))))
    (typetopology-search--render (and typetopology-search--query-active
                                      (minibuffer-contents))
                                 typetopology-search--matches
                                 typetopology-search--selected
                                 typetopology-search--display-fn)))

(defun typetopology-search--select-next ()
  (interactive)
  (typetopology-search--select-move 1))

(defun typetopology-search--select-prev ()
  (interactive)
  (typetopology-search--select-move -1))

(defun typetopology-search--refilter ()
  "Recompute matches for the current input and reset the selection to
the top -- called whenever the input text itself changes (not when the
selection alone moves; see `typetopology-search--minibuffer-map')."
  (setq typetopology-search--matches
        (typetopology-search--filter (minibuffer-contents))
        typetopology-search--selected 0)
  (typetopology-search--render (minibuffer-contents)
                               typetopology-search--matches
                               typetopology-search--selected
                               typetopology-search--display-fn))

(defvar-local typetopology-search--last-query nil
  "The input text as of the last `typetopology-search--maybe-refilter'
call, so a command that leaves the text unchanged (an arrow key moving
the selection, in particular) does not trigger a pointless refilter --
which would also wrongly reset the selection right back after moving
it, since `typetopology-search--refilter' always resets to the top.")

(defun typetopology-search--maybe-refilter ()
  "Refilter only if the input text genuinely changed since last checked.
Run from `post-command-hook', once a whole command has finished, NOT
`after-change-functions', which fires on every raw buffer edit --
including transient ones the Agda input method makes internally while
resolving a single keystroke (its own status indicator, briefly
inserted then removed, was observed leaking into a real search this
way: the query some refilter calls saw was not \"fla\" but
\"fla  [∏]\\n\", \"∏\" being that input method's own configured title,
per its `quail-define-package' call -- a bug hit in real use, not
theoretical). By the time a command completes, whatever the input
method needed to do internally has already settled."
  (let ((q (minibuffer-contents)))
    (unless (equal q typetopology-search--last-query)
      (setq typetopology-search--last-query q)
      (typetopology-search--refilter))))

(defvar typetopology-search--result nil
  "(ENTRY . VIA-TAB) once a pick has been confirmed, for
`typetopology-search--read-candidate' to hand back after the minibuffer
read this was set inside of has exited -- completing-read's own return
value (necessarily a string) has no room for VIA-TAB, and reaching back
into an already-exited minibuffer for anything else is not possible,
so the result travels out via this variable instead.")

(defun typetopology-search--confirm (via-tab)
  "Finish the read with the currently selected entry, if there is one."
  (let ((e (nth typetopology-search--selected typetopology-search--matches)))
    (if e
        (progn (setq typetopology-search--result (cons e via-tab))
               (exit-minibuffer))
      (minibuffer-message "No match selected"))))

(defun typetopology-search--confirm-ret ()
  (interactive)
  (typetopology-search--confirm nil))

(defun typetopology-search--confirm-tab ()
  "TAB always opens the action menu for whatever is currently selected --
unlike the old completing-read-based design, there is no separate
\"still narrowing\" state to distinguish it from: a selection is always
well defined once there is at least one match."
  (interactive)
  (typetopology-search--confirm t))

(defvar typetopology-search--minibuffer-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "<down>") #'typetopology-search--select-next)
    (define-key m (kbd "<up>") #'typetopology-search--select-prev)
    (define-key m (kbd "RET") #'typetopology-search--confirm-ret)
    (define-key m (kbd "TAB") #'typetopology-search--confirm-tab)
    m)
  "Installed for the duration of the candidate read only. Arrow keys
move the selection over the CURRENTLY MATCHING entries shown in
`typetopology-search--results-buffer-name', not minibuffer history --
history is still reachable, just on M-p/M-n instead, which this map
does not touch.")

(defun typetopology-search--read-prompt ()
  "The candidate-list prompt, naming the current default action (or, the
first time, how to search instead, since what a pick DOES is already
explained in full by the action menu itself right after) so RET's
effect is never a surprise."
  (if typetopology-search--last-action
      (format "TypeTopology (RET: %s; ↑/↓ to pick, TAB for menu): "
              (downcase (typetopology-search--action-label
                         typetopology-search--last-action)))
    "TypeTopology (type to filter; ↑/↓ to pick, TAB for menu): "))

(defun typetopology-search--read-candidate ()
  "Read one candidate, returning (ENTRY . VIA-TAB). Own minimal
incremental-search UI, not `completing-read' -- after chasing several
real but not-ours-to-fix issues from leaning on whatever completion
setup happens to be active (shared minibuffer history, the
default-add-completions fallback, and finally an out-of-the-box
vertical-completion mode's own inconsistent window-height handling in
real use), this owns the whole interaction instead: filtering,
rendering, and arrow-key selection are all this file's own code, so
they behave the same regardless of what -- if anything -- is
configured elsewhere."
  (setq typetopology-search--result nil)
  (unwind-protect
      (minibuffer-with-setup-hook
          (lambda ()
            (use-local-map
             (make-composed-keymap typetopology-search--minibuffer-map
                                   (current-local-map)))
            (setq typetopology-search--display-fn
                  #'typetopology-search--display-propertized)
            (typetopology-search--activate-agda-input)
            (typetopology-search--no-default-completions)
            (add-hook 'post-command-hook
                      #'typetopology-search--maybe-refilter
                      nil t)
            (typetopology-search--show-results)
            (typetopology-search--maybe-refilter))
        (read-from-minibuffer (typetopology-search--read-prompt) nil nil nil
                              'typetopology-search--history))
    (let ((buf (get-buffer typetopology-search--results-buffer-name)))
      (when buf (kill-buffer buf))))
  typetopology-search--result)

(defvar typetopology-search--action-history nil
  "The action menu's own minibuffer history -- see
`typetopology-search--history', the same reasoning applies here.")

(defvar typetopology-search--action-result nil
  "The chosen label, set by `typetopology-search--action-confirm' just
before exiting the minibuffer -- same reasoning as
`typetopology-search--result': `read-from-minibuffer' can only return
the literal typed string, and nothing is typed here at all.")

(defun typetopology-search--action-confirm ()
  "RET on the action menu: like `typetopology-search--confirm', but
there is always exactly one thing selected here (a fixed three-item
list), so no \"nothing selected yet\" case to handle."
  (interactive)
  (let ((label (nth typetopology-search--selected typetopology-search--matches)))
    (setq typetopology-search--action-result label)
    (exit-minibuffer)))

(defvar typetopology-search--action-minibuffer-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "<down>") #'typetopology-search--select-next)
    (define-key m (kbd "<up>") #'typetopology-search--select-prev)
    (define-key m (kbd "RET") #'typetopology-search--action-confirm)
    m)
  "The action menu's own arrow-key selection, the same idea as
`typetopology-search--minibuffer-map' for the main search (and reusing
its `typetopology-search--select-next'/`--select-prev') minus TAB,
which has no separate meaning here.")

(defun typetopology-search--choose-action (entry &optional first-time)
  "Prompt for one of `typetopology-search--actions' and remember it as
the new default -- the \"sticky\" half of RET repeating the last choice.
ENTRY, the result just picked, is shown first, so the prompt asking
what to do with it is never divorced from what \"it\" actually is.
FIRST-TIME says whether this is the very first pick this session, purely
to word the rest of the prompt accordingly.

Uses the same own arrow-key selection UI as the main search
(`typetopology-search--read-candidate'), not `completing-read' -- for
the identical reason: with `completing-read', arrow keys depend on
whatever completion setup, if any, happens to be configured, which is
exactly what broke here too (\"same problem we had in the search
box\", his own words) before this fix, by the same underlying cause."
  (let* ((prompt (concat (typetopology-search--display entry) "\n"
                         (if first-time
                             "First pick -- choose what happens (becomes your \
default from now on; TAB re-opens this menu later): "
                           "Choose an action (becomes the new default): ")))
         (labels (mapcar #'car typetopology-search--actions)))
    (setq typetopology-search--action-result nil)
    (unwind-protect
        (minibuffer-with-setup-hook
            (lambda ()
              (use-local-map
               (make-composed-keymap typetopology-search--action-minibuffer-map
                                     (current-local-map)))
              (typetopology-search--no-default-completions)
              (setq typetopology-search--matches labels
                    typetopology-search--selected 0
                    typetopology-search--display-fn #'identity
                    typetopology-search--query-active nil)
              (typetopology-search--show-results)
              (typetopology-search--render nil labels 0 #'identity))
          (read-from-minibuffer prompt nil nil nil
                                'typetopology-search--action-history))
      (let ((buf (get-buffer typetopology-search--results-buffer-name)))
        (when buf (kill-buffer buf))))
    (let ((action (cdr (assoc typetopology-search--action-result
                              typetopology-search--actions))))
      (setq typetopology-search--last-action action)
      action)))

(defun typetopology-search--decide-action (entry via-tab)
  "Which action to perform, given whether TAB (rather than RET) ended the
read: the menu wins if TAB asked for it explicitly, or if none has ever
been chosen yet this session; otherwise the last one sticks. ENTRY is
passed through to `typetopology-search--choose-action', to show in the
menu's own prompt when it does run."
  (if (or via-tab (null typetopology-search--last-action))
      (typetopology-search--choose-action entry (null typetopology-search--last-action))
    typetopology-search--last-action))

;; ------------------------------------------------------------ actions

(defun typetopology-search--jump-to-source (e)
  (let ((file (typetopology-search-entry-file e)))
    (when (string-empty-p file)
      (user-error "No source file recorded for %s"
                  (typetopology-search-entry-name e)))
    (let ((path (expand-file-name file (typetopology-search--source-root))))
      (unless (file-exists-p path)
        (user-error "%s not found (typetopology-search-checkout-root is %s)"
                    path typetopology-search-checkout-root))
      (find-file path)
      ;; `auto-mode-alist' normally puts a .lagda/.agda buffer straight into
      ;; agda2-mode already, via the boilerplate agda2-mode's own install
      ;; instructions have a user add to their init file -- this is only a
      ;; fallback for when that hasn't happened (or hasn't happened YET, in
      ;; whatever Emacs session this runs in), and does nothing at all,
      ;; silently, if agda2-mode isn't loaded here, rather than erroring.
      (when (and (fboundp 'agda2-mode) (not (derived-mode-p 'agda2-mode)))
        (agda2-mode))
      (goto-char (point-min))
      (forward-line (1- (typetopology-search-entry-line e))))))

(defun typetopology-search--perform (action e)
  (pcase action
    ('insert-name
     (insert (typetopology-search-entry-name e))
     (message "Inserted %s" (typetopology-search-entry-name e)))
    ('insert-import
     (let ((line (concat "open import " (typetopology-search-entry-importmod e))))
       (insert line)
       (message "Inserted %s" line)))
    ('jump-to-source
     (typetopology-search--jump-to-source e)
     (message "Jumped to %s, line %d"
              (typetopology-search-entry-file e) (typetopology-search-entry-line e)))
    (_ (error "typetopology-search: unknown action %s" action))))

;;;###autoload
(defun typetopology-search ()
  "Search TypeTopology's ~21,000 definitions by name or type fragment,
and act on the one you pick.

Plain RET repeats whatever action you last chose (or, the very first
time this is used in a session, opens a menu to choose one, so all
three are seen at least once). TAB, once your typing already names a
candidate exactly, opens that same menu on demand without changing
what RET repeats afterward -- unless you pick something different from
it, in which case that becomes the new default.

The three actions are: insert the matched name at point; jump to its
definition in the source; or insert \"open import Module\" for it.

This searches the whole library regardless of what the current buffer
has imported -- for a live, exactly-normalised type of something
already in scope, Agda's own `agda2-search-about-toplevel' is the
complementary command, bound by agda2-mode itself.

`ttsearch' is a shorthand alias for this same command."
  (interactive)
  (typetopology-search--ensure-loaded)
  (pcase-let ((`(,e . ,via-tab) (typetopology-search--read-candidate)))
    (unless e
      (user-error "No such definition"))
    (typetopology-search--perform (typetopology-search--decide-action e via-tab) e)))

;;;###autoload
(defalias 'ttsearch #'typetopology-search
  "Shorthand for `typetopology-search'.")

;; --------------------------------------------------------------- mode

(defvar typetopology-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c C-g") #'ttsearch)
    m)
  "Keymap for `typetopology-mode' -- \"v\", next to agda2-mode's own \"c\"
prefix commands, so it is reachable with the same hand.")

;;;###autoload
(define-minor-mode typetopology-mode
  "Minor mode adding TypeTopology search on top of agda2-mode.

\\{typetopology-mode-map}"
  :lighter " TT"
  :keymap typetopology-mode-map)

;; Every agda2-mode buffer gets this automatically, the same way several
;; other companion minor modes (eldoc, ...) attach themselves to a major
;; mode via its hook -- requiring typetopology-search is then the whole
;; setup, no separate keybinding line needed in a user's own init file.
;;;###autoload
(add-hook 'agda2-mode-hook #'typetopology-mode)

(provide 'typetopology-search)
;;; typetopology-search.el ends here
