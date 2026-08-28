# Weebill vs. published Codec 2 ports — adversarial derivation audit

Date: 2026-08-27. Auditor: automated adversarial audit (Claude, Fable 5),
run as a fresh agent independent of the implementer sessions and the other
audits. Ports were shallow-cloned for comparison and are not vendored here;
each is cited by URL. Stance: adversarial — the goal was to *prove* that
the Weebill Swift implementation (`/Users/charles/src/3200bps-speech-codec/weebill`)
derives from a published port of codec2 (training-data contamination via a
port, rather than via the C reference). Spec baseline:
`/Users/charles/src/3200bps-speech-codec/codec2-3200-spec` (algorithm.md,
bitstream.md, conformance.md, qa-log.md, codebooks/, provenance/).

Discipline: similarity forced by the algorithm or by the spec text is NOT
evidence; only unforced expressive similarity (identifiers, comment wording,
constants absent from the spec, structural/organisational mirroring,
idiosyncrasies) counts.

---

## 1. Port inventory

### Hand-written reimplementations with actual codec logic (cloned & compared)

| Repo | Lang | 3200 mode | Character |
|---|---|---|---|
| github.com/scriptjunkie/codec2 (crates.io `codec2`, by Matt Weeks) | Rust | yes (3200/2400/1600/1400/1300/1200) | Pure-Rust, but a *name-preserving* translation of the C: `codec2_encode_3200`, `analyse_one_frame`, `est_voicing_mbe`, `hs_pitch_refinement`, `ear_protection`, `MODEL`, `COMP`, `kiss_fft`, `#![allow(non_snake_case)]` |
| github.com/ggrandes-clones/jcodec2 (copy of ggrandes/jcodec2) | Java | yes (3200/2400) | Mechanical Java translation; files are `J<cfile>.java` (Jnlp, Jquantise, Jpack, Jcodebookd…), keeps C names and C banner comments (`FUNCTION....: codec2_encode_3200`) |
| github.com/n7tae/c2-test | C++ | yes | Straight C→C++ translation of the reference, C comments preserved |
| github.com/blues/codec2 (`go/` tree) | Go | **no — 2400 only** | Semi-idiomatic Go translation of encoder+decoder at 2400; keeps many C names (`Sn`, `Sw`, `interp_Wo`, `postProcessSubMultiples`) alongside camelCase (`levinsonDurbin`) |

### Bindings / wrappers (not reimplementations — noted, skipped for logic; iOS one API-checked)

- Beartooth/codec2-ios (Swift) — Swift class wrapping the C library via a
  private module; *the* published Swift API for codec2, so its API shape was
  compared (see §4).
- yuvadm/codec2.rs, crates.io `codec2-sys` — Rust FFI bindings.
- gregorias/pycodec2 (Cython), wgaylord/pycodec2 (ctypes) — Python wrappers.
- UstadMobile/Codec2-Android, AhmedObaidi/codec2-android, sh123/codec2_talkie —
  Java/Android JNI wrappers around the C library.
- dz0ny/codec2_flutter (FFI), relrod/bindings-codec2 (Haskell FFI),
  JFF-Bohdan/qcodec2 (Qt wrapper), traud/asterisk-codec2 (transcoding module).
- mnasyrov/codec24net (.NET) — clone inspected: `Sources/Codec24Net/` is the
  (old) reference C source (kiss_fft.cpp, pack.cpp, lpc.cpp, …) compiled as a
  C++/CLI assembly; a recompile of the reference, not a rewrite. Skipped.

### Machine transpiles (noted, not deep-compared per instructions)

- rameshvarun/codec2-emscripten — C compiled to WASM via Emscripten.
- vdepedraza/codec2-js — Emscripten port of codec2 to JS.

### Other, out of scope

- ~100 forks of drowe67/codec2 (C) — the reference itself, not ports.
- philayres/Vocoder1300 (C, 1300 mode), lwvmobile/tiny-tones (C, uses
  libcodec2), santhiyaskumar/FPGA_Codec2Encoder (Verilog RTL) — not
  comparable hand-ports of 3200 logic in a high-level language.
- "Codec2 700C and FDM Modem in Native Java" (srsampson) — GitHub account/repos
  no longer resolvable via API (user 404); covers 700C, not 3200. Could not be
  cloned; noted as unavailable.
- No pure Python, C#, TypeScript, or Kotlin hand-reimplementation of the 3200
  mode was found (multiple searches; the Python and C# hits are all wrappers or
  reference-source recompiles).

Conclusion of inventory: **exactly one published hand port covers the 3200 mode
in a memory-safe language with any independence of expression (scriptjunkie
Rust), plus two mechanical translations (jcodec2 Java, c2-test C++) and one
2400-only Go translation.** All four were cloned into this directory and
compared.

