import Foundation

/// Verifies MacChain proofs.
public struct Verifier {
    public let params: MacChainParams
    public let expectedBits: UInt32?
    public let enforceTrimmedCycle: Bool
    public let difficulty: Difficulty

    public init(
        params: MacChainParams = .default,
        difficulty: Difficulty = .initial,
        expectedBits: UInt32? = nil,
        enforceTrimmedCycle: Bool = true
    ) {
        self.params = params
        self.expectedBits = expectedBits
        self.enforceTrimmedCycle = enforceTrimmedCycle
        self.difficulty = difficulty
    }

    /// Verify a complete proof.
    public func verify(_ proof: MacChainProof) -> VerificationResult {
        let metadata = validateProofMetadata(proof)
        guard case .valid = metadata else {
            return metadata
        }
        let indices = proof.cycleEdges.map(Int.init)

        guard let bits = headerBits(from: proof.blockHeader) else {
            return .invalid("Proof header must contain a valid 80-byte block header")
        }
        if let expectedBits, bits != expectedBits {
            return .invalid("Header bits \(String(format: "0x%08x", bits)) do not match expected \(String(format: "0x%08x", expectedBits))")
        }

        let headerDifficulty = Difficulty(compact: bits)
        if isEasier(headerDifficulty.target, than: difficulty.target) {
            return .invalid("Header bits are easier than allowed network target")
        }
        if !headerDifficulty.isSatisfied(by: proof) {
            return .invalid("Proof hash does not meet difficulty target")
        }

        let edgeGen = EdgeGenerator(params: params)
        let proofEdges: [Edge]

        if enforceTrimmedCycle {
            let allEdges = edgeGen.generateEdges(
                blockHeader: proof.blockHeader,
                nonce: proof.nonce
            )

            var selected: [Edge] = []
            selected.reserveCapacity(indices.count)
            for idx in indices {
                selected.append(allEdges[idx])
            }
            proofEdges = selected

            if !Self.formsValidCycle(proofEdges) {
                return .invalid("Edges do not form a valid single 8-cycle")
            }

            let alive = trimmedAliveMask(edges: allEdges)
            for idx in indices where idx >= alive.count || !alive[idx] {
                return .invalid("Proof cycle edges do not survive trimming")
            }
        } else {
            let edgeMap = edgeGen.generateEdges(
                blockHeader: proof.blockHeader,
                nonce: proof.nonce,
                atIndices: indices
            )

            var selected: [Edge] = []
            selected.reserveCapacity(indices.count)
            for idx in indices {
                guard let edge = edgeMap[idx] else {
                    return .invalid("Failed to compute edge at index \(idx)")
                }
                selected.append(edge)
            }
            proofEdges = selected

            if !Self.formsValidCycle(proofEdges) {
                return .invalid("Edges do not form a valid single 8-cycle")
            }
        }

        return .valid
    }

    /// Verify only that the edges form a valid cycle (skip difficulty check).
    public func verifyCycleOnly(_ proof: MacChainProof) -> VerificationResult {
        let metadata = validateProofMetadata(proof)
        guard case .valid = metadata else {
            return metadata
        }
        let indices = proof.cycleEdges.map(Int.init)

        let edgeGen = EdgeGenerator(params: params)
        let edgeMap = edgeGen.generateEdges(
            blockHeader: proof.blockHeader,
            nonce: proof.nonce,
            atIndices: indices
        )

        var edges = [Edge]()
        for idx in indices {
            guard let edge = edgeMap[idx] else {
                return .invalid("Failed to compute edge at index \(idx)")
            }
            edges.append(edge)
        }

        if !Self.formsValidCycle(edges) {
            return .invalid("Edges do not form a valid single 8-cycle")
        }

        return .valid
    }

    // MARK: - Internal Helpers

