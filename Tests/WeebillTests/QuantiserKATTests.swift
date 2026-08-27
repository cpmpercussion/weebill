// QuantiserKATTests.swift — conformance.md §B1 known-answer tests for the
// three quantiser laws (bitstream.md §4.1, §4.2, §4.3).

import XCTest
@testable import Weebill

final class WoKATTests: XCTestCase {

    /// conformance.md §B1 `wo_kat.csv`: all 128 indices -> decoded ω₀
    /// (match to 1e-6), plus encode cases ω₀ -> index (exact).
    func testWoKAT() throws {
        let rows = try KAT.rows("wo_kat.csv")
        var decodeCases = 0, encodeCases = 0

        for row in rows {
            let direction = row[0]
            switch direction {
            case "decode":
                let index = Int(row[1])!
                let expected = Double(row[2])!
                let got = WoQuantiser.decode(index)
                XCTAssertEqual(got, expected, accuracy: 1e-6,
                               "wo decode index \(index)")
                decodeCases += 1
            case "encode":
                let wo = Double(row[1])!
                let expected = Int(row[2])!
                XCTAssertEqual(WoQuantiser.encode(wo), expected,
                               "wo encode \(wo)")
                encodeCases += 1
            default:
                XCTFail("unexpected direction \(direction) in wo_kat.csv")
            }
        }
        XCTAssertEqual(decodeCases, 128, "expected all 128 indices covered")
        XCTAssertGreaterThan(encodeCases, 0)
    }

    /// bitstream.md §4.1: encode clamps to [0, 127].
    func testWoEncodeClamps() {
        XCTAssertEqual(WoQuantiser.encode(0.0), 0)
        XCTAssertEqual(WoQuantiser.encode(-1.0), 0)
        XCTAssertEqual(WoQuantiser.encode(10.0), 127)
    }

    /// bitstream.md §4.1: `L = floor(π / Wo)`.
    func testHarmonicCount() {
        XCTAssertEqual(WoQuantiser.harmonicCount(wo: 0.1), 31)          // π/0.1 = 31.4159
        XCTAssertEqual(WoQuantiser.harmonicCount(wo: Double.pi / 20), 20)
        // Across the whole quantiser range L stays within (π/Wo_max, π/Wo_min].
        for i in 0..<128 {
            let l = WoQuantiser.harmonicCount(wo: WoQuantiser.decode(i))
            XCTAssertGreaterThanOrEqual(l, 9)
            XCTAssertLessThanOrEqual(l, 80)
        }
    }
}

final class EnergyKATTests: XCTestCase {

    /// conformance.md §B1 `e_kat.csv`: decode to 1e-4 relative, encode exact.
    func testEnergyKAT() throws {
        let rows = try KAT.rows("e_kat.csv")
        var decodeCases = 0, encodeCases = 0

        for row in rows {
            switch row[0] {
            case "decode":
                let index = Int(row[1])!
                let expected = Double(row[2])!
                let got = EnergyQuantiser.decode(index)
                XCTAssertEqual(got / expected, 1.0, accuracy: 1e-4,
                               "e decode index \(index): got \(got) want \(expected)")
                decodeCases += 1
            case "encode":
                let e = Double(row[1])!
                let expected = Int(row[2])!
                XCTAssertEqual(EnergyQuantiser.encode(e), expected,
                               "e encode \(e)")
                encodeCases += 1
            default:
                XCTFail("unexpected direction \(row[0]) in e_kat.csv")
            }
        }
        XCTAssertEqual(decodeCases, 32, "expected all 32 indices covered")
        XCTAssertGreaterThan(encodeCases, 0)
    }

    /// bitstream.md §4.2: index 0 is the −10 dB floor.
    func testEnergyFloorAndClamp() {
        XCTAssertEqual(EnergyQuantiser.decode(0), 0.1, accuracy: 1e-9)
        XCTAssertEqual(EnergyQuantiser.encode(1e-30), 0)
        XCTAssertEqual(EnergyQuantiser.encode(1e30), 31)
    }
}

final class LSPDKATTests: XCTestCase {

    /// conformance.md §B1 `lspd_kat.csv`: 25 LSP vectors -> 10 indices (exact)
    /// and decoded LSPs (1e-5 rad). bitstream.md §4.3.
    func testLSPDKAT() throws {
        let rows = try KAT.rows("lspd_kat.csv")
        XCTAssertEqual(rows.count, 25, "expected 25 LSP KAT vectors")

        for row in rows {
            let caseID = row[0]
            let lspIn = KAT.doubles(row[1])
            let expectedIdx = KAT.ints(row[2])
            let expectedOut = KAT.doubles(row[3])
            XCTAssertEqual(lspIn.count, 10)
            XCTAssertEqual(expectedIdx.count, 10)
            XCTAssertEqual(expectedOut.count, 10)

            let idx = LSPDQuantiser.encode(lsp: lspIn)
            XCTAssertEqual(idx, expectedIdx, "lspd indices, case \(caseID)")

            let out = LSPDQuantiser.decode(indices: expectedIdx)
            for i in 0..<10 {
                XCTAssertEqual(out[i], expectedOut[i], accuracy: 1e-5,
                               "lspd decoded lsp[\(i)], case \(caseID)")
            }
        }
    }

    /// bitstream.md §4.3: differences accumulate against the *quantised*
    /// running sum, so encode->decode->encode is a fixed point and the
    /// decoder never drifts. (The brief's #2 interop trap.)
    func testQuantisedCumulativeIsIdempotent() throws {
        let rows = try KAT.rows("lspd_kat.csv")
        for row in rows {
            let lspIn = KAT.doubles(row[1])
            let idx1 = LSPDQuantiser.encode(lsp: lspIn)
            let dec = LSPDQuantiser.decode(indices: idx1)
            let idx2 = LSPDQuantiser.encode(lsp: dec)
            XCTAssertEqual(idx1, idx2, "re-encoding decoded LSPs must be stable")
        }
    }

    /// bitstream.md §4.3 step 3: ties resolve to the lowest index.
    func testTieResolvesToLowestIndex() {
        // dlsp1 is uniform 25 Hz steps; 37.5 Hz is exactly between entries
        // 0 (25 Hz) and 1 (50 Hz) -> must choose index 0.
        let cb = dlspCodebooks[0]
        XCTAssertEqual(cb[0], 25.0)
        XCTAssertEqual(cb[1], 50.0)
        XCTAssertEqual(LSPDQuantiser.nearest(37.5, in: cb), 0)
    }

    /// The compiled-in tables must be 10 codebooks of 32 entries (§4.3).
    func testCodebookShape() {
        XCTAssertEqual(dlspCodebooks.count, 10)
        for (i, cb) in dlspCodebooks.enumerated() {
            XCTAssertEqual(cb.count, 32, "codebook \(i + 1) size")
        }
    }
}
