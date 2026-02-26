import XCTest
@testable import MacChainLib

final class EdgeGenTests: XCTestCase {

    // Use small params for fast tests
    static let testParams = MacChainParams(
        scratchpadSize: 1_048_576,   // 1 MB
        numEdges: 1 << 12,           // 4096 edges
        numNodes: 1 << 11,           // 2048 nodes per side
        nodeMask: 0x7FF,             // 11-bit mask
        matrixDim: 8,                // 8x8 matrix
        trimRounds: 20
    )

    func testScratchpadFillDeterministic() {
        let scratchpad1 = Scratchpad(size: Self.testParams.scratchpadSize)
        let scratchpad2 = Scratchpad(size: Self.testParams.scratchpadSize)
        let header = Data(repeating: 0x42, count: 80)
        let nonce: UInt64 = 12345

        scratchpad1.fill(blockHeader: header, nonce: nonce)
        scratchpad2.fill(blockHeader: header, nonce: nonce)

        // Compare first 256 bytes
        let ptr1 = scratchpad1.buffer
        let ptr2 = scratchpad2.buffer
        for i in 0..<256 {
            XCTAssertEqual(
                ptr1.load(fromByteOffset: i, as: UInt8.self),
                ptr2.load(fromByteOffset: i, as: UInt8.self),
                "Scratchpad mismatch at byte \(i)"
            )
        }
    }

    func testScratchpadDifferentNonces() {
        let scratchpad = Scratchpad(size: Self.testParams.scratchpadSize)
        let header = Data(repeating: 0x42, count: 80)

        scratchpad.fill(blockHeader: header, nonce: 0)
        var bytes0 = [UInt8](repeating: 0, count: 16)
        scratchpad.buffer.copyMemory(from: scratchpad.buffer, byteCount: 16)
        for i in 0..<16 {
            bytes0[i] = scratchpad.buffer.load(fromByteOffset: i, as: UInt8.self)
        }

        scratchpad.fill(blockHeader: header, nonce: 1)
        var bytes1 = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 {
            bytes1[i] = scratchpad.buffer.load(fromByteOffset: i, as: UInt8.self)
        }

        XCTAssertNotEqual(bytes0, bytes1, "Different nonces should produce different scratchpads")
    }

    func testEdgeGenDeterministic() {
        let gen = EdgeGenerator(params: Self.testParams)
        let header = Data(repeating: 0xAA, count: 80)
        let nonce: UInt64 = 42

        let edges1 = gen.generateEdges(blockHeader: header, nonce: nonce)
        let edges2 = gen.generateEdges(blockHeader: header, nonce: nonce)

        XCTAssertEqual(edges1.count, Self.testParams.numEdges)
        XCTAssertEqual(edges1, edges2, "Same inputs must produce identical edges")
    }

    func testEdgeEndpointsInRange() {
        let gen = EdgeGenerator(params: Self.testParams)
        let header = Data(repeating: 0xBB, count: 80)
        let edges = gen.generateEdges(blockHeader: header, nonce: 0)

        for (i, edge) in edges.enumerated() {
            XCTAssertLessThan(edge.u, UInt32(Self.testParams.numNodes),
                              "Edge \(i) u=\(edge.u) exceeds numNodes")
            XCTAssertLessThan(edge.v, UInt32(Self.testParams.numNodes),
                              "Edge \(i) v=\(edge.v) exceeds numNodes")
        }
    }

    func testSingleEdgeMatchesBatch() {
        let gen = EdgeGenerator(params: Self.testParams)
        let header = Data(repeating: 0xCC, count: 80)
        let nonce: UInt64 = 7

        let allEdges = gen.generateEdges(blockHeader: header, nonce: nonce)

        // Check a few specific indices
        let indicesToCheck = [0, 1, 10, 100, Self.testParams.numEdges - 1]
        let batchResult = gen.generateEdges(
            blockHeader: header,
            nonce: nonce,
            atIndices: indicesToCheck
        )

        for idx in indicesToCheck {
            guard let edge = batchResult[idx] else {
                XCTFail("Missing edge at index \(idx)")
                continue
            }
            XCTAssertEqual(edge, allEdges[idx],
                           "Edge at index \(idx) doesn't match: batch=\(edge) vs full=\(allEdges[idx])")
        }
    }
}
