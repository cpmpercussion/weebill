// ArcticFieldsKATTests.swift — conformance.md §B1 `arctic_bdl_fields.csv`:
// the first 25 frames of speech_arctic_bdl.c2bits unpacked to field indices
// and decoded Wo/E. Ties the bitstream layer to a real reference stream.

import XCTest
@testable import Weebill

final class ArcticFieldsKATTests: XCTestCase {

    func testArcticBDLFields() throws {
        let stream = try KAT.bytes("speech_arctic_bdl.c2bits")
        XCTAssertEqual(stream.count % Codec2Frame.frameBytes, 0,
                       "bitstream.md §5: stream is whole 8-byte frames")

        let rows = try KAT.rows("arctic_bdl_fields.csv")
        XCTAssertEqual(rows.count, 25, "expected 25 reference frames")

        for row in rows {
            let n = Int(row[0])!
            let start = n * Codec2Frame.frameBytes
            let frameBytes = Array(stream[start..<(start + Codec2Frame.frameBytes)])
            let f = Codec2Frame.unpack(frameBytes)

            XCTAssertEqual(f.v1, Int(row[1])!, "frame \(n) v1")
            XCTAssertEqual(f.v2, Int(row[2])!, "frame \(n) v2")
            XCTAssertEqual(f.woIndex, Int(row[3])!, "frame \(n) Wo index")
            XCTAssertEqual(f.eIndex, Int(row[4])!, "frame \(n) E index")
            XCTAssertEqual(f.lspdIndices, KAT.ints(row[5]), "frame \(n) LSP indices")

            // Decoded parameters, bitstream.md §4.1 / §4.2.
            let woExpected = Double(row[6])!
            XCTAssertEqual(WoQuantiser.decode(f.woIndex), woExpected,
                           accuracy: 1e-6, "frame \(n) decoded Wo")
            let eExpected = Double(row[7])!
            XCTAssertEqual(EnergyQuantiser.decode(f.eIndex) / eExpected, 1.0,
                           accuracy: 1e-4, "frame \(n) decoded E")

            // Repacking the unpacked fields must reproduce the reference bytes.
            XCTAssertEqual(f.packed(), frameBytes, "frame \(n) repack identity")
        }
    }

    /// Every frame of the real reference bitstream must repack identically
    /// (bitstream.md §3, §5), not just the 25 covered by the KAT.
    func testWholeArcticStreamRepacks() throws {
        let stream = try KAT.bytes("speech_arctic_bdl.c2bits")
        let frames = stream.count / Codec2Frame.frameBytes
        XCTAssertGreaterThan(frames, 100)
        for n in 0..<frames {
            let start = n * Codec2Frame.frameBytes
            let b = Array(stream[start..<(start + Codec2Frame.frameBytes)])
            XCTAssertEqual(Codec2Frame.unpack(b).packed(), b, "frame \(n)")
        }
    }
}
