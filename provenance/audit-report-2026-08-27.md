# Similarity & provenance audit — Weebill vs codec2 1.2.0

Date: 2026-08-27
Auditor: Claude (contaminated-side audit session; read both the reference C
source and the Swift implementation for this audit, wrote no implementation
code). Performed per PLAN.md Phase 3 items 1–2, in the context of the
2026-08-23/26 email exchange with David Rowe (archived at the project root),
in which he confirmed the LGPL cannot be relicensed, noted that a
clean-room + interop-test approach is the plausible route, and placed all
compliance responsibility on this project.

## Verdicts

**Similarity audit: PASS.** No copied or transliterated expression from
codec2 1.2.0 was found in `Sources/` or `Tests/` beyond (a) the two
sanctioned interface-data tables, which are confined to
`Codebooks.swift`/the spec CSVs and carry provenance headers, and
(b) interop-required constants and algorithm structure that any conforming
implementation must share. Three minor wording items are flagged below for
optional cleanup; none involves program code.

**Provenance audit: PASS with noted limitations.** The information barrier
is documented, internally consistent, and was exercised for real (Q1–Q7
answered as spec revisions, two contaminated revision agents logged, an
erroneous spec-side hint retracted on the record). The main structural
weakness — instruction-only enforcement of the implementer's input
restriction, against a model that plausibly saw codec2 in training — is
inherent to the method, was identified in PLAN.md up front, is disclosed in
NOTICE, and is exactly what this similarity audit mitigates.

---

## 1. Similarity audit

### 1.1 Method

- Reference corpus: codec2 1.2.0 `src/` files on the 3200 path (codec2.c,
  sine.c, nlp.c, quantise.c, lpc.c, lsp.c, pack.c, interp.c, postfilter.c,
  phase.c, defines.h, codec2_internal.h, codebook/dlsp*.txt), read in full
  or in the relevant functions.
- Audited corpus: all 10 Swift source files (1,983 lines) and the test
  files, read in full.
- Automated scans (token-level tools such as MOSS/JPlag are ineffective
  across C↔Swift, so these were run bespoke):
  1. **Identifier intersection** Swift ∩ C, filtered for common
     English/language words, then each distinctive survivor traced to its
     transmission path.
  2. **Comment/prose n-gram overlap** (6-gram and 5-gram, word-level,
     case-folded) of Swift comments vs C comments, and spec text vs C
     comments.
  3. **Interface-data verification**: spec CSVs and the generated
     `Codebooks.swift` compared numerically against the upstream tables.
- Manual structural side-by-side of every pipeline stage.

### 1.2 Automated results

**Identifiers.** Every distinctive identifier shared between the Swift and
the C (`Sw`, `Aw`, `Pn`, `sq`, `nw`, `eratio`, `bmin`/`bmax`, `prev_f0`,
`lsp_hz`, `Wo`, `Wo_min`/`Wo_max`, `acc`) also appears in the spec
documents, i.e. the transmission path is spec → Swift, not C → Swift.
The Swift's own naming is otherwise descriptive English
(`harmonicMagnitudes`, `refinePitch`, `voicingDecision`, `overlapAdd`,
`excitationPhase`, `backgroundDB`) where the C uses
`estimate_amplitudes`, `two_stage_pitch_refinement`, `est_voicing_mbe`,
`synthesise`, `ex_phase`, `bg_est`.

**Prose.** The only shared word sequences of ≥5 words between the Swift
comments (or the spec) and the C comments are: the mathematical identities
P′(z) = P(z)/(1+z⁻¹), Q′(z) = Q(z)/(1−z⁻¹) and y[n] = x[n] − x[n−1]
(standard textbook notation), the Makhoul citation, and the factual phrase
"in the first 1000 Hz". No copied comment prose.

