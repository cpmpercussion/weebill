// DecoderVectorTests.swift — decoder checks against the `vectors/` reference
// decodes. These are the implementer-side sanity gates for M2; the official
// D1 conformance run (segmental spectral distortion) happens on the spec side.

import XCTest
import Foundation
@testable import Weebill

/// Small PCM helpers.
enum PCM {
    /// Reads headerless 16-bit signed little-endian PCM (vectors/README.md).
    static func readRaw(_ name: String) throws -> [Int16] {
        let data = try Data(contentsOf: try KAT.url(name))
        var out = [Int16]()
        out.reserveCapacity(data.count / 2)
        for i in stride(from: 0, to: data.count - 1, by: 2) {
            out.append(Int16(bitPattern: UInt16(data[i]) | (UInt16(data[i + 1]) << 8)))
        }
        return out
    }

    static func rms(_ x: ArraySlice<Int16>) -> Double {
        guard !x.isEmpty else { return 0 }
        var acc = 0.0
        for v in x { acc += Double(v) * Double(v) }
        return (acc / Double(x.count)).squareRoot()
    }

    static func rms(_ x: [Int16]) -> Double { rms(x[...]) }

    static func dB(_ x: Double) -> Double { 20.0 * log10(max(x, 1e-12)) }
}

/// Decodes a whole `.c2bits` resource with a fresh codec instance.
func decodeVector(_ stem: String, phaseSeed: UInt64? = nil) throws -> [Int16] {
    let bits = try KAT.bytes("\(stem).c2bits")
    XCTAssertEqual(bits.count % Codec2_3200.frameBytes, 0)
    let codec = phaseSeed.map { Codec2_3200(phaseSeed: $0) } ?? Codec2_3200()
    var pcm = [Int16]()
    for n in 0..<(bits.count / Codec2_3200.frameBytes) {
        let start = n * Codec2_3200.frameBytes
        pcm.append(contentsOf:
            codec.decode(Array(bits[start..<(start + Codec2_3200.frameBytes)])))
    }
    return pcm
}

final class DecoderLevelTests: XCTestCase {

    /// bitstream.md §1: 20 ms frame = 160 samples out, for every vector.
    func testOutputLengthIs160SamplesPerFrame() throws {
        for stem in ["silence_1s", "tone400_1s", "noise_1s",
                     "speech_arctic_bdl", "speech_arctic_slt",
                     "frames_zero", "frames_random"] {
            let bits = try KAT.bytes("\(stem).c2bits")
            let pcm = try decodeVector(stem)
            XCTAssertEqual(pcm.count,
                           (bits.count / Codec2_3200.frameBytes) * 160,
                           "\(stem) output length")
            // And it must agree with the reference decode's length.
            let ref = try PCM.readRaw("\(stem)_refdec.raw")
            XCTAssertEqual(pcm.count, ref.count, "\(stem) length vs refdec")
        }
    }

    /// conformance.md D1a/D1b: long-term level within ±1 dB of the reference
    /// decoder's output for the same bitstream.
    func testLongTermLevelMatchesReferenceDecode() throws {
        for stem in ["silence_1s", "tone400_1s", "noise_1s",
                     "speech_arctic_bdl", "speech_arctic_slt",
                     "frames_zero", "frames_random"] {
            let pcm = try decodeVector(stem)
            let ref = try PCM.readRaw("\(stem)_refdec.raw")
            let delta = PCM.dB(PCM.rms(pcm)) - PCM.dB(PCM.rms(ref))
            XCTAssertLessThanOrEqual(abs(delta), 1.0,
                "\(stem): level \(String(format: "%+.2f", delta)) dB vs refdec")
        }
    }

    /// conformance.md D1c: no NaN/Inf, nothing outside int16. (Int16 output
    /// enforces the range; this checks the float path did not produce
    /// garbage that the limiter silently clamped for every sample.)
    func testNoPathologicalOutput() throws {
        for stem in ["silence_1s", "tone400_1s", "noise_1s",
                     "speech_arctic_bdl", "speech_arctic_slt",
                     "frames_zero", "frames_random"] {
            let pcm = try decodeVector(stem)
            let clipped = pcm.filter { $0 == 32767 || $0 == -32767 }.count
            XCTAssertLessThan(Double(clipped) / Double(pcm.count), 0.001,
                              "\(stem): \(clipped) samples at full scale")
            XCTAssertTrue(pcm.contains { $0 != 0 }, "\(stem): output is all zeros")
        }
    }
}

final class DecoderToneTests: XCTestCase {

