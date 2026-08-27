# M3 implementer response — received 2026-08-26

Verbatim highlights of the M3 continuation report (full text in session
transcript archive). Spec-side E1 run confirms: E1b PASS on both speech
stems (voicing 100%, Wo±2 100%, E±1 100%/99.8%); E1a speech PASS
(refdec(testbits) vs refdec(refbits): bdl SD 3.48 dB / level −0.02 dB,
slt SD 3.93 dB / level −0.21 dB); tone400 FAILS E1a at −7.78 dB — blocked
on Q5.

- swift test: 52 tests, 0 failures (18 M1 + 16 M2 + 18 M3).
- bdl 89.4% bit-exact frames, slt 81.7%; only Wo deltas anywhere: −1 (bdl, 1 frame), −2 (noise, 1 frame).
- Silence path bit-exact vs reference (confirms Q1 E<=0 → index 0).
- Encoder RTF ≈ 0.004.
- Files: LPC.swift, Encoder.swift, EncoderTests.swift; nlpFIR48 added to codebook generator; weebill-cli enc implemented.

## QA raised

**Q5**: algorithm.md §6's 0.01 cos-domain grid cannot resolve LSP root
pairs the reference transmits (gaps down to ~0.006); no autocorrelation
conditioning (e.g. lag windowing) is specified though the milestone text
mentioned it. Evidence: 88/88 fallback frames have reference LSP pairs
closer than the grid step; tone LSPs at 375/400/425/450 Hz; k2=0.99966 on
tone (near-singular R). Implementer correctly declined to guess.
→ Routed to a contaminated-side spec-author agent for an algorithm.md
revision (see m3b-spec-revision-*).

**Q6**: §0 lacks initial values for NLP DC-notch/FIR memories and squared
buffer; implementer assumed zeros. → Same spec revision round.

Other interpretations logged: §5.2 rule ordering immaterial (conditions
mutually exclusive); §4 L recomputed per stage from stage-start period.
