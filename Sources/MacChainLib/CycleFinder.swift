import Foundation

/// Phase 3: Find an 8-cycle in the trimmed bipartite graph.
public final class CycleFinder {

    /// Result of cycle search
    public struct CycleResult {
        public let edgeIndices: [Int]    // indices into the original edge array
        public let edges: [Edge]         // the actual edges forming the cycle
    }

    /// Find an 8-cycle in the bipartite graph defined by the given edges.
    /// `survivingIndices` maps positions in `edges` back to original edge indices.
    /// Returns nil if no 8-cycle is found.
    public static func findCycle(
        edges: [Edge],
        survivingIndices: [Int]
    ) -> CycleResult? {
        let n = edges.count
        guard n > 0 else { return nil }

        // Build adjacency lists for the bipartite graph.
        // We tag U-nodes and V-nodes to avoid confusion:
        //   U-nodes: node ID as-is
        //   V-nodes: node ID + offset
        // But since it's bipartite, we store adjacency from U→V edges and V→U edges separately.

        // adj[u] = [(v, edgeIndex)] for U-side
        // adjV[v] = [(u, edgeIndex)] for V-side
        var adjU = [UInt32: [(v: UInt32, idx: Int)]]()
        var adjV = [UInt32: [(u: UInt32, idx: Int)]]()

        for (i, edge) in edges.enumerated() {
            adjU[edge.u, default: []].append((v: edge.v, idx: i))
            adjV[edge.v, default: []].append((u: edge.u, idx: i))
        }

        // Remove degree-1 nodes (they can't be in any cycle)
        // This is a CPU-side quick trim on the already-trimmed graph
        var degreeU = [UInt32: Int]()
        var degreeV = [UInt32: Int]()
        for edge in edges {
            degreeU[edge.u, default: 0] += 1
            degreeV[edge.v, default: 0] += 1
        }

        // BFS from each U-node, looking for a path that returns to the start
        // at exactly depth 8 (alternating U-V-U-V-U-V-U-V)
        // An 8-cycle in a bipartite graph alternates between U and V partitions:
        // u0 -> v0 -> u1 -> v1 -> u2 -> v2 -> u3 -> v3 -> u0
        // That's 8 edges: (u0,v0), (u1,v0), (u1,v1), (u2,v1), (u2,v2), (u3,v2), (u3,v3), (u0,v3)
        // Wait — in a bipartite graph, an 8-cycle uses 8 edges and visits 4 U-nodes and 4 V-nodes.

        // DFS approach: path tracks alternating (U, V) nodes
        // path[0] = u0, edge to v0, then from v0 edge to u1, etc.

        // For efficiency, we enumerate all paths of length 4 from each U-node
        // (going u->v->u->v->u through 4 edges) and check if any two paths
        // from the same start share an endpoint, forming the cycle.

        // Simpler: BFS to depth 4 from each U-node through the bipartite structure,
        // collecting all U-nodes reachable at distance 4 (4 edges = 2 hops in each partition).
        // If start node is reachable at distance 8 (8 edges), we have a cycle.

        // Actually, let's use the standard approach for small trimmed graphs:
        // For each edge (u0, v0), do a depth-limited DFS from v0 looking for
        // a path of length 7 more edges back to u0.

        let sortedUNodes = Array(adjU.keys).filter { (degreeU[$0] ?? 0) >= 2 }

        for startU in sortedUNodes {
            guard let neighbors = adjU[startU] else { continue }

            for (v0, edgeIdx0) in neighbors {
                // Try to find a path of 7 more edges from v0 back to startU
                // Path: startU -e0-> v0 -e1-> u1 -e2-> v1 -e3-> u2 -e4-> v2 -e5-> u3 -e6-> v3 -e7-> startU
                // We need 7 more edges (3 V→U + 4 U→V including the return)

                var path = [edgeIdx0]
                var usedEdges = Set([edgeIdx0])
                var usedU = Set([startU])
                var usedV = Set([v0])

                if dfs(
                    currentV: v0,
                    targetU: startU,
                    depth: 1,
                    maxDepth: kCycleLength,
                    path: &path,
                    usedEdges: &usedEdges,
                    usedU: &usedU,
                    usedV: &usedV,
                    adjU: adjU,
                    adjV: adjV,
                    degreeU: degreeU,
                    degreeV: degreeV
                ) {
                    // Map local indices back to original edge indices
                    let originalIndices = path.map { survivingIndices[$0] }
                    let cycleEdges = path.map { edges[$0] }
                    return CycleResult(edgeIndices: originalIndices, edges: cycleEdges)
                }
            }
        }

        return nil
    }

    /// DFS to find remaining edges of an 8-cycle.
    /// At even depths we're at a V-node looking for edges to U-nodes.
    /// At odd depths we're at a U-node looking for edges to V-nodes.
    private static func dfs(
        currentV: UInt32,
        targetU: UInt32,
        depth: Int,
        maxDepth: Int,
        path: inout [Int],
        usedEdges: inout Set<Int>,
        usedU: inout Set<UInt32>,
        usedV: inout Set<UInt32>,
        adjU: [UInt32: [(v: UInt32, idx: Int)]],
        adjV: [UInt32: [(u: UInt32, idx: Int)]],
        degreeU: [UInt32: Int],
        degreeV: [UInt32: Int]
    ) -> Bool {
        // We're at a V-node. Need to go to a U-node.
        guard let vNeighbors = adjV[currentV] else { return false }

        for (nextU, edgeIdx) in vNeighbors {
            guard !usedEdges.contains(edgeIdx) else { continue }

            // At depth 7 (last edge), we need nextU == targetU
            if depth == maxDepth - 1 {
                if nextU == targetU {
                    path.append(edgeIdx)
                    return true
                }
                continue
            }

            // Don't revisit U-nodes (except target at final step)
            guard !usedU.contains(nextU) else { continue }
            guard (degreeU[nextU] ?? 0) >= 2 else { continue }

            usedEdges.insert(edgeIdx)
            usedU.insert(nextU)
            path.append(edgeIdx)

            // Now from this U-node, go to a V-node
            if let uNeighbors = adjU[nextU] {
                for (nextV, edgeIdx2) in uNeighbors {
                    guard !usedEdges.contains(edgeIdx2) else { continue }
                    guard !usedV.contains(nextV) else { continue }
                    if depth + 2 < maxDepth - 1 {
                        guard (degreeV[nextV] ?? 0) >= 2 else { continue }
                    }

                    usedEdges.insert(edgeIdx2)
                    usedV.insert(nextV)
                    path.append(edgeIdx2)

                    if dfs(
                        currentV: nextV,
                        targetU: targetU,
                        depth: depth + 2,
                        maxDepth: maxDepth,
                        path: &path,
                        usedEdges: &usedEdges,
                        usedU: &usedU,
                        usedV: &usedV,
                        adjU: adjU,
                        adjV: adjV,
                        degreeU: degreeU,
                        degreeV: degreeV
                    ) {
                        return true
                    }

                    path.removeLast()
                    usedV.remove(nextV)
                    usedEdges.remove(edgeIdx2)
                }
            }

            path.removeLast()
            usedU.remove(nextU)
            usedEdges.remove(edgeIdx)
        }

        return false
    }
}
