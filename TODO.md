# TODO

* **Concept search in the Emacs command.** Add concepts as a third
  `typetopology-search-entry` kind, alongside `def` and `person`, with
  the same treatment contributors got: matched by name, and the action
  menu offering "jump to a module mentioning it" (reusing
  `typetopology-search--jump-to-mention` as is, since a concept's data
  -- name plus discussing modules -- has the same shape as a
  contributor's).

  Two things to decide first, discussed 2026-08-01 and deliberately
  deferred rather than decided:

  1. Match by label text only (simple, matches the contributor
     precedent exactly), or also by the concept's prose pattern/alias
     the way the browser page does (e.g. typing "searchable" finds
     "compactness")? Label-only is a real, noticeable step down from
     the browser page's own matching.
  2. `concepts.tsv` is currently optional for the Emacs bootstrap
     (`--no-html --emacs-index` needs neither `concepts.tsv` nor
     `agda-input-escapes.json` at all, and this is documented and
     tested). Adding concepts to `Definitions.tsv` should degrade
     gracefully -- skip concepts silently when the file is not there --
     rather than making it newly required.

  Smaller, lower-risk items to check while building this: the
  per-concept "which modules discuss this" scan currently only runs
  when building the browser page (`not --no-html`); running it for
  `--emacs-index` too adds some unmeasured cost (likely modest, since
  the expensive prose-extraction step already runs unconditionally).
  Concepts.tsv's "landmark" definitions (names that *are* the concept,
  with real file/line) are a separate richer feature the browser page
  also has -- out of scope here unless asked for.
