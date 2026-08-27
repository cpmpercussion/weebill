# M3 follow-up prompt (post Q5/Q6 spec revision) — sent 2026-08-26

Continuation of the clean implementer agent. Sent verbatim as below.

---

Q5 and Q6 are answered as spec revisions. Re-read algorithm.md §0, §6 (step 4 and the fully rewritten step 5), §8 and §9, plus the new qa-log.md entries. Headlines: there is NO autocorrelation conditioning to add — your near-singular R observation is expected behaviour; the fix is in the root search, which §6 step 5 now specifies completely (alternating per-polynomial scans re-anchored at each found root, with bisection refinement). §0/§8 now pin the NLP initial state; your zeros assumption was correct, no change needed there.

Task: bring your LPC→LSP root finder into line with the revised §6 step 5, keep everything else as is, and re-run your full loop:
1. All previous tests stay green (52 tests).
2. Fallback-rate check: with the revised search you should fall back on ~0% of bdl/slt/tone400 frames (silence stays ~49/50, matching the reference).
3. E1b track comparison on both speech stems (targets unchanged).
4. Round-trip levels: tone400 through your enc→your dec should now come out near the reference chain's 61.9 dB (the 7.8 dB deficit should vanish).

Report in the same format (STATUS/FILES/QA QUESTIONS/NOTES). Stop after that; M4 next.

## Q7 routing (m3d) — sent 2026-08-26

Q7 forwarded verbatim to the contaminated spec-author agent with
instructions to instrument the reference on tone400_1s.raw, identify the
analysis-chain difference (buffer alignment, pre-processing, precision,
post-conversion LSP handling, or search anchoring), and answer as a spec
revision or an accepted-divergence ruling in qa-log.md.
