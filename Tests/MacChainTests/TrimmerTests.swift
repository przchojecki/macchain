import XCTest
@testable import MacChainLib

final class TrimmerTests: XCTestCase {

    func testCPUTrimRemovesDegree1() {
        // Build a graph where some nodes have degree 1 (leaves)
        // Leaf edges should be trimmed
        let edges = [
            // These form a small dense cluster (will survive)
            Edge(u: 0, v: 0),
            Edge(u: 1, v: 0),
            Edge(u: 1, v: 1),
            Edge(u: 0, v: 1),
            // These are leaves (degree 1 on at least one side)
            Edge(u: 10, v: 10),  // u=10 appears once, v=10 appears once
            Edge(u: 20, v: 20),  // u=20 appears once, v=20 appears once
        ]

        // Manually run CPU trimming
        let surviving = cpuTrim(edges: edges, numNodes: 100, trimRounds: 10)
        let survivingEdges = surviving.map { edges[$0] }

        // The leaf edges (indices 4, 5) should be trimmed
        // The cluster edges (indices 0-3) should survive
        XCTAssertEqual(surviving.count, 4, "Only the 4-cycle cluster should survive")
        for idx in surviving {
            XCTAssertTrue(idx < 4, "Surviving edge \(idx) should be from the cluster")
        }
    }

    func testCPUTrimPreservesCycles() {
        // A 4-cycle: all nodes have degree 2, nothing to trim
        let edges = [
            Edge(u: 0, v: 0),
            Edge(u: 1, v: 0),
            Edge(u: 1, v: 1),
            Edge(u: 0, v: 1),
        ]

        let surviving = cpuTrim(edges: edges, numNodes: 100, trimRounds: 10)
        XCTAssertEqual(surviving.count, 4, "Cycle should survive trimming intact")
    }

    func testCPUTrimRemovesAll() {
        // A path (no cycles) — all nodes eventually have degree 1
        let edges = [
            Edge(u: 0, v: 0),
            Edge(u: 1, v: 0),
            Edge(u: 1, v: 1),
            Edge(u: 2, v: 1),
            Edge(u: 2, v: 2),
        ]

        let surviving = cpuTrim(edges: edges, numNodes: 100, trimRounds: 20)
        XCTAssertEqual(surviving.count, 0, "A path graph should be fully trimmed")
    }

    // MARK: - Helper

    private func cpuTrim(edges: [Edge], numNodes: Int, trimRounds: Int) -> [Int] {
        var alive = [Bool](repeating: true, count: edges.count)
        var degU = [UInt32: Int]()
        var degV = [UInt32: Int]()

        for e in edges {
            degU[e.u, default: 0] += 1
            degV[e.v, default: 0] += 1
        }

        for _ in 0..<trimRounds {
            for (i, e) in edges.enumerated() where alive[i] {
                if (degU[e.u] ?? 0) <= 1 {
                    alive[i] = false
                    degU[e.u, default: 0] -= 1
                    degV[e.v, default: 0] -= 1
                }
            }
            for (i, e) in edges.enumerated() where alive[i] {
                if (degV[e.v] ?? 0) <= 1 {
                    alive[i] = false
                    degU[e.u, default: 0] -= 1
                    degV[e.v, default: 0] -= 1
                }
            }
        }

        return (0..<edges.count).filter { alive[$0] }
    }
}
