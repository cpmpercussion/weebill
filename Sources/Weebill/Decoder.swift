// Decoder.swift — Codec 2 3200 bit/s decoder.
// algorithm.md §7 (interpolation, §7.1 LSP→LPC, §7.2 envelope + postfilter,
// §7.3 phase synthesis, §7.4 background-noise phase dither, §7.5 overlap-add
// synthesis) with initial state from algorithm.md §0 / §8.

import Foundation

/// Deterministic uniform PRNG for the unvoiced/dither phases.
///
/// algorithm.md §7.3: "The random source need not match the reference (output
/// is not bit-exact anyway); any decent uniform PRNG is fine." A fixed seed is
/// used so decoder output is reproducible run to run, which the tests rely on.
struct PhaseRandom {
    private var state: UInt64

    init(seed: UInt64 = 0x2545F4914F6CDD1D) { state = seed }

    /// SplitMix64.
    private mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 2π).
    mutating func phase() -> Double {
        Double(next() >> 11) * (2.0 * Double.pi / Double(1 << 53))
    }
}

/// One subframe's model parameters (algorithm.md §0, §7).
struct SubframeModel {
    var wo: Double
    var harmonicCount: Int
    var voiced: Bool
    var energy: Double
    var lsp: [Double]
}

/// The Codec 2 3200 bit/s decoder.
///
/// Stateful: one instance per stream (algorithm.md §8). Not thread-safe.
public final class Codec2Decoder {

    // MARK: State (algorithm.md §0 "Initial state (decoder)", §8)

    /// Previous frame's subframe-2 fundamental. Initially 2π/160.
    private var prevWo: Double
    /// Previous frame's subframe-2 voicing. Initially unvoiced.
    private var prevVoiced: Bool
    /// Previous frame's subframe-2 energy. Initially 1.0.
    private var prevEnergy: Double
    /// Previous frame's subframe-2 LSPs. Initially i·π/11 for i = 0..9.
    private var prevLSP: [Double]
    /// Running excitation phase Φ (algorithm.md §7.3). Initially 0.
    private var excitationPhase: Double
    /// Background-noise estimate in dB (algorithm.md §7.4). Initially 0.
    private var backgroundDB: Double
    /// 160-sample synthesis accumulator (algorithm.md §7.5). Initially zeros.
    private var accumulator: [Float]

    /// Diagnostic: how many synthesised samples the §7.5 step 5 limiter found
    /// non-finite and had to substitute. Must stay 0 for every input; the
    /// robustness tests assert on it, since NaN/Inf cannot otherwise be
    /// observed through the `[Int16]` return type.
    public private(set) var nonFiniteSampleCount = 0

    private let dft = DFT512()
    private var rng: PhaseRandom
    /// Synthesis window Pn[0...159], precomputed (algorithm.md §7.5 step 1).
    private let pn: [Double]

    /// Samples emitted per 20 ms frame (bitstream.md §1).
    public static let samplesPerFrame = 160
    /// Samples per 10 ms subframe.
    public static let samplesPerSubframe = 80

    /// Seed for the unvoiced/dither phase PRNG (algorithm.md §7.3 — a
    /// decoder-side rendering choice that need not match the reference).
    private let phaseSeed: UInt64

    /// Creates a decoder in the algorithm.md §0 initial state.
    /// - Parameter phaseSeed: seeds the unvoiced/dither phase PRNG
    ///   (algorithm.md §7.3), a free decoder-side rendering choice. Fixing it
    ///   makes output reproducible run to run.
    public init(phaseSeed: UInt64 = 0x2545F4914F6CDD1D) {
        self.phaseSeed = phaseSeed
        rng = PhaseRandom(seed: phaseSeed)
        prevWo = 2.0 * Double.pi / 160.0
        prevVoiced = false
        prevEnergy = 1.0
        prevLSP = (0..<10).map { Double($0) * Double.pi / 11.0 }
        excitationPhase = 0.0
        backgroundDB = 0.0
        accumulator = [Float](repeating: 0, count: 160)
        pn = Codec2Decoder.synthesisWindow()
    }

