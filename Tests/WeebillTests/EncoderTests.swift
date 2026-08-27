// EncoderTests.swift — unit tests for the analysis primitives of
// algorithm.md §2 (window/DFT), §3 (NLP), §6 (LPC, LSP), plus end-to-end
// encoder behaviour.

import XCTest
import Foundation
@testable import Weebill

final class AnalysisWindowTests: XCTestCase {

    /// algorithm.md §2.1: nw = 279 raised-cosine occupying buffer indices
    /// 21…298, zero elsewhere.
    func testWindowSupport() {
        let w = Codec2Encoder.makeWindow()
        XCTAssertEqual(w.count, 320)
        for i in 0..<21 { XCTAssertEqual(w[i], 0, "w[\(i)] must be zero") }
        for i in 299..<320 { XCTAssertEqual(w[i], 0, "w[\(i)] must be zero") }
        // 21 + 277 = 298 is the last nonzero sample.
        XCTAssertGreaterThan(w[298], 0)
        XCTAssertEqual(w[21], 0, accuracy: 1e-18, "j = 0 gives 0.5 − 0.5·cos(0) = 0")
    }

    /// algorithm.md §2.1: "normalise so that Σ w² · N_dft = 1".
    func testWindowNormalisation() {
        let w = Codec2Encoder.makeWindow()
        var energy = 0.0
        for v in w { energy += v * v }
        XCTAssertEqual(energy * 512.0, 1.0, accuracy: 1e-12)
    }

    /// algorithm.md §2.1: the window is *very slightly asymmetric* because
    /// the denominator is nw−1 = 278 while j only reaches 277 — reproduced
    /// as written, so the peak is not exactly at the centre.
    func testWindowIsSlightlyAsymmetricAsSpecified() {
        let w = Codec2Encoder.makeWindow()
        // Shape check against the defining formula (up to the normalisation).
        let scale = w[21 + 139] / (0.5 - 0.5 * cos(2.0 * Double.pi * 139.0 / 278.0))
        for j in 0...277 {
            let want = scale * (0.5 - 0.5 * cos(2.0 * Double.pi * Double(j) / 278.0))
            XCTAssertEqual(w[21 + j], want, accuracy: 1e-15, "w[21+\(j)]")
        }
        // The asymmetry: the mirror of the first sample is not the last one.
        XCTAssertNotEqual(w[21], w[298], "window would be symmetric if j reached 278")
    }

    /// algorithm.md §2.3: the rotated window's DFT is purely real, and after
    /// the 256-bin circular shift its main lobe sits at index 256.
    func testWindowSpectrumIsRealWithMainLobeAt256() {
        let dft = DFT512()
        let w = Codec2Encoder.makeWindow()

        // Imaginary parts must vanish (nw is odd, arrangement is zero-phase).
        var input = [Float](repeating: 0, count: 512)
        for i in 0..<139 { input[i] = Float(w[160 + i]) }
        for i in 0..<139 { input[512 - 139 + i] = Float(w[21 + i]) }
        let (re, im) = dft.forward(real: input)
        var maxIm = 0.0, maxRe = 0.0
        for k in 0..<512 {
            maxIm = max(maxIm, abs(Double(im[k])))
            maxRe = max(maxRe, abs(Double(re[k])))
        }
        XCTAssertLessThan(maxIm / maxRe, 1e-5, "window spectrum must be purely real")

        let spectrum = Codec2Encoder.makeWindowSpectrum(w, dft: dft)
        var peakBin = 0
        var peak = -Double.infinity
        for k in 0..<512 where spectrum[k] > peak { peak = spectrum[k]; peakBin = k }
        XCTAssertEqual(peakBin, 256, "main lobe must be centred at index 256")
        // And it must decay away from the lobe.
        XCTAssertLessThan(abs(spectrum[0]), abs(spectrum[256]) * 1e-3)
    }
}

final class LPCAnalysisTests: XCTestCase {

