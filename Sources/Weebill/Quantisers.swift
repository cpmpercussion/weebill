// Quantisers.swift — the three Codec 2 3200 quantiser laws.
// bitstream.md §4.1 (pitch), §4.2 (energy), §4.3 (LSP differences).

import Foundation

/// Constants from bitstream.md §4.
public enum Codec2Constants {
    /// Minimum pitch period, samples (bitstream.md §4).
    public static let pMin = 20.0
    /// Maximum pitch period, samples.
    public static let pMax = 160.0
    /// Wo_min = 2π / P_MAX.
    public static let woMin = 2.0 * Double.pi / pMax
    /// Wo_max = 2π / P_MIN.
    public static let woMax = 2.0 * Double.pi / pMin
    /// Energy quantiser floor, dB.
    public static let eMinDB = -10.0
    /// Energy quantiser ceiling, dB.
    public static let eMaxDB = 40.0
    /// LPC order.
    public static let lpcOrder = 10
    /// Sample rate, Hz.
    public static let sampleRate = 8000.0
}

/// bitstream.md §4.1: "round" means floor(x + 0.5), including for negative x.
@inlinable
func specRound(_ x: Double) -> Double {
    (x + 0.5).rounded(.down)
}

// MARK: - Pitch quantiser (bitstream.md §4.1)

/// The 7-bit uniform pitch quantiser (bitstream.md §4.1).
///
/// Encode and decode are deliberately asymmetric — encode divides the range
/// into 128 levels and rounds, decode steps by range/128 from Wo_min — and
/// both must be reproduced exactly.
public enum WoQuantiser {
    /// Number of quantiser levels (7-bit field).
    public static let levels = 128

    /// bitstream.md §4.1 encode:
    /// `index = round(128 * (Wo − Wo_min) / (Wo_max − Wo_min))`, clamped [0,127].
    public static func encode(_ wo: Double) -> Int {
        let range = Codec2Constants.woMax - Codec2Constants.woMin
        let x = Double(levels) * (wo - Codec2Constants.woMin) / range
        let r = specRound(x)
        // Clamp written as range tests that also absorb NaN/±inf, so a
        // degenerate ω₀ yields an in-range index instead of trapping in
        // `Int(_:)`. In-contract inputs are unaffected.
        if !(r > 0) { return 0 }
        if !(r < Double(levels - 1)) { return levels - 1 }
        return Int(r)
    }

    /// bitstream.md §4.1 decode:
    /// `Wo = Wo_min + index * (Wo_max − Wo_min) / 128`.
    ///
    /// Note the deliberate asymmetry with `encode` — the spec calls this out
    /// explicitly and requires both to be reproduced exactly.
    public static func decode(_ index: Int) -> Double {
        let range = Codec2Constants.woMax - Codec2Constants.woMin
        return Codec2Constants.woMin + Double(index) * range / Double(levels)
    }

    /// Number of harmonics, `L = floor(π / Wo)` (bitstream.md §4.1).
    public static func harmonicCount(wo: Double) -> Int {
        Int((Double.pi / wo).rounded(.down))
    }
}

// MARK: - Energy quantiser (bitstream.md §4.2)

/// The 5-bit uniform-in-decibels frame energy quantiser (bitstream.md §4.2).
public enum EnergyQuantiser {
    /// Number of quantiser levels (5-bit field).
    public static let levels = 32

    /// bitstream.md §4.2 encode: `e_dB = 10·log10(E)`;
    /// `index = round(32 * (e_dB − (−10)) / (40 − (−10)))`, clamped [0,31].
    public static func encode(_ energy: Double) -> Int {
        let eDB = 10.0 * log10(energy)
        let span = Codec2Constants.eMaxDB - Codec2Constants.eMinDB
        let x = Double(levels) * (eDB - Codec2Constants.eMinDB) / span
        guard x.isFinite else { return x < 0 || x.isNaN ? 0 : levels - 1 }
        let r = specRound(x)
        if r < 0 { return 0 }
        if r > Double(levels - 1) { return levels - 1 }
        return Int(r)
    }

