// Bitstream.swift — Codec 2 3200 bit/s frame packing.
// Implements bitstream.md §2 (field list), §3 (Gray coding + MSB-first
// packing) and §5 (frame/stream conventions).

import Foundation

// MARK: - Gray coding (bitstream.md §3)

/// Natural binary -> Gray code: `g = q ^ (q >> 1)`.
/// bitstream.md §3.
@inlinable
public func grayEncode(_ q: UInt32) -> UInt32 {
    q ^ (q >> 1)
}

/// Gray code -> natural binary, for fields of at most 8 bits.
/// bitstream.md §3 gives exactly this fold sequence.
@inlinable
public func grayDecode(_ g: UInt32) -> UInt32 {
    var t = g
    t ^= t >> 4
    t ^= t >> 2
    t ^= t >> 1
    return t
}

// MARK: - MSB-first bit writer / reader (bitstream.md §3)

/// Accumulates Gray-coded fields MSB-first into a byte buffer.
/// bitstream.md §3: "the first field occupies the most significant bits of
/// byte 0, and a field that straddles a byte boundary continues in the most
/// significant bits of the next byte."
public struct BitWriter {
    /// The packed bytes written so far.
    public private(set) var bytes: [UInt8]
    /// Number of bits written so far.
    public private(set) var bitCount: Int

    /// Creates a writer over `byteCapacity` zeroed bytes; it grows if more
    /// bits are written than that.
    public init(byteCapacity: Int = 8) {
        bytes = [UInt8](repeating: 0, count: byteCapacity)
        bitCount = 0
    }

    /// Writes the low `width` bits of `value`, most significant bit first.
    /// The value is written as-is (no Gray coding); see `writeField`.
    public mutating func writeBits(_ value: UInt32, width: Int) {
        precondition(width >= 0 && width <= 32, "bad field width \(width)")
        var k = width - 1
        while k >= 0 {
            let bit = (value >> UInt32(k)) & 1
            let byteIndex = bitCount >> 3
            if byteIndex >= bytes.count { bytes.append(0) }
            if bit == 1 {
                bytes[byteIndex] |= UInt8(1 << (7 - (bitCount & 7)))
            }
            bitCount += 1
            k -= 1
        }
    }

    /// Writes a quantiser index: Gray-coded, then packed MSB-first.
    /// bitstream.md §3 — "Every field is Gray-coded before packing."
    public mutating func writeField(_ naturalIndex: Int, width: Int) {
        precondition(naturalIndex >= 0 && naturalIndex < (1 << width),
                     "index \(naturalIndex) out of range for \(width)-bit field")
        writeBits(grayEncode(UInt32(naturalIndex)), width: width)
    }
}

/// Reads Gray-coded fields MSB-first from a byte buffer.
/// bitstream.md §3.
public struct BitReader {
    /// The buffer being read.
    public let bytes: [UInt8]
    /// Bit offset of the next read.
    public private(set) var bitPos: Int

    /// Creates a reader positioned at the first bit of `bytes`.
    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.bitPos = 0
    }

    /// Reads `width` raw bits, most significant bit first.
    public mutating func readBits(width: Int) -> UInt32 {
        precondition(width >= 0 && width <= 32, "bad field width \(width)")
        var v: UInt32 = 0
        for _ in 0..<width {
            let byteIndex = bitPos >> 3
            precondition(byteIndex < bytes.count, "read past end of frame")
            let bit = (bytes[byteIndex] >> UInt8(7 - (bitPos & 7))) & 1
            v = (v << 1) | UInt32(bit)
            bitPos += 1
        }
        return v
    }

    /// Reads a field and converts it from Gray code back to natural binary.
    /// bitstream.md §3.
    public mutating func readField(width: Int) -> Int {
        Int(grayDecode(readBits(width: width)))
    }
}

// MARK: - Frame (bitstream.md §2, §3)

/// The natural-binary quantiser indices carried by one 20 ms, 64-bit frame.
///
/// bitstream.md §2: fields are transmitted in the order v1, v2, Wo, E,
/// d1…d10. All values here are **natural binary**; Gray coding happens only
/// at the pack/unpack boundary (bitstream.md §3).
public struct Codec2Frame: Equatable, Sendable {
    /// Voicing, subframe 1 (1 bit): 1 = voiced.
    public var v1: Int
    /// Voicing, subframe 2 (1 bit).
    public var v2: Int
    /// Pitch index (7 bits), bitstream.md §4.1.
    public var woIndex: Int
    /// Frame energy index (5 bits), bitstream.md §4.2.
    public var eIndex: Int
    /// LSP difference indices d1…d10 (5 bits each), bitstream.md §4.3.
    public var lspdIndices: [Int]

    /// Bit widths, in transmission order (bitstream.md §2).
    public static let voicingBits = 1
    /// Width of the pitch field (bitstream.md §2).
    public static let woBits = 7
    /// Width of the energy field.
    public static let energyBits = 5
    /// Width of each LSP difference field.
    public static let lspdBits = 5
    /// Number of LSP difference fields.
    public static let lspdCount = 10
    /// 1 + 1 + 7 + 5 + 50 = 64 bits = 8 bytes (bitstream.md §2).
    public static let frameBytes = 8

    /// Creates a frame from natural-binary field indices. `lspdIndices` must
    /// contain exactly 10 values.
    public init(v1: Int, v2: Int, woIndex: Int, eIndex: Int, lspdIndices: [Int]) {
        precondition(lspdIndices.count == Codec2Frame.lspdCount,
                     "expected \(Codec2Frame.lspdCount) LSP difference indices")
        self.v1 = v1
        self.v2 = v2
        self.woIndex = woIndex
        self.eIndex = eIndex
        self.lspdIndices = lspdIndices
    }

    /// Packs the frame to 8 bytes: Gray-code each field, then MSB-first.
    /// bitstream.md §3 (layout table).
    public func packed() -> [UInt8] {
        var w = BitWriter(byteCapacity: Codec2Frame.frameBytes)
        w.writeField(v1, width: Codec2Frame.voicingBits)
        w.writeField(v2, width: Codec2Frame.voicingBits)
        w.writeField(woIndex, width: Codec2Frame.woBits)
        w.writeField(eIndex, width: Codec2Frame.energyBits)
        for d in lspdIndices {
            w.writeField(d, width: Codec2Frame.lspdBits)
        }
        precondition(w.bitCount == 64, "frame must be exactly 64 bits")
        return w.bytes
    }

    /// Unpacks 8 bytes into natural-binary field indices.
    /// bitstream.md §3, §5 — every 64-bit pattern is valid by construction.
    public static func unpack(_ bytes: [UInt8]) -> Codec2Frame {
        precondition(bytes.count == frameBytes, "frame must be 8 bytes")
        var r = BitReader(bytes)
        let v1 = r.readField(width: voicingBits)
        let v2 = r.readField(width: voicingBits)
        let wo = r.readField(width: woBits)
        let e = r.readField(width: energyBits)
        var d = [Int]()
        d.reserveCapacity(lspdCount)
        for _ in 0..<lspdCount {
            d.append(r.readField(width: lspdBits))
        }
        return Codec2Frame(v1: v1, v2: v2, woIndex: wo, eIndex: e, lspdIndices: d)
    }
}
