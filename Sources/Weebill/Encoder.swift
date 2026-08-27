// Encoder.swift — Codec 2 3200 bit/s encoder.
// algorithm.md §1 (per-10 ms step order), §2 (window/DFT), §3 (NLP pitch),
// §4 (pitch refinement), §5 (harmonic magnitudes, voicing), §6 (LPC/LSP/E),
// with initial state from algorithm.md §0 / §8.

import Foundation

/// Parameters produced by one 10 ms analysis step.
struct AnalysisResult {
    var wo: Double
    var harmonicCount: Int
    var voiced: Bool
    /// 1-based harmonic magnitudes, index 0 unused.
    var amplitude: [Double]
}

/// The Codec 2 3200 bit/s encoder.
///
/// Stateful: one instance per stream (algorithm.md §8). Not thread-safe.
public final class Codec2Encoder {

    // MARK: Constants (algorithm.md §2, §3)

    /// Analysis buffer length: 40 ms at 8 kHz.
    static let bufferLength = 320
    /// Samples per 10 ms analysis step.
    static let stepSamples = 80
    /// Analysis centre — algorithm.md §2.1 ("all analysis is centred on
    /// sample 160, the buffer centre").
    static let centre = 160
    /// Window parameter nw (algorithm.md §2.1).
    static let nw = 279
    /// ⌊nw/2⌋ — the window's half-width in samples.
    static let halfWindow = nw / 2                 // 139
    /// DFT size (algorithm.md §2.2).
    static let nDFT = 512
    /// Bins per radian/sample: 512/2π.
    static let binsPerRadian = Double(nDFT) / (2.0 * Double.pi)

    // MARK: State (algorithm.md §0, §8)

    /// 320-sample sliding analysis buffer. Initially filled with **1.0**,
    /// not 0.0 (algorithm.md §0).
    private var buf: [Double]
    /// NLP buffer of processed squared samples (algorithm.md §3 step 4).
    private var sq: [Double]
    /// DC-notch memories (algorithm.md §3 step 2).
    private var notchPrevX = 0.0
    private var notchPrevY = 0.0
    /// 48-tap FIR memory (algorithm.md §3 step 3): the 47 previous inputs,
    /// most recent first.
    private var firMemory: [Double]
    /// Previous frame's F0 in Hz, for the NLP pitch tracker. Initially 50 Hz
    /// (algorithm.md §0).
    private var prevF0 = 50.0

    private let dft = DFT512()
    /// Normalised analysis window w[0…319] (algorithm.md §2.1).
    private let window: [Double]
    /// Window spectrum W[0…511], real, main lobe centred at 256
    /// (algorithm.md §2.3).
    private let windowSpectrum: [Double]
    /// 64-point Hann window for the NLP DFT (algorithm.md §3 step 5).
    private let nlpWindow: [Double]

    /// Creates an encoder in the algorithm.md §0 initial state (analysis
    /// buffer filled with 1.0, previous-F0 50 Hz, all NLP state zero).
    public init() {
        buf = [Double](repeating: 1.0, count: Codec2Encoder.bufferLength)
        sq = [Double](repeating: 0, count: Codec2Encoder.bufferLength)
        firMemory = [Double](repeating: 0, count: nlpFIR48.count - 1)
        window = Codec2Encoder.makeWindow()
        nlpWindow = (0..<64).map { 0.5 - 0.5 * cos(2.0 * Double.pi * Double($0) / 63.0) }
        windowSpectrum = Codec2Encoder.makeWindowSpectrum(window, dft: dft)
    }

    /// Restores the algorithm.md §0 initial encoder state (new stream).
    public func reset() {
        buf = [Double](repeating: 1.0, count: Codec2Encoder.bufferLength)
        sq = [Double](repeating: 0, count: Codec2Encoder.bufferLength)
        notchPrevX = 0
        notchPrevY = 0
        firMemory = [Double](repeating: 0, count: nlpFIR48.count - 1)
        prevF0 = 50.0
    }

    // MARK: - Window (algorithm.md §2.1)