---

## 2. Method

1. Identifier extraction (regex `[A-Za-z_][A-Za-z0-9_]{2,}`) from all Weebill
   Swift sources; intersection with each port's identifier set; subtraction of
   every token appearing anywhere in the spec repo (all .md + codebooks/) and
   of English/keyword noise.
2. Comment text extraction (`//`, `/* */`, doc comments) from Weebill and each
   port; 5-gram intersection; subtraction of spec-text 5-grams.
3. Magic-constant sweep: every numeric idiosyncrasy in Weebill checked against
   the spec first, then against ports.
4. Structural comparison: file split, function decomposition, API shape,
   state handling, PRNG, FFT choice, bit-packing design, CLI shape.

---

## 3. Findings per port

### 3.1 scriptjunkie/codec2 (Rust) — the only real 3200 candidate

- **Identifiers**: after removing spec terms and English noise, the
  intersection is 47 tokens, *all* of them either plain English
  ("Creates", "Returns", "combined", "refined") or spec-derived terms that the
  filter missed on case ("chebyshev", "beta", "gamma", "dlsp2…dlsp9" — the
  spec ships `codebooks/dlsp1.csv…dlsp10.csv`, cited in Weebill
  `Codebooks.swift:5`). **Zero** of the Rust port's distinctive names appear
  in Weebill: no `analyse_one_frame`, `hs_pitch_refinement`,
  `two_stage_pitch_refinement`, `est_voicing_mbe`, `ear_protection`,
  `MODEL`, `COMP`, `C2const`, `Sn`/`Sw`/`Fw`/`Pn` Hungarian-C names, no
  `codec2_rand`. Weebill's names (`Codec2Encoder.refinePitch`,
  `searchPeriod`, `voicingDecision`, `nlpPitch`, `overlapAdd`,
  `WoQuantiser`, `LSPDQuantiser`, `PhaseRandom`) appear in no port.
- **Comments**: 5-gram overlap after spec subtraction = 5 grams, all from one
  mathematical formula, P'(z) = P(z)/(1+z^-1), Q'(z) = Q(z)/(1-z^-1). That
  text is *in the spec* verbatim (algorithm.md:266–269, "P' and Q' are degree
  10 and symmetric, so six coefficients each suffice") and Weebill's comment
  (LPC.swift:99–100) tracks the spec wording, not the C/lsp.c wording; it
  survived the subtraction only because of unicode-minus vs ASCII
  normalisation. Classified **forced (spec text)**.
- **PRNG (discriminating idiosyncrasy)**: the Rust port reproduces the
  reference's LCG — `next*1103515245+12345`, `CODEC2_RAND_MAX: f32 = 32767.0`
  (quantise.rs:985–992). Weebill uses **SplitMix64** with seed
  0x2545F4914F6CDD1D (Decoder.swift:13–31), explicitly permitted to diverge by
  algorithm.md §7.3 ("any decent uniform PRNG is fine", quoted at
  Decoder.swift:10–12). A port-derived implementation would almost certainly
  have inherited the LCG. **Disconfirming.**
- **FFT (discriminating)**: Rust port ships a kiss_fft translation
  (kiss_fft.rs, `codec2_fftr`, `kf_cexp`). Weebill uses Apple vDSP behind its
  own `DFT512` wrapper (DFT512.swift), with scaling pinned to the spec's DFT
  convention. **Disconfirming.**
- **Bit packing**: Rust mirrors C's `pack_natural_or_gray(bits, &mut nbit, …)`
  free functions with a running `nbit` out-param. Weebill has `BitWriter`/
  `BitReader` structs with `writeField/readField` and Gray helpers
  `grayEncode/grayDecode` (Bitstream.swift) — different decomposition, and
  Gray decode is an unrolled shift-fold (`t ^= t>>4; t ^= t>>2; t ^= t>>1`,
  which bitstream.md §3 itself gives as "exactly this fold sequence") where
  the ports use the reference's loop. **Divergent.**
- **File/module structure**: Rust = one 2447-line lib.rs mirroring codec2.c
  plus nlp.rs/quantise.rs/codebook*.rs mirroring the C files. Weebill =
  Encoder / Decoder / LPC / LSP / Quantisers / Bitstream / Codebooks / DFT512,
  a decomposition matching the *spec's section structure* (each file header
  cites its algorithm.md/bitstream.md sections). **Divergent.**
- **API shape**: Rust `Codec2::new(Codec2Mode::MODE_3200)`,
  `encode(&mut bits, &samps)`, `samples_per_frame()` — a mirror of the C API.
  Weebill: single-mode `Codec2_3200` facade, value-returning
  `encode(_ pcm: [Int16]) -> [UInt8]` / `decode(_ frame: [UInt8]) -> [Int16]`,
  separate public `Codec2Encoder`/`Codec2Decoder`, `reset()`, a
  `nonFiniteSampleCount` diagnostic that exists in no port. **Divergent.**
