import Foundation
import CryptoKit

/// Difficulty adjustment for MacChain proof-of-work.
public struct Difficulty {

    /// The 256-bit target. A valid proof hash must be <= this value.
    public let target: Data  // 32 bytes, big-endian

    public init(target: Data) {
        self.target = target
    }

    /// Compact representation (nBits-style) derived from the current target.
    public var compact: UInt32 {
        Self.compactFromTarget(target)
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
        guard expectedTimeSeconds > 0 else { return currentBits }

        let ratio = actualTimeSeconds / expectedTimeSeconds
        // Fixed-point ratio with 1_000_000 precision.
        let scaledRatio = UInt32(max(250_000, min(4_000_000, Int((ratio * 1_000_000.0).rounded()))))

        let currentTarget = Difficulty(compact: currentBits).target
        let adjustedTarget = scaleTarget(currentTarget, multiplyBy: scaledRatio, divideBy: 1_000_000)
        return compactFromTarget(adjustedTarget)
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

    private static func scaleTarget(_ target: Data, multiplyBy multiplier: UInt32, divideBy divisor: UInt32) -> Data {
        guard multiplier > 0, divisor > 0 else { return target }

        let words = wordsBE32(fromTarget: target)
        let multiplied = multiply(words: words, by: multiplier)
        let divided = divide(words: multiplied, by: divisor)

        // Overflow beyond 256 bits => clamp to max target.
        if divided[0] != 0 {
            return Data(repeating: 0xFF, count: 32)
        }

        return targetFromWordsBE32(Array(divided.dropFirst()))
    }

    private static func wordsBE32(fromTarget target: Data) -> [UInt32] {
        var padded = Data(target.prefix(32))
        if padded.count < 32 {
            padded.insert(contentsOf: repeatElement(UInt8(0), count: 32 - padded.count), at: 0)
        }

        var words = [UInt32](repeating: 0, count: 8)
        for i in 0..<8 {
            let offset = i * 4
            words[i] =
                (UInt32(padded[offset]) << 24) |
                (UInt32(padded[offset + 1]) << 16) |
                (UInt32(padded[offset + 2]) << 8) |
                UInt32(padded[offset + 3])
        }
        return words
    }

    private static func targetFromWordsBE32(_ words: [UInt32]) -> Data {
        var out = Data(capacity: 32)
        for word in words.prefix(8) {
            out.append(UInt8((word >> 24) & 0xFF))
            out.append(UInt8((word >> 16) & 0xFF))
            out.append(UInt8((word >> 8) & 0xFF))
            out.append(UInt8(word & 0xFF))
        }
        return out
    }

    private static func multiply(words: [UInt32], by multiplier: UInt32) -> [UInt32] {
        guard words.count == 8 else { return [UInt32](repeating: 0, count: 9) }

        var out = [UInt32](repeating: 0, count: 9)
        var carry: UInt64 = 0
        for i in stride(from: words.count - 1, through: 0, by: -1) {
            let product = UInt64(words[i]) * UInt64(multiplier) + carry
            out[i + 1] = UInt32(product & 0xFFFF_FFFF)
            carry = product >> 32
        }
        out[0] = UInt32(carry & 0xFFFF_FFFF)
        return out
    }

    private static func divide(words: [UInt32], by divisor: UInt32) -> [UInt32] {
        guard divisor > 0 else { return words }

        var out = [UInt32](repeating: 0, count: words.count)
        var remainder: UInt64 = 0
        for i in 0..<words.count {
            let value = (remainder << 32) | UInt64(words[i])
            out[i] = UInt32(value / UInt64(divisor))
            remainder = value % UInt64(divisor)
        }
        return out
    }

    private static func compactFromTarget(_ target: Data) -> UInt32 {
        let bytes = Array(target.prefix(32))
        guard let firstNonZero = bytes.firstIndex(where: { $0 != 0 }) else {
            return 0
        }

        var exponent = bytes.count - firstNonZero
        var coefficient: UInt32 = 0

        if exponent <= 3 {
            for i in 0..<exponent {
                coefficient |= UInt32(bytes[firstNonZero + i]) << UInt32(8 * (2 - i))
            }
            coefficient <<= UInt32(8 * (3 - exponent))
        } else {
            coefficient = UInt32(bytes[firstNonZero]) << 16
            if firstNonZero + 1 < bytes.count {
                coefficient |= UInt32(bytes[firstNonZero + 1]) << 8
            }
            if firstNonZero + 2 < bytes.count {
                coefficient |= UInt32(bytes[firstNonZero + 2])
            }
        }

        if (coefficient & 0x0080_0000) != 0 {
            coefficient >>= 8
            exponent += 1
        }

        coefficient &= 0x007F_FFFF
        return (UInt32(exponent) << 24) | coefficient
    }
}
