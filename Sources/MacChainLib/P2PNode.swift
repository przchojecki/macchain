import Foundation
import Network

public struct NodeServiceConfig {
    public var networkID: String
    public var listenPort: UInt16
    public var bootstrapPeers: [String]
    public var maxPeers: Int
    public var heartbeatSeconds: TimeInterval
    public var maxInboundFrameBytes: Int
    public var maxPayloadBase64Bytes: Int
    public var maxPendingBlockRequests: Int
    public var blockRequestTTLSeconds: TimeInterval
    public var maxInFlightAsyncTasks: Int

    public init(
        networkID: String = "macchain-main",
        listenPort: UInt16 = 8338,
        bootstrapPeers: [String] = [],
        maxPeers: Int = 32,
        heartbeatSeconds: TimeInterval = 15,
        maxInboundFrameBytes: Int = 4_000_000,
        maxPayloadBase64Bytes: Int = 3_000_000,
        maxPendingBlockRequests: Int = 4_096,
        blockRequestTTLSeconds: TimeInterval = 300,
        maxInFlightAsyncTasks: Int = 256
    ) {
        self.networkID = networkID
        self.listenPort = listenPort
        self.bootstrapPeers = bootstrapPeers
        self.maxPeers = maxPeers
        self.heartbeatSeconds = heartbeatSeconds
        self.maxInboundFrameBytes = maxInboundFrameBytes
        self.maxPayloadBase64Bytes = maxPayloadBase64Bytes
        self.maxPendingBlockRequests = maxPendingBlockRequests
        self.blockRequestTTLSeconds = blockRequestTTLSeconds
        self.maxInFlightAsyncTasks = maxInFlightAsyncTasks
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
    private struct PeerHandshakeState {
        var sawVersion: Bool = false
        var sawVerack: Bool = false

        var isComplete: Bool {
            sawVersion && sawVerack
        }
    }

    public let config: NodeServiceConfig

    private let chainState: ChainState
    private let mempool: Mempool
    private let localNodeID = UUID().uuidString
    private let queue = DispatchQueue(label: "macchain.p2p.node")
    private let encoder = JSONEncoder()
    private let requestedBlockLock = NSLock()
    private let peersLock = NSLock()
    private let asyncWorkLock = NSLock()

    private var listener: NWListener?
    private var heartbeatTimer: DispatchSourceTimer?
    private var peers: [UUID: PeerSession] = [:]
    private var peerHandshake: [UUID: PeerHandshakeState] = [:]
    private var requestedBlockHashes: [String: TimeInterval] = [:]
    private var inFlightAsyncWork: Int = 0

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
        guard config.maxInboundFrameBytes > 0,
              config.maxPayloadBase64Bytes > 0,
              config.maxPendingBlockRequests > 0,
              config.blockRequestTTLSeconds > 0,
              config.maxInFlightAsyncTasks > 0 else {
            throw NodeServiceError.invalidLimits
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

        let currentPeers = peersSnapshot()
        for peer in currentPeers {
            peer.stop()
        }
        peersLock.lock()
        peers.removeAll()
        peerHandshake.removeAll()
        peersLock.unlock()

        requestedBlockLock.lock()
        requestedBlockHashes.removeAll()
        requestedBlockLock.unlock()
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
        submitBoundedAsyncWork(label: "submit-local-block") { [weak self] in
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
        submitBoundedAsyncWork(label: "submit-local-tx") { [weak self] in
            guard let self else { return }
            let addResult = await mempool.add(transaction)
            if case .accepted = addResult {
                let payload = transaction.serialized().base64EncodedString()
                self.broadcast(WireMessage(kind: .tx, payloadBase64: payload))
            }
        }
    }

    private func accept(connection: NWConnection) {
        addPeer(connection: connection, label: "inbound")
    }

    private func addPeer(connection: NWConnection, label: String) {
        let peer = PeerSession(
            connection: connection,
            queue: queue,
            maxFrameBytes: config.maxInboundFrameBytes
        )
        peer.onReady = { [weak self] p in
            self?.handlePeerReady(p, label: label)
        }
        peer.onMessage = { [weak self] p, message in
            self?.handlePeerMessage(peer: p, message: message)
        }
        peer.onClosed = { [weak self] p in
            self?.removePeer(id: p.id)
        }

        peersLock.lock()
        if peers.count >= config.maxPeers {
            peersLock.unlock()
            connection.cancel()
            return
        }
        peers[peer.id] = peer
        peerHandshake[peer.id] = PeerHandshakeState()
        peersLock.unlock()
        peer.start()
    }

    private func removePeer(id: UUID) {
        peersLock.lock()
        peers[id] = nil
        peerHandshake[id] = nil
        peersLock.unlock()
    }

    private func handlePeerReady(_ peer: PeerSession, label: String) {
        submitBoundedAsyncWork(label: "peer-ready") { [self] in
            let tip = await self.chainState.tip()
            let version = WireMessage(
                kind: .version,
                networkID: self.config.networkID,
                nodeID: self.localNodeID,
                height: tip.height,
                hashHex: tip.hash.hexString
            )
            peer.send(version, encoder: self.encoder)
            self.log("connected peer (\(label)) \(peer.id.uuidString)")
        }
    }

    private func handlePeerMessage(peer: PeerSession, message: WireMessage) {
        if let payload = message.payloadBase64,
           payload.utf8.count > config.maxPayloadBase64Bytes {
            log("peer \(peer.id.uuidString) exceeded payload limit")
            peer.stop()
            return
        }

        if message.kind != .version && message.kind != .verack &&
            requiresHandshake(message.kind) && !isHandshakeComplete(for: peer.id) {
            log("peer \(peer.id.uuidString) sent \(message.kind.rawValue) before handshake")
            peer.stop()
            return
        }

        switch message.kind {
        case .version:
            guard message.networkID == config.networkID else {
                log("peer \(peer.id.uuidString) network mismatch")
                peer.stop()
                return
            }
            if message.nodeID == localNodeID {
                log("peer \(peer.id.uuidString) loopback node ID, disconnecting")
                peer.stop()
                return
            }
            guard markPeerSawVersion(peer.id) else {
                log("peer \(peer.id.uuidString) sent duplicate version")
                peer.stop()
                return
            }
            peer.send(WireMessage(kind: .verack), encoder: encoder)
            submitBoundedAsyncWork(label: "send-tip-after-version") { [self] in
                let tip = await self.chainState.tip()
                peer.send(
                    WireMessage(
                        kind: .tip,
                        height: tip.height,
                        hashHex: tip.hash.hexString
                    ),
                    encoder: self.encoder
                )
            }

        case .verack:
            guard markPeerSawVerack(peer.id) else {
                log("peer \(peer.id.uuidString) sent invalid verack")
                peer.stop()
                return
            }
            peer.send(WireMessage(kind: .getTip), encoder: encoder)

        case .ping:
            peer.send(WireMessage(kind: .pong, nonce: message.nonce), encoder: encoder)

        case .pong:
            break

        case .getTip:
            submitBoundedAsyncWork(label: "respond-getTip") { [self] in
                let tip = await self.chainState.tip()
                peer.send(
                    WireMessage(
                        kind: .tip,
                        height: tip.height,
                        hashHex: tip.hash.hexString
                    ),
                    encoder: self.encoder
                )
            }

        case .tip:
            guard let peerHeight = message.height,
                  let peerTipHashHex = message.hashHex else {
                return
            }

            submitBoundedAsyncWork(label: "tip-sync") { [self] in
                let localTip = await self.chainState.tip()
                guard peerHeight > localTip.height else { return }
                guard let peerTipHash = Data(hexString: peerTipHashHex) else { return }
                guard await self.chainState.block(hash: peerTipHash) == nil else { return }

                self.requestBlockIfNeeded(hashHex: peerTipHashHex, from: peer)
            }

        case .block:
            guard let payload = message.payloadBase64,
                  let data = Data(base64Encoded: payload),
                  let block = Block.deserialize(from: data) else {
                return
            }
            clearRequestedBlock(hashHex: block.blockHash.hexString)

            submitBoundedAsyncWork(label: "handle-block") { [self] in
                let result = await self.chainState.submitBlock(block)
                switch result {
                case .accepted(_, let becameBest):
                    let txIDs = block.transactions.map(\.txID)
                    await self.mempool.remove(txIDs: txIDs)

                    if becameBest {
                        let tip = await self.chainState.tip()
                        let msg = WireMessage(
                            kind: .tip,
                            height: tip.height,
                            hashHex: tip.hash.hexString
                        )
                        self.broadcast(msg)
                    }
                case .orphan(let parentHash):
                    self.requestBlockIfNeeded(hashHex: parentHash.hexString, from: peer)
                case .duplicate:
                    break
                case .rejected(let reason):
                    self.log("rejected peer block \(block.blockHash.hexString): \(reason)")
                }
            }

        case .getBlock:
            guard let hashHex = message.hashHex,
                  hashHex.count <= 64,
                  let hash = Data(hexString: hashHex) else {
                return
            }

            submitBoundedAsyncWork(label: "respond-getBlock") { [self] in
                guard let block = await self.chainState.block(hash: hash) else { return }
                let payload = block.serialized().base64EncodedString()
                peer.send(WireMessage(kind: .block, payloadBase64: payload), encoder: self.encoder)
            }

        case .tx:
            guard let payload = message.payloadBase64,
                  let data = Data(base64Encoded: payload),
                  let tx = Transaction.deserialize(from: data) else {
                return
            }

            submitBoundedAsyncWork(label: "handle-tx") { [self] in
                _ = await self.mempool.add(tx)
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
        for peer in peersSnapshot() {
            peer.send(message, encoder: encoder)
        }
    }

    private func requiresHandshake(_ kind: WireMessage.Kind) -> Bool {
        switch kind {
        case .version, .verack, .ping, .pong:
            return false
        case .getTip, .getBlock, .tip, .block, .tx:
            return true
        }
    }

    private func isHandshakeComplete(for peerID: UUID) -> Bool {
        peersLock.lock()
        defer { peersLock.unlock() }
        return peerHandshake[peerID]?.isComplete ?? false
    }

    @discardableResult
    private func markPeerSawVersion(_ peerID: UUID) -> Bool {
        peersLock.lock()
        defer { peersLock.unlock() }
        var state = peerHandshake[peerID] ?? PeerHandshakeState()
        if state.sawVersion {
            return false
        }
        state.sawVersion = true
        peerHandshake[peerID] = state
        return true
    }

    @discardableResult
    private func markPeerSawVerack(_ peerID: UUID) -> Bool {
        peersLock.lock()
        defer { peersLock.unlock() }
        var state = peerHandshake[peerID] ?? PeerHandshakeState()
        guard state.sawVersion, !state.sawVerack else {
            return false
        }
        state.sawVerack = true
        peerHandshake[peerID] = state
        return true
    }

    private func requestBlockIfNeeded(hashHex: String, from peer: PeerSession) {
        let normalized = hashHex.lowercased()
        guard !normalized.isEmpty else { return }

        let now = Date().timeIntervalSince1970
        requestedBlockLock.lock()
        pruneRequestedBlockHashesLocked(now: now)

        if requestedBlockHashes[normalized] != nil {
            requestedBlockLock.unlock()
            return
        }
        if requestedBlockHashes.count >= config.maxPendingBlockRequests {
            requestedBlockLock.unlock()
            log("request queue full, skipping block request \(normalized.prefix(16))...")
            return
        }

        requestedBlockHashes[normalized] = now
        requestedBlockLock.unlock()

        peer.send(
            WireMessage(kind: .getBlock, hashHex: normalized),
            encoder: encoder
        )
        log("requesting block \(normalized.prefix(16))... from \(peer.id.uuidString)")
    }

    private func clearRequestedBlock(hashHex: String) {
        let normalized = hashHex.lowercased()
        requestedBlockLock.lock()
        requestedBlockHashes.removeValue(forKey: normalized)
        requestedBlockLock.unlock()
    }

    private func pruneRequestedBlockHashesLocked(now: TimeInterval) {
        requestedBlockHashes = requestedBlockHashes.filter {
            now - $0.value <= config.blockRequestTTLSeconds
        }
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

    private func peersSnapshot() -> [PeerSession] {
        peersLock.lock()
        let snapshot = Array(peers.values)
        peersLock.unlock()
        return snapshot
    }

    private func submitBoundedAsyncWork(
        label: String,
        _ work: @escaping @Sendable () async -> Void
    ) {
        guard tryBeginAsyncWork() else {
            log("dropping async work (\(label)); max in-flight reached")
            return
        }

        Task { [weak self] in
            await work()
            self?.endAsyncWork()
        }
    }

    private func tryBeginAsyncWork() -> Bool {
        asyncWorkLock.lock()
        defer { asyncWorkLock.unlock() }
        guard inFlightAsyncWork < config.maxInFlightAsyncTasks else {
            return false
        }
        inFlightAsyncWork += 1
        return true
    }

    private func endAsyncWork() {
        asyncWorkLock.lock()
        if inFlightAsyncWork > 0 {
            inFlightAsyncWork -= 1
        }
        asyncWorkLock.unlock()
    }
}

public enum NodeServiceError: Error {
    case invalidPort
    case invalidLimits
}

private final class PeerSession {
    let id = UUID()

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let maxFrameBytes: Int
    private var receiveBuffer = Data()
    private var closed = false

    var onReady: ((PeerSession) -> Void)?
    var onMessage: ((PeerSession, WireMessage) -> Void)?
    var onClosed: ((PeerSession) -> Void)?

    init(connection: NWConnection, queue: DispatchQueue, maxFrameBytes: Int) {
        self.connection = connection
        self.queue = queue
        self.maxFrameBytes = max(1_024, maxFrameBytes)
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
                if self.receiveBuffer.count > self.maxFrameBytes {
                    self.closeIfNeeded()
                    return
                }
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
            if newline > maxFrameBytes {
                closeIfNeeded()
                return
            }
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
