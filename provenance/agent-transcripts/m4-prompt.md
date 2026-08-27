# M3 close-out + M4 prompt — sent 2026-08-26

Continuation of the clean implementer agent. Sent verbatim as below.

---

Q7 is resolved. Re-read algorithm.md §6 step 2 (Levinson–Durbin now written out in full, including the reflection-coefficient clamp whose effect is a stage no-op with aᵢ = 0 — on rank-deficient frames this silently reduces the effective model order and is the normal outcome, not an error path), §6 step 6 (nothing is applied to LSPs between conversion and quantisation; the 375/400/425/450 "ladder" you compared against was the 25 Hz difference-codebook floor, not computed LSPs — your first four roots actually agree with the reference's unquantised values), §9 (new "cannot match, by construction" paragraph), conformance.md (E1a now speech-only; new E1d gives the tonal-stem bar: no NaN/Inf/overflow, 0 LSP fallbacks, single steady line with no OLA ripple, pitch within one Wo step — NO level bar), and qa-log.md Q7 (the divergence you found is real float indeterminacy: the reference recompiled at a different optimisation level disagrees with its own shipped tone bitstream on 49/50 frames).

Tasks, in order:

1. **M3 close-out**: bring your Levinson–Durbin into line with the revised §6 step 2 (implement the clamp exactly as specified). Do not otherwise tune anything toward the tone number — E1d is the bar now. Re-run your loop; confirm speech E1b/round-trip figures hold and tone meets E1d's implementer-side checks (0 fallbacks; your-chain output is a single steady line, no ripple, pitch within one Wo step of the reference chain's).

2. **Milestone M4 — robustness & performance**, per the brief:
   - Decode robustness: 1000 all-zero frames, 1000 seeded-random frames, plus a fuzz run (≥ 100k random 8-byte frames through decode, mixed with structured mutations: single-bit flips of a valid speech frame, all-ones, alternating patterns). Assert: no crash, no NaN/Inf, output always in int16, bounded output level.
   - Encode robustness: full-scale ±32767 input (clipped square), DC-offset input, impulse train, alternating ±full-scale, silence — no crash/NaN, output always 8 bytes/frame, and round-trip through your decoder stays finite and bounded.
   - State safety: interleaving decode of unrelated streams on separate instances gives identical results to running them separately (no shared state); reset() restores initial behaviour bit-exactly.
   - Performance: sustained RTF for encode and decode on this Mac (release build), measured over ≥ 60 s of looped speech, reported; plus a rough allocation check (no per-frame heap growth).
   - Add these as tests where practical (fuzz test can use a fixed seed and a smaller count in CI-mode, with the big run done once and reported).
   - Housekeeping for release: README.md for the package (what it is, API, clean-room methodology one-liner pointing to NOTICE), NOTICE file per implementer-brief (methodology statement: spec-only clean-room, AI implementer caveat, codebook tables reproduced as interoperability data), and doc comments on the public API.

Report in the usual format. This should complete M4; the spec side then runs the final full conformance sweep.
