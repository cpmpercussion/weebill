// KATSupport.swift — loading helpers for the conformance.md §B1 vectors.

import Foundation
import XCTest

enum KAT {
    /// Locates a file copied from `codec2-3200-spec/vectors/kat/`.
    static func url(_ name: String) throws -> URL {
        guard let u = Bundle.module.url(forResource: "Resources/\(name)", withExtension: nil)
                ?? Bundle.module.url(forResource: name, withExtension: nil) else {
            throw XCTSkip("KAT resource \(name) not found in test bundle")
        }
        return u
    }

    static func lines(_ name: String) throws -> [String] {
        let text = try String(contentsOf: try url(name), encoding: .utf8)
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Rows of a CSV, header dropped, split on commas (no quoting in these files).
    static func rows(_ name: String) throws -> [[String]] {
        var l = try lines(name)
        if !l.isEmpty { l.removeFirst() }  // header
        return l.map { $0.split(separator: ",", omittingEmptySubsequences: false)
                         .map { String($0).trimmingCharacters(in: .whitespaces) } }
    }

    static func ints(_ field: String) -> [Int] {
        field.split(separator: " ").compactMap { Int($0) }
    }

    static func doubles(_ field: String) -> [Double] {
        field.split(separator: " ").compactMap { Double($0) }
    }

    static func bytes(_ name: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: try url(name)))
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
