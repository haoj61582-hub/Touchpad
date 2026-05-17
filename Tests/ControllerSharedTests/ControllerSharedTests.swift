import XCTest
@testable import ControllerShared

final class ControllerSharedTests: XCTestCase {
    func testHelloRoundTrip() throws {
        let hello = PeerHello(
            deviceName: "Jiahao's iPad",
            platform: .ipadOS,
            appVersion: "0.1.0"
        )

        let encoded = try JSONLinesWireCodec.encode(WireMessage.hello(hello))
        let decoded = try JSONLinesWireCodec.decode(WireMessage.self, from: encoded.dropLast())

        XCTAssertEqual(decoded.kind, .hello)
        XCTAssertEqual(decoded.hello, hello)
    }

    func testDrainDecodesMultipleMessages() throws {
        var buffer = Data()
        buffer.append(try JSONLinesWireCodec.encode(WireMessage.input(.pointerMove(dx: 12, dy: -4))))
        buffer.append(try JSONLinesWireCodec.encode(WireMessage.input(.text("hello"))))

        let messages = try JSONLinesWireCodec.drain(WireMessage.self, from: &buffer)

        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(messages[0].input?.pointerDelta, PointerDelta(dx: 12, dy: -4))
        XCTAssertEqual(messages[1].input?.text, "hello")
    }

    func testRawKeyCodeRoundTrip() throws {
        let payload = KeyPressPayload(
            keyCode: 12,
            modifiers: [.command, .shift],
            keyLabel: "Q"
        )

        let encoded = try JSONLinesWireCodec.encode(WireMessage.input(.keyPress(payload)))
        let decoded = try JSONLinesWireCodec.decode(WireMessage.self, from: encoded.dropLast())

        XCTAssertEqual(decoded.input?.keyPress?.keyCode, 12)
        XCTAssertEqual(decoded.input?.keyPress?.modifiers, [.command, .shift])
        XCTAssertEqual(decoded.input?.keyPress?.keyLabel, "Q")
        XCTAssertNil(decoded.input?.keyPress?.key)
    }
}