    /// Restores the initial state of algorithm.md §0 (new stream).
    public func reset() {
        prevWo = 2.0 * Double.pi / 160.0
        prevVoiced = false
        prevEnergy = 1.0
        prevLSP = (0..<10).map { Double($0) * Double.pi / 11.0 }
        excitationPhase = 0.0
        backgroundDB = 0.0
        accumulator = [Float](repeating: 0, count: 160)
        rng = PhaseRandom(seed: phaseSeed)
        nonFiniteSampleCount = 0
    }

    /// algorithm.md §7.5 step 1: symmetric triangle, adjacent subframes'
    /// windows summing to 1 over the 80-sample overlap.
    static func synthesisWindow() -> [Double] {
        var w = [Double](repeating: 0, count: 160)
        for i in 0...79 { w[i] = Double(i) / 80.0 }
        w[80] = 1.0
        for i in 81...159 { w[i] = 1.0 - Double(i - 80) / 80.0 }
        return w
    }

    // MARK: - Frame decode

    /// Decodes one 8-byte frame to 160 PCM samples (bitstream.md §1,
    /// algorithm.md §7).
    public func decode(frame bytes: [UInt8]) -> [Int16] {
        let frame = Codec2Frame.unpack(bytes)

        // Parameters of subframe 2 — the transmitted "new" set
        // (bitstream.md §1, §4).
        let woNew = WoQuantiser.decode(frame.woIndex)
        let energyNew = EnergyQuantiser.decode(frame.eIndex)
        let lspNew = LSPDQuantiser.decode(indices: frame.lspdIndices)
        let voicedNew = frame.v2 == 1

        // --- algorithm.md §7 interpolation, subframe 1 ---

        // Voicing: "subframe 1 uses v₁ … but if v₁ is voiced while *both*
        // prev and new are unvoiced, force subframe 1 unvoiced."
        var voiced1 = frame.v1 == 1
        if voiced1 && !prevVoiced && !voicedNew { voiced1 = false }

        // ω₀ (subframe 1).
        let wo1: Double
        if voiced1 {
            if prevVoiced && voicedNew {
                wo1 = 0.5 * (prevWo + woNew)
            } else if prevVoiced {
                wo1 = prevWo
            } else {
                wo1 = woNew
            }
        } else {
            // Unvoiced: minimum ω₀ — dense harmonics model noise well.
            wo1 = 2.0 * Double.pi / 160.0
        }

        // Energy: geometric mean. LSPs: element-wise arithmetic mean.
        let energy1 = (prevEnergy * energyNew).squareRoot()
        var lsp1 = [Double](repeating: 0, count: 10)
        for i in 0..<10 { lsp1[i] = 0.5 * (prevLSP[i] + lspNew[i]) }

        let sub1 = SubframeModel(wo: wo1,
                                 harmonicCount: Codec2Decoder.harmonicCount(wo1),
                                 voiced: voiced1,
                                 energy: energy1,
                                 lsp: lsp1)
        let sub2 = SubframeModel(wo: woNew,
                                 harmonicCount: Codec2Decoder.harmonicCount(woNew),
                                 voiced: voicedNew,
                                 energy: energyNew,
                                 lsp: lspNew)

        var out = [Int16]()
        out.reserveCapacity(Codec2Decoder.samplesPerFrame)
        out.append(contentsOf: synthesise(sub1))
        out.append(contentsOf: synthesise(sub2))

        // Carry subframe 2 forward as "prev" (algorithm.md §7, §8).
        prevWo = woNew
        prevVoiced = voicedNew
        prevEnergy = energyNew
        prevLSP = lspNew

        return out
    }

    /// `L = ⌊π/ω₀⌋` (bitstream.md §4.1, algorithm.md §7).
    static func harmonicCount(_ wo: Double) -> Int {
        max(1, Int((Double.pi / wo).rounded(.down)))
    }

    // MARK: - Per-subframe synthesis (algorithm.md §7.1 – §7.5)