    /// bitstream.md §4.2 decode: `e_dB = −10 + index * 50/32`; `E = 10^(e_dB/10)`.
    public static func decode(_ index: Int) -> Double {
        let span = Codec2Constants.eMaxDB - Codec2Constants.eMinDB
        let eDB = Codec2Constants.eMinDB + Double(index) * span / Double(levels)
        return pow(10.0, eDB / 10.0)
    }
}

// MARK: - LSP difference quantiser (bitstream.md §4.3)

/// The 10 × 5-bit LSP difference quantiser (bitstream.md §4.3).
///
/// Differences accumulate against the previous **quantised** cumulative
/// value, not the unquantised input, so encoder and decoder stay in lockstep.
public enum LSPDQuantiser {
    /// Number of LSPs / codebooks.
    public static let order = Codec2Constants.lpcOrder
    /// Entries per scalar codebook.
    public static let levels = 32

    /// radians -> Hz: `lsp_hz = (4000/π) · lsp` (bitstream.md §4.3 step 1).
    @inlinable
    public static func radiansToHz(_ r: Double) -> Double {
        (Codec2Constants.sampleRate / 2.0 / Double.pi) * r
    }

    /// Hz -> radians: `lsp = (π/4000) · lsp_hz` (bitstream.md §4.3 decode 2).
    @inlinable
    public static func hzToRadians(_ hz: Double) -> Double {
        (Double.pi / (Codec2Constants.sampleRate / 2.0)) * hz
    }

    /// bitstream.md §4.3 step 3: minimum squared error against codebook `i`,
    /// unweighted, ties to the lowest index — "search entries in ascending
    /// index order keeping the first strict improvement".
    static func nearest(_ value: Double, in codebook: [Double]) -> Int {
        var bestIndex = 0
        var bestErr = (value - codebook[0]) * (value - codebook[0])
        for j in 1..<codebook.count {
            let d = value - codebook[j]
            let err = d * d
            if err < bestErr {
                bestErr = err
                bestIndex = j
            }
        }
        return bestIndex
    }

    /// Quantises 10 ascending LSPs (radians) to 10 codebook indices.
    ///
    /// bitstream.md §4.3 encode. Critically, each difference is taken against
    /// the previous **quantised** cumulative value (`q_cum`), not against the
    /// unquantised input — so encoder and decoder stay in lockstep.
    public static func encode(lsp: [Double]) -> [Int] {
        precondition(lsp.count == order, "expected \(order) LSPs")
        var indices = [Int](repeating: 0, count: order)
        var qCum = 0.0
        for i in 0..<order {
            let hz = radiansToHz(lsp[i])
            let d = (i == 0) ? hz : hz - qCum
            let idx = nearest(d, in: dlspCodebooks[i])
            indices[i] = idx
            qCum = (i == 0 ? 0.0 : qCum) + dlspCodebooks[i][idx]
        }
        return indices
    }

    /// Reconstructs 10 LSPs (radians) from 10 codebook indices.
    /// bitstream.md §4.3 decode.
    public static func decode(indices: [Int]) -> [Double] {
        precondition(indices.count == order, "expected \(order) indices")
        var lsp = [Double](repeating: 0, count: order)
        var qCum = 0.0
        for i in 0..<order {
            qCum += dlspCodebooks[i][indices[i]]
            lsp[i] = hzToRadians(qCum)
        }
        return lsp
    }

    /// Convenience: the quantised cumulative values in Hz (bitstream.md §4.3).
    public static func decodeHz(indices: [Int]) -> [Double] {
        precondition(indices.count == order, "expected \(order) indices")
        var out = [Double](repeating: 0, count: order)
        var qCum = 0.0
        for i in 0..<order {
            qCum += dlspCodebooks[i][indices[i]]
            out[i] = qCum
        }
        return out
    }
}
