// RobustnessTests.swift — M4 robustness, state safety and performance smoke
// tests. Covers conformance.md D1c (decoder robustness) and the encoder-side
// equivalents, plus bitstream.md §5's requirement that decoders accept any
// 64-bit pattern.

import XCTest
import Foundation
@testable import Weebill

/// A deterministic PRNG so every fuzz run is reproducible.
struct FuzzRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    mutating func byte() -> UInt8 { UInt8(next() & 0xff) }
    mutating func frame() -> [UInt8] { (0..<8).map { _ in byte() } }
}

/// Shared assertions for a decoded frame.
private func assertFrameSane(_ pcm: [Int16], _ context: @autoclosure () -> String) {
    XCTAssertEqual(pcm.count, 160, "frame length: \(context())")
    for v in pcm {
        XCTAssertTrue(v >= -32767 && v <= 32767, "sample \(v) out of range: \(context())")
    }
}

final class DecodeFuzzTests: XCTestCase {

    /// Number of random frames per fuzz test. Kept modest so the suite stays
    /// quick in a debug build; the full sweep (>100k frames, plus the
    /// structured corpora) is run against the release build via
    /// `Scripts/fuzz-run.sh` and reported.
    static let fuzzFrames = 6_000

    /// conformance.md D1c(a): 1000 frames of all-zero bytes.
    ///
    /// Note that "all-zero decodes as near-silence" (bitstream.md §5) is a
    /// statement about the *parameters* — unvoiced, Wo index 0, E index 0 —
    /// not about output amplitude. E index 0 is the −10 dB floor, but the
    /// synthesised level is carried by the LPC gain, so the output is
    /// audible: the reference's own `frames_zero` decode peaks around 12400.
    /// The bar is therefore stability and agreement with the reference
    /// vector, not smallness.
    func testThousandZeroFrames() throws {
        let codec = Codec2_3200()
        let zero = [UInt8](repeating: 0, count: 8)
        var out = [Int16]()
        for n in 0..<1000 {
            let pcm = codec.decode(zero)
            assertFrameSane(pcm, "zero frame \(n)")
            out.append(contentsOf: pcm)
        }
        XCTAssertEqual(codec.nonFiniteSampleCount, 0)

        // Level must match the reference decode of the same all-zero stream.
        let reference = try PCM.readRaw("frames_zero_refdec.raw")
        let delta = PCM.dB(PCM.rms(out)) - PCM.dB(PCM.rms(reference))
        XCTAssertLessThanOrEqual(abs(delta), 1.0,
                                 "all-zero level \(delta) dB vs reference decode")

        // And it must be stationary: no drift or ratcheting across 1000
        // frames of identical input.
        let firstTenth = PCM.dB(PCM.rms(out[0..<16_000]))
        let lastTenth = PCM.dB(PCM.rms(out[(out.count - 16_000)...]))
        XCTAssertLessThan(abs(lastTenth - firstTenth), 1.0,
                          "level drifted from \(firstTenth) to \(lastTenth) dB")
    }

    /// conformance.md D1c(b): 1000 frames of seeded-random bytes.
    func testThousandRandomFrames() {
        let codec = Codec2_3200()
        var rng = FuzzRandom(seed: 0xC0FFEE)
        for n in 0..<1000 {
            assertFrameSane(codec.decode(rng.frame()), "random frame \(n)")
        }
        XCTAssertEqual(codec.nonFiniteSampleCount, 0)
    }

    /// Large random-frame sweep. bitstream.md §5: "Decoders must accept any
    /// 64-bit pattern without error (all field values are in-range by
    /// construction)."
    func testLargeRandomFuzz() {
        let codec = Codec2_3200()
        var rng = FuzzRandom(seed: 0x5EED_1234)
        var peak: Int16 = 0
        var railed = 0
        for _ in 0..<DecodeFuzzTests.fuzzFrames {
            let pcm = codec.decode(rng.frame())
            XCTAssertEqual(pcm.count, 160)
            for v in pcm {
                guard v >= -32767 && v <= 32767 else {
                    return XCTFail("sample \(v) out of int16 range")
                }
                peak = max(peak, Int16(abs(Int(v))))
                if abs(Int(v)) >= 32767 { railed += 1 }
            }
        }
        XCTAssertEqual(codec.nonFiniteSampleCount, 0, "decoder produced NaN/Inf")
        // Output level must stay bounded: the §7.5 step 5 limiter caps the
        // synthesised signal, so railing should be rare even on garbage.
        let total = DecodeFuzzTests.fuzzFrames * 160
        XCTAssertLessThan(Double(railed) / Double(total), 0.01,
                          "\(railed)/\(total) samples at the rail")
    }

