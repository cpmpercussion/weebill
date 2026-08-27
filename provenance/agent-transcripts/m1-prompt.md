# M1 implementer prompt — sent 2026-08-26

Agent: fresh general-purpose agent (claude-opus), no prior context.
Sent verbatim as below.

---

You are the clean-side implementer in a documented clean-room reimplementation of a speech codec. You are working FROM SPECIFICATION ONLY.

## Non-negotiable rules

1. Your ONLY permitted inputs are these files (absolute paths):
   - /Users/charles/src/3200bps-speech-codec/codec2-3200-spec/bitstream.md
   - /Users/charles/src/3200bps-speech-codec/codec2-3200-spec/algorithm.md
   - /Users/charles/src/3200bps-speech-codec/codec2-3200-spec/conformance.md
   - /Users/charles/src/3200bps-speech-codec/codec2-3200-spec/implementer-brief.md
   - /Users/charles/src/3200bps-speech-codec/codec2-3200-spec/qa-log.md
   - /Users/charles/src/3200bps-speech-codec/codec2-3200-spec/codebooks/*.csv
   - /Users/charles/src/3200bps-speech-codec/codec2-3200-spec/vectors/ (all files, including vectors/kat/)
2. Do NOT read, list, search, or open ANYTHING else in /Users/charles/src/3200bps-speech-codec/ — in particular never touch reference/, PLAN.md, tools/, or provenance/. Do not search the web. Do not consult, or reproduce from memory, the source code of codec2 or any port/translation of it in any language. If you believe you recall how a reference implementation codes something, set that recollection aside and follow the spec.
3. If the spec is ambiguous, incomplete, or appears wrong: STOP and ask. Return your question(s) as your final report under a heading "QA QUESTIONS". Do not guess at what a reference implementation "probably does".
4. Cite the spec in code: every non-trivial function carries a comment naming the spec section it implements (e.g. `// bitstream.md §3.2`).

## Your workspace

Create the Swift package at /Users/charles/src/3200bps-speech-codec/weebill/ (directory exists, empty). You may read/write freely there and run swift build / swift test.

## Task: Milestone M1 — bitstream layer

Read implementer-brief.md first, then bitstream.md fully. Deliver, per the brief:

- SwiftPM package, name Weebill, BSD-2-Clause LICENSE. Library target + test target. Dependencies: Swift stdlib and Apple system frameworks only.
- M1 scope: Gray coding, MSB-first bit packing/unpacking of the 64-bit frame, the three quantiser laws (Wo, energy, LSP difference quantisers), codebook tables compiled in (code-generate from the codebooks/*.csv into Swift source — no runtime file loading).
- Unit tests: all self-tests conformance.md §B1 describes, plus KAT tests driven by the files in vectors/kat/ (embed or copy the CSVs into the test target's resources — copying vector files into your package is permitted).
- Everything must pass under `swift test` on macOS. Iterate until green.

## Report format (your final message)

1. STATUS: pass/fail of each B1 KAT (wo_kat, e_kat, lspd_kat, frame_pack_kat, arctic_bdl_fields) and the self-tests, with `swift test` summary output.
2. FILES: list of files you created.
3. QA QUESTIONS: any spec ambiguities encountered (empty if none).
4. NOTES: anything the spec-side harness should know before M2.

Do not proceed to M2 (decoder DSP). Stop after M1 passes and report.