    /// Runs a deterministic white-noise sequence through a known all-pole
    /// filter and checks that algorithm.md §6 steps 1–2 recover it.
    func testLevinsonRecoversKnownARCoefficients() {
        // A(z) = 1 + a1 z^-1 + a2 z^-2 ... a stable AR(4) system.
        let trueA: [Double] = [1.0, -1.6, 1.1, -0.45, 0.08]
        var x = [Double](repeating: 0, count: 20000)
        var state = [Double](repeating: 0, count: 4)
        var seed: UInt64 = 42
        func noise() -> Double {
            seed = 6364136223846793005 &* seed &+ 1442695040888963407
            return Double(Int64(bitPattern: seed >> 11)) / Double(1 << 52) - 1.0
        }
        for n in 0..<x.count {
            var v = noise()
            for j in 0..<4 { v -= trueA[j + 1] * state[j] }
            x[n] = v
            for j in stride(from: 3, to: 0, by: -1) { state[j] = state[j - 1] }
            state[0] = v
        }

        let r = LPC.autocorrelation(x, order: 10)
        let a = LPC.levinsonDurbin(r, order: 10)
        XCTAssertEqual(a[0], 1.0)
        for j in 1...4 {
            XCTAssertEqual(a[j], trueA[j], accuracy: 0.05, "a[\(j)]")
        }
        for j in 5...10 {
            XCTAssertEqual(a[j], 0.0, accuracy: 0.05, "a[\(j)] should be ~0")
        }
    }

    /// algorithm.md §6 step 1: `R[j] = Σ_i x[i]·x[i+j]`.
    func testAutocorrelationOfKnownSignal() {
        // A unit impulse: R[0] = 1, all other lags 0.
        var impulse = [Double](repeating: 0, count: 64)
        impulse[10] = 1.0
        let r = LPC.autocorrelation(impulse, order: 10)
        XCTAssertEqual(r[0], 1.0, accuracy: 1e-12)
        for j in 1...10 { XCTAssertEqual(r[j], 0.0, accuracy: 1e-12) }

        // A cosine at ω: R[j]/R[0] ≈ cos(ω·j).
        let omega = 2.0 * Double.pi * 400.0 / 8000.0
        let cosine = (0..<4000).map { cos(omega * Double($0)) }
        let rc = LPC.autocorrelation(cosine, order: 10)
        for j in 0...10 {
            XCTAssertEqual(rc[j] / rc[0], cos(omega * Double(j)), accuracy: 0.01, "lag \(j)")
        }
    }

    /// algorithm.md §6 step 2: "If a reflection coefficient magnitude exceeds
    /// 1, use 0 for that stage" — the recursion must stay finite on a
    /// degenerate autocorrelation rather than diverging.
    func testLevinsonSurvivesDegenerateAutocorrelation() {
        for r in [[Double](repeating: 0, count: 11),
                  [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0],
                  [0.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]] {
            let a = LPC.levinsonDurbin(r, order: 10)
            XCTAssertEqual(a[0], 1.0)
            for v in a { XCTAssertTrue(v.isFinite, "coefficient must stay finite") }
        }
    }

    /// algorithm.md §6 step 4: `a_i ← a_i · 0.994^i`.
    func testBandwidthExpansion() {
        let a = [Double](repeating: 1.0, count: 11)
        let e = LPC.bandwidthExpand(a)
        for i in 0...10 {
            XCTAssertEqual(e[i], pow(0.994, Double(i)), accuracy: 1e-12)
        }
    }
}

final class LPCToLSPTests: XCTestCase {

    /// Builds a realistic LPC set by analysing a synthetic AR signal.
    private func syntheticLPC(_ trueA: [Double], seed: UInt64 = 7) -> [Double] {
        var x = [Double](repeating: 0, count: 8000)
        var state = [Double](repeating: 0, count: trueA.count - 1)
        var s = seed
        func noise() -> Double {
            s = 6364136223846793005 &* s &+ 1442695040888963407
            return Double(Int64(bitPattern: s >> 11)) / Double(1 << 52) - 1.0
        }
        for n in 0..<x.count {
            var v = noise()
            for j in 0..<state.count { v -= trueA[j + 1] * state[j] }
            x[n] = v
            for j in stride(from: state.count - 1, to: 0, by: -1) { state[j] = state[j - 1] }
            state[0] = v
        }
        let r = LPC.autocorrelation(x, order: 10)
        return LPC.bandwidthExpand(LPC.levinsonDurbin(r, order: 10))
    }

