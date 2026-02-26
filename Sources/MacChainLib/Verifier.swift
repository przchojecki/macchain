import Foundation
import CryptoKit

/// Verifies MacChain proofs.
public struct Verifier {
    public let params: MacChainParams
    public let difficulty: Difficulty

    public init(params: MacChainParams = .default, difficulty: Difficulty = .initial) {
        self.params = params
        self.difficulty = difficulty
    }

    /// Verify a complete proof.
    /// Returns nil on success, or an error description on failure.
    public func verify(_ proof: MacChainProof) -> VerificationResult {
        // 1. Check proof format
        guard proof.cycleEdges.count == kCycleLength else {
            return .invalid("Proof must contain exactly \(kCycleLength) edges")
        }

        // Check for duplicate edge indices
        let edgeSet = Set(proof.cycleEdges)
        guard edgeSet.count == kCycleLength else {
            return .invalid("Proof contains duplicate edge indices")
        }

        // Check edge indices are in range
        for idx in proof.cycleEdges {
            guard idx < UInt32(params.numEdges) else {
                return .invalid("Edge index \(idx) out of range")
            }
        }

        // 2. Recompute edges
        let edgeGen = EdgeGenerator(params: params)
        let indices = proof.cycleEdges.map { Int($0) }
        let edgeMap = edgeGen.generateEdges(
            blockHeader: proof.blockHeader,
            nonce: proof.nonce,
            atIndices: indices
        )

        // Collect edges in order
        var edges = [Edge]()
        for idx in indices {
            guard let edge = edgeMap[idx] else {
                return .invalid("Failed to compute edge at index \(idx)")
            }
            edges.append(edge)
        }

        // 3. Verify cycle structure
        // The 8 edges must form a closed cycle in the bipartite graph.
        // In a bipartite 8-cycle: u0-v0-u1-v1-u2-v2-u3-v3-u0
        // Each consecutive pair of edges shares a node.
        if !verifyCycleStructure(edges) {
            return .invalid("Edges do not form a valid 8-cycle")
        }

        // 4. Check difficulty target
        if !difficulty.isSatisfied(by: proof) {
            return .invalid("Proof hash does not meet difficulty target")
        }

        return .valid
    }

    /// Verify only that the edges form a valid cycle (skip difficulty check).
    /// Useful for testing.
    public func verifyCycleOnly(_ proof: MacChainProof) -> VerificationResult {
        guard proof.cycleEdges.count == kCycleLength else {
            return .invalid("Proof must contain exactly \(kCycleLength) edges")
        }

        let edgeSet = Set(proof.cycleEdges)
        guard edgeSet.count == kCycleLength else {
            return .invalid("Proof contains duplicate edge indices")
        }

        let edgeGen = EdgeGenerator(params: params)
        let indices = proof.cycleEdges.map { Int($0) }
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

        if !verifyCycleStructure(edges) {
            return .invalid("Edges do not form a valid 8-cycle")
        }

        return .valid
    }

    // MARK: - Cycle Structure Verification

    /// Check that edges form a valid 8-cycle in a bipartite graph.
    /// A cycle alternates between U and V partitions:
    ///   edge0=(u0,v0), edge1=(u1,v1), ..., edge7=(u7,v7)
    /// must satisfy: consecutive edges share a node on alternating sides.
    private func verifyCycleStructure(_ edges: [Edge]) -> Bool {
        guard edges.count == kCycleLength else { return false }

        // No duplicate nodes allowed
        var uNodes = Set<UInt32>()
        var vNodes = Set<UInt32>()
        for edge in edges {
            uNodes.insert(edge.u)
            vNodes.insert(edge.v)
        }

        // In an 8-cycle with 8 edges in a bipartite graph, we visit 4 U-nodes and 4 V-nodes
        guard uNodes.count == kCycleLength / 2 && vNodes.count == kCycleLength / 2 else {
            return false
        }

        // Try to form a valid cycle by finding an ordering where consecutive edges
        // share nodes in the bipartite structure.
        // Build adjacency and verify connectivity as a cycle.
        return canFormCycle(edges)
    }

    /// Check if the given edges can be arranged into a single Hamiltonian cycle
    /// on their induced subgraph.
    private func canFormCycle(_ edges: [Edge]) -> Bool {
        // Build adjacency: for each U-node, which V-nodes; for each V-node, which U-nodes
        var uAdj = [UInt32: [UInt32]]()  // u -> [v]
        var vAdj = [UInt32: [UInt32]]()  // v -> [u]

        for edge in edges {
            uAdj[edge.u, default: []].append(edge.v)
            vAdj[edge.v, default: []].append(edge.u)
        }

        // Each node must have degree exactly 2 in the cycle subgraph
        for (_, vs) in uAdj {
            guard vs.count == 2 else { return false }
        }
        for (_, us) in vAdj {
            guard us.count == 2 else { return false }
        }

        // Walk the cycle: start at first edge's U-node
        let startU = edges[0].u
        var currentU = startU
        var currentV = uAdj[startU]![0]
        var visited = 1

        while visited < kCycleLength / 2 {
            // From currentV, go to the other U-node (not currentU)
            let uNeighbors = vAdj[currentV]!
            let nextU = uNeighbors[0] == currentU ? uNeighbors[1] : uNeighbors[0]

            // From nextU, go to the other V-node (not currentV)
            let vNeighbors = uAdj[nextU]!
            let nextV = vNeighbors[0] == currentV ? vNeighbors[1] : vNeighbors[0]

            currentU = nextU
            currentV = nextV
            visited += 1
        }

        // After visiting all 4 U-nodes, the cycle should close back to startU
        let uNeighbors = vAdj[currentV]!
        let finalU = uNeighbors[0] == currentU ? uNeighbors[1] : uNeighbors[0]

        return finalU == startU
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