    /// Internal helper exposed for tests via @testable.
    static func formsValidCycle(_ edges: [Edge]) -> Bool {
        guard edges.count == kCycleLength else { return false }
        guard Set(edges).count == kCycleLength else { return false }

        var uNodes = Set<UInt32>()
        var vNodes = Set<UInt32>()
        var adjacency = [BipartiteNode: [BipartiteNode]]()

        for edge in edges {
            uNodes.insert(edge.u)
            vNodes.insert(edge.v)

            let uNode = BipartiteNode.u(edge.u)
            let vNode = BipartiteNode.v(edge.v)
            adjacency[uNode, default: []].append(vNode)
            adjacency[vNode, default: []].append(uNode)
        }

        guard uNodes.count == kCycleLength / 2 && vNodes.count == kCycleLength / 2 else {
            return false
        }
        guard adjacency.count == kCycleLength else { return false }

        for neighbors in adjacency.values {
            guard neighbors.count == 2 else { return false }
        }

        guard let start = adjacency.keys.first else { return false }
        var visited: Set<BipartiteNode> = [start]
        var queue: [BipartiteNode] = [start]
        var readIdx = 0

        while readIdx < queue.count {
            let node = queue[readIdx]
            readIdx += 1

            for next in adjacency[node] ?? [] {
                if visited.insert(next).inserted {
                    queue.append(next)
                }
            }
        }

        // Two disjoint 4-cycles satisfy degree checks, but fail connectivity.
        return visited.count == adjacency.count
    }

    // MARK: - Private

    private enum BipartiteNode: Hashable {
        case u(UInt32)
        case v(UInt32)
    }

    private func validateProofMetadata(_ proof: MacChainProof) -> VerificationResult {
        guard proof.blockHeader.count == 80 else {
            return .invalid("Proof header must be exactly 80 bytes")
        }

        guard proof.cycleEdges.count == kCycleLength else {
            return .invalid("Proof must contain exactly \(kCycleLength) edges")
        }

        guard Set(proof.cycleEdges).count == kCycleLength else {
            return .invalid("Proof contains duplicate edge indices")
        }

        for idx in proof.cycleEdges {
            guard idx < UInt32(params.numEdges) else {
                return .invalid("Edge index \(idx) out of range")
            }
        }

        return .valid
    }

    private func headerBits(from header: Data) -> UInt32? {
        guard header.count >= 76 else { return nil }
        let b0 = UInt32(header[72])
        let b1 = UInt32(header[73]) << 8
        let b2 = UInt32(header[74]) << 16
        let b3 = UInt32(header[75]) << 24
        return b0 | b1 | b2 | b3
    }

    private func isEasier(_ lhs: Data, than rhs: Data) -> Bool {
        let l = Array(lhs.prefix(32))
        let r = Array(rhs.prefix(32))
        for i in 0..<32 {
            let lb = i < l.count ? l[i] : 0
            let rb = i < r.count ? r[i] : 0
            if lb > rb { return true }
            if lb < rb { return false }
        }
        return false
    }

    private func trimmedAliveMask(edges: [Edge]) -> [Bool] {
        var alive = [Bool](repeating: true, count: edges.count)
        var degreeU = [Int32](repeating: 0, count: params.numNodes)
        var degreeV = [Int32](repeating: 0, count: params.numNodes)

        for edge in edges {
            let u = Int(edge.u)
            let v = Int(edge.v)
            guard u < degreeU.count, v < degreeV.count else {
                return [Bool](repeating: false, count: edges.count)
            }
            degreeU[u] += 1
            degreeV[v] += 1
        }

        for _ in 0..<params.trimRounds {
            var changed = false

            for (i, edge) in edges.enumerated() where alive[i] {
                let u = Int(edge.u)
                let v = Int(edge.v)
                guard u < degreeU.count, v < degreeV.count else {
                    alive[i] = false
                    changed = true
                    continue
                }
                if degreeU[u] <= 1 {
                    alive[i] = false
                    changed = true

                    if degreeU[u] > 0 { degreeU[u] -= 1 }
                    if degreeV[v] > 0 { degreeV[v] -= 1 }
                }
            }

            for (i, edge) in edges.enumerated() where alive[i] {
                let v = Int(edge.v)
                let u = Int(edge.u)
                guard u < degreeU.count, v < degreeV.count else {
                    alive[i] = false
                    changed = true
                    continue
                }
                if degreeV[v] <= 1 {
                    alive[i] = false
                    changed = true

                    if degreeV[v] > 0 { degreeV[v] -= 1 }
                    if degreeU[u] > 0 { degreeU[u] -= 1 }
                }
            }

            if !changed { break }
        }

        return alive
    }
}

// MARK: - Verification Result

public enum VerificationResult: Equatable {
    case valid
    case invalid(String)

    public var isValid: Bool {
        if case .valid = self { return true }
        return false
    }
}