    private var testFilters: [[Double]] {
        [[1.0, -1.6, 1.1, -0.45, 0.08],
         [1.0, -0.9, 0.6, -0.2],
         [1.0, -1.2, 0.9, -0.5, 0.3, -0.1]]
    }

    /// algorithm.md §6 step 5: LSPs must be strictly ascending and lie in
    /// (0, π) — the interlacing property of P'/Q' roots.
    func testLSPsAreAscendingAndInRange() {
        for filter in testFilters {
            let a = syntheticLPC(filter)
            let lsp = LPC.toLSP(a)
            XCTAssertEqual(lsp.count, 10)
            for i in 0..<10 {
                XCTAssertGreaterThan(lsp[i], 0.0, "lsp[\(i)] must be > 0")
                XCTAssertLessThan(lsp[i], Double.pi, "lsp[\(i)] must be < π")
            }
            for i in 1..<10 {
                XCTAssertGreaterThan(lsp[i], lsp[i - 1], "LSPs must ascend at \(i)")
            }
        }
    }

    /// Cross-validates the two independently-specified conversions:
    /// algorithm.md §6 step 5 (LPC→LSP, analysis) against §7.1 (LSP→LPC,
    /// synthesis, implemented for M2). Round-tripping must return the same
    /// filter, which also confirms the even→P / odd→Q convention is
    /// consistent between them.
    func testLPCToLSPToLPCRoundTrip() {
        for filter in testFilters {
            let a = syntheticLPC(filter)
            let lsp = LPC.toLSP(a)
            let back = LSP.toLPC(lsp)
            XCTAssertEqual(back.count, a.count)
            for i in 0...10 {
                XCTAssertEqual(back[i], a[i], accuracy: 5e-3,
                               "round-trip coefficient a[\(i)]")
            }
        }
    }

    /// The grid search has a floor of 0.01 in x = cos(ω) with 6 bisection
    /// steps (algorithm.md §6 step 5), so recovered roots are accurate to
    /// roughly 0.01/2⁶ in x. Confirms the bisection actually refines.
    func testBisectionRefinesRootsBelowGridResolution() {
        let a = syntheticLPC(testFilters[0])
        let lsp = LPC.toLSP(a)
        // If bisection were absent, every root would land exactly on a
        // 0.01 grid point. Check the cosines are not all grid multiples.
        var offGrid = 0
        for omega in lsp {
            let x = cos(omega)
            let nearest = (x * 100.0).rounded() / 100.0
            if abs(x - nearest) > 1e-6 { offGrid += 1 }
        }
        XCTAssertGreaterThan(offGrid, 5, "bisection should move roots off the grid")
    }

    /// algorithm.md §6 step 5 (re-anchoring). Adjacent LSPs are roots of
    /// *different* polynomials, so two of them may lie arbitrarily close —
    /// even inside one 0.01 cell — without either being missed. A frame whose
    /// LSPs are ~0.006 apart in x = cos ω "is therefore normal and must not
    /// fall back".
    ///
    /// Regression test for the search that scans a single monotone descending
    /// grid and requires each successive LSP to fall in its own 0.01 cell:
    /// that loses roots on tonal frames and is "a specification misreading".
    func testResolvesLSPsCloserThanTheGridStep() {
        // A tonal LSP set: four roots clustered at 25 Hz spacing around
        // 400 Hz, which is ~0.006 apart in cos ω — well inside one cell.
        let hz: [Double] = [375, 400, 425, 450, 1300, 1800, 1850, 2650, 3450, 3725]
        let lsp = hz.map { $0 * Double.pi / 4000.0 }

        // Confirm the premise: adjacent roots really are sub-grid-step apart.
        var minGap = Double.infinity
        for i in 1..<10 { minGap = min(minGap, abs(cos(lsp[i]) - cos(lsp[i - 1]))) }
        XCTAssertLessThan(minGap, 0.01, "premise: roots closer than the grid step")

        // Round-trip through the §7.1 synthesis and the §6 step 5 analysis.
        let a = LSP.toLPC(lsp)
        let recovered = LPC.toLSP(a)

        XCTAssertNotEqual(recovered, LPC.fallbackLSP,
                          "must not fall back on a legitimately tonal frame")
        for i in 0..<10 {
            XCTAssertEqual(recovered[i], lsp[i], accuracy: 2e-3,
                           "LSP \(i) (\(hz[i]) Hz)")
        }
    }