    private func synthesise(_ model: SubframeModel) -> [Int16] {
        // §7.1 LSP -> LPC.
        let a = LSP.toLPC(model.lsp)

        // §7.2 step 1: LPC magnitude-squared response on the 512-point grid.
        let aFloat = a.map { Float($0) }
        let (awRe, awIm) = dft.forward(real: aFloat)

        var pw = [Double](repeating: 0, count: 256)
        for k in 0..<256 {
            let mag2 = Double(awRe[k]) * Double(awRe[k]) + Double(awIm[k]) * Double(awIm[k])
            pw[k] = 1.0 / (mag2 + 1e-6)
        }

        // §7.2 step 2: frequency-domain postfilter, β = 0.2, γ = 0.5.
        let beta = 0.2, gamma = 0.5
        var aw = [Float](repeating: 0, count: 11)
        var g = 1.0
        for i in 0...10 {
            aw[i] = Float(a[i] * g)
            g *= gamma
        }
        let (wwRe, wwIm) = dft.forward(real: aw)

        var sumBefore = 1e-4
        for k in 0..<256 { sumBefore += pw[k] }
        for k in 0..<256 {
            let ww = Double(wwRe[k]) * Double(wwRe[k]) + Double(wwIm[k]) * Double(wwIm[k])
            let r = (ww * pw[k]).squareRoot()          // combined |W/A| magnitude
            pw[k] *= pow(r, 2.0 * beta)
        }
        var sumAfter = 1e-4
        for k in 0..<256 { sumAfter += pw[k] }
        let gain = sumBefore / sumAfter
        let scale = gain * model.energy
        for k in 0..<256 { pw[k] *= scale }

        // Bass boost: 0–1000 Hz.
        for k in 0..<64 { pw[k] *= 1.96 }

        // §7.2 step 3: harmonic magnitudes by sampling the model.
        let l = model.harmonicCount
        let binsPerRadian = 512.0 / (2.0 * Double.pi)
        var amplitude = [Double](repeating: 0, count: l + 1)   // 1-based
        for m in 1...l {
            var lo = Int(((Double(m) - 0.5) * model.wo * binsPerRadian + 0.5).rounded(.down))
            var hi = Int(((Double(m) + 0.5) * model.wo * binsPerRadian + 0.5).rounded(.down))
            lo = max(0, min(lo, 256))
            hi = max(0, min(hi, 256))                 // b_m clamped to 256
            var sum = 0.0
            if lo < hi {
                for k in lo..<min(hi, 256) { sum += pw[k] }
            }
            amplitude[m] = sum.squareRoot()
        }

        // §7.2 step 4: low-pitch correction.
        if model.wo < Double.pi * 150.0 / 4000.0 {
            amplitude[1] *= 0.032
        }

        // §7.3 phase synthesis.
        excitationPhase += model.wo * 80.0
        excitationPhase -= 2.0 * Double.pi * (excitationPhase / (2.0 * Double.pi) + 0.5).rounded(.down)

        var phase = [Double](repeating: 0, count: l + 1)
        for m in 1...l {
            let excitation: Double = model.voiced
                ? Double(m) * excitationPhase
                : rng.phase()
            let b = min(256, max(0, Int((Double(m) * model.wo * binsPerRadian + 0.5).rounded(.down))))
            // H_m = conj(Aw[b]) — the synthesis filter 1/A has phase
            // opposite to the analysis filter A; only its phase matters.
            let hRe = Double(awRe[b])
            let hIm = -Double(awIm[b])
            // arg(H_m · e^(j·excitation)) = arg(H_m) + excitation.
            phase[m] = atan2(hIm, hRe) + excitation
        }

        // §7.4 background-noise phase dither.
        if !model.voiced {
            var energySum = 1e-12
            for m in 1...l { energySum += amplitude[m] * amplitude[m] }
            let eDB = 10.0 * log10(energySum / Double(l))
            if eDB < 40.0 {
                backgroundDB = 0.9 * backgroundDB + 0.1 * eDB
            }
        } else {
            let threshold = pow(10.0, (backgroundDB + 6.0) / 20.0)
            for m in 1...l where amplitude[m] < threshold {
                phase[m] = rng.phase()
            }
        }

        // §7.5 sinusoidal synthesis, overlap-add.
        return overlapAdd(amplitude: amplitude, phase: phase, wo: model.wo, l: l)
    }

