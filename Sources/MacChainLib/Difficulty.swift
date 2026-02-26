import Foundation
import CryptoKit

/// Difficulty adjustment for MacChain proof-of-work.
public struct Difficulty {

    /// The 256-bit target. A valid proof hash must be <= this value.
    public let target: Data  // 32 bytes, big-endian

    public init(target: Data) {
        self.target = target
    }

    /// Create from compact "bits" representation (similar to Bitcoin's nBits).
    /// Format: first byte = number of bytes, remaining 3 bytes = coefficient.
    /// target = coefficient * 2^(8*(exponent-3))
    public init(compact bits: UInt32) {
        let exponent = Int(bits >> 24)
        let coefficient = bits & 0x007F_FFFF

        var target = Data(repeating: 0, count: 32)
        if exponent <= 3 {
            let shifted = coefficient >> (8 * (3 - exponent))
            target[31] = UInt8(shifted & 0xFF)
            if exponent >= 2 { target[30] = UInt8((shifted >> 8) & 0xFF) }
            if exponent >= 3 { target[29] = UInt8((shifted >> 16) & 0xFF) }
        } else {
            let offset = 32 - exponent
            if offset >= 0 && offset < 32 {
                target[offset] = UInt8((coefficient >> 16) & 0xFF)
                if offset + 1 < 32 { target[offset + 1] = UInt8((coefficient >> 8) & 0xFF) }
                if offset + 2 < 32 { target[offset + 2] = UInt8(coefficient & 0xFF) }
            }
        }

        self.target = target
    }

    /// Default initial difficulty (very easy — for testing/genesis).
    public static let initial = Difficulty(compact: 0x1f00_ffff)

    /// Check if a proof's hash meets the difficulty target.
    public func isSatisfied(by proof: MacChainProof) -> Bool {
        let proofHash = Data(SHA256.hash(data: proof.serialized()))
        return compareBigEndian(proofHash, isLessOrEqual: target)
    }

    /// Check if raw hash bytes meet the target.
    public func isSatisfied(byHash hash: Data) -> Bool {
        compareBigEndian(hash, isLessOrEqual: target)
    }

    /// Adjust difficulty based on actual time taken for a block window.
    /// Returns new compact bits value.
    public static func adjust(
        currentBits: UInt32,
        actualTimeSeconds: Double,
        expectedTimeSeconds: Double = kTargetBlockTimeSeconds * Double(kBlocksPerAdjustment)
    ) -> UInt32 {
        // Ratio of actual to expected time
        var ratio = actualTimeSeconds / expectedTimeSeconds

        // Clamp to 4x adjustment per period (like Bitcoin)
        ratio = max(0.25, min(4.0, ratio))

        // Convert current bits to target, multiply by ratio, convert back
        let currentTarget = Difficulty(compact: currentBits).target

        // Simple scaling: multiply target by ratio
        // Higher ratio = more time taken = difficulty too high = increase target (make easier)
        var targetValue = targetToDouble(currentTarget) * ratio
        targetValue = min(targetValue, pow(2.0, 256) - 1) // cap at max

        return doubleToCompact(targetValue)
    }

    // MARK: - Private

    private func compareBigEndian(_ a: Data, isLessOrEqual b: Data) -> Bool {
        let aBytes = Array(a.prefix(32))
        let bBytes = Array(b.prefix(32))
        for i in 0..<32 {
            let ab = i < aBytes.count ? aBytes[i] : 0
            let bb = i < bBytes.count ? bBytes[i] : 0
            if ab < bb { return true }
            if ab > bb { return false }
        }
        return true // equal
    }

    private static func targetToDouble(_ target: Data) -> Double {
        var value: Double = 0
        for (i, byte) in target.enumerated() {
            value += Double(byte) * pow(256.0, Double(31 - i))
        }
        return value
    }

    private static func doubleToCompact(_ value: Double) -> UInt32 {
        guard value > 0 else { return 0x0100_0001 }

        // Find the most significant byte position
        var v = value
        var exponent = 0
        while v >= 256 {
            v /= 256
            exponent += 1
        }
        exponent += 1 // 1-based

        // Extract 3 most significant bytes
        let coefficient = UInt32(value / pow(256.0, Double(max(0, exponent - 3))))
        let clampedCoeff = coefficient & 0x007F_FFFF

        return (UInt32(exponent) << 24) | clampedCoeff
    }
}
