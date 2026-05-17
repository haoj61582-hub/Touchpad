import ControllerShared
import Foundation
import Network

final class CompanionServer {
    private let listener: NWListener
    private let injector: InputInjector
    private let queue = DispatchQueue(label: "controller.mac-companion")
    private var sessions: [UUID: ClientSession] = [:]

    init(port: UInt16, promptForAccessibility: Bool) throws {
        guard let listenerPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "CompanionServer", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid TCP port \(port)."
            ])
        }

        listener = try NWListener(using: .tcp, on: listenerPort)
        listener.service = NWListener.Service(
            name: Host.current().localizedName ?? "Mac Companion",
            type: RemoteCompanionService.bonjourType,
            domain: nil,
            txtRecord: nil
        )
        injector = InputInjector(promptForAccessibility: promptForAccessibility)
    }

    func start() {
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("Server ready.")
            case .failed(let error):
                print("Server failed: \(error.localizedDescription)")
            default:
                break
            }
        }

        listener.serviceRegistrationUpdateHandler = { change in
            print("Bonjour registration: \(change)")
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        listener.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        let sessionID = UUID()
        let session = ClientSession(
            id: sessionID,
            connection: connection,
            injector: injector,
            onStop: { [weak self] id in
                self?.sessions[id] = nil
            }
        )

        sessions[sessionID] = session
        session.start(on: queue)
    }
}

private final class ClientSession {
    private let id: UUID
    private let connection: NWConnection
    private let injector: InputInjector
    private let onStop: (UUID) -> Void
    private var receiveBuffer = Data()
    private var peerHello: PeerHello?

    init(
        id: UUID,
        connection: NWConnection,
        injector: InputInjector,
        onStop: @escaping (UUID) -> Void
    ) {
        self.id = id
        self.connection = connection
        self.injector = injector
        self.onStop = onStop
    }

    func start(on queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState(state)
        }

        connection.start(queue: queue)
        receiveLoop()
    }

    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            print("Client connected: \(connection.endpoint)")
            send(.acknowledgement(note: "mac companion ready"))
        case .failed(let error):
            print("Client failed: \(error.localizedDescription)")
            stop()
        case .cancelled:
            stop()
        default:
            break
        }
    }

    private func stop() {
        connection.cancel()
        onStop(id)
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }

            if let data, !data.isEmpty {
                receiveBuffer.append(data)

                do {
                    let messages = try JSONLinesWireCodec.drain(WireMessage.self, from: &receiveBuffer)
                    try messages.forEach(handle)
                } catch {
                    send(.error(code: "decode_failed", message: error.localizedDescription))
                }
            }

            if let error {
                print("Receive error: \(error.localizedDescription)")
                stop()
                return
            }

            if isComplete {
                stop()
                return
            }

            receiveLoop()
        }
    }

    private func handle(_ message: WireMessage) throws {
        switch message.kind {
        case .hello:
            guard let hello = message.hello else {
                send(.error(code: "missing_hello", message: "Hello payload was missing."))
                return
            }

            peerHello = hello
            print("Paired with \(hello.deviceName) (\(hello.platform.rawValue)) via \(hello.transportHint)")
            send(.acknowledgement(note: "hello received"))
        case .input:
            guard let input = message.input else {
                send(.error(code: "missing_input", message: "Input payload was missing."))
                return
            }

            try injector.inject(input)
            send(.acknowledgement(messageID: input.id, note: "input applied"))
        case .ping:
            send(.ping())
        case .acknowledgement, .error:
            break
        }
    }

    private func send(_ message: WireMessage) {
        do {
            let data = try JSONLinesWireCodec.encode(message)
            connection.send(content: data, completion: .contentProcessed({ error in
                if let error {
                    print("Send error: \(error.localizedDescription)")
                }
            }))
        } catch {
            print("Encoding error: \(error.localizedDescription)")
        }
    }
}
