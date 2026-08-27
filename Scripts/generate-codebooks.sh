#!/bin/sh
# Code-generates Sources/Weebill/Codebooks.swift from the spec's
# codebooks/dlsp1.csv ... dlsp10.csv (bitstream.md §4.3).
#
# The generated file is checked in; the codec never reads files at runtime.
#
# Usage: Scripts/generate-codebooks.sh [path-to-spec-codebooks-dir]
set -eu

SPEC_DIR="${1:-../codec2-3200-spec/codebooks}"
OUT="$(dirname "$0")/../Sources/Weebill/Codebooks.swift"

{
  echo "// Codebooks.swift — GENERATED FILE, DO NOT EDIT BY HAND."
  echo "// Regenerate with Scripts/generate-codebooks.sh"
  echo "//"
  echo "// LSP-difference scalar quantiser tables, bitstream.md §4.3."
  echo "// Source: codec2-3200-spec/codebooks/dlsp1.csv ... dlsp10.csv."
  echo "// Values are in Hz; array position = natural-binary index (0...31)."
  echo ""
  echo "/// The ten 32-entry LSP-difference codebooks (bitstream.md §4.3)."
  echo "/// \`dlspCodebooks[i]\` is codebook i+1 in spec numbering, i.e. the"
  echo "/// table used for LSP difference d[i] (0-based i)."
  echo "public let dlspCodebooks: [[Double]] = ["
  for n in 1 2 3 4 5 6 7 8 9 10; do
    f="$SPEC_DIR/dlsp$n.csv"
    printf '    // dlsp%s.csv\n    [' "$n"
    awk -F, '/^[0-9]/ { printf "%s%s", (c++ ? ", " : ""), $2 }' "$f"
    echo "],"
  done
  echo "]"
  echo ""
  echo "/// 48-tap 600 Hz low-pass FIR used by the NLP pitch estimator"
  echo "/// (algorithm.md §3 step 3). Source: codebooks/nlp_fir48.csv."
  echo "/// Linear-phase (symmetric); applied at 8 kHz before decimation by 5."
  printf 'public let nlpFIR48: [Double] = ['
  awk -F, '/^[0-9]/ { printf "%s%s", (c++ ? ", " : ""), $2 }' "$SPEC_DIR/nlp_fir48.csv"
  echo "]"
} > "$OUT"

echo "wrote $OUT"