    /// The gap that the 0.01 step must actually beat is between LSP i and
    /// LSP i+2 (successive roots *within* p or within q), not between
    /// adjacent LSPs — algorithm.md §6 step 5.
    func testWithinPolynomialSpacingIsWhatMatters() {
        let hz: [Double] = [375, 400, 425, 450, 1300, 1800, 1850, 2650, 3450, 3725]
        let lsp = hz.map { $0 * Double.pi / 4000.0 }
        var minAdjacent = Double.infinity
        var minSamePolynomial = Double.infinity
        for i in 1..<10 { minAdjacent = min(minAdjacent, abs(cos(lsp[i]) - cos(lsp[i - 1]))) }
        for i in 2..<10 { minSamePolynomial = min(minSamePolynomial, abs(cos(lsp[i]) - cos(lsp[i - 2]))) }
        XCTAssertLessThan(minAdjacent, 0.01)
        XCTAssertGreaterThan(minSamePolynomial, 0.01,
                             "within-polynomial spacing must exceed the scan step")
    }

    /// algorithm.md §6 step 5: "If fewer than 10 roots are found, substitute
    /// lsp[i] = i·π/10." Degenerate input must take that path, not crash.
    func testFallbackOnDegenerateFilter() {
        // An all-zero predictor gives P'/Q' with no interlacing roots.
        let a = [1.0] + [Double](repeating: 0, count: 10)
        let lsp = LPC.toLSP(a)
        XCTAssertEqual(lsp.count, 10)
        for v in lsp { XCTAssertTrue(v.isFinite) }
        XCTAssertEqual(LPC.fallbackLSP.count, 10)
        XCTAssertEqual(LPC.fallbackLSP[0], 0.0)
        XCTAssertEqual(LPC.fallbackLSP[5], Double.pi / 2, accuracy: 1e-12)
    }
}

final class NLPPitchTests: XCTestCase {

    /// Builds a harmonically rich periodic signal at a known F0 — the kind
    /// of input the NLP estimator of algorithm.md §3 is designed for.
    /// (A *pure* sine is deliberately not used: squaring it regenerates only
    /// DC and 2·F0, so its NLP peak is at 2·F0 by construction.)
    private func harmonicTone(f0: Double, samples: Int, amplitude: Double = 6000) -> [Int16] {
        var out = [Int16]()
        out.reserveCapacity(samples)
        let harmonics = max(1, Int(3600.0 / f0))
        for n in 0..<samples {
            var v = 0.0
            for h in 1...harmonics {
                v += cos(2.0 * Double.pi * f0 * Double(h) * Double(n) / 8000.0)
            }
            out.append(Int16(max(-32000, min(32000, v * amplitude / Double(harmonics)))))
        }
        return out
    }

    /// algorithm.md §3 + §4: the encoder must lock onto a known F0.
    /// Checked through the packed frame (bitstream.md §4.1) so the whole
    /// analysis chain is exercised.
    func testNLPLocksOntoKnownF0() {
        for f0 in [100.0, 125.0, 160.0, 200.0] {
            let pcm = harmonicTone(f0: f0, samples: 160 * 30)
            let codec = Codec2_3200()
            var lastWo = 0.0
            var voicedFrames = 0
            for f in 0..<30 {
                let frame = codec.encode(Array(pcm[(f * 160)..<((f + 1) * 160)]))
                let fields = Codec2Frame.unpack(frame)
                lastWo = WoQuantiser.decode(fields.woIndex)
                // Ignore the first few frames while the 40 ms buffer fills.
                if f >= 10 && fields.v2 == 1 { voicedFrames += 1 }
            }
            let measuredF0 = lastWo * 8000.0 / (2.0 * Double.pi)
            XCTAssertEqual(measuredF0, f0, accuracy: max(4.0, f0 * 0.03),
                           "F0 \(f0) Hz estimated as \(measuredF0) Hz")
            XCTAssertGreaterThan(voicedFrames, 15,
                                 "a periodic tone at \(f0) Hz should read voiced")
        }
    }

