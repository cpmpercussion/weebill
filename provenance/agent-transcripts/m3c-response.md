# M3 follow-up response (post Q5/Q6 revision) — received 2026-08-26

Verbatim highlights of the clean implementer's report:

- swift test: 54 tests, 0 failures (2 new re-anchoring regression tests).
- Fallback rates now 0/498 (bdl), 0/515 (slt), 0/50 (tone), 49/50
  (silence) — all matching the reference exactly.
- E1b: voicing 100/100, Wo±2 100/100, E±1 100/99.8 (bdl/slt).
- Bit-exact frames: bdl 95.2%, slt 91.3%, noise 98%. LSP mean |Δ| 0.010.
- Round-trip levels: bdl −0.00 dB, slt −0.01 dB, noise +0.05, silence
  +0.23; tone400 now +6.27 dB (was −7.78) — residual raised as Q7.
- Q7: on the near-singular tone frame the implementation's LPC yields a
  structurally different (higher-Q) root set than the reference
  transmits; implementer ruled out single-precision (would cause
  fallbacks the reference doesn't have) and γ sweep; declined to tune.
  Routed to contaminated spec agent (m3d).
- silence Wo index 4 vs ref 3 (inert unvoiced field), noted.
