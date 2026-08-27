# M3 implementer prompt — sent 2026-08-26

Continuation of the same clean implementer agent. Sent verbatim as below.

---

Gate result: M2 PASSES. Spec-side D1 run (official harness): bdl SD 3.36 dB / segSNR 26.4 dB; slt SD 3.10 dB / segSNR 28.3 dB; levels ±0.00 dB; tone peak bin identical; 1000-frame zero/random robustness ok. Your PRNG-floor calibration was confirmed on our side (reference decoder is run-to-run deterministic; conformance.md D1a has been revised to SD ≤ 4.0 dB AND segSNR ≥ 15 dB AND level ±1 dB, calibration documented). Your §7.1 P/Q and §7.2 interpretation calls are accepted and logged in qa-log.md.

Proceed to **Milestone M3 — encoder**, same rules as before (spec files only — you may re-read the updated conformance.md and qa-log.md; nothing outside the permitted list; no web; no memory of any codec2 implementation; stop and ask on ambiguity; cite spec sections).

## Task

Implement the full encoder per the brief's M3 scope: analysis window/DFT, NLP pitch estimation (codebooks/nlp_fir48.csv is the FIR table — add it to the generator), pitch refinement, harmonic analysis, voicing decision, LPC order-10 analysis with lag windowing, LPC→LSP, quantisation (Wo/E/LSP-diff — you already have the laws), packing (you already have it).

Deliverables:

1. Working `Codec2_3200.encode(_ pcm: [Int16]) -> [UInt8]`, stateful per spec.
2. `weebill-cli enc <in.raw> <out.c2bits>` working.
3. Self-iteration loop, in this order:
   a. Unit tests for the analysis primitives testable from the spec (window properties, LPC on synthetic AR signals, LPC→LSP→LPC round-trip against your M2 LSP→LPC, NLP on pure tones with known F0).
   b. Encode the vectors' `.raw` files and compare your bitstream's parameter tracks against the reference `.c2bits` (you have both, and your M1 unpacker): per conformance.md E1b the targets are voicing agreement ≥ 90%, Wo index within ±2 on ≥ 90% of both-voiced frames, E index within ±1 on ≥ 95% of frames. Iterate until you meet them on both speech stems.
   c. Round-trip check: your encoder → your decoder sounds/levels sane on all vectors (tone stays a tone at the right pitch, speech level ≈ input processing chain).
4. All previous tests stay green.

The official E1 gate (reference decoder on your bitstreams, E1a/E1c listening) runs on our side after you report.

Expect this milestone's difficulty to be the pitch estimator and voicing decision — follow algorithm.md exactly, including every truncation-vs-rounding call-out; the E1b track comparison is diagnostic (a systematic Wo offset means a binning/rounding detail, scattered voicing disagreements near thresholds are expected).

## Report format (final message)

1. STATUS: swift test summary; your E1b track-agreement numbers per speech stem; round-trip observations.
2. FILES: created/changed.
3. QA QUESTIONS: spec ambiguities (empty if none).
4. NOTES: anything the harness should know.

Stop after M3 and report. M4 (fuzzing/perf) comes next.
