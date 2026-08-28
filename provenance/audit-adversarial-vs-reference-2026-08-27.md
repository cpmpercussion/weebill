# Adversarial derivation audit: weebill (Swift) vs codec2 v1.2.0 (C)

Role: prosecutor. Goal: prove the Swift package at
/Users/charles/src/3200bps-speech-codec/weebill is derived from the C
reference at /Users/charles/src/3200bps-speech-codec/reference/codec2
(v1.2.0), attacking a prior no-derivation finding. Discipline: similarity
forced by the published spec (/Users/charles/src/3200bps-speech-codec/codec2-3200-spec,
which the Swift implementer legitimately saw in full, including qa-log.md,
codebooks/, and vectors/) or by the mathematics is NOT evidence; only
UNFORCED similarity counts.

Date: 2026-08-27. Auditor: automated adversarial audit (Claude, Fable 5),
run as a fresh agent independent of both the implementer sessions and the
first audit. The mechanical working extracts this report cites (identifier
lists, constant lists, corpora) are retained in the project's private
archive and are reproducible from the method in §0.

## 0. Corpora and method

- C corpus (6,248 lines): src/{codec2.c, nlp.c, sine.c, quantise.c, lpc.c,
  lsp.c, interp.c, phase.c, postfilter.c, pack.c, defines.h,
  codec2_internal.h, sine.h, nlp.h, quantise.h, lpc.h, lsp.h, interp.h,
  phase.h, postfilter.h} -> c_corpus.txt.
- Swift corpus (1,716 lines): Sources/Weebill/*.swift + Sources/weebill-cli/main.swift
  -> swift_corpus.txt. (Sources/c2fuzz and Tests examined separately.)
- Spec corpus (98,430 bytes): all spec *.md + codebooks/*.csv + codebooks/*.py
  + provenance/*.md -> spec_corpus.txt.
- Mechanical extraction: identifier lists (c_ids.txt 1,940 / swift_ids.txt
  1,143 / raw intersection id_intersect.txt 441), numeric-literal lists
  (c_nums.txt 163 / swift_nums.txt 166 / intersection num_intersect.txt 88 /
  nums_not_in_spec.txt), comment word 5/6/7-gram overlap (python, code and
  strings stripped), plus manual reading of every Swift source file against
  the corresponding C functions and the spec text.

## 1. Identifier echoes

Raw token intersection (441 entries) is dominated by English prose from
comments. After stripping comments/strings and filtering language keywords
and generic math names, the code-level intersection is 29 tokens
(code_id_intersect.txt):

    beta bmax bmin codebook decode den encode eratio err exit gain gamma
    imag nearest next nw offset real roots scale speech start step sw
    synthesise unpack v1 voiced window

Classification (spec cites verified by grep):

| identifier | C | Swift | spec? | class |
|---|---|---|---|---|
| bmin/bmax | nlp.c post_process_sub_multiples | Encoder.swift:244-245 | algorithm.md:144-145 ("bmin = trunc(0.8*b) clamped up to 16, bmax = trunc(1.2*b)") | forced |
| eratio | sine.c:452 | Encoder.swift:414 | algorithm.md:197 | forced |
| nw | C2CONST | Encoder.swift:32 | algorithm.md:76 ("nw = 279") | forced |
| beta/gamma | quantise.c lpc_post_filter | Decoder.swift:212 | algorithm.md:397-398 (beta = 0.2, gamma = 0.5) | forced (also standard Kondoz notation) |
| v1 | codec2.c | Bitstream.swift:116 | bitstream.md:24 (field named "v1") | forced |
| offset | sine.c:447 | Encoder.swift:375 | algorithm.md:190 ("offset = trunc(256 - ...)") | forced |
| sw (Sw) | sine.c COMP Sw[] | Encoder.swift locals | algorithm.md uses Sw[] throughout | forced |
| synthesise | sine.c synthesise() | Decoder.swift:197 | spec is British English throughout ("synthesises" algorithm.md:43; "quantise", "initialise") | forced/plausibly-forced |
| den | sine.c:448 ("float den; /* denominator of Am expression */") | Encoder.swift:379 ("var numRe = 0.0, numIm = 0.0, den = 0.0") | NOT in spec (whole-word grep: no hit) | plausibly-forced -- see below |
| rest (codebook, decode, encode, err, exit, gain, imag, nearest, next, real, roots, scale, speech, start, step, unpack, voiced, window) | - | - | generic programming vocabulary and/or spec terms | forced/generic |