- Weakest residual echo: weebill-cli's `enc|dec <in> <out>` verbs
  (weebill-cli/main.swift:3–4) superficially resemble the Rust crate's doc
  example (`(enc|dec) inputfile outputfilename`, lib.rs doc). But the spec
  itself names the reference tools `c2enc`/`c2dec` (conformance.md:10,
  vectors/README.md:5), making enc/dec the obvious spec-suggested verbs.
  Classified **forced/generic**.

**Verdict vs Rust port: no evidence of derivation; multiple independent
divergences at exactly the points where a derived work would converge.**

### 3.2 ggrandes jcodec2 (Java)

Mechanical translation preserving C identifiers (`codec2_encode_3200`,
`Jcodec2.codec2_rand()`, `CODEC2_RAND_MAX`, Jphase.java:179) and C banner
comments. Identifier intersection with Weebill after filtering: only English
words and spec terms (same list as Rust plus Java noise like `sampleRate`).
Comment 5-gram overlap: the same spec-covered P'/Q' formula only.
Class-per-C-file structure (Jnlp, Jlsp, Jlpc, Jpack, Jcodebookd…) unlike
Weebill's spec-sectioned split. The Java port keeps the C API
(`codec2_bits_per_frame`, mode constants `CODEC2_MODE_3200 = 0`,
Jcodec2.java:34); Weebill has none of it. **No evidence of derivation.**

### 3.3 n7tae/c2-test (C++)

