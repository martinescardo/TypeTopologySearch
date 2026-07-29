;;; typetopology-search-tests.el --- ERT tests for typetopology-search  -*- lexical-binding: t; -*-

;; Run with:
;;   emacs --batch -L . -l ert -l typetopology-search.el \
;;         -l typetopology-search-tests.el -f ert-run-tests-batch-and-exit
;;
;; Covers every pure function directly (parsing, display formatting,
;; loading, action dispatch, the sticky-default/menu decision). The
;; interactive minibuffer read itself (`typetopology-search--read-candidate',
;; the TAB rebinding) is not exercised here -- ERT in batch mode has no
;; real minibuffer to drive, and `typetopology-search--tab' is a thin,
;; six-line wrapper around two well-documented Emacs primitives
;; (`test-completion', `minibuffer-complete'), reviewed by hand instead.

(require 'ert)
(require 'typetopology-search)

(defun tt-search--make-entry (&rest args)
  "Like `typetopology-search-entry-create', but also fills in DTEXT the
same way `typetopology-search--parse-line' does for a real entry --
`typetopology-search--filter' reads that field directly (a performance
fix: computed once at load time rather than on every keystroke), so a
hand-built entry missing it would error when filtered, not just read
oddly."
  (let ((e (apply #'typetopology-search-entry-create args)))
    (setf (typetopology-search-entry-dtext e)
          (downcase (typetopology-search--display e)))
    e))

(defun tt-search--sample-entry ()
  (tt-search--make-entry
   :name "flabby" :dispmod "M" :importmod "M" :file "" :line 1 :uses 0
   :sig "" :assumes ""))

;; ------------------------------------------------------------- parsing

(ert-deftest tt-search-parse-line-full ()
  (let ((e (typetopology-search--parse-line
            (string-join
             '("cale-lo-lemma" "MetricSpaces.DedekindReals"
               "MetricSpaces.DedekindReals" "MetricSpaces/DedekindReals.lagda"
               "268" "2"
               "(p q : ℚ) → p < q → let ε = 1/5 * (q - p) in p + ε + ε < q - ε - ε"
               "")
             "\t"))))
    (should e)
    (should (equal (typetopology-search-entry-name e) "cale-lo-lemma"))
    (should (equal (typetopology-search-entry-dispmod e) "MetricSpaces.DedekindReals"))
    (should (equal (typetopology-search-entry-importmod e) "MetricSpaces.DedekindReals"))
    (should (equal (typetopology-search-entry-file e) "MetricSpaces/DedekindReals.lagda"))
    (should (= (typetopology-search-entry-line e) 268))
    (should (= (typetopology-search-entry-uses e) 2))
    (should (equal (typetopology-search-entry-assumes e) ""))
    (should (equal (typetopology-search-entry-dtext e)
                   (downcase (typetopology-search--display e))))))

(ert-deftest tt-search-parse-line-with-assumes ()
  (let ((e (typetopology-search--parse-line
            (string-join
             '("flabby" "InjectiveTypes.Blackboard.injective"
               "InjectiveTypes.Blackboard" "InjectiveTypes/Blackboard.lagda"
               "1554" "4" "𝓦 ̇ → (𝓤 : Universe) → 𝓦 ⊔ 𝓤 ⁺ ̇"
               "(pt : propositional-truncations-exist)")
             "\t"))))
    (should e)
    (should (equal (typetopology-search-entry-assumes e)
                   "(pt : propositional-truncations-exist)"))))

(ert-deftest tt-search-parse-line-malformed-is-nil ()
  "Too few fields (a truncated or corrupted line) is dropped, not an error."
  (should (null (typetopology-search--parse-line "just\ttwo")))
  (should (null (typetopology-search--parse-line ""))))

;; ------------------------------------------------------------- display

(ert-deftest tt-search-display-with-sig-and-uses ()
  (let ((e (typetopology-search-entry-create
            :name "flabby" :dispmod "InjectiveTypes.Blackboard.injective"
            :importmod "InjectiveTypes.Blackboard" :file "x.lagda" :line 1
            :uses 4 :sig "𝓦 ̇ → 𝓤" :assumes "")))
    (should (equal (typetopology-search--display e)
                   "flabby : 𝓦 ̇ → 𝓤  [InjectiveTypes.Blackboard.injective, 4 uses]"))))

(ert-deftest tt-search-display-no-sig-no-uses ()
  "An alias with no signature of its own, and never used: no \" : \", no
\", N uses\" -- matches Definitions.txt's own formatting choices."
  (let ((e (typetopology-search-entry-create
            :name "is-compact" :dispmod "M" :importmod "M" :file "x.lagda"
            :line 1 :uses 0 :sig "" :assumes "")))
    (should (equal (typetopology-search--display e) "is-compact  [M]"))))

(ert-deftest tt-search-display-shows-assumes ()
  "His question: are enclosing-module assumptions (`funext', a whole
record's worth of structure, ...) shown here at all? They were parsed
onto every entry but never actually displayed -- this is the fix, the
same trailing \"(assumes: ...)\" clause Definitions.txt and the browser
page already use, since the whole reason it exists there is equally
true here: it never shows up any other way."
  (let ((e (typetopology-search-entry-create
            :name "homotopy-id-sys" :dispmod "M" :importmod "M"
            :file "x.lagda" :line 1 :uses 2 :sig "Id-Sys 𝓤 (A → B) f"
            :assumes "(fe : funext 𝓤 𝓥) {A : 𝓤 ̇ } {B : 𝓥 ̇ } (f : A → B)")))
    (should (equal (typetopology-search--display e)
                   "homotopy-id-sys : Id-Sys 𝓤 (A → B) f  [M, 2 uses]  \
(assumes: (fe : funext 𝓤 𝓥) {A : 𝓤 ̇ } {B : 𝓥 ̇ } (f : A → B))"))))

;; ------------------------------------------------------------- loading

(ert-deftest tt-search-load-from-fixture-file ()
  (let ((file (make-temp-file "tt-search-test" nil ".tsv")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "# a comment line, skipped\n")
            (insert "# another\n")
            (insert (string-join '("foo" "M" "M" "M.lagda" "10" "3" "A → B" "") "\t"))
            (insert "\n")
            (insert (string-join '("bar" "M" "M" "M.lagda" "20" "0" "" "") "\t"))
            (insert "\n"))
          (typetopology-search--load file)
          (should (= (length typetopology-search--entries) 2))
          (should (equal (mapcar #'typetopology-search-entry-name
                                 typetopology-search--entries)
                         '("foo" "bar"))))
      (delete-file file))))

(ert-deftest tt-search-ensure-loaded-picks-up-regeneration ()
  "Editing the file (a later mtime) is picked up on the next call, with no
separate reload step -- this is what makes \"just re-run agda-index.py\"
enough."
  (let ((file (make-temp-file "tt-search-test" nil ".tsv"))
        (typetopology-search--entries nil)
        (typetopology-search--loaded-mtime nil))
    (unwind-protect
        (let ((typetopology-search-file file))
          (with-temp-file file
            (insert (string-join '("foo" "M" "M" "M.lagda" "1" "0" "" "") "\t") "\n"))
          (typetopology-search--ensure-loaded)
          (should (= (length typetopology-search--entries) 1))
          ;; Force a distinguishable, later mtime, then rewrite with two rows.
          (sleep-for 1)
          (with-temp-file file
            (insert (string-join '("foo" "M" "M" "M.lagda" "1" "0" "" "") "\t") "\n")
            (insert (string-join '("baz" "M" "M" "M.lagda" "2" "0" "" "") "\t") "\n"))
          (typetopology-search--ensure-loaded)
          (should (= (length typetopology-search--entries) 2)))
      (delete-file file))))

;; --------------------------------------------------------- regeneration

(ert-deftest tt-search-default-generator-prefers-sibling-file ()
  "A copy right next to typetopology-search.el itself wins, even when
another one would also be found on $PATH -- the sibling is guaranteed
to be the matching version, an arbitrary $PATH one is not."
  (let* ((dir (make-temp-file "tt-search-el-dir" t))
         (el (expand-file-name "typetopology-search.el" dir))
         (sibling (expand-file-name "agda-index.py" dir)))
    (unwind-protect
        (progn
          (with-temp-file el (insert ";; not really loaded, just present"))
          (with-temp-file sibling (insert "#!/bin/sh\n"))
          (let ((load-file-name el))
            (cl-letf (((symbol-function 'executable-find)
                       (lambda (&rest _) "/somewhere/else/agda-index.py")))
              (should (equal (typetopology-search--default-generator) sibling)))))
      (delete-directory dir t))))

(ert-deftest tt-search-default-generator-falls-back-to-path ()
  "No sibling next to the .el file (it was copied somewhere on its own)
-- falls back to whatever is on $PATH."
  (let* ((dir (make-temp-file "tt-search-el-dir" t))
         (el (expand-file-name "typetopology-search.el" dir)))
    (unwind-protect
        (progn
          (with-temp-file el (insert ";; not really loaded, just present"))
          (let ((load-file-name el))
            (cl-letf (((symbol-function 'executable-find)
                       (lambda (&rest _) "/somewhere/else/agda-index.py")))
              (should (equal (typetopology-search--default-generator)
                             "/somewhere/else/agda-index.py")))))
      (delete-directory dir t))))

(ert-deftest tt-search-default-generator-nil-when-neither-found ()
  (let* ((dir (make-temp-file "tt-search-el-dir" t))
         (el (expand-file-name "typetopology-search.el" dir)))
    (unwind-protect
        (progn
          (with-temp-file el (insert ";; not really loaded, just present"))
          (let ((load-file-name el))
            (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))
              (should-not (typetopology-search--default-generator)))))
      (delete-directory dir t))))

(defun tt-search--write-fake-generator (path &optional fail)
  "A tiny stand-in for agda-index.py: writes one valid row of
Definitions.tsv next to itself (mirroring how the real script always
writes beside its own location), or, if FAIL, writes to stderr and
exits non-zero instead."
  (with-temp-file path
    (insert
     (if fail
         "#!/bin/sh\necho 'boom' >&2\nexit 1\n"
       "#!/bin/sh\nDIR=$(dirname \"$0\")\nprintf 'foo\\tM\\tM\\tM.lagda\\t1\\t0\\t\\t\\n' > \"$DIR/Definitions.tsv\"\n")))
  (set-file-modes path #o755))

(ert-deftest tt-search-ensure-loaded-regenerates-when-missing ()
  "The actual complaint this was built for: requiring the file alone,
with no separate manual `agda-index.py --emacs-index' step, is enough
the very first time, when there is no index yet at all."
  (let* ((dir (make-temp-file "tt-search-gen" t))
         (typetopology-search-generator (expand-file-name "agda-index.py" dir))
         (typetopology-search-file (expand-file-name "Definitions.tsv" dir))
         (typetopology-search--entries nil)
         (typetopology-search--loaded-mtime nil))
    (unwind-protect
        (progn
          (should-not (file-exists-p typetopology-search-file))
          (tt-search--write-fake-generator typetopology-search-generator)
          (typetopology-search--ensure-loaded)
          (should (file-exists-p typetopology-search-file))
          (should (= (length typetopology-search--entries) 1))
          (should (equal (typetopology-search-entry-name
                          (car typetopology-search--entries))
                         "foo")))
      (delete-directory dir t))))

(ert-deftest tt-search-regenerate-errors-clearly-on-failure ()
  (let* ((dir (make-temp-file "tt-search-gen" t))
         (typetopology-search-generator (expand-file-name "agda-index.py" dir)))
    (unwind-protect
        (progn
          (tt-search--write-fake-generator typetopology-search-generator t)
          (let ((err (should-error (typetopology-search--regenerate))))
            (should (string-match-p "boom" (cadr err)))))
      (delete-directory dir t))))

(ert-deftest tt-search-regenerate-user-error-without-generator ()
  (let ((typetopology-search-generator nil)
        (typetopology-search-file "/nonexistent-dir/Definitions.tsv"))
    (should-error (typetopology-search--regenerate) :type 'user-error)))

(ert-deftest tt-search-regenerate-user-error-bad-source-root ()
  "The generator is deployable separately from any particular
TypeTopology checkout, so a source root that is not actually a
directory (never set, or set wrong) is caught here with a clear
message, rather than surfacing as a raw Python traceback from
agda-index.py itself failing to find anything to render."
  (let* ((dir (make-temp-file "tt-search-gen" t))
         (typetopology-search-generator (expand-file-name "agda-index.py" dir))
         (typetopology-search-source-root "/nonexistent-source-root"))
    (unwind-protect
        (progn
          (tt-search--write-fake-generator typetopology-search-generator)
          (should-error (typetopology-search--regenerate) :type 'user-error))
      (delete-directory dir t))))

(ert-deftest tt-search-regenerate-passes-source-and-out-explicitly ()
  "Confirms the actual arguments passed to the generator, not just that
SOME invocation succeeds -- this is what makes deploying
typetopology-search.el and agda-index.py somewhere other than inside
the TypeTopology checkout itself work at all, rather than silently
falling back to agda-index.py's own directory-relative defaults."
  (let* ((dir (make-temp-file "tt-search-gen" t))
         (typetopology-search-generator (expand-file-name "agda-index.py" dir))
         (typetopology-search-source-root dir)
         (typetopology-search-file (expand-file-name "out/Definitions.tsv" dir))
         (seen-args nil))
    (unwind-protect
        (progn
          (tt-search--write-fake-generator typetopology-search-generator)
          (cl-letf (((symbol-function 'call-process)
                     (lambda (_prog _infile _dest _display &rest args)
                       (setq seen-args args) 0)))
            (typetopology-search--regenerate))
          (should (equal seen-args
                        (list "--emacs-index" "--no-html"
                              "--source" dir
                              "--out" (file-name-directory typetopology-search-file)))))
      (delete-directory dir t))))

(ert-deftest tt-search-regenerate-expands-tilde-in-source-root ()
  "The actual bug hit in real use: call-process hands its argument
strings to the subprocess exactly as given, with none of the \"~\"
expansion Emacs's own file functions (file-directory-p, used in the
precondition check just before this) do transparently -- a source root
of \"~/TypeTopology/source/\" reached Python as that literal string,
where `os.path.exists' on a leading \"~\" is simply false. Uses a real
directory under the real $HOME, not a fixture elsewhere, since the bug
was specifically about \"~\" -- a fixture path without one would not
have caught it."
  (let* ((real-home-dir (make-temp-file (expand-file-name
                                         "tt-search-tilde-test" "~/") t))
         (tilde-path (concat "~/" (file-name-nondirectory
                                   (directory-file-name real-home-dir))))
         (dir (make-temp-file "tt-search-gen" t))
         (typetopology-search-generator (expand-file-name "agda-index.py" dir))
         (typetopology-search-source-root tilde-path)
         (typetopology-search-file (expand-file-name "Definitions.tsv" dir))
         (seen-args nil))
    (unwind-protect
        (progn
          (tt-search--write-fake-generator typetopology-search-generator)
          (cl-letf (((symbol-function 'call-process)
                     (lambda (_prog _infile _dest _display &rest args)
                       (setq seen-args args) 0)))
            (typetopology-search--regenerate))
          (let ((source-arg (nth (1+ (cl-position "--source" seen-args
                                                  :test #'equal))
                                 seen-args)))
            (should-not (string-prefix-p "~" source-arg))
            (should (equal source-arg (expand-file-name tilde-path)))))
      (delete-directory dir t)
      (delete-directory real-home-dir t))))

(ert-deftest tt-search-regenerate-index-command-reloads ()
  (let* ((dir (make-temp-file "tt-search-gen" t))
         (typetopology-search-generator (expand-file-name "agda-index.py" dir))
         (typetopology-search-file (expand-file-name "Definitions.tsv" dir))
         (typetopology-search--entries nil)
         (typetopology-search--loaded-mtime nil))
    (unwind-protect
        (progn
          (tt-search--write-fake-generator typetopology-search-generator)
          (typetopology-search-regenerate-index)
          (should (= (length typetopology-search--entries) 1))
          (should typetopology-search--loaded-mtime))
      (delete-directory dir t))))

;; ------------------------------------------------------- action decision

(ert-deftest tt-search-decide-action-first-time-forces-menu ()
  (let ((typetopology-search--last-action nil))
    (cl-letf (((symbol-function 'typetopology-search--choose-action)
               (lambda (_entry &optional first-time)
                 (should (eq first-time t))   ; worded as a first pick
                 'insert-name)))
      ;; Even via-tab = nil (i.e. RET), the menu fires the first time.
      (should (eq (typetopology-search--decide-action
                  (tt-search--sample-entry) nil)
                 'insert-name)))))

(ert-deftest tt-search-decide-action-ret-repeats-last ()
  (let ((typetopology-search--last-action 'jump-to-source))
    (cl-letf (((symbol-function 'typetopology-search--choose-action)
               (lambda (&rest _) (error "menu should not be shown"))))
      (should (eq (typetopology-search--decide-action
                  (tt-search--sample-entry) nil)
                 'jump-to-source)))))

(ert-deftest tt-search-decide-action-tab-always-menus ()
  (let ((typetopology-search--last-action 'insert-name)
        (calls 0))
    (cl-letf (((symbol-function 'typetopology-search--choose-action)
               (lambda (_entry &optional first-time)
                 (should (eq first-time nil))   ; not the first pick this time
                 (cl-incf calls) 'insert-import)))
      (should (eq (typetopology-search--decide-action
                  (tt-search--sample-entry) t)
                 'insert-import))
      (should (= calls 1)))))

(ert-deftest tt-search-choose-action-sets-sticky-default ()
  (let ((typetopology-search--last-action nil))
    (cl-letf (((symbol-function 'read-from-minibuffer)
               (lambda (&rest _)
                 (setq typetopology-search--action-result
                       "Jump to its definition in the source file"))))
      (should (eq (typetopology-search--choose-action (tt-search--sample-entry))
                 'jump-to-source))
      (should (eq typetopology-search--last-action 'jump-to-source)))))

(ert-deftest tt-search-read-candidate-uses-dedicated-history ()
  "Regression test for a real bug hit in use: without an explicit HIST
argument, a minibuffer read falls back to the shared, global
`minibuffer-history', so M-p/M-n (the only history keys left once the
arrow keys were claimed for candidate selection -- see
`typetopology-search--minibuffer-map') could otherwise surface an
unrelated leftover entry from some entirely different prompt. Confirms
the actual HIST argument received by `read-from-minibuffer' (which
`typetopology-search--read-candidate' calls directly, not
`completing-read' any more), not just that some invocation succeeds."
  (let (seen-hist)
    (cl-letf (((symbol-function 'read-from-minibuffer)
               (lambda (_prompt &optional _init _keymap _read hist &rest _)
                 (setq seen-hist hist) "")))
      (typetopology-search--read-candidate)
      (should (eq seen-hist 'typetopology-search--history)))))

(ert-deftest tt-search-choose-action-uses-dedicated-history ()
  "Confirms the actual HIST argument received by `read-from-minibuffer'
(which `typetopology-search--choose-action' calls directly, not
`completing-read' any more -- see `typetopology-search--read-candidate'
for why), not just that some invocation succeeds."
  (let (seen-hist)
    (cl-letf (((symbol-function 'read-from-minibuffer)
               (lambda (_prompt &optional _init _keymap _read hist &rest _)
                 (setq seen-hist hist)
                 (setq typetopology-search--action-result
                       "Insert the name at point"))))
      (typetopology-search--choose-action (tt-search--sample-entry))
      (should (eq seen-hist 'typetopology-search--action-history)))))

(ert-deftest tt-search-no-default-completions-sets-local-nil ()
  (with-temp-buffer
    (typetopology-search--no-default-completions)
    (should (local-variable-p 'minibuffer-default-add-function))
    (should-not minibuffer-default-add-function)))

;; A version of the above once existed that drove a REAL minibuffer read
;; (`completing-read'/`read-from-minibuffer' from inside
;; `minibuffer-with-setup-hook', calling `exit-minibuffer' from the hook
;; itself) rather than calling `typetopology-search--no-default-completions'
;; directly. Removed: reproduced in isolation, that exact pattern is
;; genuinely unreliable in `--batch' Emacs -- `exit-minibuffer' called
;; from a setup hook does not consistently unwind the read before Emacs
;; tries to block on real terminal input, which does not exist in batch
;; mode, so the same test intermittently hung for the full two-minute
;; process timeout or failed with "end-of-file: Error reading from
;; stdin", by observed timing, not by anything about the code under
;; test. `tt-search-no-default-completions-sets-local-nil' above already
;; covers the same property reliably, without needing a read to
;; complete.

(ert-deftest tt-search-action-label-round-trips ()
  (dolist (pair typetopology-search--actions)
    (should (equal (typetopology-search--action-label (cdr pair)) (car pair)))))

(ert-deftest tt-search-read-prompt-mentions-default-once-set ()
  (let ((typetopology-search--last-action 'jump-to-source))
    (should (string-match-p "jump to its definition"
                            (typetopology-search--read-prompt)))))

(ert-deftest tt-search-read-prompt-before-any-default ()
  (let ((typetopology-search--last-action nil))
    (should (string-match-p "type to filter"
                            (typetopology-search--read-prompt)))))

(ert-deftest tt-search-choose-action-prompt-differs-first-time ()
  (let (seen-prompt)
    (cl-letf (((symbol-function 'read-from-minibuffer)
               (lambda (prompt &rest _)
                 (setq seen-prompt prompt)
                 (setq typetopology-search--action-result
                       "Insert the name at point"))))
      (typetopology-search--choose-action (tt-search--sample-entry) t)
      (should (string-match-p "First pick" seen-prompt))
      (typetopology-search--choose-action (tt-search--sample-entry) nil)
      (should-not (string-match-p "First pick" seen-prompt)))))

(ert-deftest tt-search-choose-action-prompt-shows-the-entry ()
  "His request: after picking a search result, the action-menu prompt
should show WHICH result was picked, not just say \"choose what
happens\" with no reminder of what \"it\" refers to."
  (let (seen-prompt)
    (cl-letf (((symbol-function 'read-from-minibuffer)
               (lambda (prompt &rest _)
                 (setq seen-prompt prompt)
                 (setq typetopology-search--action-result
                       "Insert the name at point"))))
      (typetopology-search--choose-action (tt-search--sample-entry) t)
      (should (string-prefix-p
              (typetopology-search--display (tt-search--sample-entry))
              seen-prompt)))))

(ert-deftest tt-search-ttsearch-is-an-alias ()
  ;; `symbol-function' on a plain defalias gives back the SYMBOL aliased
  ;; to, not its function object -- `indirect-function' follows that
  ;; through to the actual function, which is what should be compared.
  (should (eq (indirect-function 'ttsearch)
             (indirect-function 'typetopology-search))))

;; ------------------------------------------------------------- actions

(ert-deftest tt-search-perform-insert-name ()
  (with-temp-buffer
    (typetopology-search--perform
     'insert-name (typetopology-search-entry-create
                   :name "flabby" :dispmod "M" :importmod "M" :file ""
                   :line 1 :uses 0 :sig "" :assumes ""))
    (should (equal (buffer-string) "flabby"))))

(ert-deftest tt-search-perform-insert-import ()
  (with-temp-buffer
    (typetopology-search--perform
     'insert-import (typetopology-search-entry-create
                     :name "flabby" :dispmod "InjectiveTypes.Blackboard"
                     :importmod "InjectiveTypes.Blackboard" :file ""
                     :line 1 :uses 0 :sig "" :assumes ""))
    (should (equal (buffer-string) "open import InjectiveTypes.Blackboard"))))

(ert-deftest tt-search-perform-insert-name-at-point-not-at-end ()
  "Insertion happens at point, not appended -- matters when the name is
being dropped into the middle of an existing line."
  (with-temp-buffer
    (insert "before  after")
    (goto-char (+ (point-min) 7))
    (typetopology-search--perform
     'insert-name (typetopology-search-entry-create
                   :name "X" :dispmod "M" :importmod "M" :file ""
                   :line 1 :uses 0 :sig "" :assumes ""))
    (should (equal (buffer-string) "before X after"))))

(ert-deftest tt-search-jump-to-source ()
  (let* ((dir (make-temp-file "tt-search-src" t))
         (typetopology-search-source-root dir))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "M.lagda" dir)
            (dotimes (i 5) (insert (format "line %d\n" (1+ i)))))
          (typetopology-search--jump-to-source
           (typetopology-search-entry-create
            :name "x" :dispmod "M" :importmod "M" :file "M.lagda"
            :line 3 :uses 0 :sig "" :assumes ""))
          (should (equal (buffer-name) "M.lagda"))
          (should (equal (line-number-at-pos) 3))
          (should (equal (buffer-substring (line-beginning-position)
                                           (line-end-position))
                         "line 3")))
      (kill-buffer "M.lagda")
      (delete-directory dir t))))

(ert-deftest tt-search-jump-to-source-activates-agda2-mode-when-available ()
  "The one bug report from trying this by hand: jumping to source left the
buffer out of agda2-mode. Root cause there was the isolated `-Q' test
session never loading agda2-mode at all, but the fallback this test
checks is a real robustness improvement regardless -- if agda2-mode IS
loaded (`fboundp') and the buffer did not already land in it via
auto-mode-alist, switch to it explicitly."
  (let* ((dir (make-temp-file "tt-search-src" t))
         (typetopology-search-source-root dir)
         (called nil))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "M.lagda" dir) (insert "x\n"))
          ;; agda2-mode is not normally bound in this test environment, so
          ;; `fset' rather than `cl-letf' -- the latter needs a function to
          ;; already be bound in order to save and later restore it.
          (fset 'agda2-mode (lambda () (setq called t)))
          (typetopology-search--jump-to-source
           (typetopology-search-entry-create
            :name "x" :dispmod "M" :importmod "M" :file "M.lagda"
            :line 1 :uses 0 :sig "" :assumes ""))
          (should called))
      (kill-buffer "M.lagda")
      (delete-directory dir t)
      (fmakunbound 'agda2-mode))))

(ert-deftest tt-search-jump-to-source-fine-without-agda2-mode ()
  "The ordinary case in this very test suite, made explicit: when
agda2-mode is not loaded at all (not `fboundp'), jumping to source
still works, with no error and no attempt to call it."
  (let* ((dir (make-temp-file "tt-search-src" t))
         (typetopology-search-source-root dir))
    (unwind-protect
        (progn
          (should-not (fboundp 'agda2-mode))
          (with-temp-file (expand-file-name "M.lagda" dir) (insert "x\n"))
          (typetopology-search--jump-to-source
           (typetopology-search-entry-create
            :name "x" :dispmod "M" :importmod "M" :file "M.lagda"
            :line 1 :uses 0 :sig "" :assumes ""))
          (should (equal (buffer-name) "M.lagda")))
      (kill-buffer "M.lagda")
      (delete-directory dir t))))

(ert-deftest tt-search-jump-to-source-missing-file-errors-cleanly ()
  (let ((typetopology-search-source-root (make-temp-file "tt-search-empty" t)))
    (unwind-protect
        (should-error
         (typetopology-search--jump-to-source
          (typetopology-search-entry-create
           :name "x" :dispmod "M" :importmod "M" :file "NoSuchFile.lagda"
           :line 1 :uses 0 :sig "" :assumes ""))
         :type 'user-error)
      (delete-directory typetopology-search-source-root t))))

(ert-deftest tt-search-jump-to-source-empty-file-field-errors-cleanly ()
  (should-error
   (typetopology-search--jump-to-source
    (typetopology-search-entry-create
     :name "x" :dispmod "M" :importmod "M" :file ""
     :line 1 :uses 0 :sig "" :assumes ""))
   :type 'user-error))

;; --------------------------------------------------- against the real file

(ert-deftest tt-search-real-index-file-loads-and-finds-known-entries ()
  "Not a fixture: the real Definitions.tsv this repository's own
agda-index.py produces, checked against the exact cases already verified
by hand against the raw HTML earlier in this project (cale-lo-lemma's
`let', flabby's self-reference and cross-module uses)."
  (let ((file (expand-file-name
               "Definitions.tsv" (file-name-directory (locate-library "typetopology-search")))))
    (skip-unless (file-exists-p file))
    (typetopology-search--load file)
    (let* ((matches (cl-remove-if-not
                     (lambda (e) (equal (typetopology-search-entry-name e) "cale-lo-lemma"))
                     typetopology-search--entries))
           (e (car matches)))
      (should (= (length matches) 1))
      (should (equal (typetopology-search-entry-file e)
                     "MetricSpaces/DedekindReals.lagda"))
      (should (= (typetopology-search-entry-line e) 268))
      (should (string-match-p "let ε = 1/5" (typetopology-search-entry-sig e))))
    (let ((flabby (cl-remove-if-not
                   (lambda (e) (equal (typetopology-search-entry-name e) "flabby"))
                   typetopology-search--entries)))
      (should (>= (length flabby) 1)))))

;; --------------------------------------------------------- end to end

;; typetopology-search--read-candidate is now itself a substantial piece
;; of interactive machinery (filtering, rendering, arrow-key selection --
;; see the "filtering candidates" / "showing the list" / "moving around"
;; sections below, each tested directly and without a real minibuffer).
;; For `typetopology-search' ITSELF, that whole thing is the right
;; boundary to stub -- its own job (first-use forces the menu, RET
;; repeats a set sticky default) is independent of how a candidate was
;; actually picked.

(ert-deftest tt-search-end-to-end-first-use-forces-menu-then-inserts ()
  (let ((typetopology-search--last-action nil)
        (entry (typetopology-search-entry-create
               :name "flabby" :dispmod "InjectiveTypes.Blackboard"
               :importmod "InjectiveTypes.Blackboard" :file ""
               :line 1 :uses 4 :sig "𝓦 ̇ → 𝓤" :assumes "")))
    (with-temp-buffer
      (cl-letf (((symbol-function 'typetopology-search--ensure-loaded) #'ignore)
                ((symbol-function 'typetopology-search--read-candidate)
                 (lambda () (cons entry nil)))
                ((symbol-function 'read-from-minibuffer)
                 (lambda (&rest _)
                   (setq typetopology-search--action-result
                         (typetopology-search--action-label 'insert-name)))))
        (typetopology-search)
        (should (equal (buffer-string) "flabby"))
        (should (eq typetopology-search--last-action 'insert-name))))))

(ert-deftest tt-search-end-to-end-second-use-skips-menu ()
  (let ((typetopology-search--last-action 'insert-import)
        (entry (typetopology-search-entry-create
               :name "flabby" :dispmod "InjectiveTypes.Blackboard"
               :importmod "InjectiveTypes.Blackboard" :file ""
               :line 1 :uses 4 :sig "𝓦 ̇ → 𝓤" :assumes "")))
    (with-temp-buffer
      (cl-letf (((symbol-function 'typetopology-search--ensure-loaded) #'ignore)
                ((symbol-function 'typetopology-search--read-candidate)
                 (lambda () (cons entry nil)))
                ((symbol-function 'read-from-minibuffer)
                 (lambda (&rest _) (error "menu should not be shown"))))
        (typetopology-search)
        (should (equal (buffer-string) "open import InjectiveTypes.Blackboard"))))))

;; ----------------------------------------------- filtering candidates

(defun tt-search--entry (name &optional sig)
  (tt-search--make-entry
   :name name :dispmod "M" :importmod "M" :file "" :line 1 :uses 0
   :sig (or sig "") :assumes ""))

(ert-deftest tt-search-filter-empty-query-matches-nothing ()
  "There is no value in a wall of all 21,000 definitions before anything
has been typed."
  (let ((typetopology-search--entries (list (tt-search--entry "flabby"))))
    (should-not (typetopology-search--filter ""))
    (should-not (typetopology-search--filter "   "))))

(ert-deftest tt-search-filter-substring-case-insensitive ()
  (let ((typetopology-search--entries
         (list (tt-search--entry "flabby") (tt-search--entry "aflabby")
               (tt-search--entry "unrelated"))))
    (should (equal (sort (mapcar #'typetopology-search-entry-name
                                 (typetopology-search--filter "FLABB"))
                        #'string<)
                  '("aflabby" "flabby")))))

(ert-deftest tt-search-filter-all-words-required ()
  "Multiple words all have to match, each anywhere in the display text --
a name AND a piece of its signature at once, say."
  (let ((typetopology-search--entries
         (list (tt-search--entry "flabby-extension" "aflabby D 𝓤 -> D")
               (tt-search--entry "unrelated" "aflabby D 𝓤"))))
    (should (equal (mapcar #'typetopology-search-entry-name
                           (typetopology-search--filter "flabby extension"))
                   '("flabby-extension")))))

(ert-deftest tt-search-word-score-tiers ()
  (should (= (typetopology-search--word-score "is-prop" "is-prop") 0))
  (should (= (typetopology-search--word-score "is-prop" "is-prop-valued") 1))
  (should (= (typetopology-search--word-score "is-prop" "a-is-prop") 2))
  ;; "xis-propx": occurs mid-word, "x" right before it is not one of the
  ;; boundary characters -- unlike "unrelated-is-prop-ish" above, where
  ;; the "-" right before "is-prop" DOES make it a word-start (tier 2),
  ;; not a plain substring.
  (should (= (typetopology-search--word-score "is-prop" "xis-propx") 3))
  (should (= (typetopology-search--word-score "is-prop" "unrelated-is-prop-ish") 2))
  (should-not (typetopology-search--word-score "is-prop" "nothing here")))

(ert-deftest tt-search-filter-ranks-exact-name-match-first ()
  "The actual bug reported in real use: search.html correctly puts
`is-prop' itself first for the query \"is-prop\"; this file, before
this fix, had no ranking at all and put whatever came first
alphabetically ahead of it (\"A-is-prop\", since entries only ever kept
Definitions.tsv's own alphabetical order)."
  (let ((typetopology-search--entries
         (list (tt-search--entry "A-is-prop") (tt-search--entry "is-prop"))))
    (should (equal (mapcar #'typetopology-search-entry-name
                           (typetopology-search--filter "is-prop"))
                   '("is-prop" "A-is-prop")))))

(ert-deftest tt-search-filter-ranks-word-start-above-plain-substring ()
  (let ((typetopology-search--entries
         (list (tt-search--entry "xis-propx") (tt-search--entry "a-is-prop"))))
    (should (equal (mapcar #'typetopology-search-entry-name
                           (typetopology-search--filter "is-prop"))
                   '("a-is-prop" "xis-propx")))))

(ert-deftest tt-search-filter-breaks-ties-by-uses-descending ()
  "Same relevance tier (both plain substring matches, say) -- the more
popular one, the same secondary sort key the browser search page uses,
wins the tie, rather than falling back to whatever incidental order
they happened to be in."
  (let ((typetopology-search--entries
         (list (typetopology-search-entry-create
                :name "flabby-a" :dispmod "M" :importmod "M" :file ""
                :line 1 :uses 2 :sig "" :assumes ""
                :dtext "flabby-a  [m]")
               (typetopology-search-entry-create
                :name "flabby-b" :dispmod "M" :importmod "M" :file ""
                :line 1 :uses 50 :sig "" :assumes ""
                :dtext "flabby-b  [m]"))))
    (should (equal (mapcar #'typetopology-search-entry-name
                           (typetopology-search--filter "flabby"))
                   '("flabby-b" "flabby-a")))))

;; --------------------------------------------------- showing the list

(ert-deftest tt-search-render-shows-matches-and-highlights-selected ()
  (unwind-protect
      (let* ((e1 (tt-search--entry "aaa")) (e2 (tt-search--entry "bbb"))
             (buf (typetopology-search--render "q" (list e1 e2) 1)))
        (with-current-buffer buf
          (should (string-match-p "aaa" (buffer-string)))
          (should (string-match-p "bbb" (buffer-string)))
          (let ((ovs (overlays-in (point-min) (point-max))))
            (should (= (length ovs) 1))
            (should (eq (overlay-get (car ovs) 'face) 'highlight))
            (should (save-excursion (goto-char (overlay-start (car ovs)))
                                    (looking-at-p "bbb"))))))
    (when (get-buffer typetopology-search--results-buffer-name)
      (kill-buffer typetopology-search--results-buffer-name))))

(ert-deftest tt-search-render-empty-query-message ()
  (unwind-protect
      (let ((buf (typetopology-search--render "" nil 0)))
        (with-current-buffer buf
          (should (string-match-p "Type to search" (buffer-string)))))
    (when (get-buffer typetopology-search--results-buffer-name)
      (kill-buffer typetopology-search--results-buffer-name))))

(ert-deftest tt-search-render-no-matches-message ()
  (unwind-protect
      (let ((buf (typetopology-search--render "xyz" nil 0)))
        (with-current-buffer buf
          (should (string-match-p "No matches" (buffer-string)))))
    (when (get-buffer typetopology-search--results-buffer-name)
      (kill-buffer typetopology-search--results-buffer-name))))

(ert-deftest tt-search-render-caps-shown-and-notes-more ()
  "35 matches, 30 shown (`typetopology-search--max-shown'), the rest
noted rather than dumped -- rendering thousands of lines every
keystroke is not worth it, and narrowing the query is always the way
to reach further down anyway."
  (unwind-protect
      (let* ((many (cl-loop for i from 1 to 35 collect
                            (tt-search--entry (format "e%02d" i))))
             (buf (typetopology-search--render "q" many 0)))
        (with-current-buffer buf
          (should (string-match-p "and 5 more" (buffer-string)))))
    (when (get-buffer typetopology-search--results-buffer-name)
      (kill-buffer typetopology-search--results-buffer-name))))

(ert-deftest tt-search-show-results-before-any-render-does-not-error ()
  "Regression test for a real bug hit in use: `display-buffer' requires
its buffer argument to already exist, and signals a bare \"Invalid
buffer\" otherwise -- `typetopology-search--show-results' used to be
called before the first `typetopology-search--render', when the
results buffer did not exist yet at all. Confirmed with the buffer
genuinely absent going in, not just re-shown."
  (when (get-buffer typetopology-search--results-buffer-name)
    (kill-buffer typetopology-search--results-buffer-name))
  (should-not (get-buffer typetopology-search--results-buffer-name))
  (unwind-protect
      (should-not (condition-case err
                     (progn (typetopology-search--show-results) nil)
                   (error err)))
    (when (get-buffer typetopology-search--results-buffer-name)
      (kill-buffer typetopology-search--results-buffer-name))))

;; ------------------------------------------------------- moving around

(ert-deftest tt-search-select-move-clamps-at-bounds ()
  "Clamped, not wrapped: running off either end is a clear stop, not a
surprise jump to the other end."
  (with-temp-buffer
    (let ((typetopology-search--matches
           (list (tt-search--entry "a") (tt-search--entry "b")))
          (typetopology-search--selected 0))
      (cl-letf (((symbol-function 'minibuffer-contents) (lambda () "x")))
        (typetopology-search--select-move -1)
        (should (= typetopology-search--selected 0))
        (typetopology-search--select-move 1)
        (should (= typetopology-search--selected 1))
        (typetopology-search--select-move 1)
        (should (= typetopology-search--selected 1))))
    (when (get-buffer typetopology-search--results-buffer-name)
      (kill-buffer typetopology-search--results-buffer-name))))

(ert-deftest tt-search-select-move-noop-with-no-matches ()
  (with-temp-buffer
    (let ((typetopology-search--matches nil) (typetopology-search--selected 0))
      (typetopology-search--select-move 1)
      (should (= typetopology-search--selected 0)))))

;; ------------------------------------------- shared with the action menu

(ert-deftest tt-search-render-display-fn-defaults-to-display ()
  "No DISPLAY-FN argument -- the main search's own usage -- still shows
an entry via `typetopology-search--display', exactly as before this was
generalised for the action menu to share."
  (unwind-protect
      (let ((buf (typetopology-search--render "q" (list (tt-search--entry "flabby")) 0)))
        (with-current-buffer buf
          (should (string-match-p "flabby  \\[M\\]" (buffer-string)))))
    (when (get-buffer typetopology-search--results-buffer-name)
      (kill-buffer typetopology-search--results-buffer-name))))

(ert-deftest tt-search-display-propertized-matches-plain-text-content ()
  "Drift guard: `typetopology-search--display-propertized' must always
say the exact same thing as `typetopology-search--display', just with
faces layered on top -- stripping properties back off should give
byte-for-byte the same string, for every case those other display
tests already cover, so the two cannot silently diverge later."
  (dolist (e (list (tt-search--entry "flabby")
                   (tt-search--make-entry
                    :name "homotopy-id-sys" :dispmod "M" :importmod "M"
                    :file "" :line 1 :uses 2 :sig "Id-Sys 𝓤 (A → B) f"
                    :assumes "(fe : funext 𝓤 𝓥)")))
    (should (equal (substring-no-properties
                    (typetopology-search--display-propertized e))
                   (typetopology-search--display e)))))

(ert-deftest tt-search-display-propertized-faces-name-bold-rest-shadow ()
  (let* ((e (tt-search--entry "flabby" "A -> B"))
         (s (typetopology-search--display-propertized e))
         (name-end (length "flabby")))
    (should (eq (get-text-property 0 'face s) 'bold))
    (should (eq (get-text-property (1- name-end) 'face s) 'bold))
    (should (eq (get-text-property name-end 'face s) 'shadow))
    (should (eq (get-text-property (1- (length s)) 'face s) 'shadow))))

(ert-deftest tt-search-highlight-matches-adds-match-face ()
  (with-temp-buffer
    (insert "flabby : A -> B  [M]")
    (typetopology-search--highlight-matches (point-min) (point-max) '("flab"))
    ;; buffer positions start at 1, not 0 -- (point-min) is the real start
    ;; of "flab", (+ (point-min) 3) its last character.
    (should (memq 'match (ensure-list (get-text-property (point-min) 'face))))
    (should (memq 'match (ensure-list (get-text-property (+ (point-min) 3) 'face))))
    ;; ...and nothing past it, where the word does not occur, should.
    (should-not (get-text-property (+ (point-min) 5) 'face))))

(ert-deftest tt-search-highlight-matches-is-case-insensitive-and-literal ()
  "Same matching rule as `typetopology-search--filter' itself -- case-
insensitive, and literal text rather than a regexp, so a query
fragment that happens to contain a regexp-special character (common in
TypeTopology signatures: \"(\", \"[\", \"*\", ...) still highlights
instead of erroring or silently matching nothing."
  (with-temp-buffer
    (insert "aflabby (D : U) [3 uses]")
    (typetopology-search--highlight-matches (point-min) (point-max) '("(D"))
    ;; --highlight-matches restores point afterward (it works via
    ;; save-excursion), so search from the real start, not wherever
    ;; point happens to be left.
    (goto-char (point-min))
    (goto-char (search-forward "(D"))
    (should (memq 'match (ensure-list (get-text-property (- (point) 2) 'face))))))

(ert-deftest tt-search-render-highlights-query-in-results ()
  (unwind-protect
      (let ((buf (typetopology-search--render "flab" (list (tt-search--entry "flabby")) 0)))
        (with-current-buffer buf
          (goto-char (point-min))
          (should (memq 'match (ensure-list (get-text-property (point) 'face))))))
    (when (get-buffer typetopology-search--results-buffer-name)
      (kill-buffer typetopology-search--results-buffer-name))))

(ert-deftest tt-search-render-nil-query-never-highlights ()
  "The action menu (QUERY nil) has nothing typed to highlight against --
confirms no `match' face leaks in even though the label text itself
could coincidentally contain any given substring."
  (unwind-protect
      (let ((buf (typetopology-search--render nil '("Insert the name at point") 0
                                              #'identity)))
        (with-current-buffer buf
          (should-not (text-property-any (point-min) (point-max) 'face 'match))))
    (when (get-buffer typetopology-search--results-buffer-name)
      (kill-buffer typetopology-search--results-buffer-name))))

(ert-deftest tt-search-render-display-fn-identity-for-plain-strings ()
  "The action menu's own usage: plain label strings, shown as-is via
`identity' rather than treated as entries."
  (unwind-protect
      (let ((buf (typetopology-search--render "q" '("Insert the name at point") 0
                                              #'identity)))
        (with-current-buffer buf
          (should (string-match-p "\\`Insert the name at point"
                                  (buffer-string)))))
    (when (get-buffer typetopology-search--results-buffer-name)
      (kill-buffer typetopology-search--results-buffer-name))))

(ert-deftest tt-search-render-nil-query-skips-type-to-search ()
  "QUERY nil (as opposed to an empty string) is the action menu's \"there
is no typed-query concept here at all\" signal -- its fixed list is
shown regardless, never the main search's \"nothing typed yet\"
message, which only ever applies when there IS something to type into."
  (unwind-protect
      (let ((buf (typetopology-search--render nil '("a") 0 #'identity)))
        (with-current-buffer buf
          (should-not (string-match-p "Type to search" (buffer-string)))
          (should (string-match-p "\\`a" (buffer-string)))))
    (when (get-buffer typetopology-search--results-buffer-name)
      (kill-buffer typetopology-search--results-buffer-name))))

(ert-deftest tt-search-select-move-uses-display-fn-and-query-active ()
  "`typetopology-search--select-move' (bound to the arrow keys, so it
cannot take extra arguments of its own) reads
`typetopology-search--display-fn' and
`typetopology-search--query-active' -- the two buffer-local settings
that let the SAME selection-movement code serve both UIs -- rather
than assuming the main search's own defaults."
  (with-temp-buffer
    (let ((typetopology-search--matches '("a" "b"))
          (typetopology-search--selected 0)
          (typetopology-search--display-fn #'identity)
          (typetopology-search--query-active nil)
          (seen-query 'unset))
      (cl-letf (((symbol-function 'typetopology-search--render)
                 (lambda (query matches selected display-fn)
                   (setq seen-query query)
                   (should (eq display-fn #'identity))
                   (should (equal matches '("a" "b")))
                   (should (= selected 1)))))
        (typetopology-search--select-move 1))
      (should-not seen-query))))

(ert-deftest tt-search-action-confirm-sets-result-and-exits ()
  (let ((typetopology-search--matches '("Insert the name at point" "Jump to its definition in the source file"))
        (typetopology-search--selected 1)
        (typetopology-search--action-result nil)
        (exited nil))
    (cl-letf (((symbol-function 'exit-minibuffer) (lambda () (setq exited t))))
      (typetopology-search--action-confirm)
      (should exited)
      (should (equal typetopology-search--action-result
                     "Jump to its definition in the source file")))))

(ert-deftest tt-search-action-minibuffer-map-has-no-tab-binding ()
  "TAB has no separate meaning in the action menu -- unlike the main
search's own map, this one only ever needs arrow keys and RET."
  (should-not (lookup-key typetopology-search--action-minibuffer-map (kbd "TAB"))))

(ert-deftest tt-search-refilter-resets-selection-and-filters ()
  (with-temp-buffer
    (let ((typetopology-search--entries
           (list (tt-search--entry "flabby") (tt-search--entry "unrelated")))
          (typetopology-search--matches nil)
          (typetopology-search--selected 5))
      (cl-letf (((symbol-function 'minibuffer-contents) (lambda () "flabb")))
        (typetopology-search--refilter)
        (should (= (length typetopology-search--matches) 1))
        (should (= typetopology-search--selected 0))))
    (when (get-buffer typetopology-search--results-buffer-name)
      (kill-buffer typetopology-search--results-buffer-name))))

(ert-deftest tt-search-maybe-refilter-runs-when-query-changed ()
  "Regression test for a real bug hit in use: refiltering used to run
from `after-change-functions', which fires on every raw buffer edit,
including transient ones the Agda input method makes internally while
resolving a single keystroke (its own guidance/title indicator,
briefly inserted then removed -- confirmed from a real session's debug
log: a query of \"fla  [∏]\\n\" where \"∏\" is literally that input
method's own title string, per its `quail-define-package' call, not
anything a user typed). `typetopology-search--maybe-refilter', run
from `post-command-hook' instead, only acts once a whole command has
settled, and only if the text is actually different from last time."
  (with-temp-buffer
    (let ((typetopology-search--entries
           (list (tt-search--entry "flabby") (tt-search--entry "unrelated")))
          (typetopology-search--matches nil)
          (typetopology-search--last-query nil))
      (cl-letf (((symbol-function 'minibuffer-contents) (lambda () "flabb")))
        (typetopology-search--maybe-refilter)
        (should (= (length typetopology-search--matches) 1))
        (should (equal typetopology-search--last-query "flabb"))))
    (when (get-buffer typetopology-search--results-buffer-name)
      (kill-buffer typetopology-search--results-buffer-name))))

(ert-deftest tt-search-maybe-refilter-skips-when-query-unchanged ()
  "The other half of the same fix: a command that leaves the text alone
(an arrow key, moving the selection) must not trigger a refilter --
that would silently reset the selection right back to the top,
defeating the very keypress that just moved it."
  (with-temp-buffer
    (let ((typetopology-search--entries (list (tt-search--entry "flabby")))
          (typetopology-search--matches (list (tt-search--entry "flabby")))
          (typetopology-search--selected 0)
          (typetopology-search--last-query "flabb")
          (called 0))
      (cl-letf (((symbol-function 'minibuffer-contents) (lambda () "flabb"))
                ((symbol-function 'typetopology-search--refilter)
                 (lambda () (cl-incf called))))
        (typetopology-search--maybe-refilter)
        (should (= called 0))))))

(ert-deftest tt-search-confirm-sets-result-and-exits ()
  (let ((typetopology-search--matches (list (tt-search--entry "flabby")))
        (typetopology-search--selected 0)
        (typetopology-search--result nil)
        (exited nil))
    (cl-letf (((symbol-function 'exit-minibuffer) (lambda () (setq exited t))))
      (typetopology-search--confirm nil)
      (should exited)
      (should (equal (car typetopology-search--result)
                     (car typetopology-search--matches)))
      (should-not (cdr typetopology-search--result)))))

(ert-deftest tt-search-confirm-tab-sets-via-tab-t ()
  (let ((typetopology-search--matches (list (tt-search--entry "flabby")))
        (typetopology-search--selected 0)
        (typetopology-search--result nil))
    (cl-letf (((symbol-function 'exit-minibuffer) #'ignore))
      (typetopology-search--confirm t)
      (should (cdr typetopology-search--result)))))

(ert-deftest tt-search-confirm-no-match-does-not-exit ()
  (let ((typetopology-search--matches nil)
        (typetopology-search--selected 0)
        (typetopology-search--result nil)
        (exited nil))
    (cl-letf (((symbol-function 'exit-minibuffer) (lambda () (setq exited t)))
              ((symbol-function 'minibuffer-message) #'ignore))
      (typetopology-search--confirm nil)
      (should-not exited)
      (should-not typetopology-search--result))))

;; A genuine end-to-end version of the above (a real minibuffer read via
;; `read-from-minibuffer', `insert' to simulate typing, arrow-key
;; commands, `exit-minibuffer' via RET) was tried and removed -- the same
;; `--batch' unreliability documented above the removed
;; really-disables-default-completions test applies here too, reproduced
;; directly: the identical pattern hung for the full process timeout in
;; isolation, then errored with "end-of-file" on a second attempt, then
;; happened to pass once embedded in a full suite run. Not something to
;; depend on. Every piece of what it would have exercised -- filtering
;; (`tt-search-filter-*'), rendering (`tt-search-render-*'), selection
;; movement (`tt-search-select-move-*'), and confirming
;; (`tt-search-confirm-*') -- is already covered individually, reliably,
;; just above.

;; -------------------------------------------------------- unicode input

(ert-deftest tt-search-activate-agda-input-noop-when-unavailable ()
  "In this test environment agda-input.el is never loaded, so this must
do nothing -- and, above all, must not signal, since typetopology-search
does not require agda2-mode to be loaded to work at all."
  (should-not (featurep 'agda-input))
  (should-not (assoc "Agda" input-method-alist))
  (typetopology-search--activate-agda-input))

(ert-deftest tt-search-activate-agda-input-activates-when-available ()
  (let ((called nil) (orig-featurep (symbol-function 'featurep)))
    (cl-letf (((symbol-function 'featurep)
               (lambda (f &rest r)
                 (if (eq f 'agda-input) t (apply orig-featurep f r))))
              ((symbol-function 'activate-input-method)
               (lambda (name) (setq called name))))
      (typetopology-search--activate-agda-input)
      (should (equal called "Agda")))))

;; -------------------------------------------------------------- mode

(ert-deftest tt-search-mode-map-binds-ttsearch ()
  (should (eq (lookup-key typetopology-mode-map (kbd "C-c C-v")) #'ttsearch)))

(ert-deftest tt-search-mode-auto-hooked-to-agda2-mode-hook ()
  "Loading typetopology-search.el is the whole setup -- confirms the
top-level `add-hook' actually ran, not just that the mode CAN be turned
on by hand."
  (should (memq #'typetopology-mode agda2-mode-hook)))

(ert-deftest tt-search-mode-toggles-on-and-off ()
  (with-temp-buffer
    (should-not typetopology-mode)
    (typetopology-mode 1)
    (should typetopology-mode)
    (typetopology-mode -1)
    (should-not typetopology-mode)))

(provide 'typetopology-search-tests)
;;; typetopology-search-tests.el ends here
