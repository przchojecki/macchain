import Foundation
import CryptoKit

public struct ChainPolicy {
    public var maxBlockBytes: Int
    public var maxTransactionsPerBlock: Int
    public var maxFutureTimeSeconds: UInt32
    public var blockSubsidy: UInt64
    public var allowInsecureGenesis: Bool
    public var allowInsecureBlocks: Bool
    public var enforceSignatureScripts: Bool

    public init(
        maxBlockBytes: Int = 2_000_000,
        maxTransactionsPerBlock: Int = 10_000,
        maxFutureTimeSeconds: UInt32 = 2 * 60 * 60,
        blockSubsidy: UInt64 = 5_000_000_000,
        allowInsecureGenesis: Bool = true,
        allowInsecureBlocks: Bool = false,
        enforceSignatureScripts: Bool = true
    ) {
        self.maxBlockBytes = maxBlockBytes
        self.maxTransactionsPerBlock = maxTransactionsPerBlock
        self.maxFutureTimeSeconds = maxFutureTimeSeconds
        self.blockSubsidy = blockSubsidy
        self.allowInsecureGenesis = allowInsecureGenesis
        self.allowInsecureBlocks = allowInsecureBlocks
        self.enforceSignatureScripts = enforceSignatureScripts
    }
}

public struct ChainConfig {
    public var genesisBlock: Block
    public var params: MacChainParams
    public var minimumDifficulty: Difficulty
    public var policy: ChainPolicy
    public var storageDirectory: URL?

    public init(
        genesisBlock: Block,
        params: MacChainParams = .default,
        minimumDifficulty: Difficulty = .initial,
        policy: ChainPolicy = ChainPolicy(),
        storageDirectory: URL? = nil
    ) {
        self.genesisBlock = genesisBlock
        self.params = params
        self.minimumDifficulty = minimumDifficulty
        self.policy = policy
        self.storageDirectory = storageDirectory
    }
}

public enum ChainStateError: Error, LocalizedError {
    case invalidGenesis(String)
    case storage(String)
    case invalidStoredBlock(String)

    public var errorDescription: String? {
        switch self {
        case .invalidGenesis(let reason):
            return "Invalid genesis block: \(reason)"
        case .storage(let reason):
            return "Chain storage error: \(reason)"
        case .invalidStoredBlock(let reason):
            return "Invalid stored block data: \(reason)"
        }
    }
}

public enum BlockSubmissionResult: Equatable {
    case accepted(height: UInt64, becameBest: Bool)
    case duplicate
    case orphan(parentHash: Data)
    case rejected(String)

    public var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }
}

public struct ChainTip: Equatable {
    public let hash: Data
    public let height: UInt64
    public let totalWork: UInt64
    public let bits: UInt32
}

