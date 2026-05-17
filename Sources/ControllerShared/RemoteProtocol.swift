import Foundation

public enum RemoteProtocolVersion {
    public static let current = 1
}

public enum RemoteCompanionService {
    public static let defaultPort: UInt16 = 38_765
    public static let bonjourType = "_controller-remote._tcp"
}

public enum PeerPlatform: String, Codable, Sendable, Equatable {
    case ipadOS
    case iOS
    case macOS
    case windows
    case unknown
}

public struct PeerHello: Codable, Sendable, Equatable {
    public let deviceName: String
    public let platform: PeerPlatform
    public let appVersion: String
    public let protocolVersion: Int
    public let transportHint: String

    public init(
        deviceName: String,
        platform: PeerPlatform,
        appVersion: String,
        protocolVersion: Int = RemoteProtocolVersion.current,
        transportHint: String = "tcp-json-lines"
    ) {
        self.deviceName = deviceName
        self.platform = platform
        self.appVersion = appVersion
        self.protocolVersion = protocolVersion
        self.transportHint = transportHint
    }
}

public struct PointerDelta: Codable, Sendable, Equatable {
    public let dx: Double
    public let dy: Double

    public init(dx: Double, dy: Double) {
        self.dx = dx
        self.dy = dy
    }
}

public struct ScrollDelta: Codable, Sendable, Equatable {
    public let dx: Double
    public let dy: Double

    public init(dx: Double, dy: Double) {
        self.dx = dx
        self.dy = dy
    }
}

public enum MouseButton: String, Codable, Sendable, Equatable {
    case primary
    case secondary
    case middle
}

public enum MouseButtonState: String, Codable, Sendable, Equatable {
    case down
    case up
    case click
}

public enum ModifierKey: String, Codable, Sendable, Hashable {
    case command
    case option
    case control
    case shift
    case capsLock
}

public enum NamedKey: String, Codable, Sendable, Equatable {
    case `return`
    case delete
    case forwardDelete
    case escape
    case tab
    case space
    case leftArrow
    case rightArrow
    case upArrow
    case downArrow
    case home
    case end
    case pageUp
    case pageDown
}

public struct KeyPressPayload: Codable, Sendable, Equatable {
    public let key: NamedKey?
    public let keyCode: UInt16?
    public let keyLabel: String?
    public let modifiers: Set<ModifierKey>

    public init(key: NamedKey, modifiers: Set<ModifierKey> = []) {
        self.key = key
        self.keyCode = nil
        self.keyLabel = nil
        self.modifiers = modifiers
    }

    public init(keyCode: UInt16, modifiers: Set<ModifierKey> = [], keyLabel: String? = nil) {
        self.key = nil
        self.keyCode = keyCode
        self.keyLabel = keyLabel
        self.modifiers = modifiers
    }
}

public enum RemoteInputEventType: String, Codable, Sendable, Equatable {
    case pointerMove
    case scroll
    case mouseButton
    case text
    case keyPress
}

public struct RemoteInputEvent: Codable, Sendable, Equatable {
    public let id: UUID
    public let sentAt: Date
    public let type: RemoteInputEventType
    public let pointerDelta: PointerDelta?
    public let scrollDelta: ScrollDelta?
    public let mouseButton: MouseButton?
    public let buttonState: MouseButtonState?
    public let text: String?
    public let keyPress: KeyPressPayload?

    public init(
        id: UUID = UUID(),
        sentAt: Date = Date(),
        type: RemoteInputEventType,
        pointerDelta: PointerDelta? = nil,
        scrollDelta: ScrollDelta? = nil,
        mouseButton: MouseButton? = nil,
        buttonState: MouseButtonState? = nil,
        text: String? = nil,
        keyPress: KeyPressPayload? = nil
    ) {
        self.id = id
        self.sentAt = sentAt
        self.type = type
        self.pointerDelta = pointerDelta
        self.scrollDelta = scrollDelta
        self.mouseButton = mouseButton
        self.buttonState = buttonState
        self.text = text
        self.keyPress = keyPress
    }

    public static func pointerMove(dx: Double, dy: Double) -> RemoteInputEvent {
        RemoteInputEvent(
            type: .pointerMove,
            pointerDelta: PointerDelta(dx: dx, dy: dy)
        )
    }

    public static func scroll(dx: Double, dy: Double) -> RemoteInputEvent {
        RemoteInputEvent(
            type: .scroll,
            scrollDelta: ScrollDelta(dx: dx, dy: dy)
        )
    }

    public static func mouseButton(_ button: MouseButton, state: MouseButtonState) -> RemoteInputEvent {
        RemoteInputEvent(
            type: .mouseButton,
            mouseButton: button,
            buttonState: state
        )
    }

    public static func text(_ text: String) -> RemoteInputEvent {
        RemoteInputEvent(
            type: .text,
            text: text
        )
    }

    public static func keyPress(_ payload: KeyPressPayload) -> RemoteInputEvent {
        RemoteInputEvent(
            type: .keyPress,
            keyPress: payload
        )
    }
}

public struct Acknowledgement: Codable, Sendable, Equatable {
    public let messageID: UUID?
    public let note: String

    public init(messageID: UUID? = nil, note: String) {
        self.messageID = messageID
        self.note = note
    }
}

public struct ProtocolErrorPayload: Codable, Sendable, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct PingPayload: Codable, Sendable, Equatable {
    public let sentAt: Date

    public init(sentAt: Date = Date()) {
        self.sentAt = sentAt
    }
}

public enum WireMessageKind: String, Codable, Sendable, Equatable {
    case hello
    case input
    case acknowledgement
    case error
    case ping
}

public struct WireMessage: Codable, Sendable, Equatable {
    public let kind: WireMessageKind
    public let hello: PeerHello?
    public let input: RemoteInputEvent?
    public let acknowledgement: Acknowledgement?
    public let error: ProtocolErrorPayload?
    public let ping: PingPayload?

    public init(
        kind: WireMessageKind,
        hello: PeerHello? = nil,
        input: RemoteInputEvent? = nil,
        acknowledgement: Acknowledgement? = nil,
        error: ProtocolErrorPayload? = nil,
        ping: PingPayload? = nil
    ) {
        self.kind = kind
        self.hello = hello
        self.input = input
        self.acknowledgement = acknowledgement
        self.error = error
        self.ping = ping
    }

    public static func hello(_ payload: PeerHello) -> WireMessage {
        WireMessage(kind: .hello, hello: payload)
    }

    public static func input(_ payload: RemoteInputEvent) -> WireMessage {
        WireMessage(kind: .input, input: payload)
    }

    public static func acknowledgement(messageID: UUID? = nil, note: String) -> WireMessage {
        WireMessage(
            kind: .acknowledgement,
            acknowledgement: Acknowledgement(messageID: messageID, note: note)
        )
    }

    public static func error(code: String, message: String) -> WireMessage {
        WireMessage(
            kind: .error,
            error: ProtocolErrorPayload(code: code, message: message)
        )
    }

    public static func ping() -> WireMessage {
        WireMessage(kind: .ping, ping: PingPayload())
    }
}