    /// Raised-cosine window with nw = 279 occupying buffer indices 21…298,
    /// normalised so that Σw²·N_dft = 1.
    ///
    /// algorithm.md §2.1: `w[21 + j] = 0.5 − 0.5·cos(2π·j/(nw − 1))`, j = 0…277
    /// (denominator 278; j only reaches 277, so the window is very slightly
    /// asymmetric — reproduced as written).
    static func makeWindow() -> [Double] {
        var w = [Double](repeating: 0, count: bufferLength)
        let start = centre - halfWindow          // 21
        for j in 0...277 {
            w[start + j] = 0.5 - 0.5 * cos(2.0 * Double.pi * Double(j) / Double(nw - 1))
        }
        var energy = 0.0
        for v in w { energy += v * v }
        let scale = 1.0 / (energy * Double(nDFT)).squareRoot()
        for i in 0..<w.count { w[i] *= scale }
        return w
    }

    /// algorithm.md §2.3: the 512-point DFT of the normalised window arranged
    /// in the same rotated way as §2.2 (purely real), circularly shifted by
    /// 256 bins so its main lobe is centred at index 256.
    static func makeWindowSpectrum(_ w: [Double], dft: DFT512) -> [Double] {
        var input = [Float](repeating: 0, count: nDFT)
        for i in 0..<halfWindow { input[i] = Float(w[centre + i]) }
        for i in 0..<halfWindow {
            input[nDFT - halfWindow + i] = Float(w[centre - halfWindow + i])
        }
        let (re, _) = dft.forward(real: input)
        // Shift by N/2 (self-inverse): W[k] = Re(DFT[(k + 256) mod 512]).
        var out = [Double](repeating: 0, count: nDFT)
        for k in 0..<nDFT { out[k] = Double(re[(k + nDFT / 2) % nDFT]) }
        return out
    }

    // MARK: - Frame encode

    /// Encodes 160 PCM samples (20 ms) to one 8-byte frame.
    ///
    /// algorithm.md §1 / bitstream.md §1: a 20 ms codec frame is two
    /// consecutive 10 ms analyses; only the second analysis' parameters are
    /// transmitted, plus both voicing flags.
    public func encode(_ pcm: [Int16]) -> [UInt8] {
        precondition(pcm.count == 2 * Codec2Encoder.stepSamples,
                     "expected 160 samples per frame")

        let first = analyse(Array(pcm[0..<80]))
        let second = analyse(Array(pcm[80..<160]))

        // LPC / LSP / energy: second subframe only (algorithm.md §1, §6).
        let (lsp, energy) = lpcAnalysis()

        // Quantise and pack (bitstream.md §3, §4).
        let frame = Codec2Frame(
            v1: first.voiced ? 1 : 0,
            v2: second.voiced ? 1 : 0,
            woIndex: WoQuantiser.encode(second.wo),
            eIndex: EnergyQuantiser.encode(energy),
            lspdIndices: LSPDQuantiser.encode(lsp: lsp))
        return frame.packed()
    }

    /// One 10 ms analysis step, algorithm.md §1: shift in 80 new samples,
    /// then windowed DFT (§2), NLP (§3), refinement (§4), magnitudes (§5.1),
    /// voicing (§5.2).
    private func analyse(_ newSamples: [Int16]) -> AnalysisResult {
        // Slide the buffer left by 80 and append the new samples
        // (algorithm.md §0 "Timing structure").
        let n = Codec2Encoder.stepSamples
        for i in 0..<(Codec2Encoder.bufferLength - n) { buf[i] = buf[i + n] }
        for i in 0..<n { buf[Codec2Encoder.bufferLength - n + i] = Double(newSamples[i]) }

        let sw = windowedDFT()
        let woInitial = nlpPitch()
        let (wo, l) = refinePitch(initial: woInitial, sw: sw)
        let amplitude = harmonicMagnitudes(wo: wo, l: l, sw: sw)
        let voiced = voicingDecision(wo: wo, l: l, sw: sw, amplitude: amplitude)

        return AnalysisResult(wo: wo, harmonicCount: l, voiced: voiced,
                              amplitude: amplitude)
    }

    // MARK: - §2.2 Windowed, zero-phase-arranged DFT