    /// Structured mutations rather than uniform noise: single-bit flips of a
    /// real speech frame explore the neighbourhood of valid bitstreams, where
    /// field combinations stay plausible and bugs are likelier to surface.
    func testSingleBitFlipsOfValidFrames() throws {
        let bits = try KAT.bytes("speech_arctic_bdl.c2bits")
        let codec = Codec2_3200()
        // Cover a spread of real frames, all 64 bit positions each.
        for frameIndex in stride(from: 0, to: min(200, bits.count / 8), by: 7) {
            let base = Array(bits[(frameIndex * 8)..<(frameIndex * 8 + 8)])
            for bit in 0..<64 {
                var mutated = base
                mutated[bit / 8] ^= UInt8(1 << (7 - (bit % 8)))
                assertFrameSane(codec.decode(mutated),
                                "frame \(frameIndex) bit \(bit)")
            }
        }
        XCTAssertEqual(codec.nonFiniteSampleCount, 0)
    }

    /// Degenerate and adversarial fixed patterns.
    func testStructuredExtremePatterns() {
        let patterns: [[UInt8]] = [
            [UInt8](repeating: 0x00, count: 8),
            [UInt8](repeating: 0xff, count: 8),
            [UInt8](repeating: 0xaa, count: 8),
            [UInt8](repeating: 0x55, count: 8),
            [0xff, 0x00, 0xff, 0x00, 0xff, 0x00, 0xff, 0x00],
            [0x00, 0xff, 0x00, 0xff, 0x00, 0xff, 0x00, 0xff],
            [0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
            [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01],
            [0xfe, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
        ]
        // Each pattern repeated, and the whole set cycled, to exercise state
        // transitions between wildly different parameter sets.
        let codec = Codec2_3200()
        for repetition in 0..<50 {
            for (i, p) in patterns.enumerated() {
                assertFrameSane(codec.decode(p), "pattern \(i) rep \(repetition)")
            }
        }
        XCTAssertEqual(codec.nonFiniteSampleCount, 0)

        // And each pattern in isolation from a fresh decoder.
        for (i, p) in patterns.enumerated() {
            let fresh = Codec2_3200()
            for _ in 0..<20 { assertFrameSane(fresh.decode(p), "isolated pattern \(i)") }
            XCTAssertEqual(fresh.nonFiniteSampleCount, 0)
        }
    }
}

final class EncodeRobustnessTests: XCTestCase {

    /// Adversarial encoder inputs: each must produce exactly 8 bytes per
    /// frame, never trap, and round-trip to finite bounded audio.
    func testAdversarialInputs() {
        let cases: [(String, (Int) -> Int16)] = [
            ("silence",            { _ in 0 }),
            ("positive full DC",   { _ in 32767 }),
            ("negative full DC",   { _ in -32767 }),
            ("int16 min DC",       { _ in Int16.min }),
            ("clipped square",     { n in (n / 20) % 2 == 0 ? 32767 : -32767 }),
            ("alternating rail",   { n in n % 2 == 0 ? 32767 : -32767 }),
            ("impulse train",      { n in n % 80 == 0 ? 32767 : 0 }),
            ("dense impulses",     { n in n % 3 == 0 ? 30000 : 0 }),
            ("dc offset speech",   { n in Int16(clamping: 16000 + Int(8000.0 * sin(Double(n) * 0.05))) }),
            ("ramp",               { n in Int16(clamping: (n * 37) % 65536 - 32768) })
        ]

        for (name, generator) in cases {
            let encoder = Codec2_3200()
            let decoder = Codec2_3200()
            var peak = 0
            for f in 0..<60 {
                let pcm = (0..<160).map { generator(f * 160 + $0) }
                let frame = encoder.encode(pcm)
                XCTAssertEqual(frame.count, 8, "\(name): frame size")

                // Fields must be in range by construction (bitstream.md §5).
                let fields = Codec2Frame.unpack(frame)
                XCTAssertTrue((0...127).contains(fields.woIndex), "\(name): Wo index")
                XCTAssertTrue((0...31).contains(fields.eIndex), "\(name): E index")
                for d in fields.lspdIndices {
                    XCTAssertTrue((0...31).contains(d), "\(name): LSP index")
                }

                let out = decoder.decode(frame)
                assertFrameSane(out, name)
                for v in out { peak = max(peak, abs(Int(v))) }
            }
            XCTAssertEqual(decoder.nonFiniteSampleCount, 0, "\(name): NaN/Inf")
            XCTAssertLessThanOrEqual(peak, 32767, "\(name): output level unbounded")
        }
    }

    /// Encoding must be robust to abrupt transitions between adversarial
    /// inputs, which is where analysis state (NLP memories, buffers) is most
    /// likely to misbehave.
    func testAbruptInputTransitions() {
        let encoder = Codec2_3200()
        let decoder = Codec2_3200()
        var rng = FuzzRandom(seed: 99)
        for f in 0..<300 {
            let mode = f % 5
            let pcm: [Int16] = (0..<160).map { n in
                switch mode {
                case 0: return 0
                case 1: return 32767
                case 2: return n % 2 == 0 ? 32767 : -32767
                case 3: return Int16(clamping: Int(rng.byte()) * 256 - 32768)
                default: return Int16(clamping: Int(8000.0 * sin(Double(f * 160 + n) * 0.31)))
                }
            }
            let frame = encoder.encode(pcm)
            XCTAssertEqual(frame.count, 8)
            assertFrameSane(decoder.decode(frame), "transition frame \(f) mode \(mode)")
        }
        XCTAssertEqual(decoder.nonFiniteSampleCount, 0)
    }

    /// The NaN-absorbing clamps in the quantisers (bitstream.md §4.1, §4.2)
    /// must yield in-range indices rather than trapping in `Int(_:)`.
    func testQuantisersAbsorbDegenerateInputs() {
        for bad in [Double.nan, .infinity, -.infinity, 1e308, -1e308] {
            let wo = WoQuantiser.encode(bad)
            XCTAssertTrue((0...127).contains(wo), "Wo index \(wo) for \(bad)")
            let e = EnergyQuantiser.encode(bad)
            XCTAssertTrue((0...31).contains(e), "E index \(e) for \(bad)")
        }
        // Energy is 10·log10(E), so non-positive E must also stay in range
        // (qa-log.md Q1).
        for bad in [0.0, -1.0, -1e30] {
            XCTAssertTrue((0...31).contains(EnergyQuantiser.encode(bad)))
        }
    }
}

final class StateSafetyTests: XCTestCase {

    /// Separate instances must not share state: interleaving two unrelated
    /// streams frame by frame must give exactly the same bytes as decoding
    /// each stream on its own (algorithm.md §8 — one instance per stream).
    func testInterleavedDecodeStreamsAreIndependent() throws {
        let a = try KAT.bytes("speech_arctic_bdl.c2bits")
        let b = try KAT.bytes("noise_1s.c2bits")
        let frames = min(a.count, b.count) / 8

        func decodeAlone(_ bits: [UInt8], _ n: Int) -> [Int16] {
            let codec = Codec2_3200(phaseSeed: 4242)
            var out = [Int16]()
            for f in 0..<n { out.append(contentsOf: codec.decode(Array(bits[(f * 8)..<(f * 8 + 8)]))) }
            return out
        }
        let soloA = decodeAlone(a, frames)
        let soloB = decodeAlone(b, frames)

        let codecA = Codec2_3200(phaseSeed: 4242)
        let codecB = Codec2_3200(phaseSeed: 4242)
        var interleavedA = [Int16](), interleavedB = [Int16]()
        for f in 0..<frames {
            interleavedA.append(contentsOf: codecA.decode(Array(a[(f * 8)..<(f * 8 + 8)])))
            interleavedB.append(contentsOf: codecB.decode(Array(b[(f * 8)..<(f * 8 + 8)])))
        }
        XCTAssertEqual(interleavedA, soloA, "stream A changed when interleaved")
        XCTAssertEqual(interleavedB, soloB, "stream B changed when interleaved")
    }

    /// The same, for the encoder.
    func testInterleavedEncodeStreamsAreIndependent() throws {
        let a = try PCM.readRaw("speech_arctic_bdl.raw")
        let b = try PCM.readRaw("noise_1s.raw")
        let frames = min(a.count, b.count) / 160

        func encodeAlone(_ pcm: [Int16], _ n: Int) -> [UInt8] {
            let codec = Codec2_3200()
            var out = [UInt8]()
            for f in 0..<n { out.append(contentsOf: codec.encode(Array(pcm[(f * 160)..<(f * 160 + 160)]))) }
            return out
        }
        let soloA = encodeAlone(a, frames)
        let soloB = encodeAlone(b, frames)

        let codecA = Codec2_3200(), codecB = Codec2_3200()
        var ia = [UInt8](), ib = [UInt8]()
        for f in 0..<frames {
            ia.append(contentsOf: codecA.encode(Array(a[(f * 160)..<(f * 160 + 160)])))
            ib.append(contentsOf: codecB.encode(Array(b[(f * 160)..<(f * 160 + 160)])))
        }
        XCTAssertEqual(ia, soloA, "encoder stream A changed when interleaved")
        XCTAssertEqual(ib, soloB, "encoder stream B changed when interleaved")
    }

    /// `reset()` must restore the algorithm.md §0 initial state bit-exactly,
    /// for both directions, even after adversarial traffic in between.
    func testResetRestoresInitialBehaviourBitExactly() throws {
        let bits = try KAT.bytes("speech_arctic_bdl.c2bits")
        let pcm = try PCM.readRaw("speech_arctic_bdl.raw")

        let codec = Codec2_3200(phaseSeed: 31337)
        func decodeRun() -> [Int16] {
            var out = [Int16]()
            for f in 0..<80 { out.append(contentsOf: codec.decode(Array(bits[(f * 8)..<(f * 8 + 8)]))) }
            return out
        }
        func encodeRun() -> [UInt8] {
            var out = [UInt8]()
            for f in 0..<80 { out.append(contentsOf: codec.encode(Array(pcm[(f * 160)..<(f * 160 + 160)]))) }
            return out
        }

        let decodeFirst = decodeRun()
        let encodeFirst = encodeRun()

        // Pollute the state thoroughly.
        var rng = FuzzRandom(seed: 7)
        for _ in 0..<500 { _ = codec.decode(rng.frame()) }
        for _ in 0..<500 { _ = codec.encode((0..<160).map { _ in Int16(bitPattern: UInt16(rng.next() & 0xffff)) }) }

        codec.reset()
        XCTAssertEqual(decodeRun(), decodeFirst, "reset() did not restore decoder state")
        XCTAssertEqual(encodeRun(), encodeFirst, "reset() did not restore encoder state")
    }
}

final class PerformanceSmokeTests: XCTestCase {

    /// Resident memory must not grow with the number of frames processed:
    /// the codec allocates per frame but must not accumulate.
    func testNoUnboundedMemoryGrowth() throws {
        let bits = try KAT.bytes("speech_arctic_bdl.c2bits")
        let pcm = try PCM.readRaw("speech_arctic_bdl.raw")
        let codec = Codec2_3200()

        func residentBytes() -> Int {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size
                                               / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? Int(info.resident_size) : 0
        }

        func work(_ frames: Int) {
            for f in 0..<frames {
                let i = f % (bits.count / 8)
                _ = codec.decode(Array(bits[(i * 8)..<(i * 8 + 8)]))
                let j = f % (pcm.count / 160)
                _ = codec.encode(Array(pcm[(j * 160)..<(j * 160 + 160)]))
            }
        }

        work(1500)                                  // warm up allocators
        let before = residentBytes()
        work(9_000)
        let after = residentBytes()
        try XCTSkipIf(before == 0, "task_info unavailable")

        let growthMB = Double(after - before) / (1024 * 1024)
        XCTAssertLessThan(growthMB, 8.0,
                          "resident memory grew \(growthMB) MB over 9k frames")
    }

    /// Real-time factor smoke test: processing must be far faster than real
    /// time. The sustained measurement over 60 s of audio is run against the
    /// release build and reported separately; this guards against a
    /// catastrophic regression in the debug/CI build.
    func testRealTimeFactorIsWellUnderOne() throws {
        let bits = try KAT.bytes("speech_arctic_bdl.c2bits")
        let codec = Codec2_3200()
        let frames = 500                             // 10 s of audio
        let start = Date()
        for f in 0..<frames {
            let i = f % (bits.count / 8)
            _ = codec.decode(Array(bits[(i * 8)..<(i * 8 + 8)]))
        }
        let elapsed = Date().timeIntervalSince(start)
        let audioSeconds = Double(frames) * 0.02
        let rtf = elapsed / audioSeconds
        XCTAssertLessThan(rtf, 1.0, "decode RTF \(rtf) (debug build)")
    }
}
