# Q5/Q6 spec revision — 2026-08-26

A separate CONTAMINATED spec-author agent (claude-opus; logged in
contamination-log.md) read reference lpc.c/lsp.c/quantise.c/nlp.c and
revised algorithm.md to answer Q5/Q6. It never touched the clean
implementation and reported no C excerpts. Findings, in its own words:

- No autocorrelation conditioning exists in the 3200 encode path; the
  0.994^i bandwidth expansion (after E) is the only regularisation.
- Root search: 0.01 cos-domain step is sufficient because P'/Q' roots are
  found by alternating scans re-anchored at each found root, each with 6
  bisection refinements (root = last midpoint); fallback = fewer than 10
  roots.
- NLP state initialises to all zeros (buffer, notch memories, 48 FIR
  taps); previous F0 = 50 Hz.

Sections changed: §0 (encoder initial state), §6 step 4 (explicit
no-conditioning statement), §6 step 5 (full rewrite of the root search),
§8 (NLP state resets), §9 (must-match list). qa-log.md Q5/Q6 resolutions
appended; contamination log row added. Copied-expression self-review
performed (renamed first-draft variable names that were too close to the
reference's).
