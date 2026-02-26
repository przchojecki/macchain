import Foundation
import Network

public struct NodeServiceConfig {
    public var networkID: String
    public var listenPort: UInt16
    public var bootstrapPeers: [String]
    public var maxPeers: Int
    public var heartbeatSeconds: TimeInterval

    public init(
        networkID: String = "macchain-main",
        listenPort: UInt16 = 8338,
        bootstrapPeers: [String] = [],
        maxPeers: Int = 32,
        heartbeatSeconds: TimeInterval = 15
    ) {
        self.networkID = networkID
        self.listenPort = listenPort
        self.bootstrapPeers = bootstrapPeers
        self.maxPeers = maxPeers
        self.heartbeatSeconds = heartbeatSeconds
    }
}

public struct WireMessage: Codable {
    public enum Kind: String, Codable {
        case version
        case verack
        case ping
        case pong
        case getTip
        case getBlock
        case tip
        case block
        case tx
    }

    public var kind: Kind
    public var networkID: String?
    public var nodeID: String?
    public var nonce: UInt64?
    public var height: UInt64?
    public var hashHex: String?
    public var payloadBase64: String?

    public init(
        kind: Kind,
        networkID: String? = nil,
        nodeID: String? = nil,
        nonce: UInt64? = nil,
        height: UInt64? = nil,
        hashHex: String? = nil,
        payloadBase64: String? = nil
    ) {
        self.kind = kind
        self.networkID = networkID
        self.nodeID = nodeID
        self.nonce = nonce
        self.height = height
        self.hashHex = hashHex
        self.payloadBase64 = payloadBase64
    }
}

public final class P2PNodeService {
    public let config: NodeServiceConfig

    private let chainState: ChainState
    private let mempool: Mempool
    private let localNodeID = UUID().uuidString
    private let queue = DispatchQueue(label: "macchain.p2p.node")
    private let encoder = JSONEncoder()
    private let requestedBlockLock = NSLock()

    private var listener: NWListener?
    private var heartbeatTimer: DispatchSourceTimer?
    private var peers: [UUID: PeerSession] = [:]
    private var requestedBlockHashes: Set<String> = []

    public init(config: NodeServiceConfig, chainState: ChainState, mempool: Mempool) {
        self.config = config
        self.chainState = chainState
        self.mempool = mempool
    }

    public func start() throws {
        guard listener == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: config.listenPort) else {
            throw NodeServiceError.invalidPort
        }

