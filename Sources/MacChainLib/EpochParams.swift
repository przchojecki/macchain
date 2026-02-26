import Foundation
import CryptoKit

public struct EpochParams {
    public let seed: Data
    public let params: MacChainParams

    public init(epochSeed: Data) {
        self.seed = epochSeed
        self.params = EpochParams.derive(from: epochSeed)
    }

    public init(blockHash: Data) {
        let seed = Data(SHA256.hash(data: blockHash))
        self.seed = seed
        self.params = EpochParams.derive(from: seed)
    }

    public static func derive(from seed: Data) -> MacChainParams {
        // Expand seed into parameter bytes using SHA-256 chain
        let expanded = expand(seed: seed)

        let scratchpadMB = 12 + Int(expanded[0] % 9)          // 12–20 MB
        let scratchpadSize = scratchpadMB * 1_048_576

        let edgeShift = 23 + Int(expanded[1] % 3)             // 23, 24, or 25
        let numEdges = 1 << edgeShift

        let matrixShift = Int(expanded[2] % 3)                // 0, 1, or 2
        let matrixDim = 8 << matrixShift                      // 8, 16, or 32

        let trimRounds = 60 + Int(expanded[3] % 41)           // 60–100

        let numNodes = numEdges / 2                            // E/N = 2.0
        let nodeBits = UInt32(edgeShift - 1)                   // log2(numNodes)
        let nodeMask = (UInt32(1) << nodeBits) - 1

        return MacChainParams(
            scratchpadSize: scratchpadSize,
            numEdges: numEdges,
            numNodes: numNodes,
            nodeMask: nodeMask,
            matrixDim: matrixDim,
            trimRounds: trimRounds
        )
    }

    static func expand(seed: Data) -> [UInt8] {
        let hash = SHA256.hash(data: seed)
        return Array(hash)
    }

    /// Compute epoch number from block height
    public static func epochNumber(forBlock height: UInt64) -> UInt64 {
        height / kBlocksPerEpoch
    }

    /// Get the seed for an epoch based on the last block hash of the previous epoch
    public static func epochSeed(fromBlockHash hash: Data) -> Data {
        Data(SHA256.hash(data: hash))
    }
}
