# M2 implementer prompt — sent 2026-08-26

Continuation of the same clean implementer agent (claude-opus). Sent verbatim as below.

---

Gate result: M1 PASSES. The spec side independently re-ran `swift test`: 18 tests, 0 failures. Your two flagged points are logged; treat your resolutions (E<=0 → index 0; round-before-clamp) as accepted spec interpretations for now.

Proceed to **Milestone M2 — decoder**, under exactly the same rules as before (spec files only; never read anything else under /Users/charles/src/3200bps-speech-codec/ outside codec2-3200-spec/{bitstream,algorithm,conformance,implementer-brief,qa-log}.md, codebooks/, vectors/; no web; no memory of any codec2 implementation; stop and ask when the spec is ambiguous; cite spec sections in code).

## Task

Read algorithm.md fully (you have not needed it until now). Implement the full decoder per the brief's M2 scope: index decode + interpolation across 10 ms subframes, LSP→LPC, harmonic magnitudes from the LPC spectrum, energy scaling, postfilter, phase synthesis, sinusoidal synthesis with overlap-add.

Deliverables this milestone:

1. `Codec2_3200` public class with the working `decode(_ frame: [UInt8]) -> [Int16]` (encode may `fatalError("M3")` for now), stateful per the spec.
2. The `weebill-cli` executable target: `weebill-cli dec <in.c2bits> <out.raw>` (raw 16-bit LE PCM @ 8 kHz, consecutive 8-byte frames, as vectors/README.md describes). `weebill-cli enc` may exit with an error for now.
3. Unit tests you can run yourself, in the order the brief suggests: the algorithm.md §7.5 step 3 inverse-DFT identity test FIRST (verify your vDSP wrapper scaling), then decode `silence_1s.c2bits` and `tone400_1s.c2bits` and sanity-check against the corresponding `_refdec.raw` files in vectors/ (you have them — RMS level within ±1 dB, tone shows a clean 400 Hz-region line, no NaN/Inf, output length = 160 samples/frame), then the speech vectors (decode without crash, plausible level).
4. Keep all M1 tests green.

You may compute your own rough comparison metrics against the `_refdec.raw` files to iterate quickly. The official D1 gate (segmental spectral distortion via the spec-side harness) is run on our side after you report; you'll get metric output back.

Accelerate/vDSP is expected and permitted for FFTs.

## Report format (final message)

1. STATUS: swift test summary; your own decode-vs-refdec level/sanity numbers per vector.
2. FILES: created/changed.
3. QA QUESTIONS: spec ambiguities (empty if none).
4. NOTES: anything the harness should know (e.g. PRNG choices for unvoiced phases).

Stop after M2 and report. Do not start the encoder.