    /// algorithm.md §7.5 steps 2–5.
    private func overlapAdd(amplitude: [Double], phase: [Double],
                            wo: Double, l: Int) -> [Int16] {
        // Step 2: harmonic half-spectrum.
        var sRe = [Float](repeating: 0, count: 257)
        var sIm = [Float](repeating: 0, count: 257)
        let binsPerRadian = 512.0 / (2.0 * Double.pi)
        for m in 1...l {
            let b = min(255, max(0, Int((Double(m) * wo * binsPerRadian + 0.5).rounded(.down))))
            // A later harmonic landing on the same bin overwrites the earlier.
            sRe[b] = Float(amplitude[m] * cos(phase[m]))
            sIm[b] = Float(amplitude[m] * sin(phase[m]))
        }

        // Step 3: inverse real DFT (convention pinned in DFT512.inverseReal).
        let s = dft.inverseReal(halfRe: sRe, halfIm: sIm)

        // Step 4: overlap-add into the 160-sample accumulator.
        for i in 0...78 { accumulator[i] = accumulator[i + 80] }
        accumulator[79] = 0
        for i in 0...78 {
            accumulator[i] += s[433 + i] * Float(pn[i])          // negative time
        }
        for i in 79...159 {
            accumulator[i] = s[i - 79] * Float(pn[i])            // assign, not add
        }

        // Step 5: output limiter ("ear protection"), then clamp and truncate.
        var maxValue: Float = 0
        for i in 0..<80 { maxValue = max(maxValue, accumulator[i]) }
        var limiter: Float = 1.0
        if maxValue > 30000 {
            let r = 30000.0 / maxValue
            limiter = r * r
        }

        var out = [Int16]()
        out.reserveCapacity(80)
        for i in 0..<80 {
            var v = accumulator[i] * limiter
            if !v.isFinite {
                nonFiniteSampleCount += 1
                v = 0
            }
            v = min(32767, max(-32767, v))
            out.append(Int16(v.rounded(.towardZero)))
        }
        return out
    }
}

// MARK: - Public codec facade

/// Codec 2, 3200 bit/s mode.
///
/// Stateful (algorithm.md §8): one instance per stream, not thread-safe
/// across concurrent frames.
public final class Codec2_3200 {

    private let decoder: Codec2Decoder
    private let encoder = Codec2Encoder()

    /// Creates a codec in the algorithm.md §0 initial state.
    public init() { decoder = Codec2Decoder() }

    /// Testing/rendering hook: seeds the unvoiced-phase PRNG (algorithm.md §7.3).
    public init(phaseSeed: UInt64) { decoder = Codec2Decoder(phaseSeed: phaseSeed) }

    /// Bytes per 20 ms frame (bitstream.md §1).
    public static let frameBytes = Codec2Frame.frameBytes
    /// PCM samples per 20 ms frame.
    public static let frameSamples = Codec2Decoder.samplesPerFrame

    /// 160 samples in -> 8 bytes out (bitstream.md, algorithm.md §1–§6).
    public func encode(_ pcm: [Int16]) -> [UInt8] {
        encoder.encode(pcm)
    }

    /// 8 bytes in -> 160 samples out (algorithm.md §7).
    public func decode(_ frame: [UInt8]) -> [Int16] {
        decoder.decode(frame: frame)
    }

    /// Number of synthesised samples that came out non-finite and had to be
    /// substituted by the output limiter (algorithm.md §7.5 step 5).
    ///
    /// This is a health check, not a normal signal path: it must stay 0 for
    /// every input, including arbitrary or corrupted bitstreams. It exists
    /// because NaN/Inf in the synthesis stage cannot otherwise be observed
    /// through the `[Int16]` return type. Reset by `reset()`.
    public var nonFiniteSampleCount: Int { decoder.nonFiniteSampleCount }

    /// Resets encoder and decoder state for a new stream (algorithm.md §0).
    public func reset() {
        decoder.reset()
        encoder.reset()
    }
}