        let listener = try NWListener(using: .tcp, on: port)
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                self?.log("listener failed: \(error.localizedDescription)")
            case .ready:
                self?.log("listening on :\(self?.config.listenPort ?? 0)")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection: connection)
        }
        listener.start(queue: queue)

        startHeartbeat()

        for peer in config.bootstrapPeers {
            connect(to: peer)
        }
    }

    public func stop() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil

        listener?.cancel()
        listener = nil

        for peer in peers.values {
            peer.stop()
        }
        peers.removeAll()
    }

    public func connect(to endpoint: String) {
        guard let (host, port) = parseEndpoint(endpoint) else {
            log("invalid peer endpoint '\(endpoint)'")
            return
        }

        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        addPeer(connection: connection, label: endpoint)
    }

    public func submitLocalBlock(_ block: Block) {
        Task { [weak self] in
            guard let self else { return }
            let result = await chainState.submitBlock(block)
            if case .accepted = result {
                let txIDs = block.transactions.map(\.txID)
                await mempool.remove(txIDs: txIDs)

                let payload = block.serialized().base64EncodedString()
                let msg = WireMessage(kind: .block, payloadBase64: payload)
                self.broadcast(msg)
            }
        }
    }

    public func submitLocalTransaction(_ transaction: Transaction) {
        Task { [weak self] in
            guard let self else { return }
            let addResult = await mempool.add(transaction)
            if case .accepted = addResult {
                let payload = transaction.serialized().base64EncodedString()
                self.broadcast(WireMessage(kind: .tx, payloadBase64: payload))
            }
        }
    }

    private func accept(connection: NWConnection) {
        if peers.count >= config.maxPeers {
            connection.cancel()
            return
        }
        addPeer(connection: connection, label: "inbound")
    }

    private func addPeer(connection: NWConnection, label: String) {
        if peers.count >= config.maxPeers {
            connection.cancel()
            return
        }

        let peer = PeerSession(connection: connection, queue: queue)
        peer.onReady = { [weak self] p in
            self?.handlePeerReady(p, label: label)
        }
        peer.onMessage = { [weak self] p, message in
            self?.handlePeerMessage(peer: p, message: message)
        }
        peer.onClosed = { [weak self] p in
            self?.removePeer(id: p.id)
        }

        peers[peer.id] = peer
        peer.start()
    }

    private func removePeer(id: UUID) {
        peers[id] = nil
    }

    private func handlePeerReady(_ peer: PeerSession, label: String) {
        Task {
            let tip = await chainState.tip()
            let version = WireMessage(
                kind: .version,
                networkID: config.networkID,
                nodeID: localNodeID,
                height: tip.height,
                hashHex: tip.hash.hexString
            )
            peer.send(version, encoder: encoder)
            log("connected peer (\(label)) \(peer.id.uuidString)")
        }
    }

    private func handlePeerMessage(peer: PeerSession, message: WireMessage) {
        switch message.kind {
        case .version:
            guard message.networkID == config.networkID else {
                log("peer \(peer.id.uuidString) network mismatch")
                peer.stop()
                return
            }
            peer.send(WireMessage(kind: .verack), encoder: encoder)
            Task {
                let tip = await chainState.tip()
                peer.send(
                    WireMessage(
                        kind: .tip,
                        height: tip.height,
                        hashHex: tip.hash.hexString
                    ),
                    encoder: encoder
                )
            }

        case .verack:
            // handshake complete
            break

        case .ping:
            peer.send(WireMessage(kind: .pong, nonce: message.nonce), encoder: encoder)

        case .pong:
            break

        case .getTip:
            Task {
                let tip = await chainState.tip()
                peer.send(
                    WireMessage(
                        kind: .tip,
                        height: tip.height,
                        hashHex: tip.hash.hexString
                    ),
                    encoder: encoder
                )
            }

        case .tip:
            guard let peerHeight = message.height,
                  let peerTipHashHex = message.hashHex else {
                return
            }

            Task {
                let localTip = await chainState.tip()
                guard peerHeight > localTip.height else { return }
                guard let peerTipHash = Data(hexString: peerTipHashHex) else { return }
                guard await chainState.block(hash: peerTipHash) == nil else { return }

                requestBlockIfNeeded(hashHex: peerTipHashHex, from: peer)
            }

        case .block:
            guard let payload = message.payloadBase64,
                  let data = Data(base64Encoded: payload),
                  let block = Block.deserialize(from: data) else {
                return
            }
            clearRequestedBlock(hashHex: block.blockHash.hexString)

            Task {
                let result = await chainState.submitBlock(block)
                switch result {
                case .accepted(_, let becameBest):
                    let txIDs = block.transactions.map(\.txID)
                    await mempool.remove(txIDs: txIDs)

                    if becameBest {
                        let tip = await chainState.tip()
                        let msg = WireMessage(
                            kind: .tip,
                            height: tip.height,
                            hashHex: tip.hash.hexString
                        )
                        broadcast(msg)
                    }
                case .orphan(let parentHash):
                    requestBlockIfNeeded(hashHex: parentHash.hexString, from: peer)
                case .duplicate:
                    break
                case .rejected(let reason):
                    log("rejected peer block \(block.blockHash.hexString): \(reason)")
                }
            }

        case .getBlock:
            guard let hashHex = message.hashHex,
                  let hash = Data(hexString: hashHex) else {
                return
            }

            Task {
                guard let block = await chainState.block(hash: hash) else { return }
                let payload = block.serialized().base64EncodedString()
                peer.send(WireMessage(kind: .block, payloadBase64: payload), encoder: encoder)
            }

        case .tx:
            guard let payload = message.payloadBase64,
                  let data = Data(base64Encoded: payload),
                  let tx = Transaction.deserialize(from: data) else {
                return
            }

            Task {
                _ = await mempool.add(tx)
            }
        }
    }

    private func startHeartbeat() {
        heartbeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + config.heartbeatSeconds, repeating: config.heartbeatSeconds)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let nonce = UInt64.random(in: 0...UInt64.max)
            self.broadcast(WireMessage(kind: .ping, nonce: nonce))
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func broadcast(_ message: WireMessage) {
        for peer in peers.values {
            peer.send(message, encoder: encoder)
        }
    }

    private func requestBlockIfNeeded(hashHex: String, from peer: PeerSession) {
        let normalized = hashHex.lowercased()
        guard !normalized.isEmpty else { return }
        requestedBlockLock.lock()
        let inserted = requestedBlockHashes.insert(normalized).inserted
        requestedBlockLock.unlock()
        guard inserted else { return }

        peer.send(
            WireMessage(kind: .getBlock, hashHex: normalized),
            encoder: encoder
        )
        log("requesting block \(normalized.prefix(16))... from \(peer.id.uuidString)")
    }

    private func clearRequestedBlock(hashHex: String) {
        let normalized = hashHex.lowercased()
        requestedBlockLock.lock()
        requestedBlockHashes.remove(normalized)
        requestedBlockLock.unlock()
    }

    private func parseEndpoint(_ endpoint: String) -> (String, NWEndpoint.Port)? {
        let parts = endpoint.split(separator: ":", omittingEmptySubsequences: true)
        guard parts.count == 2,
              let portInt = UInt16(parts[1]),
              let port = NWEndpoint.Port(rawValue: portInt) else {
            return nil
        }
        return (String(parts[0]), port)
    }

    private func log(_ message: String) {
        print("[p2p] \(message)")
    }
}

public enum NodeServiceError: Error {
    case invalidPort
}

private final class PeerSession {
    let id = UUID()

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var receiveBuffer = Data()
    private var closed = false

    var onReady: ((PeerSession) -> Void)?
    var onMessage: ((PeerSession, WireMessage) -> Void)?
    var onClosed: ((PeerSession) -> Void)?

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?(self)
                self.receiveLoop()
            case .failed, .cancelled:
                self.closeIfNeeded()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func stop() {
        connection.cancel()
        closeIfNeeded()
    }

    func send(_ message: WireMessage, encoder: JSONEncoder) {
        guard !closed else { return }
        guard let payload = try? encoder.encode(message) else { return }

        var line = payload
        line.append(0x0A) // newline frame delimiter

        connection.send(content: line, completion: .contentProcessed { _ in })
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.processReceiveBuffer()
            }

            if isComplete || error != nil {
                self.closeIfNeeded()
                return
            }

            self.receiveLoop()
        }
    }

    private func processReceiveBuffer() {
        while let newline = receiveBuffer.firstIndex(of: 0x0A) {
            let line = Data(receiveBuffer[..<newline])
            receiveBuffer.removeSubrange(...newline)

            if line.isEmpty { continue }
            guard let message = try? JSONDecoder().decode(WireMessage.self, from: line) else { continue }
            onMessage?(self, message)
        }
    }

    private func closeIfNeeded() {
        guard !closed else { return }
        closed = true
        onClosed?(self)
    }
}