The single identifier shared by C and Swift and absent from the spec is
`den`. It is the universal abbreviation for the denominator of a quotient
the spec writes as A-hat_l = Sum Sw[k]*W[offset+k] / Sum W[offset+k]^2. The
C names the numerator `Am` (a COMP); Swift names it `numRe`/`numIm` -- a
different and more natural num/den pairing the C does not use. One generic
three-letter abbreviation, with surrounding naming divergent, is not
credible evidence. Classified plausibly-forced (independent convergence),
weak.

Negative result (the damning names are absent): targeted whole-word grep of
all Swift sources and tests found ZERO hits for C-distinctive identifiers:
Sn_, ex_phase, snr_thresh, bg_est, V_THRESH, BG_THRESH, COEFF, PMAX_M,
NLP_NTAP, nlp_fir, post_process_sub_multiples, hs_pitch_refinement,
two_stage_pitch_refinement, est_voicing_mbe, aks_to_M2,
phase_synth_zero_order, lpc_post_filter, check_lsp_order,
apply_lpc_correction, speech_to_uq_lsps, analyse_one_frame,
synthesise_one_frame, codec2_encode_3200, dft_speech, psuml, psumr,
delta_x, cheb_poly_eva, fftr, gmax, Fw, xq, COMP, kiss, mem_x, mem_y,
parab. (Aw, Pn, Pw, sq, Wo_min/max, lsp_hz, prev_f0, Gray do occur in Swift
comments/code but every one is a name the spec itself uses:
algorithm.md:392-393, 444-446, 57, 147; bitstream.md 4.1/4.3 -- forced.)

## 2. Comment similarity

All C comments vs all Swift doc/line comments, word n-gram overlap after
normalisation:

- 5-grams shared: 14; 6-grams: 10; 7-grams: 9.
- After removing n-grams also present in the spec corpus: 5 / 6 / 7
  survive -- and every survivor is a fragment of the LSP polynomial
  identities (P'(z) = P(z)/(1+z^-1) and Q'(z) = Q(z)/(1-z^-1), tokenising
  to "... z 1 and q z q z 1 ...").
  - C: lsp.c:157  P'(z) = P(z)/(1 + z^(-1)) and Q'(z) = Q(z)/(1-z^(-1))
  - Swift: LPC.swift:99  P'(z) = P(z)/(1+z^-1) and Q'(z) = Q(z)/(1-z^-1)
  - Spec: algorithm.md:266-267 states the identical formulas on adjacent
    lines; only the joining word "and" is not in the spec's layout.
  Notation is decisive: Swift writes the spec's Unicode form (z^MINUS 1,
  U+2212), not the C's ASCII z^(-1). Classified plausibly-forced (standard
  mathematics stated in the spec; transcription style follows the spec).
