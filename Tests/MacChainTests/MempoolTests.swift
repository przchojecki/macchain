import XCTest
import CryptoKit
@testable import MacChainLib

final class MempoolTests: XCTestCase {
    func testAcceptValidSpendFromChainUTXO() async throws {
        let (genesis, key) = makeSpendableGenesis(timestamp: 1)
        let chain = try ChainState(config: ChainConfig(genesisBlock: genesis))
        let mempool = Mempool(chainState: chain)

        let tx = makeSignedSpendFromGenesis(genesis: genesis, privateKey: key, valueOut: 4_999_999_000)
        let result = await mempool.add(tx)
        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(await mempool.count(), 1)
    }

    func testRejectMissingInput() async throws {
        let genesis = ChainState.makeInsecureGenesis(timestamp: 1)
        let chain = try ChainState(config: ChainConfig(genesisBlock: genesis))
        let mempool = Mempool(chainState: chain)

        let tx = Transaction(
            inputs: [
                TransactionInput(
                    prevTxID: Data(repeating: 0xAB, count: 32),
                    outputIndex: 0,
                    unlockingScript: Data([0x01])
                )
            ],
            outputs: [TransactionOutput(value: 10, lockingScript: Data([0x51]))]
        )

        let result = await mempool.add(tx)
        switch result {
        case .rejected(let reason):
            XCTAssertTrue(reason.contains("missing input"))
        default:
            XCTFail("Expected missing input rejection, got \(result)")
        }
    }

    func testRejectDoubleSpendAcrossMempool() async throws {
        let (genesis, key) = makeSpendableGenesis(timestamp: 1)
        let chain = try ChainState(config: ChainConfig(genesisBlock: genesis))
        let mempool = Mempool(chainState: chain)

        let first = makeSignedSpendFromGenesis(genesis: genesis, privateKey: key, valueOut: 4_999_999_000)
        let second = makeSignedSpendFromGenesis(genesis: genesis, privateKey: key, valueOut: 4_999_998_000)

        XCTAssertEqual(await mempool.add(first), .accepted)
        let secondResult = await mempool.add(second)
        switch secondResult {
        case .rejected(let reason):
            XCTAssertTrue(reason.contains("already spent"))
        default:
            XCTFail("Expected double-spend rejection, got \(secondResult)")
        }
    }

    func testRejectCoinbaseInMempool() async throws {
        let genesis = ChainState.makeInsecureGenesis(timestamp: 1)
        let chain = try ChainState(config: ChainConfig(genesisBlock: genesis))
        let mempool = Mempool(chainState: chain)

        let coinbase = Transaction.coinbase(height: 1, value: 50, to: Data([0x51]))
        let result = await mempool.add(coinbase)
        switch result {
        case .rejected(let reason):
            XCTAssertTrue(reason.contains("coinbase"))
        default:
            XCTFail("Expected coinbase rejection, got \(result)")
        }
    }

    func testRejectInvalidSignature() async throws {
        let (genesis, _) = makeSpendableGenesis(timestamp: 1)
        let chain = try ChainState(config: ChainConfig(genesisBlock: genesis))
        let mempool = Mempool(chainState: chain)

        let coinbaseTx = genesis.transactions[0]
        let tx = Transaction(
            inputs: [
                TransactionInput(
                    prevTxID: coinbaseTx.txID,
                    outputIndex: 0,
                    unlockingScript: Data(repeating: 0xEE, count: 64)
                )
            ],
            outputs: [TransactionOutput(value: 4_999_999_000, lockingScript: Data([0x51]))]
        )

        let result = await mempool.add(tx)
        switch result {
        case .rejected(let reason):
            XCTAssertTrue(reason.contains("signature"))
        default:
            XCTFail("Expected signature rejection, got \(result)")
        }
    }

    func testRejectMissingInputWithUnconfirmedParentsEnabled() async throws {
        let genesis = ChainState.makeInsecureGenesis(timestamp: 1)
        let chain = try ChainState(config: ChainConfig(genesisBlock: genesis))
        let mempool = Mempool(chainState: chain, allowUnconfirmedParents: true)

        let tx = Transaction(
            inputs: [
                TransactionInput(
                    prevTxID: Data(repeating: 0xCD, count: 32),
                    outputIndex: 0,
                    unlockingScript: Data([0x01])
                )
            ],
            outputs: [TransactionOutput(value: 10, lockingScript: Data([0x51]))]
        )

        let result = await mempool.add(tx)
        switch result {
        case .rejected(let reason):
            XCTAssertTrue(reason.contains("missing input"))
        default:
            XCTFail("Expected missing input rejection, got \(result)")
        }
    }

    private func makeSignedSpendFromGenesis(
        genesis: Block,
        privateKey: Curve25519.Signing.PrivateKey,
        valueOut: UInt64
    ) -> Transaction {
        let coinbaseTx = genesis.transactions[0]
        var tx = Transaction(
            inputs: [
                TransactionInput(
                    prevTxID: coinbaseTx.txID,
                    outputIndex: 0,
                    unlockingScript: Data()
                )
            ],
            outputs: [TransactionOutput(value: valueOut, lockingScript: Data([0x51]))]
        )
        let signed = tx.signInput(
            at: 0,
            privateKey: privateKey,
            previousOutput: coinbaseTx.outputs[0]
        )
        precondition(signed, "failed to sign test transaction")
        return tx
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
