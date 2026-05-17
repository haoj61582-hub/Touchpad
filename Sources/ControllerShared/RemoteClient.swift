#if canImport(Network)
import Foundation
import Network

public final class RemoteClient {
    public enum State: Equatable {
        case idle
        case connecting
        case ready
        case failed(String)
        case cancelled

        public var label: String {
            switch self {
            case .idle:
                return "Idle"
            case .connecting:
                return "Connecting"
            case .ready:
                return "Connected"
            case .failed(let message):
                return "Failed: \(message)"
            case .cancelled:
                return "Disconnected"
            }
        }
    }

    public var onStateChange: ((State) -> Void)?
    public var onServerMessage: ((WireMessage) -> Void)?

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "controller.remote-client")
    private var receiveBuffer = Data()
    private var pendingHello: PeerHello?

    public init(host: String, port: UInt16) {
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(rawValue: RemoteCompanionService.defaultPort)!,
            using: .tcp
        )
    }

    public init(endpoint: NWEndpoint) {
        connection = NWConnection(to: endpoint, using: .tcp)
    }

    public func start(hello: PeerHello) {
        pendingHello = hello
        onStateChange?(.connecting)

        connection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState(state)
        }

        connection.start(queue: queue)
        receiveLoop()
    }

    public func stop() {
        connection.cancel()
        onStateChange?(.cancelled)
    }

    public func send(_ event: RemoteInputEvent) {
        send(WireMessage.input(event))
    }

    public func send(_ message: WireMessage) {
        do {
            let data = try JSONLinesWireCodec.encode(message)
            connection.send(content: data, completion: .contentProcessed({ [weak self] error in
                if let error {
                    self?.onStateChange?(.failed(error.localizedDescription))
                }
            }))
        } catch {
            onStateChange?(.failed(error.localizedDescription))
        }
    }

    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            onStateChange?(.ready)
            if let pendingHello {
                send(.hello(pendingHello))
                self.pendingHello = nil
            }
        case .failed(let error):
            onStateChange?(.failed(error.localizedDescription))
        case .cancelled:
            onStateChange?(.cancelled)
        default:
            break
        }
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }

            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)

                do {
                    let messages = try JSONLinesWireCodec.drain(WireMessage.self, from: &self.receiveBuffer)
                    messages.forEach { self.onServerMessage?($0) }
                } catch {
                    self.onStateChange?(.failed(error.localizedDescription))
                }
            }

            if let error {
                self.onStateChange?(.failed(error.localizedDescription))
                return
            }

            if isComplete {
                self.onStateChange?(.cancelled)
                return
            }

            self.receiveLoop()
        }
    }
}
#endif
