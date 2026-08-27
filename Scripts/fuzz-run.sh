#!/bin/sh
# Out-of-band M4 runs against the release build: the large decode fuzz sweep
# and the sustained real-time-factor measurement.
#
# The in-suite tests (Tests/WeebillTests/RobustnessTests.swift) cover the
# same ground at smaller counts so `swift test` stays quick; this script is
# the one whose numbers get reported.
#
# Usage: Scripts/fuzz-run.sh [path-to-spec-vectors-dir]
set -eu

VECTORS="${1:-../codec2-3200-spec/vectors}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release
exec .build/release/c2fuzz "$VECTORS"