public actor ChainState {
    private struct ChainNode {
        let block: Block
        let hash: Data
        let parentHash: Data?
        let height: UInt64
        let totalWork: UInt64
        let utxo: [OutPoint: TransactionOutput]
    }

    public let config: ChainConfig

    private var nodesByHash: [Data: ChainNode]
    private var bestHash: Data
    private let blockStore: FileBlockStore?

    public init(config: ChainConfig) throws {
        self.config = config
        self.blockStore = try config.storageDirectory.map { path in
            do {
                return try FileBlockStore(baseURL: path)
            } catch {
                throw ChainStateError.storage(error.localizedDescription)
            }
        }

        let genesis = config.genesisBlock
        guard genesis.isProofHeaderConsistent() else {
            throw ChainStateError.invalidGenesis("proof/header mismatch")
        }
        guard genesis.hasValidMerkleRoot() else {
            throw ChainStateError.invalidGenesis("invalid merkle root")
        }

        if !config.policy.allowInsecureGenesis {
            let verifier = Verifier(
                params: config.params,
                difficulty: config.minimumDifficulty,
                expectedBits: genesis.header.bits,
                enforceTrimmedCycle: true
            )
            guard case .valid = verifier.verify(genesis.proof) else {
                throw ChainStateError.invalidGenesis("proof does not satisfy verifier checks")
            }
        }

        guard let genesisUTXO = Self.applyStateTransition(
            transactions: genesis.transactions,
            parentUTXO: [:],
            height: 0,
            blockSubsidy: config.policy.blockSubsidy,
            enforceSignatureScripts: config.policy.enforceSignatureScripts
        ) else {
            throw ChainStateError.invalidGenesis("invalid transaction state transition")
        }

        let hash = genesis.blockHash
        let node = ChainNode(
            block: genesis,
            hash: hash,
            parentHash: nil,
            height: 0,
            totalWork: Self.workScore(bits: genesis.header.bits),
            utxo: genesisUTXO
        )

        var nodes = [hash: node]
        var best = hash

        if let store = self.blockStore {
            let persistedBlocks: [Block]
            do {
                persistedBlocks = try store.loadBlocks()
            } catch {
                throw ChainStateError.storage(error.localizedDescription)
            }

            if persistedBlocks.isEmpty {
                do {
                    try store.saveBlock(genesis)
                    try store.saveBestHash(hash)
                } catch {
                    throw ChainStateError.storage(error.localizedDescription)
                }
            } else {
                let rebuilt = try Self.rebuildFromPersistedBlocks(
                    persistedBlocks: persistedBlocks,
                    genesisNode: node,
                    config: config
                )
                nodes = rebuilt.nodes
                best = rebuilt.bestHash

                let persistedBest: Data? = (try? store.loadBestHash()) ?? nil
                if persistedBest != best {
                    try? store.saveBestHash(best)
                }
            }
        }

        self.nodesByHash = nodes
        self.bestHash = best
    }

    public func submitBlock(_ block: Block, now: UInt32 = UInt32(Date().timeIntervalSince1970)) -> BlockSubmissionResult {
        let hash = block.blockHash
        if nodesByHash[hash] != nil {
            return .duplicate
        }

        if block.serialized().count > config.policy.maxBlockBytes {
            return .rejected("block exceeds size limit")
        }

        if block.transactions.isEmpty {
            return .rejected("block must include at least one transaction")
        }
        if block.transactions.count > config.policy.maxTransactionsPerBlock {
            return .rejected("block contains too many transactions")
        }
        for tx in block.transactions where !tx.isStructurallyValid() {
            return .rejected("block contains structurally invalid transaction")
        }

        guard block.isProofHeaderConsistent() else {
            return .rejected("proof blockHeader must match header serialization")
        }
        guard block.hasValidMerkleRoot() else {
            return .rejected("invalid merkle root")
        }

        let parentHash = normalizedHash(block.header.prevHash)
        guard let parent = nodesByHash[parentHash] else {
            return .orphan(parentHash: parentHash)
        }

        if block.header.timestamp <= parent.block.header.timestamp {
            return .rejected("timestamp must be strictly greater than parent timestamp")
        }

        if block.header.timestamp > now &+ config.policy.maxFutureTimeSeconds {
            return .rejected("block timestamp too far in the future")
        }

        guard let nextUTXO = Self.applyStateTransition(
            transactions: block.transactions,
            parentUTXO: parent.utxo,
            height: parent.height + 1,
            blockSubsidy: config.policy.blockSubsidy,
            enforceSignatureScripts: config.policy.enforceSignatureScripts
        ) else {
            return .rejected("invalid transaction state transition")
        }

        if !config.policy.allowInsecureBlocks {
            let expectedBits = expectedBitsForNextBlock(parent: parent)
            let verifier = Verifier(
                params: config.params,
                difficulty: config.minimumDifficulty,
                expectedBits: expectedBits,
                enforceTrimmedCycle: true
            )
            switch verifier.verify(block.proof) {
            case .valid:
                break
            case .invalid(let reason):
                return .rejected("invalid proof: \(reason)")
            }
        }

        let node = ChainNode(
            block: block,
            hash: hash,
            parentHash: parent.hash,
            height: parent.height + 1,
            totalWork: parent.totalWork &+ Self.workScore(bits: block.header.bits),
            utxo: nextUTXO
        )
        nodesByHash[hash] = node

        let oldBest = nodesByHash[bestHash]!
        let becameBest: Bool
        if node.totalWork > oldBest.totalWork {
            becameBest = true
        } else if node.totalWork == oldBest.totalWork && hash.lexicographicallyPrecedes(bestHash) {
            becameBest = true
        } else {
            becameBest = false
        }

        if becameBest {
            bestHash = hash
        }

        if let store = blockStore {
            do {
                try store.saveBlock(block)
                if becameBest {
                    try store.saveBestHash(bestHash)
                }
            } catch {
                // Keep in-memory state authoritative; persistence errors surface in logs.
                fputs("warning: failed to persist chain state: \(error.localizedDescription)\n", stderr)
            }
        }

        return .accepted(height: node.height, becameBest: becameBest)
    }

    public func tip() -> ChainTip {
        let best = nodesByHash[bestHash]!
        return ChainTip(
            hash: best.hash,
            height: best.height,
            totalWork: best.totalWork,
            bits: best.block.header.bits
        )
    }

    public func block(hash: Data) -> Block? {
        nodesByHash[normalizedHash(hash)]?.block
    }

    public func height() -> UInt64 {
        nodesByHash[bestHash]?.height ?? 0
    }

    public func utxo(for outPoint: OutPoint) -> TransactionOutput? {
        nodesByHash[bestHash]?.utxo[outPoint]
    }

    public func inputValue(for inputs: [TransactionInput]) -> UInt64? {
        guard let utxo = nodesByHash[bestHash]?.utxo else { return nil }
        var sum: UInt64 = 0
        for input in inputs {
            guard let prevOut = utxo[input.outPoint] else { return nil }
            let (next, overflow) = sum.addingReportingOverflow(prevOut.value)
            guard !overflow else { return nil }
            sum = next
        }
        return sum
    }

    /// Returns `nil` if the transaction is valid against the current best tip UTXO set.
    /// Returns a human-readable rejection reason otherwise.
    public func validateTransactionAgainstTip(
        _ transaction: Transaction,
        allowUnconfirmedParents: Bool = false
    ) -> String? {
        guard transaction.isStructurallyValid() else {
            return "transaction failed structural validation"
        }
        guard !transaction.isCoinbase else {
            return "coinbase transactions are not valid in mempool"
        }
        guard !transaction.inputs.isEmpty else {
            return "non-coinbase transaction must have at least one input"
        }
        guard let tipUTXO = nodesByHash[bestHash]?.utxo else {
            return "missing chain tip UTXO set"
        }

        switch Self.validateNonCoinbaseTransaction(
            transaction,
            utxo: tipUTXO,
            enforceSignatureScripts: config.policy.enforceSignatureScripts,
            allowMissingInputs: allowUnconfirmedParents
        ) {
        case .invalid(let reason):
            return reason
        case .valid(let result):
            if !allowUnconfirmedParents && result.missingInputs > 0 {
                return "missing input in chain UTXO set"
            }

            if !allowUnconfirmedParents && result.inputValue < result.outputValue {
                return "transaction spends more than available inputs"
            }

            return nil
        }
    }

    public static func makeInsecureGenesis(
        timestamp: UInt32 = 1_735_689_600,
        bits: UInt32 = 0x1f00ffff,
        networkTag: String = "macchain-main"
    ) -> Block {
        let genesisKey = deterministicGenesisKey(networkTag: networkTag)
        let coinbase = Transaction.coinbase(
            height: 0,
            value: 5_000_000_000,
            to: TxScript.makePayToEd25519(publicKey: genesisKey.publicKey.rawRepresentation)
        )
        let merkleRoot = Block.merkleRoot(for: [coinbase])
        let header = BlockHeader(
            prevHash: Data(repeating: 0, count: 32),
            merkleRoot: merkleRoot,
            timestamp: timestamp,
            bits: bits,
            version: 1
        )
        let proof = MacChainProof(
            blockHeader: header.serialized(),
            nonce: 0,
            cycleEdges: [0, 1, 2, 3, 4, 5, 6, 7]
        )
        return Block(header: header, proof: proof, transactions: [coinbase])
    }

    public static func insecureGenesisPrivateKey(
        networkTag: String = "macchain-main"
    ) -> Curve25519.Signing.PrivateKey {
        deterministicGenesisKey(networkTag: networkTag)
    }

    private func expectedBitsForNextBlock(parent: ChainNode) -> UInt32 {
        Self.expectedBitsForNextBlock(
            parent: parent,
            nodesByHash: nodesByHash,
            minimumDifficulty: config.minimumDifficulty
        )
    }

    private static func workScore(bits: UInt32) -> UInt64 {
        let target = Difficulty(compact: bits).target
        var prefix: UInt64 = 0
        for byte in target.prefix(8) {
            prefix = (prefix << 8) | UInt64(byte)
        }
        guard prefix > 0 else { return UInt64.max / 2 }
        return UInt64.max / (prefix | 1)
    }

    private static func rebuildFromPersistedBlocks(
        persistedBlocks: [Block],
        genesisNode: ChainNode,
        config: ChainConfig
    ) throws -> (nodes: [Data: ChainNode], bestHash: Data) {
        var nodes: [Data: ChainNode] = [genesisNode.hash: genesisNode]
        let genesisHash = genesisNode.hash

        var uniqueByHash: [Data: Block] = [:]
        for block in persistedBlocks {
            let hash = block.blockHash
            if hash == genesisHash {
                // If genesis is persisted, it must match the configured genesis.
                guard block.header.serialized() == genesisNode.block.header.serialized() else {
                    throw ChainStateError.invalidStoredBlock("stored genesis does not match configured genesis")
                }
                continue
            }
            uniqueByHash[hash] = block
        }

        var unresolved = uniqueByHash
        let now = UInt32(Date().timeIntervalSince1970)
        var progressed = true

        while progressed && !unresolved.isEmpty {
            progressed = false

            for (hash, block) in unresolved {
                let parentHash = normalizedHash(block.header.prevHash)
                guard let parent = nodes[parentHash] else { continue }

                guard let child = tryBuildNode(
                    block: block,
                    parent: parent,
                    hash: hash,
                    nodesByHash: nodes,
                    config: config,
                    now: now
                ) else {
                    throw ChainStateError.invalidStoredBlock("stored block \(hash.hexString) failed validation")
                }

                nodes[hash] = child
                unresolved[hash] = nil
                progressed = true
            }
        }

        if !unresolved.isEmpty {
            throw ChainStateError.invalidStoredBlock("unresolved/orphan stored blocks: \(unresolved.count)")
        }

        let bestHash = selectBestHash(nodes) ?? genesisHash
        return (nodes, bestHash)
    }

    private static func tryBuildNode(
        block: Block,
        parent: ChainNode,
        hash: Data,
        nodesByHash: [Data: ChainNode],
        config: ChainConfig,
        now: UInt32
    ) -> ChainNode? {
        if block.serialized().count > config.policy.maxBlockBytes {
            return nil
        }
        if block.transactions.isEmpty || block.transactions.count > config.policy.maxTransactionsPerBlock {
            return nil
        }
        for tx in block.transactions where !tx.isStructurallyValid() {
            return nil
        }
        guard block.isProofHeaderConsistent(), block.hasValidMerkleRoot() else {
            return nil
        }
        guard block.header.timestamp > parent.block.header.timestamp else {
            return nil
        }
        guard block.header.timestamp <= now &+ config.policy.maxFutureTimeSeconds else {
            return nil
        }

        guard let nextUTXO = applyStateTransition(
            transactions: block.transactions,
            parentUTXO: parent.utxo,
            height: parent.height + 1,
            blockSubsidy: config.policy.blockSubsidy,
            enforceSignatureScripts: config.policy.enforceSignatureScripts
        ) else {
            return nil
        }

        if !config.policy.allowInsecureBlocks {
            let expectedBits = expectedBitsForNextBlock(
                parent: parent,
                nodesByHash: nodesByHash,
                minimumDifficulty: config.minimumDifficulty
            )
            let verifier = Verifier(
                params: config.params,
                difficulty: config.minimumDifficulty,
                expectedBits: expectedBits,
                enforceTrimmedCycle: true
            )
            guard case .valid = verifier.verify(block.proof) else {
                return nil
            }
        }

        return ChainNode(
            block: block,
            hash: hash,
            parentHash: parent.hash,
            height: parent.height + 1,
            totalWork: parent.totalWork &+ workScore(bits: block.header.bits),
            utxo: nextUTXO
        )
    }

    private static func expectedBitsForNextBlock(
        parent: ChainNode,
        nodesByHash: [Data: ChainNode],
        minimumDifficulty: Difficulty
    ) -> UInt32 {
        let nextHeight = parent.height + 1
        guard kBlocksPerAdjustment > 1,
              nextHeight % kBlocksPerAdjustment == 0 else {
            return parent.block.header.bits
        }

        guard let windowStart = ancestor(
            from: parent,
            stepsBack: kBlocksPerAdjustment - 1,
            nodesByHash: nodesByHash
        ) else {
            return parent.block.header.bits
        }

        let startTS = Int64(windowStart.block.header.timestamp)
        let endTS = Int64(parent.block.header.timestamp)
        let actualTimespan = max(1.0, Double(max(0, endTS - startTS)))
        let expectedTimespan = max(1.0, kTargetBlockTimeSeconds * Double(kBlocksPerAdjustment - 1))

        var nextBits = Difficulty.adjust(
            currentBits: parent.block.header.bits,
            actualTimeSeconds: actualTimespan,
            expectedTimeSeconds: expectedTimespan
        )

        if isTargetEasier(
            Difficulty(compact: nextBits).target,
            than: minimumDifficulty.target
        ) {
            nextBits = minimumDifficulty.compact
        }

        return nextBits
    }

    private static func ancestor(
        from node: ChainNode,
        stepsBack: UInt64,
        nodesByHash: [Data: ChainNode]
    ) -> ChainNode? {
        var current = node
        var remaining = stepsBack
        while remaining > 0 {
            guard let parentHash = current.parentHash,
                  let parent = nodesByHash[parentHash] else {
                return nil
            }
            current = parent
            remaining -= 1
        }
        return current
    }

    private static func isTargetEasier(_ lhs: Data, than rhs: Data) -> Bool {
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

    private static func deterministicGenesisKey(networkTag: String) -> Curve25519.Signing.PrivateKey {
        let seed = Data(SHA256.hash(data: Data("macchain-genesis-key-\(networkTag)".utf8)))
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
            fatalError("failed to derive deterministic genesis key")
        }
        return key
    }

    private static func selectBestHash(_ nodes: [Data: ChainNode]) -> Data? {
        var best: ChainNode?
        for node in nodes.values {
            guard let currentBest = best else {
                best = node
                continue
            }

            if node.totalWork > currentBest.totalWork {
                best = node
            } else if node.totalWork == currentBest.totalWork,
                      node.hash.lexicographicallyPrecedes(currentBest.hash) {
                best = node
            }
        }
        return best?.hash
    }

    private static func applyStateTransition(
        transactions: [Transaction],
        parentUTXO: [OutPoint: TransactionOutput],
        height: UInt64,
        blockSubsidy: UInt64,
        enforceSignatureScripts: Bool
    ) -> [OutPoint: TransactionOutput]? {
        guard !transactions.isEmpty else { return nil }
        guard transactions[0].isCoinbase else { return nil }

        for tx in transactions where !tx.isStructurallyValid() {
            return nil
        }

        var txIDSet = Set<Data>()
        var workingUTXO = parentUTXO
        var totalFees: UInt64 = 0

        for (index, tx) in transactions.enumerated() {
            let txID = tx.txID
            guard txIDSet.insert(txID).inserted else { return nil }

            let outputValue = Self.sumOutputs(tx.outputs)
            guard outputValue != nil else { return nil }

            if index == 0 {
                // first tx must be coinbase
                guard tx.isCoinbase else { return nil }
            } else {
                // only first tx can be coinbase
                guard case .valid(let nonCoinbase) = validateNonCoinbaseTransaction(
                    tx,
                    utxo: workingUTXO,
                    enforceSignatureScripts: enforceSignatureScripts,
                    allowMissingInputs: false
                ) else {
                    return nil
                }

                let fee = nonCoinbase.inputValue - nonCoinbase.outputValue
                let (nextFees, feesOverflow) = totalFees.addingReportingOverflow(fee)
                guard !feesOverflow else { return nil }
                totalFees = nextFees

                for spent in nonCoinbase.spentOutPoints {
                    workingUTXO[spent] = nil
                }
            }

            for (vout, output) in tx.outputs.enumerated() {
                guard let indexU32 = UInt32(exactly: vout) else { return nil }
                let outPoint = OutPoint(txID: txID, outputIndex: indexU32)
                workingUTXO[outPoint] = output
            }
        }

        guard let coinbaseOut = Self.sumOutputs(transactions[0].outputs) else { return nil }
        let (maxCoinbase, overflow) = Self.blockReward(
            at: height,
            blockSubsidy: blockSubsidy
        ).addingReportingOverflow(totalFees)
        guard !overflow, coinbaseOut <= maxCoinbase else { return nil }

        return workingUTXO
    }

    private struct NonCoinbaseValidation {
        let inputValue: UInt64
        let outputValue: UInt64
        let spentOutPoints: [OutPoint]
        let missingInputs: Int
    }

    private enum NonCoinbaseValidationResult {
        case valid(NonCoinbaseValidation)
        case invalid(String)
    }

    private static func validateNonCoinbaseTransaction(
        _ transaction: Transaction,
        utxo: [OutPoint: TransactionOutput],
        enforceSignatureScripts: Bool,
        allowMissingInputs: Bool
    ) -> NonCoinbaseValidationResult {
        guard !transaction.isCoinbase else { return .invalid("coinbase transaction not allowed here") }
        guard !transaction.inputs.isEmpty else { return .invalid("non-coinbase transaction has no inputs") }
        guard let outputValue = sumOutputs(transaction.outputs) else { return .invalid("transaction output value overflow") }

        var inputValue: UInt64 = 0
        var spentInTx = Set<OutPoint>()
        var spentOutPoints: [OutPoint] = []
        spentOutPoints.reserveCapacity(transaction.inputs.count)
        var missingInputs = 0

        for (inputIndex, input) in transaction.inputs.enumerated() {
            let outPoint = input.outPoint
            guard spentInTx.insert(outPoint).inserted else {
                return .invalid("transaction contains duplicate inputs")
            }

            guard let prevOut = utxo[outPoint] else {
                if allowMissingInputs {
                    missingInputs += 1
                    continue
                }
                return .invalid("missing input in chain UTXO set")
            }

            if enforceSignatureScripts && !transaction.verifyInputSignature(
                inputIndex: inputIndex,
                previousOutput: prevOut
            ) {
                return .invalid("input signature verification failed")
            }

            let (nextInputValue, overflow) = inputValue.addingReportingOverflow(prevOut.value)
            guard !overflow else { return .invalid("input value overflow") }
            inputValue = nextInputValue
            spentOutPoints.append(outPoint)
        }

        if missingInputs == 0 || !allowMissingInputs {
            guard inputValue >= outputValue else {
                return .invalid("transaction spends more than available inputs")
            }
        }

        return .valid(NonCoinbaseValidation(
            inputValue: inputValue,
            outputValue: outputValue,
            spentOutPoints: spentOutPoints,
            missingInputs: missingInputs
        ))
    }

    private static func blockReward(at height: UInt64, blockSubsidy: UInt64) -> UInt64 {
        let halvingInterval: UInt64 = 210_000
        let halvings = height / halvingInterval
        if halvings >= 63 {
            return 0
        }
        return blockSubsidy >> halvings
    }

    private static func sumOutputs(_ outputs: [TransactionOutput]) -> UInt64? {
        var total: UInt64 = 0
        for output in outputs {
            let (next, overflow) = total.addingReportingOverflow(output.value)
            guard !overflow else { return nil }
            total = next
        }
        return total
    }
}

private func normalizedHash(_ data: Data) -> Data {
    var out = Data(data.prefix(32))
    if out.count < 32 {
        out.append(Data(repeating: 0, count: 32 - out.count))
    }
    return out
}
