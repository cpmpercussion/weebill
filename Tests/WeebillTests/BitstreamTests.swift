// BitstreamTests.swift — conformance.md §B1 packing KAT plus the
// spec-derivable self-tests (Gray round-trip, 64-bit repack identity).
// Implements checks against bitstream.md §3.

import XCTest
@testable import Weebill

final class FramePackKATTests: XCTestCase {

    /// conformance.md §B1 `frame_pack_kat.csv`: natural-binary field tuples
    /// -> 8-byte frame hex, exact. Exercises Gray coding + MSB-first packing
    /// (bitstream.md §3).
    func testFramePackKAT() throws {
        let rows = try KAT.rows("frame_pack_kat.csv")
        XCTAssertGreaterThan(rows.count, 0)

        for row in rows {
            let caseID = row[0]
            let frame = Codec2Frame(v1: Int(row[1])!,
                                    v2: Int(row[2])!,
                                    woIndex: Int(row[3])!,
                                    eIndex: Int(row[4])!,
                                    lspdIndices: KAT.ints(row[5]))
            let expectedHex = row[6].lowercased()

            let packed = frame.packed()
            XCTAssertEqual(packed.count, 8)
            XCTAssertEqual(KAT.hex(packed), expectedHex, "pack, case \(caseID)")

            // And unpacking the reference hex must recover the same fields.
            var bytes = [UInt8]()
            var i = expectedHex.startIndex
            while i < expectedHex.endIndex {
                let j = expectedHex.index(i, offsetBy: 2)
                bytes.append(UInt8(expectedHex[i..<j], radix: 16)!)
                i = j
            }
            XCTAssertEqual(Codec2Frame.unpack(bytes), frame, "unpack, case \(caseID)")
        }
    }
}

final class BitstreamSelfTests: XCTestCase {

    /// conformance.md §B1 self-test: Gray pack/unpack round-trip for all
    /// field widths 1–7 and all values. bitstream.md §3.
    func testGrayRoundTripAllWidthsAllValues() {
        for width in 1...7 {
            for value in 0..<(1 << width) {
                let g = grayEncode(UInt32(value))
                XCTAssertLessThan(g, UInt32(1 << width),
                                  "Gray code must fit the field width")
                XCTAssertEqual(Int(grayDecode(g)), value,
                               "gray round-trip width \(width) value \(value)")
            }
        }
    }

    /// bitstream.md §3: successive Gray codes differ in exactly one bit.
    func testGrayIsUnitDistance() {
        for width in 1...7 {
            for value in 1..<(1 << width) {
                let a = grayEncode(UInt32(value - 1))
                let b = grayEncode(UInt32(value))
                XCTAssertEqual((a ^ b).nonzeroBitCount, 1,
                               "width \(width), \(value - 1)->\(value)")
            }
        }
    }

    /// Round-trip through the writer/reader for every width 1–7 and value.
    func testFieldWriteReadRoundTrip() {
        for width in 1...7 {
            for value in 0..<(1 << width) {
                var w = BitWriter(byteCapacity: 1)
                w.writeField(value, width: width)
                var r = BitReader(w.bytes)
                XCTAssertEqual(r.readField(width: width), value,
                               "field round-trip width \(width) value \(value)")
            }
        }
    }

    /// conformance.md §B1 self-test: any 64-bit pattern unpacks and repacks
    /// identically. bitstream.md §5 — all field values are in range by
    /// construction, so no pattern may be rejected.
    func testAnyPatternRepacksIdentically() {
        var patterns: [[UInt8]] = [
            [UInt8](repeating: 0x00, count: 8),
            [UInt8](repeating: 0xff, count: 8),
            [0xaa, 0x55, 0xaa, 0x55, 0xaa, 0x55, 0xaa, 0x55],
            [0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01]
        ]
        // Every single-bit pattern.
        for bit in 0..<64 {
            var b = [UInt8](repeating: 0, count: 8)
            b[bit / 8] = UInt8(1 << (7 - (bit % 8)))
            patterns.append(b)
        }
        // A deterministic pseudo-random sweep (LCG, no external deps).
        var x: UInt64 = 12345
        for _ in 0..<5000 {
            var b = [UInt8](repeating: 0, count: 8)
            for k in 0..<8 {
                x = 6364136223846793005 &* x &+ 1442695040888963407
                b[k] = UInt8((x >> 33) & 0xff)
            }
            patterns.append(b)
        }

        for p in patterns {
            let f = Codec2Frame.unpack(p)
            XCTAssertEqual(f.packed(), p, "repack identity for \(KAT.hex(p))")
            // Field ranges, bitstream.md §2.
            XCTAssertTrue((0...1).contains(f.v1))
            XCTAssertTrue((0...1).contains(f.v2))
            XCTAssertTrue((0...127).contains(f.woIndex))
            XCTAssertTrue((0...31).contains(f.eIndex))
            XCTAssertEqual(f.lspdIndices.count, 10)
            for d in f.lspdIndices { XCTAssertTrue((0...31).contains(d)) }
        }
    }

    /// bitstream.md §5: the all-zero frame is unvoiced/unvoiced, Wo index 0,
    /// E index 0 (≈ −10 dB), all LSP indices 0.
    func testAllZeroFrameSemantics() {
        let f = Codec2Frame.unpack([UInt8](repeating: 0, count: 8))
        XCTAssertEqual(f.v1, 0)
        XCTAssertEqual(f.v2, 0)
        XCTAssertEqual(f.woIndex, 0)
        XCTAssertEqual(f.eIndex, 0)
        XCTAssertEqual(f.lspdIndices, [Int](repeating: 0, count: 10))
        XCTAssertEqual(EnergyQuantiser.decode(f.eIndex), 0.1, accuracy: 1e-9)
    }

    /// bitstream.md §3 layout table: check the field boundaries directly by
    /// setting one Gray-coded field at a time to all-ones and confirming
    /// which bits move.
    func testFieldBitPositions() {
        // Wo occupies bits 2..8 (byte 0 bits 5..0, byte 1 bit 7).
        // Gray index 127 -> g = 127 ^ 63 = 64 = 1000000b.
        let f = Codec2Frame(v1: 0, v2: 0, woIndex: 127, eIndex: 0,
                            lspdIndices: [Int](repeating: 0, count: 10))
        XCTAssertEqual(KAT.hex(f.packed()), "2000000000000000")

        // E occupies bits 9..13. Gray index 31 -> 31 ^ 15 = 16 = 10000b,
        // so only bit 9 is set: byte 1 bit 6 -> 0x40.
        let g = Codec2Frame(v1: 0, v2: 0, woIndex: 0, eIndex: 31,
                            lspdIndices: [Int](repeating: 0, count: 10))
        XCTAssertEqual(KAT.hex(g.packed()), "0040000000000000")

        // d10 occupies the last 5 bits (bits 59..63).
        var d = [Int](repeating: 0, count: 10)
        d[9] = 31
        let h = Codec2Frame(v1: 0, v2: 0, woIndex: 0, eIndex: 0, lspdIndices: d)
        XCTAssertEqual(KAT.hex(h.packed()), "0000000000000010")

        // v1 and v2 are the top two bits of byte 0.
        let v = Codec2Frame(v1: 1, v2: 1, woIndex: 0, eIndex: 0,
                            lspdIndices: [Int](repeating: 0, count: 10))
        XCTAssertEqual(KAT.hex(v.packed()), "c000000000000000")
    }
}
