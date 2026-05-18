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

struct ManualEntryField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var isFirstResponder: Bool = false
    var keyboardType: UIKeyboardType = .default
    var submitLabel: UIReturnKeyType = .done
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var autocorrectionType: UITextAutocorrectionType = .no
    var textContentType: UITextContentType?
    var onSubmit: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField(frame: .zero)
        textField.delegate = context.coordinator
        textField.placeholder = placeholder
        textField.text = text
        textField.keyboardType = keyboardType
        textField.returnKeyType = submitLabel
        textField.autocapitalizationType = autocapitalizationType
        textField.autocorrectionType = autocorrectionType
        textField.smartDashesType = .no
        textField.smartQuotesType = .no
        textField.smartInsertDeleteType = .no
        textField.clearButtonMode = .whileEditing
        textField.borderStyle = .none
        textField.backgroundColor = .clear
        textField.textContentType = textContentType
        textField.font = .systemFont(ofSize: 16, weight: .medium)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField.addTarget(
            context.coordinator,
            action: #selector(Coordinator.handleEditingChanged(_:)),
            for: .editingChanged
        )
        return textField
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }

        uiView.placeholder = placeholder
        uiView.keyboardType = keyboardType
        uiView.returnKeyType = submitLabel
        uiView.autocapitalizationType = autocapitalizationType
        uiView.autocorrectionType = autocorrectionType
        uiView.textContentType = textContentType

        guard context.coordinator.lastFirstResponderRequest != isFirstResponder else {
            return
        }

        context.coordinator.lastFirstResponderRequest = isFirstResponder

        if isFirstResponder, uiView.window != nil, !uiView.isFirstResponder {
            DispatchQueue.main.async {
                uiView.becomeFirstResponder()
            }
        } else if !isFirstResponder, uiView.isFirstResponder {
            DispatchQueue.main.async {
                uiView.resignFirstResponder()
            }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        @Binding private var text: String
        private let onSubmit: (() -> Void)?
        var lastFirstResponderRequest = false

        init(text: Binding<String>, onSubmit: (() -> Void)?) {
            _text = text
            self.onSubmit = onSubmit
        }

        @objc func handleEditingChanged(_ textField: UITextField) {
            text = textField.text ?? ""
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            onSubmit?()
            return false
        }
    }
}
#endif