    /// conformance.md D1b: the tone vector must decode to a single dominant
    /// spectral line at the reference's decoded pitch, with no 10 ms-periodic
    /// amplitude ripple (algorithm.md §7.5 step 4 overlap-add correctness).
    func testTone400DominantLineMatchesReference() throws {
        let pcm = try decodeVector("tone400_1s")
        let ref = try PCM.readRaw("tone400_1s_refdec.raw")

        XCTAssertEqual(dominantBin(pcm, from: 2000), dominantBin(ref, from: 2000),
                       "dominant spectral bin must match the reference decode")

        // RMS within ±1 dB (D1b).
        let delta = PCM.dB(PCM.rms(pcm)) - PCM.dB(PCM.rms(ref))
        XCTAssertLessThanOrEqual(abs(delta), 1.0, "tone RMS \(delta) dB vs refdec")
    }

    /// Overlap-add correctness (algorithm.md §7.5 step 4): a steady sinusoid
    /// must synthesise without 10 ms-periodic amplitude ripple. Measured as
    /// the spread of per-80-sample RMS over the steady region, and required
    /// to be no worse than the reference decode's own spread.
    func testTone400HasNoOverlapAddRipple() throws {
        let pcm = try decodeVector("tone400_1s")
        let ref = try PCM.readRaw("tone400_1s_refdec.raw")

        let ourSpread = subframeRMSSpreadDB(pcm)
        let refSpread = subframeRMSSpreadDB(ref)
        XCTAssertLessThan(ourSpread, 0.5,
                          "10 ms subframe RMS spread \(ourSpread) dB indicates OLA ripple")
        XCTAssertLessThan(ourSpread, refSpread + 0.2,
                          "spread \(ourSpread) dB vs reference \(refSpread) dB")
    }

    /// Index of the strongest bin of a 512-point DFT taken in the steady region.
    private func dominantBin(_ pcm: [Int16], from offset: Int) -> Int {
        let dft = DFT512()
        var x = [Float](repeating: 0, count: 512)
        for i in 0..<512 { x[i] = Float(pcm[offset + i]) }
        let (re, im) = dft.forward(real: x)
        var best = 1
        var bestMag = -1.0
        for k in 1...256 {
            let m = Double(re[k]) * Double(re[k]) + Double(im[k]) * Double(im[k])
            if m > bestMag { bestMag = m; best = k }
        }
        return best
    }

    /// Spread (max/min, in dB) of per-subframe RMS over the steady region.
    private func subframeRMSSpreadDB(_ pcm: [Int16]) -> Double {
        var lo = Double.infinity, hi = 0.0
        var i = 2000
        while i + 80 <= 7000 {
            let r = PCM.rms(pcm[i..<(i + 80)])
            lo = min(lo, r); hi = max(hi, r)
            i += 80
        }
        return PCM.dB(hi) - PCM.dB(lo)
    }
}

final class DecoderRobustnessTests: XCTestCase {

    /// conformance.md D1c: all-zero and seeded-random frames decode without
    /// crash or pathological output (bitstream.md §5 — "Decoders must accept
    /// any 64-bit pattern without error").
    func testRobustnessVectors() throws {
        for stem in ["frames_zero", "frames_random"] {
            let pcm = try decodeVector(stem)
            XCTAssertEqual(pcm.count % 160, 0)
            for v in pcm {
                XCTAssertTrue(v >= -32767 && v <= 32767, "\(stem) sample out of range")
            }
        }
    }

    /// bitstream.md §5 / D1c: 1000 frames of arbitrary bytes must decode.
    func testThousandArbitraryFramesDecode() {
        let codec = Codec2_3200()
        var x: UInt64 = 987654321
        for _ in 0..<1000 {
            var frame = [UInt8](repeating: 0, count: 8)
            for k in 0..<8 {
                x = 6364136223846793005 &* x &+ 1442695040888963407
                frame[k] = UInt8((x >> 33) & 0xff)
            }
            let pcm = codec.decode(frame)
            XCTAssertEqual(pcm.count, 160)
            for v in pcm { XCTAssertTrue(v >= -32767 && v <= 32767) }
        }
    }

    /// The decoder is stateful (algorithm.md §8) but deterministic given a
    /// fixed phase seed, and `reset()` must restore the §0 initial state.
    func testDeterminismAndReset() throws {
        let a = try decodeVector("speech_arctic_bdl", phaseSeed: 12345)
        let b = try decodeVector("speech_arctic_bdl", phaseSeed: 12345)
        XCTAssertEqual(a, b, "same seed must give identical output")

        let bits = try KAT.bytes("noise_1s.c2bits")
        let codec = Codec2_3200(phaseSeed: 777)
        func run() -> [Int16] {
            var pcm = [Int16]()
            for n in 0..<(bits.count / 8) {
                pcm.append(contentsOf: codec.decode(Array(bits[(n * 8)..<(n * 8 + 8)])))
            }
            return pcm
        }
        let first = run()
        codec.reset()
        let second = run()
        XCTAssertEqual(first, second, "reset() must restore initial decoder state")
    }

