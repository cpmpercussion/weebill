# M1 implementer response — received 2026-08-26

Verbatim final report of the M1 implementer agent (claude-opus, fresh
context). Spec-side verification: `swift test` re-run independently by the
orchestrator — 18 tests, 0 failures. Gate M1: PASS.

---

M1 is complete and green on the first run.

## 1. STATUS

`swift test` — **18 tests, 0 failures**, 0.12 s. Clean build, no warnings.

| B1 item | Test | Result |
|---|---|---|
| `wo_kat.csv` | `WoKATTests.testWoKAT` (128 decode @ 1e-6, all encode cases exact) | pass |
| `e_kat.csv` | `EnergyKATTests.testEnergyKAT` (32 decode @ 1e-4 rel, encode exact) | pass |
| `lspd_kat.csv` | `LSPDKATTests.testLSPDKAT` (25 vectors, indices exact, LSPs @ 1e-5 rad) | pass |
| `frame_pack_kat.csv` | `FramePackKATTests.testFramePackKAT` (40 cases, hex exact, plus reverse unpack) | pass |
| `arctic_bdl_fields.csv` | `ArcticFieldsKATTests.testArcticBDLFields` (25 frames vs real `.c2bits`) | pass |

Self-tests (all pass): Gray round-trip for every width 1-7 and every value; Gray unit-distance property; writer/reader field round-trip; repack identity over ~5070 patterns (all-zero, all-ones, alternating, all 64 single-bit, 5000 LCG-random); all-zero frame semantics per §5; direct field-boundary checks against the §3 layout table; whole 498-frame `speech_arctic_bdl.c2bits` unpack->repack identity; LSP-diff idempotence (encode->decode->encode stable, the quantised-cumulative trap); tie-to-lowest-index; codebook shape 10x32.

## 2. FILES

- Package.swift, LICENSE (BSD-2-Clause), .gitignore, Scripts/generate-codebooks.sh
- Sources/Weebill/{Bitstream,Quantisers,Codebooks}.swift (Codebooks generated, checked in)
- Tests/WeebillTests/{KATSupport,BitstreamTests,QuantiserKATTests,ArcticFieldsKATTests}.swift
- Tests/WeebillTests/Resources/ — copies of the five vectors/kat/*.csv plus speech_arctic_bdl.c2bits

Zero dependencies; only Foundation. Codebooks are compiled in — no runtime file access.

## 3. QA QUESTIONS

None. bitstream.md §3-§5 was unambiguous enough to implement without guessing, and every law matched the KATs on the first run. Two minor points I resolved from the spec text rather than asking, flagged here for the record in case the spec side wants them made explicit:

- §4.2 does not define behaviour for E <= 0 (log10 of zero/negative). I treat -inf as clamping to index 0 and NaN as index 0, consistent with the §4.2 clamp. This will matter for the silence vector in M3; if the reference does something else at the encoder side, say so then.
- §4.1's round = floor(x+0.5) is applied before clamping, including for negative x. The wo_kat and e_kat encode cases confirm this ordering.

## 4. NOTES FOR M2

- Public surface: grayEncode/grayDecode, BitWriter, BitReader, Codec2Frame (packed()/unpack(_:)), Codec2Constants, WoQuantiser, EnergyQuantiser, LSPDQuantiser, dlspCodebooks. The Codec2_3200 class is not created yet — lands in M2/M3.
- The weebill-cli target is deferred to M2.
- codebooks/nlp_fir48.csv unused in M1 (M3 encoder table).
- Regenerating tables: Scripts/generate-codebooks.sh /path/to/codec2-3200-spec/codebooks.
- Observed from arctic_bdl_fields.csv: frames 0-2 carry E index 0 (~ -10 dB floor) while marked voiced/voiced; if M2 shows level problems at onsets this is a spec-side calibration question.