A C→C++ transliteration of the reference with original Rowe comments intact
(e.g. codec2.cpp:2343 `float phi = TWO_PI*(float)codec2_rand()/CODEC2_RAND_MAX;`,
2369 "a continuous, non-random phase track", 2381 "made unvoiced by
randomising it's [sic] phases"). None of these comment strings, nor the C
identifiers, appear in Weebill; the 5-gram overlap is again only the
spec-covered polynomial formula. **No evidence of derivation.** (Comparing
against this port is nearly equivalent to comparing against the C reference —
which a separate audit at
`weebill/provenance/audit-report-2026-08-27.md` already covered.)

### 3.4 blues/codec2 (Go, 2400 mode only)

The most interesting *superficial* hits, because this port half-camelCases:
intersection contains `levinsonDurbin` (analyze.go:363 / LPC.swift:45),
`prevF0` (analyze.go:44, types.go:143 / Encoder.swift:55), `woMin`
(interp.go:8 / Quantisers.swift:13), `bestErr`/`bestIndex`
(quantize.go:361–373 / Quantisers.swift:130–135), `nearest`
(quantize.go:404–428 / Quantisers.swift:128), `mag2` (Decoder.swift:207).
Assessment: every one is the mechanical camelCase of a term that is in the
spec ("Levinson–Durbin", algorithm.md:215; the previous frame's F0;
"Wo_min", bitstream.md:84) or the universal idiom for a nearest-neighbour
search (`bestErr`, `nearest`). The Go port meanwhile keeps C names Weebill
lacks (`Sn`, `Sw`, `COMP`, `gmax_bin`, `interp_Wo`,
`postProcessSubMultiples`), does not implement the 3200 quantisers at all
(no 7-bit Wo scalar quantiser, no dlsp difference codebooks), and its
structure (analyze/synthesize/quantize/interp files with C function names)
does not match Weebill's. Classified **forced/coincidental naming; no
derivation signal**. Notably the Go decoder also inherits the C
`codec2_rand` behaviour via its own port — again unlike Weebill.

### 3.5 Beartooth/codec2-ios (Swift wrapper — API comparison only)

The one published *Swift* codec2 API, so the converse question matters most
here. Beartooth: `public class Codec2` with `Bitrate` enum
(`case _3200 = 0` mirroring the C mode integers), computed properties
`samplesPerFrame`/`bitsPerEncFrame` delegating to
`codec2_samples_per_frame(cPtr)`, UnsafeMutablePointer plumbing,
`withMemoryRebound` (Codec2.swift:28–65). Weebill: no mode enum, no pointer
plumbing, single-mode type named `Codec2_3200`, static `frameBytes`/
`frameSamples`, array-in/array-out methods. The only shared name is
`samplesPerFrame`, the inevitable Swift camelCase of the concept.
**No API-shape inheritance.**

---

## 4. Converse assessment: Weebill's idiom

Weebill reads as spec-first, not port-first:

- Every file opens with a spec citation header and nearly every constant,
  branch, and epsilon is annotated with its algorithm.md/bitstream.md section
  (e.g. Encoder.swift:1–4, 92–94; Quantisers.swift:60–63 quoting the spec's
  "deliberate asymmetry" note; LPC.swift:104–114 paraphrasing the spec's
  root-search discussion, including spec-only editorial content such as the
  qa-log Q7 reproducible-envelope caveat, LPC.swift:41–44 — text that exists
  in no port).
- Design choices with any freedom diverge from all ports simultaneously:
  SplitMix64 vs everyone's C LCG; vDSP vs everyone's kiss_fft; struct-based
  BitWriter/BitReader vs everyone's `pack(&nbit)`; value-returning API vs
  everyone's out-parameter C API; `Codec2Frame` as an Equatable/Sendable
  value type; a `nonFiniteSampleCount` observability hook found nowhere else.
- Where Weebill *is* identical to the ports, the spec is identical too: all
  shared magic constants (0.95 notch + 1.0 offset, 48-tap FIR, bins 16–128,
  0.8/1.2 window, 0.3/0.15 thresholds, 6.0 dB voicing, ±10/−4 dB eratio,
  β=0.2/γ=0.5, 1.96 bass boost, 0.032 low-pitch factor, 30000 quadratic
  limiter, 1e−4/1e−6/1e−12 seeds, nw=279, 0.01 scan step, exactly 6
  bisections) are pinned in algorithm.md/bitstream.md (verified line by line —
  e.g. algorithm.md:124, 126, 146, 393–406, 469–471, 299, 313). The spec is a
  bit-exact prose rewrite of the reference, so algorithm-level agreement with
  the C (and hence with every faithful port) is fully forced.

---

## 5. Candidate similarities, classified

| # | Observation | Weebill cite | Port cite | Class |
|---|---|---|---|---|
| 1 | P'/Q' polynomial comment wording | LPC.swift:99–102 | rust quantise.rs / Jlsp.java / c2-test (lsp.c comment) | **Forced** — verbatim in spec algorithm.md:266–269 |
| 2 | "ear protection" phrase in a comment | Decoder.swift:322 | rust lib.rs:2180 `ear_protection` | **Forced** — spec quotes it, algorithm.md:469 |
| 3 | `levinsonDurbin`, `prevF0`, `woMin`, `bestErr`, `nearest` | LPC.swift:45, Encoder.swift:55, Quantisers.swift:13,128–135 | blues go analyze.go:363,44; interp.go:8; quantize.go:361,419 | **Forced/coincidental** — camelCase of spec terms & universal idiom; Go port lacks the 3200 quantisers entirely |
| 4 | `samplesPerFrame` name | Decoder.swift:76 | Beartooth Codec2.swift:49 | **Forced** — inevitable Swift rendering of the spec concept |
| 5 | CLI `enc`/`dec` verbs | weebill-cli/main.swift:3–4 | rust lib.rs doc example | **Forced/generic** — spec names `c2enc`/`c2dec` (conformance.md:10) |
| 6 | `dlsp1…dlsp10` codebook naming | Codebooks.swift:5–30 | rust codebookd.rs / Jcodebookd.java | **Forced** — spec ships `codebooks/dlsp1.csv…dlsp10.csv` (bitstream.md:119) |

No candidate survived classification as unforced. In particular there is
**zero** overlap in: function decomposition, state-struct naming, C-heritage
identifiers (`Sn`, `Sw`, `Pn`, `MODEL`, `COMP`, `nbit`, `gmax`), C comment
prose, PRNG, FFT machinery, pack/unpack design, or API surface — the places
where each examined port visibly betrays its C ancestry.

---

## 6. Verdict

**Strongest evidence of derivation-from-a-port found: none that survives
scrutiny.** The single strongest raw signal was the blues/codec2 Go
identifier cluster (`levinsonDurbin`/`prevF0`/`woMin`/`bestErr`), and it
dissolves on inspection: each token is the mechanical camelCase of spec
terminology, the Go port doesn't even implement the 3200 mode being compared,
and Weebill diverges from that port everywhere expression is free.

**Overall assessment: no derivation from any published port is demonstrated,
and the evidence actively points the other way.** Every hand port examined
(Rust, Java, C++, Go) carries conspicuous C-reference fingerprints — the
1103515245 LCG, kiss_fft, `pack(&nbit)`, C identifier names, Rowe's original
comments — and Weebill contains none of them, choosing a different option at
every point of freedom (SplitMix64, vDSP, struct bit I/O, value-typed API,
spec-sectioned file layout). All remaining agreement is bit-exactness forced
by an unusually prescriptive spec. Caveat for completeness: absence of
textual fingerprints cannot *prove* the authors' models never saw the ports;
it proves only that no expressive content traceable to any published port —
the thing a contamination claim needs — is present in Weebill. One inventory
gap: srsampson's Java 700C repos are no longer publicly fetchable and cover a
different mode; they could not be compared.
