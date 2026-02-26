import Foundation
import CryptoKit

/// Mining loop orchestration.
/// Runs Phase 1 → Phase 2 → Phase 3 for each nonce, checking for valid proofs.
public final class Miner {
    public let params: MacChainParams
    public let difficulty: Difficulty
    private var cancelled = false

    public init(params: MacChainParams = .default, difficulty: Difficulty = .initial) {
        self.params = params
        self.difficulty = difficulty
    }

    /// Mine starting from a given nonce. Returns when a valid proof is found or cancelled.
    public func mine(
        blockHeader: BlockHeader,
        startNonce: UInt64 = 0,
        maxAttempts: UInt64 = .max,
        onProgress: ((MinerProgress) -> Void)? = nil
    ) -> MiningResult {
        cancelled = false

        let headerData = blockHeader.serialized()
        let edgeGen = EdgeGenerator(params: params)

        let trimmer: Trimmer?
        do {
            trimmer = try Trimmer(params: params)
        } catch {
            print("Warning: Metal GPU not available, falling back to CPU trimming: \(error)")
            trimmer = nil
        }

        var nonce = startNonce
        var attempts: UInt64 = 0
        let startTime = CFAbsoluteTimeGetCurrent()

        while !cancelled && attempts < maxAttempts {
            let graphStart = CFAbsoluteTimeGetCurrent()

            // Phase 1: Edge generation
            let phase1Start = CFAbsoluteTimeGetCurrent()
            let edges = edgeGen.generateEdges(blockHeader: headerData, nonce: nonce)
            let phase1Time = CFAbsoluteTimeGetCurrent() - phase1Start

            // Phase 2: Edge trimming
            let phase2Start = CFAbsoluteTimeGetCurrent()
            let survivingIndices: [Int]
            if let trimmer = trimmer {
                do {
                    survivingIndices = try trimmer.trim(edges: edges)
                } catch {
                    print("GPU trimming failed: \(error), skipping nonce \(nonce)")
                    nonce &+= 1
                    attempts += 1
                    continue
                }
            } else {
                survivingIndices = cpuTrim(edges: edges)
            }
            let phase2Time = CFAbsoluteTimeGetCurrent() - phase2Start

            // Phase 3: Cycle detection
            let phase3Start = CFAbsoluteTimeGetCurrent()
            let survivingEdges = survivingIndices.map { edges[$0] }
            let cycleResult = CycleFinder.findCycle(
                edges: survivingEdges,
                survivingIndices: survivingIndices
            )
            let phase3Time = CFAbsoluteTimeGetCurrent() - phase3Start

            let graphTime = CFAbsoluteTimeGetCurrent() - graphStart

            if let cycle = cycleResult {
                // Found a cycle — construct proof and check difficulty
                let proof = MacChainProof(
                    blockHeader: headerData,
                    nonce: nonce,
                    cycleEdges: cycle.edgeIndices.map { UInt32($0) }
                )

                if difficulty.isSatisfied(by: proof) {
                    let totalTime = CFAbsoluteTimeGetCurrent() - startTime
                    onProgress?(MinerProgress(
                        nonce: nonce,
                        attempts: attempts + 1,
                        graphTimeMs: graphTime * 1000,
                        phase1Ms: phase1Time * 1000,
                        phase2Ms: phase2Time * 1000,
                        phase3Ms: phase3Time * 1000,
                        survivingEdges: survivingIndices.count,
                        cycleFound: true,
                        totalTimeS: totalTime
                    ))
                    return .found(proof)
                }

                // Cycle found but doesn't meet difficulty — keep going
            }

            attempts += 1

            if attempts % 10 == 0 {
                let totalTime = CFAbsoluteTimeGetCurrent() - startTime
                onProgress?(MinerProgress(
                    nonce: nonce,
                    attempts: attempts,
                    graphTimeMs: graphTime * 1000,
                    phase1Ms: phase1Time * 1000,
                    phase2Ms: phase2Time * 1000,
                    phase3Ms: phase3Time * 1000,
                    survivingEdges: survivingIndices.count,
                    cycleFound: cycleResult != nil,
                    totalTimeS: totalTime
                ))
            }

            nonce &+= 1
        }

        return cancelled ? .cancelled : .notFound
    }

    /// Cancel the mining loop.
    public func cancel() {
        cancelled = true
    }

    // MARK: - CPU Fallback Trimmer

    /// Simple CPU-based trimming fallback when Metal is unavailable.
    private func cpuTrim(edges: [Edge]) -> [Int] {
        var alive = [Bool](repeating: true, count: edges.count)
        var degreeU = [UInt32: Int]()
        var degreeV = [UInt32: Int]()

        // Count initial degrees
        for edge in edges {
            degreeU[edge.u, default: 0] += 1
            degreeV[edge.v, default: 0] += 1
        }

        for _ in 0..<params.trimRounds {
            // Trim U side
            for (i, edge) in edges.enumerated() where alive[i] {
                if (degreeU[edge.u] ?? 0) <= 1 {
                    alive[i] = false
                    degreeU[edge.u, default: 0] -= 1
                    degreeV[edge.v, default: 0] -= 1
                }
            }
            // Trim V side
            for (i, edge) in edges.enumerated() where alive[i] {
                if (degreeV[edge.v] ?? 0) <= 1 {
                    alive[i] = false
                    degreeU[edge.u, default: 0] -= 1
                    degreeV[edge.v, default: 0] -= 1
                }
            }
        }

        return (0..<edges.count).filter { alive[$0] }
    }
}

// MARK: - Progress

public struct MinerProgress {
    public let nonce: UInt64
    public let attempts: UInt64
    public let graphTimeMs: Double
    public let phase1Ms: Double
    public let phase2Ms: Double
    public let phase3Ms: Double
    public let survivingEdges: Int
    public let cycleFound: Bool
    public let totalTimeS: Double

    public var graphsPerSecond: Double {
        guard totalTimeS > 0 else { return 0 }
        return Double(attempts) / totalTimeS
    }
}