    /// algorithm.md §2.2: the windowed buffer is placed rotated so the
    /// analysis centre (buffer index 160) sits at DFT index 0.
    private func windowedDFT() -> (re: [Float], im: [Float]) {
        let h = Codec2Encoder.halfWindow          // 139
        let c = Codec2Encoder.centre              // 160
        var input = [Float](repeating: 0, count: Codec2Encoder.nDFT)
        for i in 0..<h { input[i] = Float(buf[c + i] * window[c + i]) }
        for i in 0..<h {
            input[Codec2Encoder.nDFT - h + i] = Float(buf[c - h + i] * window[c - h + i])
        }
        return dft.forward(real: input)
    }

    // MARK: - §3 NLP pitch estimation

    /// algorithm.md §3: square, DC-notch, 600 Hz low-pass, decimate by 5,
    /// windowed DFT, peak search, sub-multiple post-processing.
    /// Returns the initial ω₀ in radians/sample.
    private func nlpPitch() -> Double {
        let n = Codec2Encoder.stepSamples

        // Steps 1–4: process the 80 newest samples into sq[].
        for i in 0..<(Codec2Encoder.bufferLength - n) { sq[i] = sq[i + n] }
        for i in 0..<n {
            let s = buf[Codec2Encoder.bufferLength - n + i]
            // 1. Square.
            let x = s * s
            // 2. DC notch: y[n] = x[n] − x[n−1] + 0.95·y[n−1], then +1.0 on
            //    the output (a numerical-conditioning constant; the recursion
            //    state is the un-added value).
            let y = x - notchPrevX + 0.95 * notchPrevY
            notchPrevX = x
            notchPrevY = y
            let notched = y + 1.0
            // 3. 48-tap 600 Hz linear-phase FIR.
            var acc = nlpFIR48[0] * notched
            for t in 1..<nlpFIR48.count { acc += nlpFIR48[t] * firMemory[t - 1] }
            // Advance the FIR memory (most recent first).
            var k = firMemory.count - 1
            while k > 0 { firMemory[k] = firMemory[k - 1]; k -= 1 }
            firMemory[0] = notched
            // 4. Store.
            sq[Codec2Encoder.bufferLength - n + i] = acc
        }

        // Step 5: decimate by 5 -> 64 samples, Hann window, zero-pad to 512.
        var input = [Float](repeating: 0, count: Codec2Encoder.nDFT)
        for i in 0..<64 { input[i] = Float(sq[i * 5] * nlpWindow[i]) }
        let (re, im) = dft.forward(real: input)
        var power = [Double](repeating: 0, count: Codec2Encoder.nDFT)
        for k in 0..<Codec2Encoder.nDFT {
            power[k] = Double(re[k]) * Double(re[k]) + Double(im[k]) * Double(im[k])
        }

        // Step 6: global peak over k = 16…128 inclusive (50–400 Hz).
        // "initialise k_g = 16 in case the spectrum is all zero".
        var peakBin = 16
        var peak = 0.0
        for k in 16...128 where power[k] > peak {
            peak = power[k]
            peakBin = k
        }

        // Step 7: sub-multiple post-processing.
        var candidate = peakBin
        // Previous frame's F0 bin, p = trunc(prev_f0·(512·5)/8000).
        let prevBin = Int((prevF0 * Double(Codec2Encoder.nDFT * 5) / 8000.0)
                            .rounded(.towardZero))
        var divisor = 2
        while peakBin / divisor >= 16 {
            let b = peakBin / divisor
            var bmin = Int((0.8 * Double(b)).rounded(.towardZero))
            let bmax = Int((1.2 * Double(b)).rounded(.towardZero))
            if bmin < 16 { bmin = 16 }                     // "clamped up to 16"
            // Threshold: 0.3·g, or 0.15·g when the previous F0 bin falls
            // strictly inside the search window (cheap pitch tracking).
            let threshold = (bmin < prevBin && prevBin < bmax) ? 0.15 * peak : 0.3 * peak

            var bestBin = bmin
            var best = 0.0
            if bmin <= bmax {
                for k in bmin...min(bmax, Codec2Encoder.nDFT - 1) where power[k] > best {
                    best = power[k]
                    bestBin = k
                }
            }
            // Accept only a strict local maximum above threshold.
            if best > threshold, bestBin > 0, bestBin < Codec2Encoder.nDFT - 1,
               power[bestBin] > power[bestBin - 1], power[bestBin] > power[bestBin + 1] {
                candidate = bestBin
            }
            divisor += 1
        }

        // Step 7 tail / step 8.
        let f0 = Double(candidate) * 8000.0 / Double(Codec2Encoder.nDFT * 5)
        prevF0 = f0
        let period = 8000.0 / f0
        return 2.0 * Double.pi / period
    }

