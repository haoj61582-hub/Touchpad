#if canImport(UIKit) && !os(macOS)
import SwiftUI
import UIKit

struct TextCaptureField: UIViewRepresentable {
    let placeholder: String
    let onText: (String) -> Void
    let onDeleteBackward: () -> Void
    let onReturn: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onText: onText,
            onDeleteBackward: onDeleteBackward,
            onReturn: onReturn
        )
    }

    func makeUIView(context: Context) -> RemoteTextField {
        let textField = RemoteTextField()
        textField.placeholder = placeholder
        textField.borderStyle = .roundedRect
        textField.delegate = context.coordinator
        textField.onEmptyDeleteBackward = { [weak coordinator = context.coordinator, weak textField] in
            coordinator?.handleDeleteBackward(in: textField)
        }
        textField.autocorrectionType = .default
        textField.autocapitalizationType = .none
        textField.smartQuotesType = .yes
        textField.smartDashesType = .yes
        textField.smartInsertDeleteType = .yes
        textField.returnKeyType = .default
        textField.clearButtonMode = .whileEditing
        textField.addTarget(
            context.coordinator,
            action: #selector(Coordinator.handleEditingChanged(_:)),
            for: .editingChanged
        )
        return textField
    }

    func updateUIView(_ uiView: RemoteTextField, context: Context) {
        uiView.placeholder = placeholder
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        private let onText: (String) -> Void
        private let onDeleteBackward: () -> Void
        private let onReturn: () -> Void

        init(
            onText: @escaping (String) -> Void,
            onDeleteBackward: @escaping () -> Void,
            onReturn: @escaping () -> Void
        ) {
            self.onText = onText
            self.onDeleteBackward = onDeleteBackward
            self.onReturn = onReturn
        }

        @objc func handleEditingChanged(_ textField: RemoteTextField) {
            guard textField.markedTextRange == nil else {
                return
            }

            let committedText = textField.text ?? ""
            guard !committedText.isEmpty else {
                return
            }

            onText(committedText)
            textField.text = ""
        }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            if string == "\n" {
                onReturn()
                textField.text = ""
                return false
            }

            return true
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            onReturn()
            textField.text = ""
            return false
        }

        func handleDeleteBackward(in textField: RemoteTextField?) {
            guard let textField else {
                onDeleteBackward()
                return
            }

            let hasLocalContent = !(textField.text ?? "").isEmpty || textField.markedTextRange != nil
            if !hasLocalContent {
                onDeleteBackward()
            }
        }
    }
}

final class RemoteTextField: UITextField {
    var onEmptyDeleteBackward: (() -> Void)?

    override func deleteBackward() {
        let shouldNotify = (text ?? "").isEmpty && markedTextRange == nil
        super.deleteBackward()
        if shouldNotify {
            onEmptyDeleteBackward?()
        }
    }
}
#endif
