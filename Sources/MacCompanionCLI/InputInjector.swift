import ApplicationServices
import ControllerShared
import Foundation

final class InputInjector {
    private let promptForAccessibility: Bool

    init(promptForAccessibility: Bool) {
        self.promptForAccessibility = promptForAccessibility
    }

    func inject(_ event: RemoteInputEvent) throws {
        guard isTrustedAccessibilityClient() else {
            throw NSError(domain: "InputInjector", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Accessibility permission is required before macOS will accept injected input."
            ])
        }

        switch event.type {
        case .pointerMove:
            guard let delta = event.pointerDelta else {
                return
            }
            postPointerMove(delta: delta)
        case .scroll:
            guard let delta = event.scrollDelta else {
                return
            }
            postScroll(delta: delta)
        case .mouseButton:
            guard let button = event.mouseButton, let state = event.buttonState else {
                return
            }
            postMouseButton(button: button, state: state)
        case .text:
            guard let text = event.text, !text.isEmpty else {
                return
            }
            postText(text)
        case .keyPress:
            guard let payload = event.keyPress else {
                return
            }
            postNamedKey(payload)
        }
    }

    private func isTrustedAccessibilityClient() -> Bool {
        let options: CFDictionary?
        if promptForAccessibility {
            options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        } else {
            options = nil
        }

        return AXIsProcessTrustedWithOptions(options)
    }

    private func currentCursorLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func postPointerMove(delta: PointerDelta) {
        let current = currentCursorLocation()
        let next = CGPoint(
            x: current.x + delta.dx,
            y: current.y - delta.dy
        )

        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: next,
            mouseButton: .left
        )
        event?.post(tap: .cghidEventTap)
    }

    private func postScroll(delta: ScrollDelta) {
        let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32((-delta.dy).rounded()),
            wheel2: Int32((-delta.dx).rounded()),
            wheel3: 0
        )
        event?.post(tap: .cghidEventTap)
    }

    private func postMouseButton(button: MouseButton, state: MouseButtonState) {
        switch state {
        case .click:
            postMouseButton(button: button, state: .down)
            postMouseButton(button: button, state: .up)
        case .down, .up:
            let current = currentCursorLocation()
            let event = CGEvent(
                mouseEventSource: nil,
                mouseType: mouseEventType(for: button, state: state),
                mouseCursorPosition: current,
                mouseButton: cgMouseButton(for: button)
            )
            event?.post(tap: .cghidEventTap)
        }
    }

    private func postText(_ text: String) {
        let utf16Units = Array(text.utf16)
        guard !utf16Units.isEmpty else {
            return
        }

        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: keyDown) else {
                continue
            }

            utf16Units.withUnsafeBufferPointer { buffer in
                event.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: buffer.baseAddress
                )
            }

            event.post(tap: .cghidEventTap)
        }
    }

    private func postNamedKey(_ payload: KeyPressPayload) {
        guard let keyCode = resolvedKeyCode(for: payload) else {
            return
        }

        let flags = cgFlags(for: payload.modifiers)

        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown) else {
                continue
            }

            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    private func resolvedKeyCode(for payload: KeyPressPayload) -> CGKeyCode? {
        if let keyCode = payload.keyCode {
            return keyCode
        }

        guard let key = payload.key else {
            return nil
        }

        return keyCode(for: key)
    }

    private func cgMouseButton(for button: MouseButton) -> CGMouseButton {
        switch button {
        case .primary:
            return .left
        case .secondary:
            return .right
        case .middle:
            return .center
        }
    }

    private func mouseEventType(for button: MouseButton, state: MouseButtonState) -> CGEventType {
        switch (button, state) {
        case (.primary, .down):
            return .leftMouseDown
        case (.primary, .up):
            return .leftMouseUp
        case (.secondary, .down):
            return .rightMouseDown
        case (.secondary, .up):
            return .rightMouseUp
        case (.middle, .down):
            return .otherMouseDown
        case (.middle, .up):
            return .otherMouseUp
        case (_, .click):
            return .null
        }
    }

    private func cgFlags(for modifiers: Set<ModifierKey>) -> CGEventFlags {
        var flags: CGEventFlags = []

        if modifiers.contains(.command) {
            flags.insert(.maskCommand)
        }
        if modifiers.contains(.option) {
            flags.insert(.maskAlternate)
        }
        if modifiers.contains(.control) {
            flags.insert(.maskControl)
        }
        if modifiers.contains(.shift) {
            flags.insert(.maskShift)
        }
        if modifiers.contains(.capsLock) {
            flags.insert(.maskAlphaShift)
        }

        return flags
    }

    private func keyCode(for key: NamedKey) -> CGKeyCode? {
        switch key {
        case .return:
            return 36
        case .delete:
            return 51
        case .forwardDelete:
            return 117
        case .escape:
            return 53
        case .tab:
            return 48
        case .space:
            return 49
        case .leftArrow:
            return 123
        case .rightArrow:
            return 124
        case .downArrow:
            return 125
        case .upArrow:
            return 126
        case .home:
            return 115
        case .end:
            return 119
        case .pageUp:
            return 116
        case .pageDown:
            return 121
        }
    }
}