    // MARK: - §4 Two-stage pitch refinement

    /// algorithm.md §4: maximise the harmonic sum
    /// `E(ω₀') = Σ_{m=1}^{L} |Sw[round(m·ω₀'·512/2π)]|²` over candidate
    /// periods, coarse then fine.
    private func refinePitch(initial wo: Double, sw: (re: [Float], im: [Float]))
        -> (wo: Double, l: Int) {
        var period = 2.0 * Double.pi / wo

        // Stage 1 (coarse): p−5 … p+5 step 1.0.
        period = searchPeriod(around: period, span: 5.0, step: 1.0, sw: sw)
        // Stage 2 (fine): p−1 … p+1 step 0.25, from the stage-1 period.
        period = searchPeriod(around: period, span: 1.0, step: 0.25, sw: sw)

        // Clamp ω₀ and derive L, with the float-rounding guard.
        var refined = 2.0 * Double.pi / period
        refined = max(Codec2Constants.woMin, min(Codec2Constants.woMax, refined))
        var l = Int((Double.pi / refined).rounded(.down))
        if Double(l) * refined >= 0.95 * Double.pi { l -= 1 }
        l = max(1, l)
        return (refined, l)
    }

    /// One refinement stage. `L = ⌊π/ω₀⌋` comes from the stage's *initial*
    /// estimate and is held fixed across the stage (algorithm.md §4).
    private func searchPeriod(around period: Double, span: Double, step: Double,
                              sw: (re: [Float], im: [Float])) -> Double {
        let l = max(1, Int((Double.pi / (2.0 * Double.pi / period)).rounded(.down)))
        var bestPeriod = period
        var best = -1.0
        var candidate = period - span
        // Inclusive sweep; the tiny epsilon guards float accumulation.
        while candidate <= period + span + 1e-9 {
            if candidate > 0 {
                let w = 2.0 * Double.pi / candidate
                var energy = 0.0
                for m in 1...l {
                    let bin = Int((Double(m) * w * Codec2Encoder.binsPerRadian + 0.5)
                                    .rounded(.down))
                    if bin >= 0 && bin < Codec2Encoder.nDFT {
                        energy += Double(sw.re[bin]) * Double(sw.re[bin])
                                + Double(sw.im[bin]) * Double(sw.im[bin])
                    }
                }
                if energy > best {
                    best = energy
                    bestPeriod = candidate
                }
            }
            candidate += step
        }
        return bestPeriod
    }

    // MARK: - §5.1 Harmonic magnitudes

    /// algorithm.md §5.1: `A_m = sqrt(Σ_{k=a_m}^{b_m−1} |Sw[k]|²)` with
    /// `a_m = round((m−0.5)·ω₀·512/2π)`, `b_m = round((m+0.5)·ω₀·512/2π)`.
    private func harmonicMagnitudes(wo: Double, l: Int,
                                    sw: (re: [Float], im: [Float])) -> [Double] {
        var a = [Double](repeating: 0, count: l + 1)
        for m in 1...l {
            let lo = clampBin(Int(((Double(m) - 0.5) * wo * Codec2Encoder.binsPerRadian + 0.5)
                                    .rounded(.down)))
            let hi = clampBin(Int(((Double(m) + 0.5) * wo * Codec2Encoder.binsPerRadian + 0.5)
                                    .rounded(.down)))
            var acc = 0.0
            if lo < hi {
                for k in lo..<hi {
                    acc += Double(sw.re[k]) * Double(sw.re[k])
                         + Double(sw.im[k]) * Double(sw.im[k])
                }
            }
            a[m] = acc.squareRoot()
        }
        return a
    }

    private func clampBin(_ k: Int) -> Int {
        max(0, min(k, Codec2Encoder.nDFT / 2))
    }

    // MARK: - §5.2 Voicing decision (MBE-style)

