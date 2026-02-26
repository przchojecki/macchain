import XCTest
import CryptoKit
@testable import MacChainLib

final class ChainStateTests: XCTestCase {
    func testTransactionRoundTripSerialization() {
        let tx = Transaction(
            inputs: [
                TransactionInput(
                    prevTxID: Data(repeating: 0x11, count: 32),
                    outputIndex: 2,
                    unlockingScript: Data([0x51, 0x21])
                )
            ],
            outputs: [
                TransactionOutput(value: 42, lockingScript: Data([0xAC]))
            ],
            lockTime: 7
        )

        let encoded = tx.serialized()
        let decoded = Transaction.deserialize(from: encoded)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.version, tx.version)
        XCTAssertEqual(decoded?.inputs.count, tx.inputs.count)
        XCTAssertEqual(decoded?.outputs.count, tx.outputs.count)
        XCTAssertEqual(decoded?.lockTime, tx.lockTime)
    }

    func testBlockRoundTripSerialization() {
        let tx = Transaction.coinbase(height: 0, value: 50, to: Data("miner".utf8))
        let merkle = Block.merkleRoot(for: [tx])
        let header = BlockHeader(
            prevHash: Data(repeating: 0, count: 32),
            merkleRoot: merkle,
            timestamp: 123,
            bits: 0x1f00ffff,
            version: 1
        )
        let proof = MacChainProof(
            blockHeader: header.serialized(),
            nonce: 0,
            cycleEdges: [0, 1, 2, 3, 4, 5, 6, 7]
        )
        let block = Block(header: header, proof: proof, transactions: [tx])

        let encoded = block.serialized()
        let decoded = Block.deserialize(from: encoded)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.header.serialized(), header.serialized())
        XCTAssertEqual(decoded?.proof.nonce, proof.nonce)
        XCTAssertEqual(decoded?.transactions.count, 1)
    }

    func testChainStateInitialTipAtGenesis() async throws {
        let genesis = ChainState.makeInsecureGenesis(timestamp: 1)
        let state = try ChainState(config: ChainConfig(genesisBlock: genesis))

        let tip = await state.tip()
        XCTAssertEqual(tip.height, 0)
        XCTAssertEqual(tip.hash, genesis.blockHash)
    }

    func testSubmitDuplicateReturnsDuplicate() async throws {
        let genesis = ChainState.makeInsecureGenesis(timestamp: 1)
        let state = try ChainState(config: ChainConfig(genesisBlock: genesis))

        let result = await state.submitBlock(genesis)
        XCTAssertEqual(result, .duplicate)
    }

    func testSubmitOrphanReturnsOrphan() async throws {
        let genesis = ChainState.makeInsecureGenesis(timestamp: 1)
        let state = try ChainState(config: ChainConfig(genesisBlock: genesis))

        let tx = Transaction.coinbase(height: 1, value: 10, to: Data("miner".utf8))
        let merkle = Block.merkleRoot(for: [tx])
        let header = BlockHeader(
            prevHash: Data(repeating: 0xAA, count: 32),
            merkleRoot: merkle,
            timestamp: 2,
            bits: genesis.header.bits,
            version: 1
        )
        let proof = MacChainProof(
            blockHeader: header.serialized(),
            nonce: 7,
            cycleEdges: [0, 1, 2, 3, 4, 5, 6, 7]
        )
        let block = Block(header: header, proof: proof, transactions: [tx])

        let result = await state.submitBlock(block)
        switch result {
        case .orphan(let parentHash):
            XCTAssertEqual(parentHash, Data(repeating: 0xAA, count: 32))
        default:
            XCTFail("Expected orphan result, got \(result)")
        }
    }

    func testRejectInvalidMerkleBeforeProofValidation() async throws {
        let genesis = ChainState.makeInsecureGenesis(timestamp: 1)
        let state = try ChainState(config: ChainConfig(genesisBlock: genesis))

        let tx = Transaction.coinbase(height: 1, value: 10, to: Data("miner".utf8))
        let header = BlockHeader(
            prevHash: genesis.blockHash,
            merkleRoot: Data(repeating: 0xEE, count: 32), // intentionally wrong
            timestamp: genesis.header.timestamp + 1,
            bits: genesis.header.bits,
            version: 1
        )
        let proof = MacChainProof(
            blockHeader: header.serialized(),
            nonce: 9,
            cycleEdges: [0, 1, 2, 3, 4, 5, 6, 7]
        )
        let block = Block(header: header, proof: proof, transactions: [tx])

        let result = await state.submitBlock(block)
        switch result {
        case .rejected(let reason):
            XCTAssertTrue(reason.contains("merkle"))
        default:
            XCTFail("Expected rejected merkle root, got \(result)")
        }
    }

    func testGenesisCoinbaseUTXOAvailable() async throws {
        let genesis = ChainState.makeInsecureGenesis(timestamp: 1)
        let state = try ChainState(config: ChainConfig(genesisBlock: genesis))

        let coinbaseTx = genesis.transactions[0]
        let outPoint = OutPoint(txID: coinbaseTx.txID, outputIndex: 0)
        let utxo = await state.utxo(for: outPoint)
        XCTAssertNotNil(utxo)
        XCTAssertEqual(utxo?.value, coinbaseTx.outputs[0].value)
    }

    func testRejectBlockWithoutCoinbase() async throws {
        let genesis = ChainState.makeInsecureGenesis(timestamp: 1)
        let state = try ChainState(config: ChainConfig(genesisBlock: genesis))

        let prevCoinbase = genesis.transactions[0]
        let spend = Transaction(
            inputs: [
                TransactionInput(
                    prevTxID: prevCoinbase.txID,
                    outputIndex: 0,
                    unlockingScript: Data([0x01])
                )
            ],
            outputs: [TransactionOutput(value: 1000, lockingScript: Data([0x51]))]
        )

        let header = BlockHeader(
            prevHash: genesis.blockHash,
            merkleRoot: Block.merkleRoot(for: [spend]),
            timestamp: genesis.header.timestamp + 1,
            bits: genesis.header.bits,
            version: 1
        )
        let proof = MacChainProof(
            blockHeader: header.serialized(),
            nonce: 5,
            cycleEdges: [0, 1, 2, 3, 4, 5, 6, 7]
        )
        let block = Block(header: header, proof: proof, transactions: [spend])

        let result = await state.submitBlock(block)
        switch result {
        case .rejected(let reason):
            XCTAssertTrue(reason.contains("state transition"))
        default:
            XCTFail("Expected state transition rejection, got \(result)")
        }
    }

    func testRejectCoinbaseOversubsidy() async throws {
        let genesis = ChainState.makeInsecureGenesis(timestamp: 1)
        let state = try ChainState(config: ChainConfig(genesisBlock: genesis))

        let tooLargeCoinbase = Transaction.coinbase(
            height: 1,
            value: 6_000_000_000, // higher than default subsidy without fees
            to: Data([0x51])
        )

        let header = BlockHeader(
            prevHash: genesis.blockHash,
            merkleRoot: Block.merkleRoot(for: [tooLargeCoinbase]),
            timestamp: genesis.header.timestamp + 1,
            bits: genesis.header.bits,
            version: 1
        )
        let proof = MacChainProof(
            blockHeader: header.serialized(),
            nonce: 10,
            cycleEdges: [0, 1, 2, 3, 4, 5, 6, 7]
        )
        let block = Block(header: header, proof: proof, transactions: [tooLargeCoinbase])

        let result = await state.submitBlock(block)
        switch result {
        case .rejected(let reason):
            XCTAssertTrue(reason.contains("state transition"))
        default:
            XCTFail("Expected state transition rejection, got \(result)")
        }
    }

    func testForkChoicePrefersHigherWorkChain() async throws {
        let genesis = ChainState.makeInsecureGenesis(timestamp: 1)
        let policy = ChainPolicy(allowInsecureGenesis: true, allowInsecureBlocks: true)
        let state = try ChainState(config: ChainConfig(genesisBlock: genesis, policy: policy))

        let a1 = makeDevChildBlock(parent: genesis, height: 1, timestamp: 2, marker: "a1")
        let b1 = makeDevChildBlock(parent: genesis, height: 1, timestamp: 2, marker: "b1")
        let b2 = makeDevChildBlock(parent: b1, height: 2, timestamp: 3, marker: "b2")

        XCTAssertEqual(await state.submitBlock(a1).isAccepted, true)
        XCTAssertEqual(await state.submitBlock(b1).isAccepted, true)

        let promote = await state.submitBlock(b2)
        switch promote {
        case .accepted(let height, let becameBest):
            XCTAssertEqual(height, 2)
            XCTAssertTrue(becameBest)
        default:
            XCTFail("Expected accepted b2 block, got \(promote)")
        }

        let tip = await state.tip()
        XCTAssertEqual(tip.height, 2)
        XCTAssertEqual(tip.hash, b2.blockHash)
    }

    func testPersistenceRebuildsChainOnRestart() async throws {
        let genesis = ChainState.makeInsecureGenesis(timestamp: 1)
        let policy = ChainPolicy(allowInsecureGenesis: true, allowInsecureBlocks: true)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macchain-chainstate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = ChainConfig(
            genesisBlock: genesis,
            policy: policy,
            storageDirectory: tempDir
        )

        let state1 = try ChainState(config: config)
        let c1 = makeDevChildBlock(parent: genesis, height: 1, timestamp: 2, marker: "c1")
        let c2 = makeDevChildBlock(parent: c1, height: 2, timestamp: 3, marker: "c2")

        XCTAssertTrue(await state1.submitBlock(c1).isAccepted)
        XCTAssertTrue(await state1.submitBlock(c2).isAccepted)
        let tip1 = await state1.tip()

        let state2 = try ChainState(config: config)
        let tip2 = await state2.tip()

        XCTAssertEqual(tip2.height, tip1.height)
        XCTAssertEqual(tip2.hash, tip1.hash)
    }

    func testPersistenceRebuildsBestForkOnRestart() async throws {
        let genesis = ChainState.makeInsecureGenesis(timestamp: 1)
        let policy = ChainPolicy(allowInsecureGenesis: true, allowInsecureBlocks: true)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macchain-fork-rebuild-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = ChainConfig(
            genesisBlock: genesis,
            policy: policy,
            storageDirectory: tempDir
        )

        let state1 = try ChainState(config: config)
        let a1 = makeDevChildBlock(parent: genesis, height: 1, timestamp: 2, marker: "a1")
        let a2 = makeDevChildBlock(parent: a1, height: 2, timestamp: 3, marker: "a2")
        let b1 = makeDevChildBlock(parent: genesis, height: 1, timestamp: 2, marker: "b1")
        let b2 = makeDevChildBlock(parent: b1, height: 2, timestamp: 3, marker: "b2")
        let b3 = makeDevChildBlock(parent: b2, height: 3, timestamp: 4, marker: "b3")

        XCTAssertTrue(await state1.submitBlock(a1).isAccepted)
        XCTAssertTrue(await state1.submitBlock(a2).isAccepted)
        XCTAssertTrue(await state1.submitBlock(b1).isAccepted)
        XCTAssertTrue(await state1.submitBlock(b2).isAccepted)
        XCTAssertTrue(await state1.submitBlock(b3).isAccepted)
        XCTAssertEqual(await state1.tip().hash, b3.blockHash)

        let state2 = try ChainState(config: config)
        let tip2 = await state2.tip()
        XCTAssertEqual(tip2.height, 3)
        XCTAssertEqual(tip2.hash, b3.blockHash)
    }

    func testRejectBlockWithInvalidSignature() async throws {
        let (genesis, key) = makeSpendableGenesis(timestamp: 1)
        let policy = ChainPolicy(allowInsecureGenesis: true, allowInsecureBlocks: true, enforceSignatureScripts: true)
        let state = try ChainState(config: ChainConfig(genesisBlock: genesis, policy: policy))

        let coinbase = Transaction.coinbase(height: 1, value: 5_000_000_000, to: Data("miner".utf8))
        let genesisTx = genesis.transactions[0]
        var spend = Transaction(
            inputs: [
                TransactionInput(
                    prevTxID: genesisTx.txID,
                    outputIndex: 0,
                    unlockingScript: Data()
                )
            ],
            outputs: [TransactionOutput(value: 4_999_999_000, lockingScript: Data([0x51]))]
        )
        let wrongKey = Curve25519.Signing.PrivateKey()
        XCTAssertFalse(spend.signInput(at: 0, privateKey: wrongKey, previousOutput: genesisTx.outputs[0]))
        XCTAssertTrue(spend.signInput(at: 0, privateKey: key, previousOutput: genesisTx.outputs[0]))
        spend.inputs[0].unlockingScript = Data(repeating: 0xCC, count: 64)

        let block = makeBlock(
            parent: genesis,
            transactions: [coinbase, spend],
            timestamp: 2,
            nonce: 1
        )

        let result = await state.submitBlock(block)
        switch result {
        case .rejected(let reason):
            XCTAssertTrue(reason.contains("state transition"))
        default:
            XCTFail("Expected invalid signature rejection, got \(result)")
        }
    }

    func testAcceptBlockWithValidSignedSpend() async throws {
        let (genesis, key) = makeSpendableGenesis(timestamp: 1)
        let policy = ChainPolicy(allowInsecureGenesis: true, allowInsecureBlocks: true, enforceSignatureScripts: true)
        let state = try ChainState(config: ChainConfig(genesisBlock: genesis, policy: policy))

        let genesisTx = genesis.transactions[0]
        var spend = Transaction(
            inputs: [
                TransactionInput(
                    prevTxID: genesisTx.txID,
                    outputIndex: 0,
                    unlockingScript: Data()
                )
            ],
            outputs: [TransactionOutput(value: 4_999_999_000, lockingScript: Data([0x51]))]
        )
        XCTAssertTrue(spend.signInput(at: 0, privateKey: key, previousOutput: genesisTx.outputs[0]))

        let coinbase = Transaction.coinbase(height: 1, value: 5_000_001_000, to: Data("miner".utf8))
        let block = makeBlock(
            parent: genesis,
            transactions: [coinbase, spend],
            timestamp: 2,
            nonce: 2
        )

        let result = await state.submitBlock(block)
        switch result {
        case .accepted(let height, _):
            XCTAssertEqual(height, 1)
        default:
            XCTFail("Expected accepted block with signed spend, got \(result)")
        }

        let spentOutPoint = OutPoint(txID: genesisTx.txID, outputIndex: 0)
        XCTAssertNil(await state.utxo(for: spentOutPoint))

        let newOutPoint = OutPoint(txID: spend.txID, outputIndex: 0)
        XCTAssertEqual(await state.utxo(for: newOutPoint)?.value, 4_999_999_000)
    }

    func testDefaultInsecureGenesisSpendableWithDerivedKey() async throws {
        let networkTag = "chainstate-derived-key-test"
        let genesis = ChainState.makeInsecureGenesis(timestamp: 1, networkTag: networkTag)
        let key = ChainState.insecureGenesisPrivateKey(networkTag: networkTag)

        let policy = ChainPolicy(allowInsecureGenesis: true, allowInsecureBlocks: true, enforceSignatureScripts: true)
        let state = try ChainState(config: ChainConfig(genesisBlock: genesis, policy: policy))

        let genesisTx = genesis.transactions[0]
        var spend = Transaction(
            inputs: [
                TransactionInput(
                    prevTxID: genesisTx.txID,
                    outputIndex: 0,
                    unlockingScript: Data()
                )
            ],
            outputs: [
                TransactionOutput(
                    value: 4_999_999_000,
                    lockingScript: TxScript.makePayToEd25519(publicKey: key.publicKey.rawRepresentation)
                )
            ]
        )
        XCTAssertTrue(spend.signInput(at: 0, privateKey: key, previousOutput: genesisTx.outputs[0]))

        let coinbase = Transaction.coinbase(height: 1, value: 5_000_001_000, to: Data("miner".utf8))
        let block = makeBlock(parent: genesis, transactions: [coinbase, spend], timestamp: 2, nonce: 42)

        let result = await state.submitBlock(block)
        switch result {
        case .accepted(let height, _):
            XCTAssertEqual(height, 1)
        default:
            XCTFail("Expected accepted block with derived genesis key spend, got \(result)")
        }
    }

    private func makeDevChildBlock(parent: Block, height: UInt64, timestamp: UInt32, marker: String) -> Block {
        let coinbase = Transaction.coinbase(
            height: height,
            value: 5_000_000_000,
            to: Data("miner-\(height)-\(marker)".utf8)
        )
        return makeBlock(parent: parent, transactions: [coinbase], timestamp: timestamp, nonce: UInt64(height))
    }

    private func makeBlock(
        parent: Block,
        transactions: [Transaction],
        timestamp: UInt32,
        nonce: UInt64
    ) -> Block {
        let header = BlockHeader(
            prevHash: parent.blockHash,
            merkleRoot: Block.merkleRoot(for: transactions),
            timestamp: timestamp,
            bits: parent.header.bits,
            version: 1
        )
        let proof = MacChainProof(
            blockHeader: header.serialized(),
            nonce: nonce,
            cycleEdges: [0, 1, 2, 3, 4, 5, 6, 7]
        )
        return Block(header: header, proof: proof, transactions: transactions)
    }

    private func makeSpendableGenesis(timestamp: UInt32) -> (Block, Curve25519.Signing.PrivateKey) {
        let key = Curve25519.Signing.PrivateKey()
        let lockingScript = TxScript.makePayToEd25519(publicKey: key.publicKey.rawRepresentation)
        let coinbase = Transaction.coinbase(height: 0, value: 5_000_000_000, to: lockingScript)
        let header = BlockHeader(
            prevHash: Data(repeating: 0, count: 32),
            merkleRoot: Block.merkleRoot(for: [coinbase]),
            timestamp: timestamp,
            bits: 0x1f00ffff,
            version: 1
        )
        let proof = MacChainProof(
            blockHeader: header.serialized(),
            nonce: 0,
            cycleEdges: [0, 1, 2, 3, 4, 5, 6, 7]
        )
        return (Block(header: header, proof: proof, transactions: [coinbase]), key)
    }
}
