import Foundation

public enum MempoolAddResult: Equatable {
    case accepted
    case duplicate
    case rejected(String)
}

public actor Mempool {
    public let maxTransactions: Int
    public let maxTransactionBytes: Int
    public let allowUnconfirmedParents: Bool

    private let chainState: ChainState?

    private var transactionsByID: [Data: Transaction] = [:]
    private var spentOutPoints: [OutPoint: Data] = [:] // outpoint -> txid

    public init(
        chainState: ChainState? = nil,
        maxTransactions: Int = 10_000,
        maxTransactionBytes: Int = 100_000,
        allowUnconfirmedParents: Bool = false
    ) {
        self.chainState = chainState
        self.maxTransactions = maxTransactions
        self.maxTransactionBytes = maxTransactionBytes
        self.allowUnconfirmedParents = allowUnconfirmedParents
    }

    public func add(_ transaction: Transaction) async -> MempoolAddResult {
        guard transaction.isStructurallyValid() else {
            return .rejected("transaction failed structural validation")
        }
        guard !transaction.isCoinbase else {
            return .rejected("coinbase transactions are not valid in mempool")
        }
        guard !transaction.inputs.isEmpty else {
            return .rejected("non-coinbase transaction must have at least one input")
        }

        let serialized = transaction.serialized()
        guard serialized.count <= maxTransactionBytes else {
            return .rejected("transaction exceeds max size")
        }

        let txID = transaction.txID
        if transactionsByID[txID] != nil {
            return .duplicate
        }
        guard transactionsByID.count < maxTransactions else {
            return .rejected("mempool is full")
        }

        var txInputs = Set<OutPoint>()
        for input in transaction.inputs {
            let outPoint = input.outPoint
            guard txInputs.insert(outPoint).inserted else {
                return .rejected("transaction contains duplicate inputs")
            }
            if spentOutPoints[outPoint] != nil {
                return .rejected("input already spent by another mempool transaction")
            }
        }

        if let chainState {
            if let reason = await chainState.validateTransactionAgainstTip(
                transaction,
                allowUnconfirmedParents: allowUnconfirmedParents
            ) {
                return .rejected(reason)
            }
        }

        transactionsByID[txID] = transaction
        for outPoint in txInputs {
            spentOutPoints[outPoint] = txID
        }
        return .accepted
    }

    public func remove(txIDs: [Data]) {
        for id in txIDs {
            if let tx = transactionsByID[id] {
                for input in tx.inputs {
                    let outPoint = input.outPoint
                    if spentOutPoints[outPoint] == id {
                        spentOutPoints[outPoint] = nil
                    }
                }
            }
            transactionsByID[id] = nil
        }
    }

    public func contains(txID: Data) -> Bool {
        transactionsByID[txID] != nil
    }

    public func count() -> Int {
        transactionsByID.count
    }

    public func snapshot(maxCount: Int = 1_000, maxBytes: Int = 1_000_000) -> [Transaction] {
        var selected: [Transaction] = []
        selected.reserveCapacity(min(maxCount, transactionsByID.count))

        var totalBytes = 0
        for tx in transactionsByID.values {
            if selected.count >= maxCount {
                break
            }

            let bytes = tx.serialized().count
            if totalBytes + bytes > maxBytes {
                break
            }

            selected.append(tx)
            totalBytes += bytes
        }

        return selected
    }
}