    /// algorithm.md §5.2: test how well the spectrum around each harmonic in
    /// the first 1000 Hz is explained by a scaled, shifted copy of the window
    /// spectrum W. Voiced if SNR > 6.0 dB, then the eratio post-rules.
    private func voicingDecision(wo: Double, l: Int,
                                 sw: (re: [Float], im: [Float]),
                                 amplitude: [Double]) -> Bool {
        let l1000 = (l * 1000) / 4000
        var error = 1e-4
        var signal = 1e-4

        if l1000 >= 1 {
            for harmonic in 1...l1000 {
                let centreBin = Double(harmonic) * wo * Codec2Encoder.binsPerRadian
                let lo = Int(((Double(harmonic) - 0.5) * wo * Codec2Encoder.binsPerRadian)
                                .rounded(.up))
                let hi = Int(((Double(harmonic) + 0.5) * wo * Codec2Encoder.binsPerRadian)
                                .rounded(.up))
                let offset = Int((256.0 - centreBin + 0.5).rounded(.towardZero))
                guard lo < hi else { continue }

                // Â_l = Σ Sw[k]·W[offset+k] / Σ W[offset+k]²   (complex)
                var numRe = 0.0, numIm = 0.0, den = 0.0
                for k in lo..<hi {
                    guard k >= 0, k < Codec2Encoder.nDFT else { continue }
                    let idx = offset + k
                    guard idx >= 0, idx < Codec2Encoder.nDFT else { continue }
                    let wv = windowSpectrum[idx]
                    numRe += Double(sw.re[k]) * wv
                    numIm += Double(sw.im[k]) * wv
                    den += wv * wv
                }
                guard den > 0 else { continue }
                let aRe = numRe / den, aIm = numIm / den

                for k in lo..<hi {
                    guard k >= 0, k < Codec2Encoder.nDFT else { continue }
                    let idx = offset + k
                    guard idx >= 0, idx < Codec2Encoder.nDFT else { continue }
                    let wv = windowSpectrum[idx]
                    let dRe = Double(sw.re[k]) - aRe * wv
                    let dIm = Double(sw.im[k]) - aIm * wv
                    error += dRe * dRe + dIm * dIm
                }
                signal += amplitude[harmonic] * amplitude[harmonic]
            }
        }

        var voiced = 10.0 * log10(signal / error) > 6.0

        // Energy-balance post-processing.
        let boundary = max(1, (l * 2000) / 4000)
        var low = 1e-4, high = 1e-4
        for m in 1...min(boundary, l) { low += amplitude[m] * amplitude[m] }
        if boundary <= l {
            for m in boundary...l { high += amplitude[m] * amplitude[m] }
        }
        let eratio = 10.0 * log10(low / high)

        if !voiced && eratio > 10.0 { voiced = true }
        if voiced && eratio < -10.0 { voiced = false }
        if voiced && eratio < -4.0 && wo <= 2.0 * Double.pi * 60.0 / 8000.0 { voiced = false }

        return voiced
    }

    // MARK: - §6 LPC analysis, LSPs, energy (second subframe only)

    /// algorithm.md §6, on the same 320-sample buffer windowed with the §2.1
    /// window (no rotation). Returns the 10 LSPs (radians) and the residual
    /// energy E.
    private func lpcAnalysis() -> (lsp: [Double], energy: Double) {
        var windowed = [Double](repeating: 0, count: Codec2Encoder.bufferLength)
        var energyCheck = 0.0
        for i in 0..<Codec2Encoder.bufferLength {
            windowed[i] = buf[i] * window[i]
            energyCheck += windowed[i] * windowed[i]
        }

        // Step 1: "If the windowed energy is exactly zero, skip LPC and use
        // the fallback LSPs lsp[i] = i·π/10 with E = 0."
        if energyCheck == 0 {
            return (LPC.fallbackLSP, 0.0)
        }

        let order = Codec2Constants.lpcOrder
        let r = LPC.autocorrelation(windowed, order: order)
        let a = LPC.levinsonDurbin(r, order: order)
        // Step 3: energy, computed *before* bandwidth expansion.
        let energy = LPC.residualEnergy(a: a, r: r)
        // Step 4: bandwidth expansion (also guards the root finder).
        let expanded = LPC.bandwidthExpand(a)
        // Step 5: LPC -> LSP.
        let lsp = LPC.toLSP(expanded)
        return (lsp, energy)
    }
}
