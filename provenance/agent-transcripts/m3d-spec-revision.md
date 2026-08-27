# Q7 spec revision / ruling — 2026-08-26

Contaminated spec-author agent (same as m3b) instrumented an unmodified
rebuild of the reference source and ruled on Q7. Findings (its words,
abridged; no C excerpts):

1. Reference's effective LPC order on the tone is 8: Levinson-Durbin
   stages 9-10 produce |k|>1 and are zeroed by the reflection-coefficient
   clamp (a9=a10=0). §6 step 2 under-specified this; now written out in
   full with clamp semantics and order-reduction consequence.
2. The 375/400/425/450 Hz "ladder" is the 25 Hz difference-codebook
   floor, not the computed LSPs; reference's unquantised LSPs agree with
   the implementation's on the first four. Confirmed nothing is applied
   to LSPs between conversion and quantisation (§6 step 6 added).
3. Divergence above LSP 4 is single-precision indeterminacy: the
   reference recompiled at -O0 differs from its own shipped bitstream on
   49/50 tone frames (decoded level Δ −3.29 dB) and 0.6%/3.7% of
   bdl/slt frames. §9 gains a "cannot match, by construction" paragraph
   with the measured compiler-variance floor.
4. conformance.md rev 2: E1a scoped to speech; new E1d for tonal stems
   (structural checks only, no level bar). qa-log.md Q7 entry added.
   Copied-expression self-review done (textbook Makhoul notation).