- Distinctive C comment phrases hunted directly, absent from Swift:
  "Type 1 errors", "Type 2 errors", "gross errors", "very neat property",
  "totally voiced", "clean up some voicing", "harmoonic" (the C's typo),
  "pitch-pulse". Zero hits.
- Swift comments that look like quirky asides -- "ear protection"
  (Decoder.swift:322), "assign, not add" (319), "negative time" (316),
  "clamped up to 16" (Encoder.swift:246), "initialise k_g = 16 in case the
  spectrum is all zero" (228-229), "the last x_mid evaluated, not the
  midpoint" (LPC.swift:185-186) -- are all verbatim quotations of the SPEC
  (algorithm.md:469, 467, 466, 145, 141, 319-320), several in explicit
  quotation marks with section cites. Notably "ear protection" is not even
  a codec2.c comment (it appears only in freedv_api.c:960, outside the 3200
  path); the Swift author demonstrably took it from algorithm.md:469. Forced.

## 3. Magic constants

88 numeric literals are shared between the C corpus and Swift
(num_intersect.txt). Every one was searched (with .0-suffix variants)
against the full spec corpus: the not-in-spec list is EMPTY
(nums_not_in_spec.txt). Spot-verified the quirky ones: 0.95 (notch pole and
L*w0 >= 0.95*pi guard, algorithm.md:124,166), 1e-4 seeds (194,198,399),
0.032 (406), 1.96 (401), 30000 and the squared ratio (470-471), 433 (466),
279 (76), 0.994 (248), 0.15/0.3/0.8/1.2 NLP thresholds (144-149), 6.0 dB
(195), -10/-4/60 Hz voicing rules (202-204), 150.0 (406), 21/298 window
extent (77).

The one prima facie smoking gun: the 48 NLP FIR coefficients appear in
Swift (Codebooks.swift:37) character-for-character identical to
nlp.c:74-85 including the 8-significant-figure e-notation formatting
(-1.0818124e-03 ...). Run to ground:

- The spec ships codebooks/nlp_fir48.csv containing exactly these strings
  (row "0,-1.0818124e-03" ...), plus codebooks/generate.py with a recipe
  (Hamming-windowed sinc, fc = 600/4000, 48 taps, unity DC gain, round to 8
  sig figs = Octave fir1(47, 600/4000)).
- I independently re-executed the recipe in Python: it reproduces the C
  table EXACTLY to all 8 significant figures -- the values are
  mathematically forced by the published design rule.
- Weebill's Scripts/generate-codebooks.sh (checked in) mechanically copies
  the CSV's second column into Codebooks.swift via awk; the file is headed
  "GENERATED FILE, DO NOT EDIT BY HAND ... Source:
  codec2-3200-spec/codebooks/nlp_fir48.csv".

So the formatting-identity chain is C -> spec CSV -> Swift, with the middle
hop inside the material the implementer was entitled to use. For the Swift
package this is forced (spec-provided data). (Whether the SPEC should pin
the C's exact ASCII is a spec-provenance question outside this audit's
target; the spec repo's commit history -- "Reclassify codebooks:
formulaic/recipe-derived", "Ship codebook generation rules instead of table
values" -- addresses it, and the recipe check above confirms the values are
recipe-derivable.)

The dlsp1-10 tables (Codebooks.swift:11-33) match C's src/codebook/dlsp*.txt,
but both equal the trivial ladders stated as normative rules in the spec
(25*(i+1); tables 4-6 switch to 50-steps after 200) and are generated from
the spec CSVs by the same script. Forced.

## 4. Structural mirroring

The spec's algorithm.md dictates the pipeline order at 10 ms-step
granularity (sections 1-7 are effectively pseudo-code), so pipeline order
proves nothing. What the spec does NOT dictate -- file layout, function
boundaries, signatures, data structures -- diverges consistently:

| aspect | C | Swift | verdict |
|---|---|---|---|
| module split | 10 files: codec2.c glue + nlp.c + sine.c + quantise.c + lpc.c + lsp.c + interp.c + phase.c + postfilter.c + pack.c | 8 files with different boundaries: NLP inlined into Encoder.swift; interp + aks_to_M2-equivalent + phase + postfilter + synthesis all inlined into Decoder.swift; quantisers split from packing (Quantisers.swift vs Bitstream.swift) where C mixes them | divergent |
| LPC<->LSP placement | both directions in lsp.c | analysis direction in LPC.swift, synthesis direction in LSP.swift | divergent |
| lsp_to_lpc algorithm | lsp.c:256-313: Speex-derived pointer-walking lattice over Wp[4*order+2] scratch (n1..n4 pointers, xin/xout shuffle) | LSP.swift:21-57: direct polynomial convolution of 5 second-order sections then average -- the spec's literal wording ("cascading ... and averaging") | strongly divergent -- same math, unmistakably different construction |
| NLP module | stateful object, nlp_create/nlp_destroy, COMP arrays, kiss FFT | private methods + stored properties on the encoder class | divergent |
| FFT | kiss_fft via codec2_fft wrappers | Apple Accelerate vDSP (DFT512.swift) with spec-convention shims + identity tests | divergent |
| synthesis split | synthesise_one_frame -> phase_synth_zero_order (phase.c) + postfilter (postfilter.c) + synthesise (sine.c) + ear_protection (codec2.c) | one synthesise(_:) + overlapAdd in Decoder.swift | divergent |
| voicing-interp rules | interp.c interp_Wo2 cascaded ifs | Decoder.swift:142-158 if/else chain matching spec section-7 bullet text, which states the rules | forced by spec |
| unvoiced-phase PRNG | codec2_rand(): LCG 1103515245, seed 1 | SplitMix64, seed 0x2545F4914F6CDD1D (Decoder.swift:13-31); spec explicitly frees this choice | divergent |
| parameter passing | out-params, MODEL mutated in place | value types AnalysisResult/SubframeModel/Codec2Frame returned | divergent |

No unforced structural mirroring found; where the spec is silent, the two
codebases consistently differ.

## 5. Idiosyncrasies and bugs

Every C quirk that Swift reproduces was checked against the spec; all are
documented (qa-log.md and section 9 exist precisely to capture them):

- acc[79] = 0 shift oddity: Decoder.swift:313-314 <-> algorithm.md:465 and qa-log.md. Forced.
- assign-not-add for i = 79..159: Decoder.swift:318-319 <-> algorithm.md:467. Forced.
- inverse-FFT tail indexing s'[433+i]: Decoder.swift:316 <-> algorithm.md:466. Forced.
- DC-notch "+1.0" conditioning constant: Encoder.swift:206 <-> algorithm.md:124-125. Forced.
- window asymmetry (denominator 278, j <= 277): Encoder.swift:92-99 <-> algorithm.md:76-79. Forced.
- L*w0 >= 0.95*pi decrement: Encoder.swift:292 <-> algorithm.md:166. Forced.
- ceil (5.2) vs round (5.1) band-edge asymmetry: Encoder.swift:336/371 <-> algorithm.md:180/187. Forced.
- 2 kHz boundary harmonic double-counted in elow and ehigh: Encoder.swift:410-413 <-> algorithm.md:199-200 ("counted in both"). Forced.
- limiter max over positive side only (no fabs -- a genuine C bug): Decoder.swift:323-324 <-> algorithm.md:470 ("raw float values, positive side"). Forced.
- LSP root search: exactly 6 bisections, root = last x_mid, x_lower never reset, re-anchoring: LPC.swift:151-201 <-> algorithm.md:300-341 (verbatim). Forced.
- w0 quantiser encode/decode asymmetry: Quantisers.swift:36-65 <-> bitstream.md 4.1 (spec "calls this out explicitly"). Forced.
- codebook tie-break to lowest index: Quantisers.swift:126-140 <-> bitstream.md 4.3. Forced.

Reproduced quirks the spec does NOT document: NONE FOUND. Conversely, Swift
contains behaviour the C does not have (NaN-absorbing clamps
Quantisers.swift:49-54; den > 0 guard Encoder.swift:389 where C divides
unguarded at sine.c:487; the nonFiniteSampleCount diagnostic; the 1e-9
float-sweep epsilon Encoder.swift:306) -- original engineering, not
transcription.

## 6. Other plaintiff angles

- Behavioural identity / KAT vectors: Tests/WeebillTests/Resources files
  are byte-identical (md5-verified) to spec vectors/, which the spec states
  were generated black-box with reference c2enc/c2dec. Using published
  conformance vectors is the sanctioned clean-room verification mechanism,
  not derivation of expression.
- British spellings analyse/synthesise/quantise match C function names, but
  the entire spec is written in the same British English -- forced.
- CLI/c2fuzz: no resemblance to c2enc.c/c2dec.c (argument handling, usage
  text, structure all Swift-idiomatic and different).
- Provenance record: weebill/provenance/ contains implementing-agent
  prompts/responses and a prior audit; nothing in the code contradicts the
  claim that the implementer's only codec-specific input was the spec repo.
- The spec's completeness cuts both ways: algorithm.md is close to a full
  behavioural transcription of the C 3200 path (down to bin 433 and the
  acc[79] oddity). This makes the Swift/C behavioural match total while
  making almost any expression-level echo "forced". A plaintiff would have
  to attack the SPEC's pedigree, not weebill's; that is outside this
  audit's defined scope, and within scope it exculpates the Swift package.

## Classification summary

- Forced: all 88 shared numeric literals; all reproduced quirks (12
  checked, 12 spec-documented); all code-identifier echoes except one; all
  comment echoes except one phrase-join.
- Plausibly-forced (weak, not evidence): local variable `den`
  (Encoder.swift:379 <-> sine.c:448); the single-line "P' ... and Q' ..."
  formula join (LPC.swift:99 <-> lsp.c:157; formulas themselves at
  algorithm.md:266-267, Swift notation follows the spec's Unicode).
- UNFORCED: none.

## Verdict

NO CREDIBLE EVIDENCE OF DERIVATION. Prosecuting as hard as the material
allows, the strongest candidates were: (1) the byte-identical NLP FIR table
including e-notation formatting -- traced to the spec's own
codebooks/nlp_fir48.csv, mechanically imported by a checked-in script, and
independently re-derivable from the spec's published fir1 recipe (verified
by re-execution); (2) the variable name `den`, a generic abbreviation whose
C-side partner (Am) Swift does not share; (3) the "P'(z) ... and Q'(z) ..."
comment line, whose formulas the spec states verbatim and whose notation
follows the spec, not the C. Everything else that matches -- every
constant, every quirk down to acc[79]=0 and the positive-side limiter bug,
every suspicious name -- is stated in the specification the implementer was
entitled to read. Where the spec is silent (function decomposition, FFT
machinery, LSP->LPC construction, PRNG, data types, defensive guards,
comment prose), the Swift consistently and substantively diverges from the
C, which is the signature of independent implementation, not of copying
with renaming. The systematic sweeps (441-token identifier intersection
classified to zero unforced survivors; 88-literal constant intersection
with an empty not-in-spec list; comment n-gram overlap reduced to
spec-stated mathematics; targeted hunts for 35+ C-distinctive names and 8
distinctive C comment phrases, all absent) are documented above and in the
retained working extracts, and constitute the well-documented
failure this brief demanded. Honest caveat: the specification is so
behaviourally complete that a derivation claim, to survive, must target the
spec's production rather than weebill -- within the ground rules given,
weebill stands clear.
