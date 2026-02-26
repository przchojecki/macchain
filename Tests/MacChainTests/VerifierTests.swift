import XCTest
@testable import MacChainLib

final class VerifierTests: XCTestCase {

    func testProofSerialization() {
        let header = Data(repeating: 0xAA, count: 80)
        let proof = MacChainProof(
            blockHeader: header,
            nonce: 12345,
            cycleEdges: [10, 20, 30, 40, 50, 60, 70, 80]
        )

        let serialized = proof.serialized()
        XCTAssertEqual(serialized.count, 120) // 80 + 8 + 32

        let deserialized = MacChainProof.deserialize(from: serialized)
        XCTAssertNotNil(deserialized)
        XCTAssertEqual(deserialized?.nonce, 12345)
        XCTAssertEqual(deserialized?.cycleEdges, [10, 20, 30, 40, 50, 60, 70, 80])
        XCTAssertEqual(deserialized?.blockHeader, header)
    }

    func testProofDeserializeRejectsShortData() {
        let shortData = Data(repeating: 0, count: 50)
        XCTAssertNil(MacChainProof.deserialize(from: shortData))
    }

    func testDifficultyCompact() {
        // Very easy target
        let easy = Difficulty(compact: 0x1f00_ffff)
        XCTAssertEqual(easy.target.count, 32)
        // Expanded target should have at least one non-zero byte.
        XCTAssertTrue(easy.target.contains { $0 != 0 })
    }

    func testDifficultySatisfied() {
        // Use maximum difficulty (all FFs target)
        let easy = Difficulty(target: Data(repeating: 0xFF, count: 32))
        let proof = MacChainProof(
            blockHeader: Data(repeating: 0, count: 80),
            nonce: 0,
            cycleEdges: [0, 1, 2, 3, 4, 5, 6, 7]
        )
        XCTAssertTrue(easy.isSatisfied(by: proof), "Any hash should meet max target")
    }

    func testDifficultyNotSatisfied() {
        // Impossible target (all zeros)
        let impossible = Difficulty(target: Data(repeating: 0, count: 32))
        let proof = MacChainProof(
            blockHeader: Data(repeating: 0xAA, count: 80),
            nonce: 42,
            cycleEdges: [0, 1, 2, 3, 4, 5, 6, 7]
        )
        XCTAssertFalse(impossible.isSatisfied(by: proof), "No hash should meet zero target")
    }

    func testDifficultyAdjustment() {
        let currentBits: UInt32 = 0x1f00_ffff

        // If blocks took twice as long as expected, target should increase (easier)
        let easierBits = Difficulty.adjust(
            currentBits: currentBits,
            actualTimeSeconds: kTargetBlockTimeSeconds * Double(kBlocksPerAdjustment) * 2
        )

        // If blocks were mined twice as fast, target should decrease (harder)
        let harderBits = Difficulty.adjust(
            currentBits: currentBits,
            actualTimeSeconds: kTargetBlockTimeSeconds * Double(kBlocksPerAdjustment) / 2
        )

        // The "easier" target should be numerically larger than "harder"
        let easierTarget = Difficulty(compact: easierBits)
        let harderTarget = Difficulty(compact: harderBits)

        // Compare: easier target should be >= harder target
        var easierIsLarger = false
        for i in 0..<32 {
            if easierTarget.target[i] > harderTarget.target[i] {
                easierIsLarger = true
                break
            } else if easierTarget.target[i] < harderTarget.target[i] {
                break
            }
        }
        XCTAssertTrue(easierIsLarger, "Slower blocks should increase target (easier)")
    }

    func testBlockHeaderSerialization() {
        let header = BlockHeader(
            prevHash: Data(repeating: 0xAA, count: 32),
            merkleRoot: Data(repeating: 0xBB, count: 32),
            timestamp: 1700000000,
            bits: 0x1f00ffff,
            version: 1
        )

        let data = header.serialized()
        XCTAssertEqual(data.count, 80)
    }
}
