# TODO

* ~~Concept search in the Emacs command.~~ **DONE 2026-08-01.** Concepts
  are a third `typetopology-search-entry` kind, alongside `def` and
  `person`, with the same treatment contributors got: matched by label
  text only (not their prose pattern or search alias the way the
  browser page also matches them -- deliberately the simpler of the two
  options this TODO left open, to keep the feature small and easy to
  remove), and the action menu offering "jump to a module mentioning
  it" (reusing `typetopology-search--jump-to-mention` unchanged, since
  a concept's data -- label plus discussing modules -- has the same
  shape as a contributor's). `concepts.tsv` stays optional for the
  Emacs bootstrap: `agda-index.py`'s `concepts_of()` degrades to `[]`
  when the file does not exist, the same as `people_of()` already does
  for a missing README.

  Built specifically so it can be dropped cheaply if it ever turns out
  to slow filtering down on a real concept list: set
  `typetopology-search-include-concepts` to nil and reload -- concept
  lines are then simply never turned into entries at load time, no
  regeneration or code revert needed. Measured directly (A/B, real
  data, several representative queries): concept entries make no
  measurable difference to filtering time either way.

* **Pre-existing bug found while verifying the above, not fixed:** the
  identifier `#-` (`PathSequences.Split.lagda:173`, a real definition,
  `#- = drop-from-end`) is silently dropped by both
  `typetopology-search.el`'s and (very likely) the browser page's own
  "lines starting with # are a comment" convention, since a definition
  row can legitimately start with a literal `#`. Affects exactly this
  one identifier out of 21,332, as far as checked. Not a regression
  from any of the above -- the convention itself predates concepts and
  contributors alike.
