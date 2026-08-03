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
;; separate manual step. After that, `typetopology-search-warn-when-stale'
;; (on by default) notices, cheaply, whenever the source has definitions
;; newer than the index and shows a bold reminder right alongside the
;; results, rather than blocking search on a prompt; `C-c C-u' during
;; the search itself, or `typetopology-search-update-index' by hand
;; any other time, rebuilds it.

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
setup; also what `typetopology-search-update-index' runs by hand
afterwards. Set to nil to disable both and always require the file to
already exist, built some other way.

Defaults to a copy right next to this file if there is one, or
whatever \"agda-index.py\" is found on $PATH otherwise -- see
`typetopology-search--default-generator'. Since Definitions.tsv's own
format is tied to the exact script version that wrote it, keep
whichever one this points at in sync with this file's own version
(the same checkout, or the same commit) rather than pointing it at an
unrelated or older copy."
  :type '(choice file (const :tag "Never update automatically" nil))
  :group 'typetopology-search)

(defcustom typetopology-search-warn-when-stale t
  "Whether `typetopology-search--ensure-loaded' checks the TypeTopology
source for definitions newer than `typetopology-search-file' and, when
it finds any, shows a bold one-line reminder right alongside the
results (see `typetopology-search--render') -- search still runs
against the existing index regardless, just possibly missing recent
definitions; `C-c C-u' during the search, or
`typetopology-search-update-index' by hand at any other time, rebuilds
it.

