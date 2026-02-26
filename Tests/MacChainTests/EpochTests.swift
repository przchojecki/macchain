import XCTest
@testable import MacChainLib

final class EpochTests: XCTestCase {

    func testDefaultParams() {
        let p = MacChainParams.default
        XCTAssertEqual(p.scratchpadSize, 16_777_216)
        XCTAssertEqual(p.numEdges, 1 << 24)
        XCTAssertEqual(p.numNodes, 1 << 23)
        XCTAssertEqual(p.nodeMask, 0x7FFFFF)
        XCTAssertEqual(p.matrixDim, 16)
        XCTAssertEqual(p.trimRounds, 80)
    }

    func testEpochDeriveIsDeterministic() {
        let seed = Data(repeating: 0xAB, count: 32)
        let params1 = EpochParams.derive(from: seed)
        let params2 = EpochParams.derive(from: seed)

        XCTAssertEqual(params1.scratchpadSize, params2.scratchpadSize)
        XCTAssertEqual(params1.numEdges, params2.numEdges)
        XCTAssertEqual(params1.numNodes, params2.numNodes)
        XCTAssertEqual(params1.matrixDim, params2.matrixDim)
        XCTAssertEqual(params1.trimRounds, params2.trimRounds)
    }

    func testEpochParamRanges() {
        // Test many seeds to verify params stay in valid ranges
        for i in 0..<100 {
            let seed = Data(repeating: UInt8(i), count: 32)
            let params = EpochParams.derive(from: seed)

            XCTAssertGreaterThanOrEqual(params.scratchpadSize, 12 * 1_048_576)
            XCTAssertLessThanOrEqual(params.scratchpadSize, 20 * 1_048_576)

            XCTAssertTrue([1 << 23, 1 << 24, 1 << 25].contains(params.numEdges))
            XCTAssertEqual(params.numNodes, params.numEdges / 2)

            XCTAssertTrue([8, 16, 32].contains(params.matrixDim))

            XCTAssertGreaterThanOrEqual(params.trimRounds, 60)
            XCTAssertLessThanOrEqual(params.trimRounds, 100)
        }
    }

    func testDifferentSeedsDifferentParams() {
        let seed1 = Data(repeating: 0x00, count: 32)
        let seed2 = Data(repeating: 0xFF, count: 32)
        let p1 = EpochParams.derive(from: seed1)
        let p2 = EpochParams.derive(from: seed2)

        // At least some params should differ (extremely unlikely to be identical)
        let same = (p1.scratchpadSize == p2.scratchpadSize) &&
                   (p1.numEdges == p2.numEdges) &&
                   (p1.matrixDim == p2.matrixDim) &&
                   (p1.trimRounds == p2.trimRounds)
        // This could theoretically be true but is astronomically unlikely
        XCTAssertFalse(same, "Different seeds should produce different params (probabilistic)")
    }

    func testEpochNumber() {
        XCTAssertEqual(EpochParams.epochNumber(forBlock: 0), 0)
        XCTAssertEqual(EpochParams.epochNumber(forBlock: 4095), 0)
        XCTAssertEqual(EpochParams.epochNumber(forBlock: 4096), 1)
        XCTAssertEqual(EpochParams.epochNumber(forBlock: 8191), 1)
        XCTAssertEqual(EpochParams.epochNumber(forBlock: 8192), 2)
    }
}