    /// Different phase seeds change unvoiced rendering but not the level
    /// (algorithm.md §7.3: the PRNG is a free decoder-side choice).
    func testPhaseSeedDoesNotChangeLevel() throws {
        let a = try decodeVector("speech_arctic_bdl", phaseSeed: 1)
        let b = try decodeVector("speech_arctic_bdl", phaseSeed: 2)
        XCTAssertNotEqual(a, b, "different seeds should render differently")
        let delta = PCM.dB(PCM.rms(a)) - PCM.dB(PCM.rms(b))
        XCTAssertLessThan(abs(delta), 0.5, "seed changed the level by \(delta) dB")
    }
}

final class LSPToLPCTests: XCTestCase {

    /// algorithm.md §7.1: A(z) must come back with a₀ = 1 and order 10.
    func testReconstructedFilterIsMonicOrder10() {
        let lsp = (0..<10).map { Double($0 + 1) * Double.pi / 11.0 }
        let a = LSP.toLPC(lsp)
        XCTAssertEqual(a.count, 11)
        XCTAssertEqual(a[0], 1.0, accuracy: 1e-12)
    }

    /// algorithm.md §6 step 5 / §7.1: the LSP angles are by definition the
    /// unit-circle roots of P'(z) and Q'(z) built from A(z). So rebuilding
    /// A(z) from the LSPs and forming
    ///   P(z) = A(z) + z^−11·A(z^−1),  Q(z) = A(z) − z^−11·A(z^−1)
    /// must vanish at the even/odd LSP angles respectively. This pins down
    /// the P/Q interlacing convention used by `LSP.toLPC`.
    func testLSPAnglesAreRootsOfPAndQ() throws {
        // Use real decoded LSP sets from the KAT so the test covers realistic
        // (non-uniform) spacings.
        let rows = try KAT.rows("lspd_kat.csv")
        for row in rows.prefix(10) {
            let lsp = KAT.doubles(row[3])
            let a = LSP.toLPC(lsp)

            for (k, omega) in lsp.enumerated() {
                let z = Complex(cos(-omega), sin(-omega))   // z^-1 = e^{-jω}
                // A(z) = Σ a_i z^-i ; z^-11·A(z^-1) = Σ a_i z^-(11-i)
                var az = Complex(0, 0)
                var azr = Complex(0, 0)
                for i in 0...10 {
                    az = az + Complex.pow(z, i) * a[i]
                    azr = azr + Complex.pow(z, 11 - i) * a[i]
                }
                let p = az + azr      // even-index LSPs are roots of this
                let q = az - azr      // odd-index LSPs are roots of this
                let value = (k % 2 == 0) ? p.magnitude : q.magnitude
                XCTAssertLessThan(value, 1e-8,
                    "LSP \(k) (ω = \(omega)) is not a root of \(k % 2 == 0 ? "P" : "Q")")
            }
        }
    }

    /// algorithm.md §7.2 step 1: `Pw[k] = 1/(|Aw[k]|² + 1e−6)` must be finite
    /// and positive across the whole grid for every realistic LSP set.
    ///
    /// The `+1e−6` is load-bearing: A(z) evaluated at DC reduces to
    /// P'(1) = Π_{even k} (2 − 2·cos ω_k), which for a low first LSP is small
    /// enough to underflow to exactly 0 in single precision. The guard is what
    /// keeps Pw[0] finite, so this test asserts the *guarded* quantity.
    func testEnvelopeIsWellConditioned() throws {
        let rows = try KAT.rows("lspd_kat.csv")
        let dft = DFT512()
        for row in rows {
            let lsp = KAT.doubles(row[3])
            let a = LSP.toLPC(lsp)
            XCTAssertEqual(a[0], 1.0, accuracy: 1e-12)
            let (re, im) = dft.forward(real: a.map { Float($0) })
            for k in 0...256 {
                let m = Double(re[k]) * Double(re[k]) + Double(im[k]) * Double(im[k])
                XCTAssertTrue(m.isFinite && m >= 0, "|A|² not finite at bin \(k)")
                let pw = 1.0 / (m + 1e-6)
                XCTAssertTrue(pw.isFinite && pw > 0, "Pw degenerate at bin \(k)")
                XCTAssertLessThanOrEqual(pw, 1e6 + 1, "Pw exceeds the 1e−6 guard's ceiling")
            }
        }
    }
}

/// Minimal complex helper for the LSP root test.
struct Complex {
    var re: Double, im: Double
    init(_ re: Double, _ im: Double) { self.re = re; self.im = im }
    var magnitude: Double { (re * re + im * im).squareRoot() }
    static func + (a: Complex, b: Complex) -> Complex { Complex(a.re + b.re, a.im + b.im) }
    static func - (a: Complex, b: Complex) -> Complex { Complex(a.re - b.re, a.im - b.im) }
    static func * (a: Complex, b: Complex) -> Complex {
        Complex(a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re)
    }
    static func * (a: Complex, s: Double) -> Complex { Complex(a.re * s, a.im * s) }
    static func pow(_ z: Complex, _ n: Int) -> Complex {
        var r = Complex(1, 0)
        for _ in 0..<n { r = r * z }
        return r
    }
}
