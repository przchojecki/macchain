import XCTest
@testable import MacChainLib

final class CycleFinderTests: XCTestCase {

    func testFind8CycleInKnownGraph() {
        // Construct a bipartite graph that contains a known 8-cycle.
        // 8-cycle: u0-v0-u1-v1-u2-v2-u3-v3-u0
        // Edges: (u0,v0), (u1,v0), (u1,v1), (u2,v1), (u2,v2), (u3,v2), (u3,v3), (u0,v3)
        let edges = [
            Edge(u: 0, v: 0),   // 0: u0-v0
            Edge(u: 1, v: 0),   // 1: u1-v0
            Edge(u: 1, v: 1),   // 2: u1-v1
            Edge(u: 2, v: 1),   // 3: u2-v1
            Edge(u: 2, v: 2),   // 4: u2-v2
            Edge(u: 3, v: 2),   // 5: u3-v2
            Edge(u: 3, v: 3),   // 6: u3-v3
            Edge(u: 0, v: 3),   // 7: u0-v3
        ]

        let indices = Array(0..<8)
        let result = CycleFinder.findCycle(edges: edges, survivingIndices: indices)

        XCTAssertNotNil(result, "Should find the 8-cycle")
        if let cycle = result {
            XCTAssertEqual(cycle.edgeIndices.count, kCycleLength)
            // All 8 edges should be used
            XCTAssertEqual(Set(cycle.edgeIndices).count, kCycleLength)
        }
    }

    func testNoCycleInTree() {
        // A tree (no cycles)
        let edges = [
            Edge(u: 0, v: 0),
            Edge(u: 1, v: 1),
            Edge(u: 2, v: 2),
            Edge(u: 3, v: 3),
        ]

        let indices = Array(0..<4)
        let result = CycleFinder.findCycle(edges: edges, survivingIndices: indices)
        XCTAssertNil(result, "Tree should have no cycles")
    }

    func testNoCycleInSmall4Cycle() {
        // A 4-cycle (too short for 8-cycle requirement)
        let edges = [
            Edge(u: 0, v: 0),
            Edge(u: 1, v: 0),
            Edge(u: 1, v: 1),
            Edge(u: 0, v: 1),
        ]

        let indices = Array(0..<4)
        let result = CycleFinder.findCycle(edges: edges, survivingIndices: indices)
        XCTAssertNil(result, "4-cycle graph should not yield an 8-cycle")
    }

    func testCycleWithExtraEdges() {
        // 8-cycle edges plus some extra edges
        var edges = [
            Edge(u: 0, v: 0),   // part of cycle
            Edge(u: 1, v: 0),   // part of cycle
            Edge(u: 1, v: 1),   // part of cycle
            Edge(u: 2, v: 1),   // part of cycle
            Edge(u: 2, v: 2),   // part of cycle
            Edge(u: 3, v: 2),   // part of cycle
            Edge(u: 3, v: 3),   // part of cycle
            Edge(u: 0, v: 3),   // part of cycle
            // Extra edges (not part of cycle)
            Edge(u: 4, v: 4),
            Edge(u: 5, v: 5),
            Edge(u: 4, v: 5),
            Edge(u: 6, v: 0),
        ]

        let indices = Array(0..<edges.count)
        let result = CycleFinder.findCycle(edges: edges, survivingIndices: indices)

        XCTAssertNotNil(result, "Should find 8-cycle among extra edges")
        if let cycle = result {
            XCTAssertEqual(cycle.edgeIndices.count, kCycleLength)
        }
    }

    func testEmptyGraph() {
        let result = CycleFinder.findCycle(edges: [], survivingIndices: [])
        XCTAssertNil(result)
    }
}