**Interface data.** All ten `dlsp` tables are value-identical to
`src/codebook/dlsp{1..10}.txt` (32 entries each) and `nlp_fir48` is
value-identical to the 48 taps in `nlp.c`. These are the two sanctioned
verbatim copies (see `codec2-3200-spec/provenance/tables-rationale.md`);
they are confined to data files/one generated Swift file, each marked with
origin, version, and the interoperability rationale. Nothing else numeric
in the Swift matches the C beyond constants the spec carries as
interop-required (window/DFT sizes, quantiser ranges, filter parameters
β=0.2/γ=0.5, thresholds 6.0 dB/±10 dB/−4 dB, 0.994 expansion, 0.95 notch,
0.032 correction, 1.96 bass boost, 30000 limiter knee, etc.). Sharing
these is a consequence of interoperating, not of copying: they change the
bitstream or gross output (algorithm.md §9). *(See the Addendum: on
re-examination the two "copied" tables turned out to be formulaic /
recipe-derived, which strengthens this section's conclusion.)*

### 1.3 Structural review

No function-level transliteration was found. Where the algorithm forces
the same mathematics, the expression differs throughout. Representative
observations:

| Stage | Reference expression | Swift expression |
|---|---|---|
| Levinson–Durbin | 2-D `a[order+1][order+1]` matrix (lpc.c) | 1-D array with per-stage copy; clamp written as a NaN-absorbing range test (a robustness improvement not in the C) |
| LPC→LSP | pre-doubled coefficient arrays, pointer-walk Chebyshev eval (lsp.c) | closure with explicit T_k recurrence, doubling folded into the sum |
| LSP→LPC | in-place IIR "clocking" ladder with 4-pointer arithmetic (lsp.c `lsp_to_lpc`) | explicit polynomial convolution of second-order sections, then A(z) assembly — a different algorithm for the same identity |
| Postfilter | Rw=√(Ww·Pw), Pfw=Rwᵝ, Pw·=Pfw² (quantise.c) | Pw·=pow(√(Ww·Pw), 2β) — same math, different factoring; 1.96 vs the C's 1.4·1.4 |
| Decoder organization | six functions across four files (aks_to_M2, lpc_post_filter, apply_lpc_correction, sample_phase, phase_synth_zero_order, postfilter) | one `synthesise(_:)` method; different decomposition |
| Synthesis buffer | 2·n_samp `Sn_` with shift flag (sine.c) | 160-sample accumulator with per-subframe emit |
| Unvoiced-phase PRNG | shared LCG `codec2_rand` | seedable SplitMix64 (deliberate divergence, spec-sanctioned) |
| NLP FIR | oldest-first shifting delay line | most-recent-first delay line |
| Precision | float | double internally, floats at the DFT boundary |
| CLI | getopt-based c2enc/c2dec | idiomatic Swift, different structure and messages |

The Swift also contains behaviour with no C counterpart (the
`nonFiniteSampleCount` diagnostic, NaN-safe quantiser clamps, fuzz-driven
robustness), consistent with independent authorship against a spec.

### 1.4 Flagged items (minor, none in program code)

1. **Spec notation carries reference variable names.** algorithm.md uses
   `Sw`, `Aw`, `Pw`, `Ww`, `Fw`, `Pn`, `sq`, `nw`, `eratio`, `bmin/bmax`,
   `prev_f0`, `elow/ehigh` — short labels that match reference variable
   names. As one- and two-letter functional labels they carry thin-to-no
   expression, and keeping them makes the spec auditable against the
   reference; but it should be a documented choice. *Recommendation:* add
   one sentence to the spec's conventions noting that signal names follow
   the reference's customary labels for auditability.
2. **One close paraphrase.** algorithm.md §7.3 "(the synthesis filter 1/A
   has phase opposite to the analysis filter A…)" ≈ phase.c comment
   "synth filter 1/A is opposite phase to analysis filter"; the sentence
   was carried into a Decoder.swift comment. It states a nine-word
   mathematical fact; still, it is the closest textual approach in the
   project. *Recommendation:* reword in both places (e.g. "1/A(z)
   contributes the negated phase of A(z)").
3. **"ear protection"** is quoted in algorithm.md §7.5 and a Decoder.swift
   comment; it is the reference's function name (`ear_protection`). Used
   as quoted jargon for the output limiter. *Recommendation:* keep or
   drop; if kept, the quotes already signal it is borrowed vocabulary.

None of these three changes the audit verdict; they are wording hygiene.

## 2. Provenance audit

### 2.1 What the record establishes

- **Roles and barrier** are defined in PLAN.md and
  `codec2-3200-spec/provenance/contamination-log.md`, which lists every
  contaminated party/context, what each saw, and when — including the two
  contaminated spec-revision agents (Q5/Q6 and Q7) and a *non*-contaminated
  Phase 2 orchestrator that ran reference binaries without reading source.
- **Implementer inputs were restricted** to the six spec inputs; the M1
  prompt (archived verbatim) enumerates permitted paths, forbids reading
  anything else including `reference/` and PLAN.md, forbids web search and
  reproduction from memory, and requires stop-and-ask on ambiguity. Each
  later prompt (M2, M3, M3c, M4 — all archived) restates the rules.
- **The Q&A discipline held.** Q1–Q7 in qa-log.md were answered as spec
  revisions, not hints; conformance failures went back as symptoms and
  metrics. The M3 brief's erroneous "lag windowing" phrase was retracted
  on the record (Q5) — evidence the channel carried corrections, not
  reference excerpts. The m3b/m3d revision notes state the contaminated
  agents reported no C excerpts and performed copied-expression
  self-review.
- **Spec-side copied-expression review** is logged as completed 2026-08-26
  (qa-log open-tasks list), and this audit's independent n-gram scan of the
  spec against the C comments corroborates it (§1.2).
- **Sanctioned copies are contained and rationalised**: the CSV headers,
  tables-rationale.md (s 47D / Google v. Oracle analysis), and NOTICE all
  align; NOTICE also discloses the AI-implementer caveat and disclaims
  affiliation/endorsement — consistent with David Rowe's explicit
  non-endorsement in the email thread ("without taking any responsibility
  for the code or legality").
- **Functionally real**: the full suite (67 tests including reference-vector
  conformance and KATs) passes as of this audit; the archived final
  conformance sweep records OVERALL PASS.

### 2.2 Limitations and caveats (disclose; do not treat as blockers)

1. **Instruction-only enforcement.** The implementer agent had filesystem
   access to the whole project; the input restriction was enforced by
   prompt, not by sandbox. The archive contains prompts and final reports,
   not the agents' intermediate tool-call logs, so "never read
   `reference/`" cannot be re-verified mechanically after the fact.
   *Recommendation for any future milestone:* run implementer agents in a
   directory containing only the spec repo, and retain full session logs.
2. **Abridged M4 response.** m4-response.md is marked "Highlights (full
   text in session transcript archive)" — slightly short of PLAN.md's
   "archived verbatim" rule. If the full transcript still exists, copy it
   in; otherwise note its loss.
3. **Training-data contamination** of the AI implementer cannot be ruled
   out, only mitigated (spec-only prompting, Swift target, this audit).
   Already disclosed in NOTICE; the "AI clean room" remains an untested
   legal theory, as PLAN.md says.
4. **The codebook copying was not blessed by the rights holder.** In the
   email thread Charles asked whether treating the quantiser tables as
   interface data "sits right"; David Rowe's reply endorsed the general
   approach but explicitly declined any statement on licensing. The
   project's s 47D/interop analysis stands on its own and legal review
   before App Store distribution (PLAN.md Phase 3 item 4) remains open —
   this audit does not substitute for it.
5. **Single-day, single-author history.** Both repos were committed in
   one squash each, so git history adds little independent evidence; the
   provenance weight rests on the transcript archive and this report.

## 3. Evidence inventory

- Reference: `reference/codec2` (v1.2.0 source tree).
- Implementation: `weebill`, tree as audited 2026-08-27 (the audited
  revisions predate the repos' public initial commits; the full
  pre-publication histories are archived privately as git bundles).
- Spec: `codec2-3200-spec`, likewise.
- Scans run 2026-08-27 (identifier intersection, 6/5-gram prose overlap,
  numeric table comparison); `swift test`: 67 tests, 0 failures.
- Email record: `emails-with-david-rowe.pdf` (2026-08-23 → 2026-08-26).

## Addendum (2026-08-27, same day) — table expressiveness re-examined

Prompted by the observation that the dlsp tables look regularly spaced
rather than trained, both "sanctioned copies" were re-derived from first
principles:

1. **dlsp1–10 are formulas.** Tables 1–3 and 7–10: entry i = 25·(i+1) Hz
   (uniform, 25…800). Tables 4–6: 25·(i+1) Hz for i = 0..7, then
   200 + 50·(i−7) Hz for i = 8..31 (25…200 step 25, 250…1400 step 50).
   Every one of the 320 values regenerates exactly from these two rules.
   They are not trained VQ data (codec2's trained codebooks are on other
   modes' paths, not 3200's).
2. **nlp_fir48 is a textbook design output.** A 48-tap Hamming-windowed
   sinc low-pass at 600 Hz/8 kHz (Octave `fir1(47, 600/4000)`, scipy
   `firwin(48, 0.15)`) reproduces all 48 published coefficients to a
   maximum error of 2.6·10⁻⁹ — the shipped values are that recipe rounded
   to 8 significant figures.
3. **Reclassification.** The dlsp tables remain true bitstream interface
   (they define index semantics for any decoder) but carry no authored
   expression at all; the FIR is encoder-side behavioural data, not
   interface — the decoder never uses it and any 64-bit frame stays valid;
   it is pinned only so pitch tracks match the reference encoder (E1b).

Consequence: the project's one deliberate legal judgment call (verbatim
table extraction under a s 47D/interop rationale) is now a fallback
position rather than the primary one — the primary position is that there
is no protectable expression in these values to copy, and both sets can be
*generated* from public one-line rules rather than extracted. Documents
updated on this basis (2026-08-27): the spec repo's
`provenance/tables-rationale.md` (rewritten), the eleven
`codebooks/*.csv` headers (generation rules replace "extracted verbatim"),
`bitstream.md` §4.3 and `algorithm.md` §3 step 3 (formulas/recipe stated,
FIR reclassified), and this repo's NOTICE. Table *values* are unchanged
everywhere; `Codebooks.swift` is untouched. The email-thread caveat stands:
the question put to David Rowe assumed trained tables, which for this mode
they are not; he made no licensing statement either way.

## Note on names (2026-08-27, later)

The package received its final name, **Weebill**, after this audit was
written; it had been developed under an interim working name. Module,
target, and CLI names in this report and in `agent-transcripts/` have
been updated to the final names (the transcripts are otherwise verbatim).
No code or functional content changed with the naming: 67/67 tests pass
unchanged. Naming policy: "Codec 2" appears in this project only
nominatively, to identify the bitstream format Weebill interoperates
with, never in the package's own branding.