The check itself only compares file modification times (the same
comparison `agda-index.py's own render() makes for the html rendering,
aimed at the index instead), so it costs nothing noticeable even when
this is on.

Set to nil to skip the check, and the reminder, altogether -- the
index is still built once automatically the very first time it does
not exist yet, but never checked again after that except by an
explicit `typetopology-search-update-index' or `C-c C-u'."
  :type 'boolean
  :group 'typetopology-search)

(defcustom typetopology-search-include-concepts t
  "Whether concept entries (see `typetopology-search-entry-kind') are
kept when `typetopology-search-file' is loaded. Concepts are matched by
label only, the same as a contributor is matched by name -- not by
their prose pattern or search alias the way the browser search page's
own concept matching also is -- so this could in principle turn out to
add enough entries to make filtering noticeably slower on a real
checkout's full concept list (as of this writing, ~237 of them).

Set to nil to drop concept entries at load time, with no need to
regenerate `typetopology-search-file' or revert any code, if that turns
out to be the case: the change takes effect on the next load (a fresh
`typetopology-search--ensure-loaded' or `typetopology-search-update-index'
call, or restarting Emacs), since entries already loaded are not
retroactively dropped."
  :type 'boolean
  :group 'typetopology-search)

(defcustom typetopology-search-include-comments t
  "Whether comment entries (see `typetopology-search-entry-kind') are
kept when `typetopology-search-file' is loaded. A comment entry is one
paragraph of the library's own prose commentary, only ever shown for a
query starting \"-- \" (see `typetopology-search--filter'), but by far
the largest addition to the index by entry count (as of this writing,
~12,000 of them against ~21,000 definitions) and the biggest single
chunk of text in it, so this is the cheapest possible way to find out
whether that makes filtering noticeably slower on a real checkout,
without regenerating `typetopology-search-file' or reverting any code.

Set to nil to drop comment entries at load time; the change takes
effect on the next load (a fresh `typetopology-search--ensure-loaded'
or `typetopology-search-update-index' call, or restarting Emacs),
since entries already loaded are not retroactively dropped."
  :type 'boolean
  :group 'typetopology-search)

;; ------------------------------------------------------------- data

(cl-defstruct (typetopology-search-entry
               (:constructor typetopology-search-entry-create))
  "One row of Definitions.tsv -- a definition (KIND `def', the default),
a contributor (KIND `person'), a concept (KIND `concept'), or one
paragraph of prose commentary (KIND `comment'), told apart by
Definitions.tsv's own trailing column. Neither a person nor a concept
has a DISPMOD, IMPORTMOD, FILE, or SIG of their own -- all \"\" --
USES holds how many modules mention them, not a use count, and ASSUMES
holds which ones, semicolon-separated, instead of an enclosing-module
hypothesis. A comment's NAME is the paragraph text itself, and its
DISPMOD, IMPORTMOD and ASSUMES all hold the one module it was found
in -- unlike a person or concept, a paragraph belongs to exactly one
module, so IMPORTMOD is never blank the way theirs is, and it is
scoped by an \" in PATH\" query (see `typetopology-search--filter') the
same way a definition is; ASSUMES repeats it only so
`typetopology-search--jump-to-mention' can read it the same way it
already reads a person's or concept's own ASSUMES."
  name        ; bare identifier, a contributor's name, a concept's label, or
              ; a comment's paragraph text
  dispmod     ; module, with any inner submodule, for display
  importmod   ; module alone, what `open import' wants
  file        ; source file, relative to the TypeTopology source directory
  line        ; source line, 1-indexed
  uses        ; use count, an integer -- or, for a person/concept, module count
  sig         ; signature, or ""
  assumes     ; enclosing-module hypotheses, or "" -- or, for a
              ; person/concept/comment, the module(s) mentioning them,
              ; semicolon-separated
  (kind 'def) ; `def', `person', `concept', or `comment' -- defaults to `def'
              ; so code and tests built before this distinction existed
              ; still work unchanged
  dtext)      ; lower-cased display text, cached -- see `typetopology-search--dtext'

(defvar typetopology-search--entries nil
  "All entries, most-recently loaded from `typetopology-search-file'.")
(defvar typetopology-search--loaded-mtime nil
  "The modification time Definitions.tsv had when last loaded, so an
edit-and-update is picked up automatically on the next search without
needing an explicit reload command.")
(defvar typetopology-search--index-stale nil
  "Whether `typetopology-search--check-staleness' last found the source
newer than `typetopology-search-file' -- read by
`typetopology-search--render' to show a bold reminder alongside the
results, rather than blocking search the way earlier versions of this
file did.")

(defconst typetopology-search--mention-phrase
  '((person . "named in") (concept . "discussed in"))
  "The phrase `typetopology-search--display' and
`typetopology-search--display-propertized' use before the module count
for a non-definition entry, by KIND (see
`typetopology-search-entry-kind') -- \"named in\" for a contributor,
matching the browser page's own wording for its \"named in\" list;
\"discussed in\" for a concept, matching that page's \"discussed in\"
list.")

(defun typetopology-search--display (e)
  "The candidate text shown for entry E. For a contributor or a concept
(see `typetopology-search-entry-kind'), just their name/label and how
many modules mention them. For a comment, the paragraph itself
followed by the one module it was found in -- unlike a definition's own
\"uses\" and \"(assumes: ...)\" clauses, neither applies to a paragraph,
so both are left out rather than shown as 0 or repeating the module a
second time (ASSUMES holds it too, but only for
`typetopology-search--jump-to-mention' to read). Otherwise mirrors
Definitions.txt's own one-line-per-definition shape -- including, the
same as there, a trailing \"(assumes: ...)\" clause for any hypothesis
(`funext', a whole record's worth of structure, ...) taken once by an
enclosing module rather than repeated in E's own signature, which
otherwise never shows up anywhere at all."
  (let ((phrase (cdr (assq (typetopology-search-entry-kind e)
                           typetopology-search--mention-phrase))))
    (cond
     (phrase
      (format "%s  (%s %d modules)"
              (typetopology-search-entry-name e) phrase
              (typetopology-search-entry-uses e)))
     ((eq (typetopology-search-entry-kind e) 'comment)
      (concat (typetopology-search-entry-name e)
              "  [" (typetopology-search-entry-dispmod e) "]"))
     (t
      (concat (typetopology-search-entry-name e)
              (unless (string-empty-p (typetopology-search-entry-sig e))
                (concat " : " (typetopology-search-entry-sig e)))
              "  [" (typetopology-search-entry-dispmod e)
              (unless (zerop (typetopology-search-entry-uses e))
                (format ", %d uses" (typetopology-search-entry-uses e)))
              "]"
              (unless (string-empty-p (typetopology-search-entry-assumes e))
                (concat "  (assumes: " (typetopology-search-entry-assumes e) ")")))))))

(defun typetopology-search--display-propertized (e)
  "Like `typetopology-search--display', but with faces applied so a
result is easy to pick out at a glance rather than lost among a page
of type signatures: the name in `bold', everything else -- signature,
module, use count, and any assumption clause -- in `shadow', the
standard Emacs face for de-emphasised text, and the word \"assumes\"
itself in `italic' on top of that. A contributor's or concept's
\"(named/discussed in ...)\" clause is `shadow' too, with no `italic'
word of its own. A comment's own name is a whole paragraph rather than
a short identifier, so it is left in the default face -- bolding a
paragraph reads as heavier, not easier to pick out -- with only its
trailing module bracket in `shadow'. Query-match highlighting is a
separate step, in `typetopology-search--render', since it depends on
what was actually typed, not on the entry alone."
  (let ((phrase (cdr (assq (typetopology-search-entry-kind e)
                           typetopology-search--mention-phrase))))
    (cond
     (phrase
      (concat (propertize (typetopology-search-entry-name e) 'face 'bold)
              (propertize (format "  (%s %d modules)"
                                  phrase (typetopology-search-entry-uses e))
                          'face 'shadow)))
     ((eq (typetopology-search-entry-kind e) 'comment)
      (concat (typetopology-search-entry-name e)
              (propertize (concat "  [" (typetopology-search-entry-dispmod e) "]")
                          'face 'shadow)))
     (t
      (let* ((name (propertize (typetopology-search-entry-name e) 'face 'bold))
             (sig (typetopology-search-entry-sig e))
             (assumes (typetopology-search-entry-assumes e))
             (rest (concat
                    (unless (string-empty-p sig) (concat " : " sig))
                    "  [" (typetopology-search-entry-dispmod e)
                    (unless (zerop (typetopology-search-entry-uses e))
                      (format ", %d uses" (typetopology-search-entry-uses e)))
                    "]"
                    (unless (string-empty-p assumes)
                      (concat "  (assumes: " assumes ")"))))
             (rest (propertize rest 'face 'shadow)))
        (unless (string-empty-p assumes)
          (let ((pos (string-match-p (regexp-quote "(assumes: ") rest)))
            (when pos
              (add-face-text-property (1+ pos) (+ pos 8) 'italic nil rest))))
        (concat name rest))))))

(defun typetopology-search--parse-line (line)
  "One Definitions.tsv line -> an entry, or nil for a malformed line (left
lenient on purpose, so one bad line does not take the whole index down),
or for a concept line when `typetopology-search-include-concepts' is
nil, or a comment line when `typetopology-search-include-comments' is
nil (see there for both) -- the cheapest possible removal, done right
here at load time rather than filtered out again on every keystroke
afterward. The trailing kind column (\"def\", \"person\", \"concept\",
or \"comment\") is itself optional here, defaulting to `def', so an
index built before contributors, concepts, or comments were added still
parses exactly as before."
  (let ((f (split-string line "\t" nil)))
    (when (>= (length f) 8)
      (let ((kind (if (>= (length f) 9) (intern (nth 8 f)) 'def)))
        (unless (or (and (eq kind 'concept) (not typetopology-search-include-concepts))
                    (and (eq kind 'comment) (not typetopology-search-include-comments)))
          (let ((e (typetopology-search-entry-create
                   :name (nth 0 f) :dispmod (nth 1 f) :importmod (nth 2 f)
                   :file (nth 3 f) :line (string-to-number (nth 4 f))
                   :uses (string-to-number (nth 5 f))
                   :sig (nth 6 f) :assumes (nth 7 f) :kind kind)))
            ;; Computed once here rather than on every keystroke: filtering
            ;; 21,000 entries means building and lower-casing this string
            ;; 21,000 times per character typed, which measured at ~130ms --
            ;; noticeable on every keystroke. Paying that cost once at load
            ;; time instead (the whole file already takes a fraction of a
            ;; second to parse) is a straightforward trade.
            (setf (typetopology-search-entry-dtext e)
                  (downcase (typetopology-search--display e)))
            e))))))

(defun typetopology-search--load (file)
  "Parse FILE into `typetopology-search--entries'. A line is data if
it contains a TAB, and skipped (a blank line, or one of the header
comments agda-index.py writes) otherwise -- NOT decided by whether the
line starts with \"#\", which a real data line can too: `#-' is a
genuine TypeTopology identifier (`PathSequences.Split.lagda', line
173), and a leading-\"#\" check alone silently dropped it, along with
any other identifier that might ever start the same way. The header
comments this file's own agda-index.py writes are always plain prose,
with no TAB in them, so this still tells the two apart correctly."
  (let ((entries nil))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (while (not (eobp))
        (let ((line (buffer-substring-no-properties
                     (line-beginning-position) (line-end-position))))
          (when (string-match-p "\t" line)
            (let ((e (typetopology-search--parse-line line)))
              (when e (push e entries)))))
        (forward-line 1)))
    (setq typetopology-search--entries (nreverse entries))))

(defun typetopology-search--rebuild ()
  "Run `typetopology-search-generator' to (re)produce
`typetopology-search-file'. Blocks Emacs for however long that takes --
unavoidable the very first time, when there is nothing to search yet
without it; a cold run (agda has to typecheck and render the whole
library first) takes a while, a warm one (the rendering is already up
to date, only Definitions.tsv itself is updated) closer to ten
seconds."
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
--emacs-index) -- this can take a while the first time...")
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
(defun typetopology-search-update-index ()
  "Rebuild the TypeTopology search index by hand -- after adding,
renaming, or removing definitions, say. `C-c C-u' does the same thing
without leaving an in-progress search (see
`typetopology-search--minibuffer-map')."
  (interactive)
  (typetopology-search--rebuild)
  (typetopology-search--load typetopology-search-file)
  (setq typetopology-search--loaded-mtime
        (file-attribute-modification-time
         (file-attributes typetopology-search-file)))
  (setq typetopology-search--index-stale nil))

;; ------------------------------------------------------- staleness check

(defun typetopology-search--git-tracked-agda-files ()
  "The TypeTopology source's own .lagda/.agda files, as `git ls-files'
reports them under `typetopology-search--source-root' -- the same list
`agda-index.py's own render() checks to decide whether the html
rendering needs a rebuild. nil, rather than an error, when the source
root is not a git checkout or git itself is not on $PATH -- either way
there is simply nothing to compare mtimes against, so staleness
detection quietly does not apply."
  (let ((root (typetopology-search--source-root)))
    (and (executable-find "git")
        (file-directory-p root)
        (with-temp-buffer
          (let ((default-directory root))
            (when (zerop (call-process "git" nil t nil "ls-files"
                                       "--" "*.lagda" "*.agda"))
              (split-string (buffer-string) "\n" t)))))))

(defun typetopology-search--newest-source-mtime ()
  "The most recent modification time among
`typetopology-search--git-tracked-agda-files', or nil when that list
itself is nil -- in which case staleness is never suspected at all."
  (let ((root (typetopology-search--source-root))
        (newest nil))
    (dolist (f (typetopology-search--git-tracked-agda-files))
      (let* ((full (expand-file-name f root))
             (mtime (and (file-exists-p full)
                        (file-attribute-modification-time
                         (file-attributes full)))))
        (when (and mtime (or (not newest) (time-less-p newest mtime)))
          (setq newest mtime))))
    newest))

(defun typetopology-search--check-staleness ()
  "Set `typetopology-search--index-stale' from a cheap mtime comparison
between `typetopology-search-file' and the source (see
`typetopology-search--newest-source-mtime') when
`typetopology-search-warn-when-stale' is non-nil -- nil (\"not stale\")
otherwise, including whenever this cannot be determined at all."
  (setq typetopology-search--index-stale
        (and typetopology-search-warn-when-stale
            (file-exists-p typetopology-search-file)
            (let ((newest (typetopology-search--newest-source-mtime)))
              (and newest
                  (time-less-p (file-attribute-modification-time
                                (file-attributes typetopology-search-file))
                               newest))))))

(defun typetopology-search--ensure-loaded ()
  "Load the index, building it first if it does not exist yet and a
generator script is available (see `typetopology-search-generator'),
and reload it whenever the file's own mtime has changed since --
picking up a `typetopology-search-update-index' or a by-hand rerun of
agda-index.py alike, with no separate reload step to remember.
Finally, see `typetopology-search--check-staleness'."
  (unless (and typetopology-search-file (file-exists-p typetopology-search-file))
    (if typetopology-search-generator
        (typetopology-search--rebuild)
      (user-error "TypeTopology index not found (%s) -- run \
agda-index.py --emacs-index, or set typetopology-search-file"
                  typetopology-search-file)))
  (let ((mtime (file-attribute-modification-time
                (file-attributes typetopology-search-file))))
    (unless (and typetopology-search--entries
                 (equal mtime typetopology-search--loaded-mtime))
      (typetopology-search--load typetopology-search-file)
      (setq typetopology-search--loaded-mtime mtime)))
  (typetopology-search--check-staleness))

;; ------------------------------------------------------- picking a result

(defconst typetopology-search--actions
  '(("Jump to its definition in the source file"      . jump-to-source)
    ("Insert the name at point"                      . insert-name)
    ("Insert \"open import Module\" for its module"   . insert-import)
    ("Jump to a module mentioning them"               . jump-to-mention)
    ("Update the index"                              . update-index))
  "Every action this file knows, and the label used for each -- the
canonical name/label mapping `typetopology-search--action-label' and
`typetopology-search--perform' use, regardless of which of these a
given entry actually offers (see `typetopology-search--actions-for').
The labels are shown as-is in the action menu, so they are written to
stand alone without needing a separate description column. The last
entry, updating the index, is unlike the rest: it does not act
on the entry the menu was opened for at all, and -- see
`typetopology-search--choose-action' -- never becomes the sticky
default plain RET repeats, unlike the others.")

(defconst typetopology-search--definition-actions
  '(jump-to-source insert-name insert-import update-index)
  "Which of `typetopology-search--actions' a definition offers -- see
`typetopology-search--actions-for'.")

(defconst typetopology-search--contributor-actions
  '(jump-to-mention)
  "Which of `typetopology-search--actions' a contributor, a concept, or a
comment offers -- see `typetopology-search--actions-for'. Inserting a
contributor's name at point, this file's very first idea for a
contributor result, does not belong here: nobody wants that: what all
three are actually for is finding the module they were found in and
jumping there -- the ONLY thing, deliberately not also offering
\"update the index\" here the way a definition's own menu does, since
`typetopology-search--decide-action' skips the menu entirely (RET goes
straight to the one action) whenever there is only one to choose from.")

(defun typetopology-search--actions-for (entry)
  "The subset of `typetopology-search--actions', in order, that ENTRY
actually offers on the menu -- `typetopology-search--definition-actions'
for a definition, `typetopology-search--contributor-actions' for a
contributor, a concept, or a comment (see
`typetopology-search-entry-kind'): none of the three has a source file
of its own to jump to directly or open an import for, only a module
that mentions it (or, for a comment, was found in), reached instead via
`jump-to-mention' (see `typetopology-search--jump-to-mention')."
  (let ((wanted (if (memq (typetopology-search-entry-kind entry) '(person concept comment))
                    typetopology-search--contributor-actions
                  typetopology-search--definition-actions)))
    (cl-remove-if-not (lambda (a) (memq (cdr a) wanted))
                      typetopology-search--actions)))

(defvar typetopology-search--last-action nil
  "The action last chosen from the menu, this Emacs session -- nil means
the menu has never been shown yet, which forces it once regardless of
RET or TAB, so the choices that can become a default are seen at least
once before becoming an unexplained one. Never set to `update-index'
-- see `typetopology-search--choose-action'.")

(defun typetopology-search--action-label (action)
  (car (rassq action typetopology-search--actions)))

(defun typetopology-search--activate-agda-input ()
  "Turn on Agda's own \\=\\to-style Unicode input method (`agda-input.el',
which agda2-mode already loads, registers it under the literal name
\"Agda\") for this one minibuffer read -- silently does nothing if it
is not available, rather than erroring, since this file does not
require agda2-mode to be loaded to work at all.

Also silently does nothing if activating it errors out instead --
hit in real use as \"Command attempted to use minibuffer while in
minibuffer\", from inside `activate-input-method' itself, on its very
first use in a session. Left unguarded, that error aborts the rest of
this minibuffer-setup-hook (in particular, `typetopology-search--show-results'
is never reached, so no results appear at all) -- a Unicode-typing
convenience should never be able to take the whole search down.
`ignore-errors', not a plain `condition-case', so `C-g' still
interrupts normally; only a genuine error is swallowed."
  (when (or (featurep 'agda-input) (assoc "Agda" input-method-alist))
    (ignore-errors (activate-input-method "Agda"))))

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
      (let ((p (string-match-p (regexp-quote word) text)))
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
the two agree here too. Lower is better: 3 for `Unsafe', since what it
defines relies on principles the rest of the library does without, 2
for `deprecated', since a superseded definition is never the one being
looked for, 1 for `MGS', since those lecture notes redevelop from
scratch names the library already has, so an unqualified search for one
of them means the library's own, and 0 for every other directory, which
is to say all of them share the top rank and are ordered by relevance
alone."
  (let ((mod (typetopology-search-entry-importmod e)))
    (cond ((string-prefix-p "Unsafe." mod) 3)
          ((string-prefix-p "deprecated." mod) 2)
          ((string-prefix-p "MGS." mod) 1)
          (t 0))))

(defun typetopology-search--term-match-p (term text)
  "Whether TERM (a (WORD . REGEXP) pair from
`typetopology-search--terms') matches somewhere in TEXT (already
lower-case)."
  (if (cdr term) (string-match-p (cdr term) text)
    (string-match-p (regexp-quote (car term)) text)))

(defun typetopology-search--split-in-scope (query)
  "QUERY split into (KEYWORDS . PATH) when it ends in a literal, whole
\"in\" (case-insensitive) followed by one more, space-free word -- the
same split the browser search page's own path-scoped search makes for
\"compact in Ordinals.Comp\". PATH is nil, and KEYWORDS is QUERY
unchanged, when QUERY does not end this way (in particular, \"in\"
alone, or \"in PATH\" with nothing before \"in\", is left as an
ordinary query, not treated as an empty-keyword scope -- an empty
keyword search already matches nothing on its own, see
`typetopology-search--filter')."
  (let ((words (split-string query)))
    (if (and (>= (length words) 3)
            (string-equal (downcase (nth (- (length words) 2) words)) "in"))
        (cons (string-join (butlast words 2) " ") (car (last words)))
      (cons query nil))))

(defun typetopology-search--split-comment-only (query)
  "QUERY split into (REST . WANT-COMMENTS) when QUERY starts with a
literal \"--\" (two hyphens, Agda's own comment marker -- Agda itself
needs no space after it either, so neither does this: \"--compact\" and
\"-- compact\" both work) -- the same syntax the browser search page's
\"search within commentary instead\" checkbox offers, but written as a
query prefix here since there is no minibuffer checkbox to tick).
WANT-COMMENTS is non-nil and REST is QUERY with the marker and any
further leading whitespace stripped; otherwise WANT-COMMENTS is nil and
REST is QUERY unchanged. No real definition, contributor, or concept
name starts with \"--\" (Agda's own lexer could not tell it apart from
a comment if one tried), so there is nothing this could mistakenly
intercept."
  (if (string-prefix-p "--" query)
      (cons (string-trim-left (substring query 2)) t)
    (cons query nil)))

(defun typetopology-search--in-scope-p (path mod)
  "Whether MOD (a dotted module name) lies within PATH, the way the
browser page's own path-scoped search does: PATH is split on \".\" into
segments, every segment but the last must match a segment of MOD in
full, case-insensitively, but the last segment is only a PREFIX of its
corresponding MOD segment, so a scope narrows while still being typed
-- \"compact in Ordinals.Comp\" already reaches
`Ordinals.CompactnessOfSuprema'. MOD shorter than PATH (fewer segments)
never matches, regardless of content."
  (let ((psegs (split-string path "\\." t))
        (msegs (split-string mod "\\." t)))
    (and (<= (length psegs) (length msegs))
        (let ((n (length psegs)) (ok t))
          (dotimes (i n)
            (unless (if (= i (1- n))
                       (string-prefix-p (nth i psegs) (nth i msegs) t)
                     (string-equal (downcase (nth i psegs)) (downcase (nth i msegs))))
              (setq ok nil)))
          ok))))

(defun typetopology-search--filter (query)
  "Every entry whose display text matches each whitespace-separated term
of QUERY, case-insensitively, in any order -- simple and predictable
over clever, and enough to find a name, a piece of a signature, or a
module by any of their terms at once -- ranked by
`typetopology-search--entry-area' first, so that `Unsafe' sinks below
everything, `deprecated' just above it and `MGS' above that, then most
relevant first by `typetopology-search--entry-score', ties broken by use count
(descending), the identical three-key sort the browser search page
uses, so the two never disagree about which result is \"first\": without
this, \"is-prop\" landed on \"A-is-prop\" ahead of `is-prop' itself,
since nothing here ranked results at all before now -- entries simply
kept whatever order Definitions.tsv happened to list them in
(alphabetical), which has nothing to do with relevance. A term is
matched literally unless it contains `*', `?', or `\\', in which case
it is a wildcard pattern -- see `typetopology-search--wildcard-regexp'.
An empty query matches nothing: there is no value in a wall of all
21,000 definitions before anything has been typed.

A query ending in \" in PATH\" (see `typetopology-search--split-in-scope')
additionally requires the entry's own module to lie within PATH (see
`typetopology-search--in-scope-p') -- PATH itself plays no part in the
term matching above, only KEYWORDS does. A contributor or concept entry
has no module of its own, so neither ever survives an \" in PATH\" query
at all; a comment entry does, and is scoped by it exactly like a
definition.

A query starting \"--\" (see `typetopology-search--split-comment-only';
no space needed after it, matching Agda's own comment syntax) searches
comment entries ONLY, excluding every definition, contributor,
and concept -- and vice versa, an ordinary query never matches a
comment entry -- since prose commentary is both the single biggest
chunk of text in the index and the likeliest to hit a plain word by
accident, the same reasoning behind the browser search page's own
\"search within commentary instead\" checkbox defaulting off. The two
markers compose: \"-- compact in Ordinals\" strips the leading marker
first, then scopes what remains exactly as any other query would."
  (if (string-blank-p query)
      nil
    (pcase-let ((`(,rest . ,want-comments) (typetopology-search--split-comment-only query)))
     (pcase-let ((`(,keywords . ,path) (typetopology-search--split-in-scope rest)))
      (let* ((terms (typetopology-search--terms keywords))
             (matches (cl-remove-if-not
                       (lambda (e)
                         (and (if want-comments
                                 (eq (typetopology-search-entry-kind e) 'comment)
                               (not (eq (typetopology-search-entry-kind e) 'comment)))
                             (or (null path)
                                 (typetopology-search--in-scope-p
                                  path (typetopology-search-entry-importmod e)))
                             (let ((text (typetopology-search-entry-dtext e)))
                               (cl-every (lambda (term) (typetopology-search--term-match-p term text))
                                         terms))))
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
                       (< sa sb))))))))))))

;; ------------------------------------------------------ showing the list

(defconst typetopology-search--results-buffer-name " *TypeTopology Search*")

(defun typetopology-search--highlight-matches (start end terms)
  "Add the standard `match' face over every occurrence of each of TERMS
(WORD . REGEXP pairs from `typetopology-search--terms') within
START..END of the current buffer, case-insensitively -- the same
matches `typetopology-search--filter' itself matched on, the same way
TypeTopologySearch.html already highlights a match within a result. A plain word
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
so the \"nothing typed yet\" message never applies, and neither does
the staleness reminder just below.

When QUERY is non-nil and `typetopology-search--index-stale' is
non-nil, a bold reminder line goes first, ahead of the matches
themselves -- shown together with the results, in the same buffer and
window, deliberately: two earlier attempts at showing this
separately (a header-line, a mode-line, a second child frame stacked
next to this one) each turned out either too easy to miss or,
independently, unreliable in real use (content not always painted
before the first keystroke; a second frame once left the minibuffer's
own window a single line tall after TAB). Bold, and first, rather than
dimmed and tucked out of the way, is deliberately hard to miss instead."
  (let ((buf (get-buffer-create typetopology-search--results-buffer-name))
        (display-fn (or display-fn #'typetopology-search--display)))
    (with-current-buffer buf
      (let ((inhibit-read-only t) (selected-pos nil))
        (erase-buffer)
        (when (and query typetopology-search--index-stale)
          (insert (propertize "TypeTopology: the index looks older than the \
source -- press C-c C-u to update it (search still works, just \
possibly missing recent definitions)"
                              'face 'bold))
          (insert "\n\n"))
        (cond
         ((and query (string-blank-p query)) (insert "Type to search..."))
         ((null matches) (insert "No matches."))
         (t
          (let ((shown (seq-take matches typetopology-search--max-shown))
                (terms (and query (not (string-blank-p query))
                           (typetopology-search--terms
                            (car (typetopology-search--split-in-scope query)))))
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

(defun typetopology-search--cleanup-results ()
  "Kill the results buffer once a minibuffer read using it has finished.
Shared by `typetopology-search--read-candidate' and
`typetopology-search--choose-action'."
  (let ((buf (get-buffer typetopology-search--results-buffer-name)))
    (when buf (kill-buffer buf))))

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

(defun typetopology-search--show-help ()
  "Pop up a brief syntax cheatsheet in a `help-mode' buffer -- `q' or
any other key dismisses it and returns straight to the search, without
exiting the minibuffer or disturbing what has been typed so far,
exactly like `C-h f' does from anywhere else. Bound to `C-h' rather
than living as a TAB menu entry precisely because it needs no existing
match to work: TAB's own menu (see `typetopology-search--confirm-tab')
only ever opens for whatever is currently selected, so someone who has
typed nothing yet, or nothing that matches -- exactly who is most
likely to need this -- could never reach it there."
  (interactive)
  (with-help-window "*TypeTopology Search Help*"
    (princ "\
Keys
  ↑ / ↓    move the selection
  RET     repeat the last action, or ask the first time
  TAB     action menu
  C-h     this help

Syntax
  several words        all have to match, each anywhere in a
                        result's name, type, module, or its
                        (assumes: ...) clause
  *  ?  \\*             any run of characters, a single one, a
                        literal star
  NAME in Ordinals.Comp
                        restrict to one directory or file -- the
                        last segment is a prefix, so it narrows
                        while still being typed
  --NAME, or -- NAME (no space needed)
                        search the library's prose commentary
                        instead, excluding definitions,
                        contributors, and concepts -- \"--compact
                        in Ordinals\" composes both")))

(defun typetopology-search--update-from-search ()
  "Rebuild the index right now, without leaving the search -- the same
work `typetopology-search-update-index' does, plus refiltering so
the results (and the bold reminder ahead of them, see
`typetopology-search--render') reflect it immediately. Blocks Emacs for
however long that takes (see `typetopology-search--rebuild'); bound
to `C-c C-u' precisely so it is reachable the moment the staleness
reminder is noticed, deliberately with no confirmation of its own --
pressing this key already is the ask. Not `C-c C-r': confirmed against
the real `agda2-mode-map' to already be `agda2-refine' there, so that
would have silently done nothing (see
`typetopology-search--read-candidate' for why a minor mode's own
binding wins over an ordinary local one regardless). Not offered from
the action menu (`typetopology-search--action-minibuffer-map' has no
binding for it): that menu is not itself a search, and has no reminder
of its own to react to."
  (interactive)
  (typetopology-search-update-index)
  (typetopology-search--refilter))

(defvar typetopology-search--minibuffer-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "<down>") #'typetopology-search--select-next)
    (define-key m (kbd "<up>") #'typetopology-search--select-prev)
    (define-key m (kbd "C-c C-u") #'typetopology-search--update-from-search)
    (define-key m (kbd "RET") #'typetopology-search--confirm-ret)
    (define-key m (kbd "TAB") #'typetopology-search--confirm-tab)
    (define-key m (kbd "C-h") #'typetopology-search--show-help)
    m)
  "Installed for the duration of the candidate read only. Arrow keys
move the selection over the CURRENTLY MATCHING entries shown in
`typetopology-search--results-buffer-name', not minibuffer history --
history is still reachable, just on M-p/M-n instead, which this map
does not touch. `C-h', not `?', since `?' is itself a live wildcard
character in the query syntax (see `typetopology-search--wildcard-regexp')
and would otherwise be unable to insert one at all.")

(defun typetopology-search--read-prompt ()
  "The candidate-list prompt, naming the current default action (or, the
first time, how to search instead, since what a pick DOES is already
explained in full by the action menu itself right after) so RET's
effect is never a surprise. No leading \"TypeTopology (...)\" -- this
is only ever shown while already running `typetopology-search', so
saying whose search this is would be telling something already known,
and dropping it makes room for \"C-h for help\" (see
`typetopology-search--show-help') without lengthening the line."
  (if typetopology-search--last-action
      (format "RET: %s; ↑/↓ to pick, TAB for menu, C-h for help: "
              (downcase (typetopology-search--action-label
                         typetopology-search--last-action)))
    ;; "Type to search", not "...to filter", to match the results
    ;; buffer's own placeholder for the same blank-query state (see
    ;; typetopology-search--render) -- the two disagreed before this.
    "Type to search; ↑/↓ to pick, TAB for menu, C-h for help: "))

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
configured elsewhere.

Installs `typetopology-search--minibuffer-map' via `set-transient-map',
not the plain `use-local-map'/`make-composed-keymap' this used to do --
a real bug hit in use: an ordinary local keymap sits BELOW any active
minor mode's own keymap in Emacs's own lookup order (see *note Active
Keymaps:: in the Elisp manual), and does not necessarily win against a
major mode's own map either, depending on exactly how and where a key
ends up looked up. Confirmed directly against the real `agda2-mode-map'
(not assumed): `C-c C-r', this map's original choice for updating
the index (see `typetopology-search--update-from-search'), is
`agda2-refine' there, and something -- not fully pinned down, possibly
this same precedence gap, possibly a separate focus issue in what has
since been simplified away below -- let that binding fire instead of
ours. `set-transient-map' installs via `overriding-terminal-local-map',
which the Elisp manual documents as outranking _all_ other keymaps
unconditionally, closing off that whole class of problem regardless of
the exact mechanism. Keys not in our map still fall through to normal
lookup exactly as before (self-insert, M-p/M-n history, ...), per its
own docstring, so nothing else about typing in this minibuffer
changes."
  (setq typetopology-search--result nil)
  (let (exit-transient-map)
    (unwind-protect
        (minibuffer-with-setup-hook
            (lambda ()
              (setq exit-transient-map
                    (set-transient-map typetopology-search--minibuffer-map
                                       (lambda () t)))
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
      (when exit-transient-map (funcall exit-transient-map))
      (typetopology-search--cleanup-results)))
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
there is always exactly one thing selected here (a fixed list, see
`typetopology-search--actions-for'), so no \"nothing selected yet\"
case to handle."
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

(defun typetopology-search--pick-from-list (prompt items)
  "Read one of ITEMS (plain strings) with PROMPT, via the same
fixed-list arrow-key picker the action menu uses --
`typetopology-search--choose-action' and
`typetopology-search--jump-to-mention' (a contributor's or concept's
own list of mentioning modules) share this one implementation rather
than each keeping its own copy of the minibuffer/transient-map/cleanup
dance.
Returns the chosen item, or nil if ITEMS is empty."
  (when items
    (let (exit-transient-map)
      (setq typetopology-search--action-result nil)
      (unwind-protect
          (minibuffer-with-setup-hook
              (lambda ()
                (setq exit-transient-map
                      (set-transient-map typetopology-search--action-minibuffer-map
                                         (lambda () t)))
                (typetopology-search--no-default-completions)
                (setq typetopology-search--matches items
                      typetopology-search--selected 0
                      typetopology-search--display-fn #'identity
                      typetopology-search--query-active nil)
                (typetopology-search--show-results)
                (typetopology-search--render nil items 0 #'identity))
            (read-from-minibuffer prompt nil nil nil
                                  'typetopology-search--action-history))
        (when exit-transient-map (funcall exit-transient-map))
        (typetopology-search--cleanup-results))
      typetopology-search--action-result)))

(defun typetopology-search--choose-action (entry &optional first-time)
  "Prompt for one of `typetopology-search--actions-for' ENTRY and
remember it as the new default -- the \"sticky\" half of RET repeating
the last choice -- unless it is `update-index', which never becomes a
default: it does not act on ENTRY at all, so there is nothing sensible
for a later RET on some unrelated result to \"repeat\".
ENTRY, the result just picked, is shown first, so the prompt asking
what to do with it is never divorced from what \"it\" actually is.
FIRST-TIME says whether this is the very first pick this session, purely
to word the rest of the prompt accordingly.

Uses `typetopology-search--pick-from-list', the same own arrow-key
selection UI as the main search (`typetopology-search--read-candidate'),
not `completing-read' -- for the identical reason: with
`completing-read', arrow keys depend on whatever completion setup, if
any, happens to be configured, which is exactly what broke here too
(\"same problem we had in the search box\", his own words) before this
fix, by the same underlying cause."
  (let* ((prompt (concat (typetopology-search--display entry) "\n"
                         (if first-time
                             "First pick -- choose what happens (becomes your \
default from now on, except updating the index; TAB re-opens this \
menu later): "
                           "Choose an action (becomes the new default, except \
updating the index): ")))
         (labels (mapcar #'car (typetopology-search--actions-for entry)))
         (chosen (typetopology-search--pick-from-list prompt labels))
         (action (cdr (assoc chosen typetopology-search--actions))))
    (unless (eq action 'update-index)
      (setq typetopology-search--last-action action))
    action))

(defun typetopology-search--decide-action (entry via-tab)
  "Which action to perform, given whether TAB (rather than RET) ended the
read. No menu, ever, when ENTRY offers only one action at all (a
contributor or a concept, see `typetopology-search--contributor-actions')
-- there is nothing to choose between, so RET and TAB alike go straight
to it. Otherwise the menu wins if TAB asked for it explicitly, if none
has ever been chosen yet this session, or if the sticky default from a
previous, differently-kinded entry does not even apply to ENTRY (a
one-action contributor picked right after \"jump to source\" was last
chosen for a definition, say) -- otherwise the last one sticks. ENTRY
is passed through to `typetopology-search--choose-action', to show in
the menu's own prompt when it does run."
  (let ((available (mapcar #'cdr (typetopology-search--actions-for entry))))
    (if (= (length available) 1)
        (car available)
      (if (or via-tab (null typetopology-search--last-action)
             (not (memq typetopology-search--last-action available)))
          (typetopology-search--choose-action entry (null typetopology-search--last-action))
        typetopology-search--last-action))))

;; ------------------------------------------------------------ actions

(defun typetopology-search--visit-agda-file (path)
  "Visit PATH, switching the buffer into `agda2-mode' first if that
mode is available and the buffer is not already in it (or a mode
derived from it) -- shared by `typetopology-search--jump-to-source'
and `typetopology-search--jump-to-mention', which otherwise land in a
file the same way. `auto-mode-alist' normally puts a .lagda/.agda
buffer straight into agda2-mode already, via the boilerplate agda2-mode's
own install instructions have a user add to their init file -- this is
only a fallback for when that hasn't happened (or hasn't happened YET,
in whatever Emacs session this runs in), and does nothing at all,
silently, if agda2-mode isn't loaded here, rather than erroring."
  (find-file path)
  (when (and (fboundp 'agda2-mode) (not (derived-mode-p 'agda2-mode)))
    (agda2-mode)))

(defun typetopology-search--jump-to-source (e)
  (let ((file (typetopology-search-entry-file e)))
    (when (string-empty-p file)
      (user-error "No source file recorded for %s"
                  (typetopology-search-entry-name e)))
    (let ((path (expand-file-name file (typetopology-search--source-root))))
      (unless (file-exists-p path)
        (user-error "%s not found (typetopology-search-checkout-root is %s)"
                    path typetopology-search-checkout-root))
      (typetopology-search--visit-agda-file path)
      (goto-char (point-min))
      (forward-line (1- (typetopology-search-entry-line e))))))

(defun typetopology-search--module-path (mod)
  "MOD (a dotted module name) as a path under
`typetopology-search--source-root', trying .lagda then .agda, or nil if
neither exists -- the same fallback `agda-index.py's own source_file()
makes when writing Definitions.tsv, redone here since a contributor's
mentioning modules are not necessarily any INDEXED definition's own
module (a module with prose but no definitions of its own -- an
overview/index file, say -- can still name a contributor), so there is
no precomputed FILE column to reuse for them the way a definition has."
  (let* ((base (expand-file-name (replace-regexp-in-string "\\." "/" mod)
                                 (typetopology-search--source-root)))
         (lagda (concat base ".lagda"))
         (agda (concat base ".agda")))
    (cond ((file-exists-p lagda) lagda)
          ((file-exists-p agda) agda))))

(defun typetopology-search--jump-to-mention (entry)
  "Prompt for one of ENTRY's mentioning modules (a contributor or a
concept, see `typetopology-search-entry-kind') via
`typetopology-search-entry-assumes', repurposed there to hold a
semicolon-separated list of dotted module names instead of an
enclosing-module hypothesis, and jump to its source file, at the very
top -- unlike `typetopology-search--jump-to-source', there is no one
specific definition to put point at, only the module ENTRY is
mentioned somewhere in the commentary of. A comment entry's own
ASSUMES always holds exactly one module, the one its paragraph was
found in, never several -- prompting which of ONE module to jump to is
pure friction, the same reasoning `typetopology-search--decide-action'
already applies one level up to skip the action menu entirely when
there is only one action, so this skips the picker too when there is
only one module, regardless of ENTRY's kind."
  (let ((modules (split-string (typetopology-search-entry-assumes entry) ";" t)))
    (unless modules
      (user-error "No modules recorded for %s"
                  (typetopology-search-entry-name entry)))
    (let* ((mod (if (= (length modules) 1)
                    (car modules)
                  (typetopology-search--pick-from-list
                   (format "%s -- jump to which module? "
                           (typetopology-search-entry-name entry))
                   modules)))
           (path (and mod (typetopology-search--module-path mod))))
      (unless path
        (user-error "Source file for %s not found (typetopology-search-checkout-root is %s)"
                    mod typetopology-search-checkout-root))
      (typetopology-search--visit-agda-file path)
      (goto-char (point-min))
      (message "Jumped to %s" mod))))

(defun typetopology-search--perform (action e)
  "Carry out ACTION on entry E -- except `update-index', which
ignores E entirely, since it does not act on any particular entry."
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
    ('jump-to-mention
     (typetopology-search--jump-to-mention e))
    ('update-index
     (typetopology-search-update-index))
    (_ (error "typetopology-search: unknown action %s" action))))

;;;###autoload
(defun typetopology-search ()
  "Search TypeTopology's ~21,000 definitions, its contributors, its
concepts (see `typetopology-search-include-concepts'), and its prose
commentary (see `typetopology-search-include-comments'), by name/label,
type fragment, or paragraph, and act on the one you pick.

Plain RET repeats whatever action you last chose (or, the very first
time this is used in a session, opens a menu to choose one, so all are
seen at least once). TAB, once your typing already names a candidate
exactly, opens that same menu on demand without changing what RET
repeats afterward -- unless you pick something different from it, in
which case that becomes the new default.

The choices, for a definition: jump to its definition in the source;
insert the matched name at point; insert \"open import Module\" for
it; or update the index (see `typetopology-search-update-index') --
the odd one out, since it does not act on the entry the menu was
opened for at all, and so never becomes what RET repeats afterward. A
contributor, a concept, or a comment, matched by name/label/paragraph
alone, has no source file of their own to open an import for directly,
and no menu either: the only thing to do with one is jump to the module
it was found in -- one picked from a list for a contributor or concept,
who can be mentioned in several, but straight there with no picker at
all for a comment, which is always found in exactly one -- so RET and
TAB alike go straight to the jump (see
`typetopology-search--decide-action' and
`typetopology-search--jump-to-mention').

A query starting \"--\" (Agda's own comment marker, no space needed
after it) searches commentary ONLY, excluding every definition,
contributor, and concept, and composes with the usual \" in PATH\"
scoping: \"-- compact in Ordinals\" (see
`typetopology-search--filter'). An ordinary query,
without the marker, never matches a paragraph -- commentary is both
the single biggest chunk of text in the index and the likeliest to hit
a plain word by accident, so it stays out unless asked for.

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
