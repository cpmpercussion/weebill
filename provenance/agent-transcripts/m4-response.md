# M3 close-out + M4 implementer response — received 2026-08-26

Highlights (full text in session transcript archive). Spec-side final
sweep: run_conformance.py ALL — OVERALL PASS (D1a/b/c, E1a speech,
E1b, E1d all green; independent swift test re-run green).

- swift test: 67 tests, 0 failures (13 new M4 robustness tests).
- Levinson–Durbin per revised §6 step 2; clamp written NaN-safely.
- E1b final: voicing/Wo±2/E±1 = 100/100/100 (bdl), 100/100/99.8 (slt);
  bit-exact frames 95.2%/91.3%; fallbacks 0/0 (49/49 silence, matching ref).
- E1d tone: 0 fallbacks, single line at 390.6 Hz (identical to ref),
  ripple 0.072 dB, no NaN/rail issues; level +6.27 dB (no bar per E1d).
- Fuzz: 178,806 decode frames (uniform random, all single-bit flips of
  every bdl frame, structured extremes, fresh-instance runs) — 0 NaN/Inf,
  all in int16, 0.0038% rail hits (limiter working).
- Encode robustness: full-scale/DC/impulse/random inputs all clean.
- State safety: instance isolation and reset() bit-exact.
- Perf (release, M-series Mac): encode RTF 0.00191, decode 0.00090,
  combined 356× real time; memory growth 0.031 MB over 200k frames.
- Bug found by M4 fuzzing and fixed: WoQuantiser.encode trapped on NaN
  ω₀ (Int(_:) conversion); clamps now absorb NaN/±inf. Unreachable from
  in-contract input.
- Release housekeeping: README.md, NOTICE (clean-room methodology + AI
  implementer disclosure + codebook interop rationale), doc comments,
  c2fuzz target + Scripts/fuzz-run.sh (fixed seeds, reproducible).
- QA questions: none.