    /// algorithm.md §5.2: deterministic pseudo-noise should mostly read
    /// unvoiced (the vector's stated purpose in conformance.md).
    func testNoiseReadsMostlyUnvoiced() {
        var x: UInt64 = 12345
        var pcm = [Int16]()
        for _ in 0..<(160 * 40) {
            x = (1103515245 &* x &+ 12345) % 2147483648
            pcm.append(Int16(Int(x % 16000) - 8000))
        }
        let codec = Codec2_3200()
        var voiced = 0, total = 0
        for f in 10..<40 {
            let fields = Codec2Frame.unpack(codec.encode(Array(pcm[(f * 160)..<((f + 1) * 160)])))
            voiced += fields.v1 + fields.v2
            total += 2
        }
        XCTAssertLessThan(Double(voiced) / Double(total), 0.35,
                          "noise read voiced in \(voiced)/\(total) subframes")
    }
}

final class EncoderFrameTests: XCTestCase {

    /// bitstream.md §1: 160 samples in -> 8 bytes out.
    func testEncodeProducesEightBytes() {
        let codec = Codec2_3200()
        let frame = codec.encode([Int16](repeating: 0, count: 160))
        XCTAssertEqual(frame.count, 8)
    }

    /// The encoder is stateful (algorithm.md §8) but deterministic, and
    /// `reset()` must restore the §0 initial state.
    func testEncoderDeterminismAndReset() throws {
        let pcm = try PCM.readRaw("speech_arctic_bdl.raw")
        func run(_ codec: Codec2_3200, frames: Int) -> [UInt8] {
            var out = [UInt8]()
            for f in 0..<frames {
                out.append(contentsOf: codec.encode(Array(pcm[(f * 160)..<((f + 1) * 160)])))
            }
            return out
        }
        let a = run(Codec2_3200(), frames: 60)
        let b = run(Codec2_3200(), frames: 60)
        XCTAssertEqual(a, b, "encoding must be deterministic")

        let codec = Codec2_3200()
        let first = run(codec, frames: 60)
        codec.reset()
        let second = run(codec, frames: 60)
        XCTAssertEqual(first, second, "reset() must restore initial encoder state")
    }

    /// Digital silence must take the algorithm.md §6 step 1 zero-energy path
    /// (fallback LSPs, E = 0 -> index 0) without producing NaN or crashing.
    func testSilenceEncodesToTheFallbackPath() {
        let codec = Codec2_3200()
        var last = Codec2Frame(v1: 0, v2: 0, woIndex: 0, eIndex: 0,
                               lspdIndices: [Int](repeating: 0, count: 10))
        for _ in 0..<30 {
            last = Codec2Frame.unpack(codec.encode([Int16](repeating: 0, count: 160)))
        }
        XCTAssertEqual(last.eIndex, 0, "zero energy must quantise to index 0")
        // The fallback LSPs i·π/10 quantise to this fixed index vector.
        XCTAssertEqual(last.lspdIndices, LSPDQuantiser.encode(lsp: LPC.fallbackLSP))
        XCTAssertEqual(last.v1, 0)
        XCTAssertEqual(last.v2, 0)
    }

    /// Any input must produce a frame that round-trips through the decoder
    /// without pathology (ties M3 back to the M1/M2 layers).
    func testEncodeDecodeRoundTripIsSane() throws {
        let pcm = try PCM.readRaw("speech_arctic_bdl.raw")
        let encoder = Codec2_3200()
        let decoder = Codec2_3200()
        var out = [Int16]()
        for f in 0..<200 {
            let frame = encoder.encode(Array(pcm[(f * 160)..<((f + 1) * 160)]))
            XCTAssertEqual(frame.count, 8)
            out.append(contentsOf: decoder.decode(frame))
        }
        XCTAssertEqual(out.count, 200 * 160)
        XCTAssertTrue(out.contains { $0 != 0 })

        // Level must be in the same ballpark as the input (the codec is not
        // waveform-preserving, but gross level is preserved).
        let inLevel = PCM.dB(PCM.rms(Array(pcm[0..<(200 * 160)])))
        let outLevel = PCM.dB(PCM.rms(out))
        XCTAssertEqual(outLevel, inLevel, accuracy: 6.0,
                       "round-trip level \(outLevel) dB vs input \(inLevel) dB")
    }
}
