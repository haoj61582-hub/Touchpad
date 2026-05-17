#if canImport(UIKit) && !os(macOS)
import AudioToolbox
import ControllerShared
import SwiftUI
import UIKit

struct MechanicalKeyboardView: View {
    let onSendKeyCode: (UInt16, Set<ModifierKey>, String) -> Void

    @State private var transientModifiers: Set<ModifierKey> = []
    @State private var capsLockEnabled = false
    @State private var inputSource: KeyboardInputSource = .english
    @State private var activeLayer: KeyboardLayer = .letters
    @State private var showsNumberPad = true

    var body: some View {
        GeometryReader { proxy in
            let metrics = KeyboardSurfaceMetrics(size: proxy.size, showsNumberPad: showsNumberPad)

            VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
                header(metrics: metrics)
                layerToolbar(metrics: metrics)

                Group {
                    if metrics.stacksNumberPad {
                        VStack(alignment: .leading, spacing: metrics.deckSpacing) {
                            keyboardDeck(rows: rows(for: activeLayer), compact: false, metrics: metrics)

                            if showsNumberPad {
                                HStack {
                                    Spacer(minLength: 0)

                                    keyboardDeck(rows: numberPadRows, compact: true, metrics: metrics)
                                        .frame(width: metrics.stackedNumberPadWidth)
                                }
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                    } else {
                        HStack(alignment: .top, spacing: metrics.deckSpacing) {
                            keyboardDeck(rows: rows(for: activeLayer), compact: false, metrics: metrics)

                            if showsNumberPad {
                                keyboardDeck(rows: numberPadRows, compact: true, metrics: metrics)
                                    .frame(width: metrics.sideNumberPadWidth)
                                    .transition(.move(edge: .trailing).combined(with: .opacity))
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)

                Text("The Globe key cycles EN, Pinyin, and Kana while also sending Control-Space to your Mac. Use the quick input field below for emoji, paste, or text committed through the iPad system keyboard.")
                    .font(.system(size: metrics.footnoteSize, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.39, green: 0.44, blue: 0.51))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(metrics.outerPadding)
            .background(
                RoundedRectangle(cornerRadius: metrics.surfaceCornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.86))
                    .overlay(
                        RoundedRectangle(cornerRadius: metrics.surfaceCornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.76), lineWidth: 1)
                    )
            )
            .shadow(color: Color.black.opacity(0.06), radius: 26, y: 14)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: activeLayer)
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: showsNumberPad)
    }

    private func header(metrics: KeyboardSurfaceMetrics) -> some View {
        Group {
            if metrics.isPortrait {
                VStack(alignment: .leading, spacing: 12) {
                    headerText(metrics: metrics)
                    badgeStrip
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    headerText(metrics: metrics)
                    Spacer(minLength: 12)
                    badgeStrip
                }
            }
        }
    }

    private func headerText(metrics: KeyboardSurfaceMetrics) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Keyboard Deck")
                .font(.system(size: metrics.titleSize, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.12, green: 0.14, blue: 0.18))

            Text("Minimal Apple-inspired extended keyboard with multilingual switching, symbols, and a dedicated number pad.")
                .font(.system(size: metrics.subtitleSize, weight: .medium, design: .rounded))
                .foregroundStyle(Color(red: 0.42, green: 0.47, blue: 0.54))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var badgeStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                KeyboardBadge(text: inputSource.badgeTitle)
                KeyboardBadge(text: activeLayer.badgeTitle)

                if showsNumberPad {
                    KeyboardBadge(text: "Numpad")
                }

                ForEach(activeBadges, id: \.self) { badge in
                    KeyboardBadge(text: badge, accent: true)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    private func layerToolbar(metrics: KeyboardSurfaceMetrics) -> some View {
        Group {
            if metrics.isPortrait {
                VStack(alignment: .leading, spacing: 12) {
                    layerButtons
                    numberPadToggle
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                HStack(spacing: 10) {
                    layerButtons
                    Spacer(minLength: 10)
                    numberPadToggle
                }
            }
        }
    }

    private var layerButtons: some View {
        HStack(spacing: 10) {
            ForEach(KeyboardLayer.allCases, id: \.self) { layer in
                Button(layer.toolbarTitle) {
                    activate(layer)
                }
                .buttonStyle(LayerChipButtonStyle(selected: activeLayer == layer))
            }
        }
    }

    private var numberPadToggle: some View {
        Button {
            showsNumberPad.toggle()
            KeyboardFeedbackEngine.shared.play(.modifier)
        } label: {
            Label(showsNumberPad ? "Hide Numpad" : "Show Numpad", systemImage: showsNumberPad ? "rectangle.split.3x1.fill" : "rectangle.split.3x1")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .buttonStyle(LayerChipButtonStyle(selected: showsNumberPad))
    }

    private func keyboardDeck(rows: [[KeyboardLayoutKey]], compact: Bool, metrics: KeyboardSurfaceMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.deckRowSpacing) {
            ForEach(rows.indices, id: \.self) { index in
                KeyboardRow(
                    keys: rows[index],
                    labelProvider: label(for:),
                    isActive: isActive(key:),
                    onTap: handleTap(_:),
                    metrics: metrics
                )
                .frame(height: rowHeight(for: index, totalRows: rows.count, compact: compact, metrics: metrics))
            }
        }
        .padding(compact ? metrics.compactDeckPadding : metrics.mainDeckPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: compact ? metrics.compactDeckCornerRadius : metrics.mainDeckCornerRadius, style: .continuous)
                .fill(Color(red: 0.94, green: 0.95, blue: 0.97))
                .overlay(
                    RoundedRectangle(cornerRadius: compact ? metrics.compactDeckCornerRadius : metrics.mainDeckCornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.96), lineWidth: 1)
                )
        )
    }

    private var activeBadges: [String] {
        var badges: [String] = []

        if transientModifiers.contains(.control) {
            badges.append("Ctrl")
        }
        if transientModifiers.contains(.option) {
            badges.append("Opt")
        }
        if transientModifiers.contains(.command) {
            badges.append("Cmd")
        }
        if transientModifiers.contains(.shift) {
            badges.append("Shift")
        }
        if capsLockEnabled {
            badges.append("Caps")
        }

        return badges
    }

    private func rowHeight(for index: Int, totalRows: Int, compact: Bool, metrics: KeyboardSurfaceMetrics) -> CGFloat {
        if compact {
            return index == 0 ? metrics.compactFunctionRowHeight : metrics.compactRowHeight
        }

        if index == 0 {
            return metrics.functionRowHeight
        }

        if index == totalRows - 1 {
            return metrics.bottomRowHeight
        }

        return metrics.standardRowHeight
    }

    private func handleTap(_ key: KeyboardLayoutKey) {
        switch key.role {
        case .modifier(let modifier):
            handleModifier(modifier)
        case .printable(let printable):
            let modifiers = resolvedModifiers(isLetter: printable.isLetter)
            KeyboardFeedbackEngine.shared.play(.printable)
            onSendKeyCode(printable.keyCode, modifiers, label(for: key))
            transientModifiers.removeAll()
        case .special(let special):
            let modifiers = transientModifiers.union(special.intrinsicModifiers)
            KeyboardFeedbackEngine.shared.play(special.feedbackKind)
            onSendKeyCode(special.keyCode, modifiers, special.label)
            transientModifiers.removeAll()
        case .utility(let utility):
            handleUtility(utility.action)
        }
    }

    private func handleModifier(_ modifier: ModifierVisual) {
        switch modifier {
        case .caps:
            capsLockEnabled.toggle()
            KeyboardFeedbackEngine.shared.play(.modifier)
        case .control:
            toggle(.control)
        case .option:
            toggle(.option)
        case .command:
            toggle(.command)
        case .shift:
            toggle(.shift)
        }
    }

    private func handleUtility(_ action: UtilityAction) {
        switch action {
        case .cycleInputSource:
            cycleInputSource()
        case .togglePrimaryLayer:
            if activeLayer == .letters {
                activate(.numbers)
            } else {
                activate(.letters)
            }
        case .setLayer(let layer):
            activate(layer)
        }
    }

    private func activate(_ layer: KeyboardLayer) {
        activeLayer = layer
        KeyboardFeedbackEngine.shared.play(.modifier)
    }

    private func cycleInputSource() {
        inputSource = inputSource.next
        activeLayer = .letters
        KeyboardFeedbackEngine.shared.play(.modifier)
        onSendKeyCode(49, [.control], "Input Source")
    }

    private func toggle(_ modifier: ModifierKey) {
        if transientModifiers.contains(modifier) {
            transientModifiers.remove(modifier)
        } else {
            transientModifiers.insert(modifier)
        }

        KeyboardFeedbackEngine.shared.play(.modifier)
    }

    private func resolvedModifiers(isLetter: Bool) -> Set<ModifierKey> {
        let shortcutModifiers = transientModifiers.intersection([.command, .option, .control])
        let explicitShift = transientModifiers.contains(.shift)
        var modifiers = shortcutModifiers

        if isLetter {
            if !shortcutModifiers.isEmpty {
                if explicitShift {
                    modifiers.insert(.shift)
                }
            } else if explicitShift != capsLockEnabled {
                modifiers.insert(.shift)
            }
        } else if explicitShift {
            modifiers.insert(.shift)
        }

        return modifiers
    }

    private func label(for key: KeyboardLayoutKey) -> String {
        switch key.role {
        case .modifier(let modifier):
            return modifier.label
        case .special(let special):
            return special.label
        case .utility(let utility):
            return utility.label
        case .printable(let printable):
            if printable.isLetter {
                return resolvedModifiers(isLetter: true).contains(.shift) ? printable.upper : printable.lower
            }

            return transientModifiers.contains(.shift) ? printable.upper : printable.lower
        }
    }

    private func isActive(key: KeyboardLayoutKey) -> Bool {
        switch key.role {
        case .modifier(let modifier):
            switch modifier {
            case .caps:
                return capsLockEnabled
            case .command:
                return transientModifiers.contains(.command)
            case .control:
                return transientModifiers.contains(.control)
            case .option:
                return transientModifiers.contains(.option)
            case .shift:
                return transientModifiers.contains(.shift)
            }
        case .utility(let utility):
            switch utility.action {
            case .togglePrimaryLayer:
                return activeLayer != .letters
            case .cycleInputSource:
                return false
            case .setLayer(let layer):
                return activeLayer == layer
            }
        case .printable, .special:
            return false
        }
    }

    private func rows(for layer: KeyboardLayer) -> [[KeyboardLayoutKey]] {
        switch layer {
        case .letters:
            return letterRows
        case .numbers:
            return numberRows
        case .symbols:
            return symbolRows
        }
    }

    private var letterRows: [[KeyboardLayoutKey]] {
        [
            functionRow,
            [
                .special(id: "esc", width: 1.3, keyCode: 53, label: "Esc", feedbackKind: .action),
                .printable(id: "grave", width: 1.0, keyCode: 50, lower: "`", upper: "~", isLetter: false),
                .printable(id: "1", width: 1.0, keyCode: 18, lower: "1", upper: "!", isLetter: false),
                .printable(id: "2", width: 1.0, keyCode: 19, lower: "2", upper: "@", isLetter: false),
                .printable(id: "3", width: 1.0, keyCode: 20, lower: "3", upper: "#", isLetter: false),
                .printable(id: "4", width: 1.0, keyCode: 21, lower: "4", upper: "$", isLetter: false),
                .printable(id: "5", width: 1.0, keyCode: 23, lower: "5", upper: "%", isLetter: false),
                .printable(id: "6", width: 1.0, keyCode: 22, lower: "6", upper: "^", isLetter: false),
                .printable(id: "7", width: 1.0, keyCode: 26, lower: "7", upper: "&", isLetter: false),
                .printable(id: "8", width: 1.0, keyCode: 28, lower: "8", upper: "*", isLetter: false),
                .printable(id: "9", width: 1.0, keyCode: 25, lower: "9", upper: "(", isLetter: false),
                .printable(id: "0", width: 1.0, keyCode: 29, lower: "0", upper: ")", isLetter: false),
                .printable(id: "minus", width: 1.0, keyCode: 27, lower: "-", upper: "_", isLetter: false),
                .printable(id: "equal", width: 1.0, keyCode: 24, lower: "=", upper: "+", isLetter: false),
                .special(id: "delete", width: 1.8, keyCode: 51, label: "Delete", symbolName: "delete.left", feedbackKind: .action)
            ],
            [
                .special(id: "tab", width: 1.55, keyCode: 48, label: "Tab", feedbackKind: .action),
                .printable(id: "q", width: 1.0, keyCode: 12, lower: "q", upper: "Q", isLetter: true),
                .printable(id: "w", width: 1.0, keyCode: 13, lower: "w", upper: "W", isLetter: true),
                .printable(id: "e", width: 1.0, keyCode: 14, lower: "e", upper: "E", isLetter: true),
                .printable(id: "r", width: 1.0, keyCode: 15, lower: "r", upper: "R", isLetter: true),
                .printable(id: "t", width: 1.0, keyCode: 17, lower: "t", upper: "T", isLetter: true),
                .printable(id: "y", width: 1.0, keyCode: 16, lower: "y", upper: "Y", isLetter: true),
                .printable(id: "u", width: 1.0, keyCode: 32, lower: "u", upper: "U", isLetter: true),
                .printable(id: "i", width: 1.0, keyCode: 34, lower: "i", upper: "I", isLetter: true),
                .printable(id: "o", width: 1.0, keyCode: 31, lower: "o", upper: "O", isLetter: true),
                .printable(id: "p", width: 1.0, keyCode: 35, lower: "p", upper: "P", isLetter: true),
                .printable(id: "leftBracket", width: 1.0, keyCode: 33, lower: "[", upper: "{", isLetter: false),
                .printable(id: "rightBracket", width: 1.0, keyCode: 30, lower: "]", upper: "}", isLetter: false),
                .printable(id: "backslash", width: 1.25, keyCode: 42, lower: "\\", upper: "|", isLetter: false)
            ],
            [
                .modifierKey(id: "caps", width: 1.85, modifier: .caps),
                .printable(id: "a", width: 1.0, keyCode: 0, lower: "a", upper: "A", isLetter: true),
                .printable(id: "s", width: 1.0, keyCode: 1, lower: "s", upper: "S", isLetter: true),
                .printable(id: "d", width: 1.0, keyCode: 2, lower: "d", upper: "D", isLetter: true),
                .printable(id: "f", width: 1.0, keyCode: 3, lower: "f", upper: "F", isLetter: true),
                .printable(id: "g", width: 1.0, keyCode: 5, lower: "g", upper: "G", isLetter: true),
                .printable(id: "h", width: 1.0, keyCode: 4, lower: "h", upper: "H", isLetter: true),
                .printable(id: "j", width: 1.0, keyCode: 38, lower: "j", upper: "J", isLetter: true),
                .printable(id: "k", width: 1.0, keyCode: 40, lower: "k", upper: "K", isLetter: true),
                .printable(id: "l", width: 1.0, keyCode: 37, lower: "l", upper: "L", isLetter: true),
                .printable(id: "semicolon", width: 1.0, keyCode: 41, lower: ";", upper: ":", isLetter: false),
                .printable(id: "quote", width: 1.0, keyCode: 39, lower: "'", upper: "\"", isLetter: false),
                .special(id: "return", width: 2.05, keyCode: 36, label: "Return", symbolName: "return", feedbackKind: .action)
            ],
            [
                .modifierKey(id: "shift", width: 2.2, modifier: .shift),
                .printable(id: "z", width: 1.0, keyCode: 6, lower: "z", upper: "Z", isLetter: true),
                .printable(id: "x", width: 1.0, keyCode: 7, lower: "x", upper: "X", isLetter: true),
                .printable(id: "c", width: 1.0, keyCode: 8, lower: "c", upper: "C", isLetter: true),
                .printable(id: "v", width: 1.0, keyCode: 9, lower: "v", upper: "V", isLetter: true),
                .printable(id: "b", width: 1.0, keyCode: 11, lower: "b", upper: "B", isLetter: true),
                .printable(id: "n", width: 1.0, keyCode: 45, lower: "n", upper: "N", isLetter: true),
                .printable(id: "m", width: 1.0, keyCode: 46, lower: "m", upper: "M", isLetter: true),
                .printable(id: "comma", width: 1.0, keyCode: 43, lower: ",", upper: "<", isLetter: false),
                .printable(id: "period", width: 1.0, keyCode: 47, lower: ".", upper: ">", isLetter: false),
                .printable(id: "slash", width: 1.0, keyCode: 44, lower: "/", upper: "?", isLetter: false),
                .special(id: "up", width: 1.45, keyCode: 126, label: "Up", symbolName: "arrow.up", feedbackKind: .action)
            ],
            utilityBottomRow(primarySwitchLabel: "123", spaceLabel: inputSource.spaceLabel)
        ]
    }

    private var numberRows: [[KeyboardLayoutKey]] {
        [
            functionRow,
            [
                fixedOutput(id: "1plain", width: 1.0, keyCode: 18, label: "1"),
                fixedOutput(id: "2plain", width: 1.0, keyCode: 19, label: "2"),
                fixedOutput(id: "3plain", width: 1.0, keyCode: 20, label: "3"),
                fixedOutput(id: "4plain", width: 1.0, keyCode: 21, label: "4"),
                fixedOutput(id: "5plain", width: 1.0, keyCode: 23, label: "5"),
                fixedOutput(id: "6plain", width: 1.0, keyCode: 22, label: "6"),
                fixedOutput(id: "7plain", width: 1.0, keyCode: 26, label: "7"),
                fixedOutput(id: "8plain", width: 1.0, keyCode: 28, label: "8"),
                fixedOutput(id: "9plain", width: 1.0, keyCode: 25, label: "9"),
                fixedOutput(id: "0plain", width: 1.0, keyCode: 29, label: "0"),
                .special(id: "deleteSymbols", width: 1.65, keyCode: 51, label: "Delete", symbolName: "delete.left", feedbackKind: .action)
            ],
            [
                .utility(id: "numbersToSymbols", width: 1.35, label: "#+=", action: .setLayer(.symbols)),
                fixedOutput(id: "minusFixed", width: 1.0, keyCode: 27, label: "-"),
                fixedOutput(id: "slashFixed", width: 1.0, keyCode: 44, label: "/"),
                fixedOutput(id: "colonFixed", width: 1.0, keyCode: 41, label: ":", intrinsicModifiers: [.shift]),
                fixedOutput(id: "semicolonFixed", width: 1.0, keyCode: 41, label: ";"),
                fixedOutput(id: "leftParenFixed", width: 1.0, keyCode: 25, label: "(", intrinsicModifiers: [.shift]),
                fixedOutput(id: "rightParenFixed", width: 1.0, keyCode: 29, label: ")", intrinsicModifiers: [.shift]),
                fixedOutput(id: "dollarFixed", width: 1.0, keyCode: 21, label: "$", intrinsicModifiers: [.shift]),
                fixedOutput(id: "ampersandFixed", width: 1.0, keyCode: 26, label: "&", intrinsicModifiers: [.shift]),
                fixedOutput(id: "atFixed", width: 1.0, keyCode: 19, label: "@", intrinsicModifiers: [.shift]),
                fixedOutput(id: "quoteDoubleFixed", width: 1.0, keyCode: 39, label: "\"", intrinsicModifiers: [.shift])
            ],
            [
                fixedOutput(id: "periodFixed", width: 1.0, keyCode: 47, label: "."),
                fixedOutput(id: "commaFixed", width: 1.0, keyCode: 43, label: ","),
                fixedOutput(id: "questionFixed", width: 1.0, keyCode: 44, label: "?", intrinsicModifiers: [.shift]),
                fixedOutput(id: "exclamationFixed", width: 1.0, keyCode: 18, label: "!", intrinsicModifiers: [.shift]),
                fixedOutput(id: "quoteSingleFixed", width: 1.0, keyCode: 39, label: "'"),
                fixedOutput(id: "leftBracketFixed", width: 1.0, keyCode: 33, label: "["),
                fixedOutput(id: "rightBracketFixed", width: 1.0, keyCode: 30, label: "]"),
                fixedOutput(id: "leftBraceFixed", width: 1.0, keyCode: 33, label: "{", intrinsicModifiers: [.shift]),
                fixedOutput(id: "rightBraceFixed", width: 1.0, keyCode: 30, label: "}", intrinsicModifiers: [.shift]),
                .special(id: "returnSymbols", width: 2.0, keyCode: 36, label: "Return", symbolName: "return", feedbackKind: .action)
            ],
            utilityBottomRow(primarySwitchLabel: "ABC", spaceLabel: inputSource.spaceLabel)
        ]
    }

    private var symbolRows: [[KeyboardLayoutKey]] {
        [
            functionRow,
            [
                fixedOutput(id: "leftBracketSymbol", width: 1.0, keyCode: 33, label: "["),
                fixedOutput(id: "rightBracketSymbol", width: 1.0, keyCode: 30, label: "]"),
                fixedOutput(id: "leftBraceSymbol", width: 1.0, keyCode: 33, label: "{", intrinsicModifiers: [.shift]),
                fixedOutput(id: "rightBraceSymbol", width: 1.0, keyCode: 30, label: "}", intrinsicModifiers: [.shift]),
                fixedOutput(id: "hashSymbol", width: 1.0, keyCode: 20, label: "#", intrinsicModifiers: [.shift]),
                fixedOutput(id: "percentSymbol", width: 1.0, keyCode: 23, label: "%", intrinsicModifiers: [.shift]),
                fixedOutput(id: "caretSymbol", width: 1.0, keyCode: 22, label: "^", intrinsicModifiers: [.shift]),
                fixedOutput(id: "asteriskSymbol", width: 1.0, keyCode: 28, label: "*", intrinsicModifiers: [.shift]),
                fixedOutput(id: "plusSymbol", width: 1.0, keyCode: 24, label: "+", intrinsicModifiers: [.shift]),
                fixedOutput(id: "equalSymbol", width: 1.0, keyCode: 24, label: "="),
                .special(id: "deleteAltSymbols", width: 1.65, keyCode: 51, label: "Delete", symbolName: "delete.left", feedbackKind: .action)
            ],
            [
                .utility(id: "symbolsToNumbers", width: 1.35, label: "123", action: .setLayer(.numbers)),
                fixedOutput(id: "underscoreSymbol", width: 1.0, keyCode: 27, label: "_", intrinsicModifiers: [.shift]),
                fixedOutput(id: "backslashSymbol", width: 1.0, keyCode: 42, label: "\\"),
                fixedOutput(id: "pipeSymbol", width: 1.0, keyCode: 42, label: "|", intrinsicModifiers: [.shift]),
                fixedOutput(id: "tildeSymbol", width: 1.0, keyCode: 50, label: "~", intrinsicModifiers: [.shift]),
                fixedOutput(id: "lessThanSymbol", width: 1.0, keyCode: 43, label: "<", intrinsicModifiers: [.shift]),
                fixedOutput(id: "greaterThanSymbol", width: 1.0, keyCode: 47, label: ">", intrinsicModifiers: [.shift]),
                fixedOutput(id: "dollarSymbol", width: 1.0, keyCode: 21, label: "$", intrinsicModifiers: [.shift]),
                fixedOutput(id: "atSymbol", width: 1.0, keyCode: 19, label: "@", intrinsicModifiers: [.shift]),
                fixedOutput(id: "doubleQuoteSymbol", width: 1.0, keyCode: 39, label: "\"", intrinsicModifiers: [.shift]),
                fixedOutput(id: "backtickSymbol", width: 1.0, keyCode: 50, label: "`")
            ],
            [
                fixedOutput(id: "periodSymbol", width: 1.0, keyCode: 47, label: "."),
                fixedOutput(id: "commaSymbol", width: 1.0, keyCode: 43, label: ","),
                fixedOutput(id: "questionSymbol", width: 1.0, keyCode: 44, label: "?", intrinsicModifiers: [.shift]),
                fixedOutput(id: "exclamationSymbol", width: 1.0, keyCode: 18, label: "!", intrinsicModifiers: [.shift]),
                fixedOutput(id: "singleQuoteSymbol", width: 1.0, keyCode: 39, label: "'"),
                fixedOutput(id: "semicolonSymbol", width: 1.0, keyCode: 41, label: ";"),
                fixedOutput(id: "colonSymbol", width: 1.0, keyCode: 41, label: ":", intrinsicModifiers: [.shift]),
                fixedOutput(id: "leftParenSymbol", width: 1.0, keyCode: 25, label: "(" , intrinsicModifiers: [.shift]),
                fixedOutput(id: "rightParenSymbol", width: 1.0, keyCode: 29, label: ")" , intrinsicModifiers: [.shift]),
                .special(id: "returnAltSymbols", width: 2.0, keyCode: 36, label: "Return", symbolName: "return", feedbackKind: .action)
            ],
            utilityBottomRow(primarySwitchLabel: "ABC", spaceLabel: inputSource.spaceLabel)
        ]
    }

    private var numberPadRows: [[KeyboardLayoutKey]] {
        [
            [
                .special(id: "keypadClear", width: 1.0, keyCode: 71, label: "Clear", feedbackKind: .action),
                .special(id: "keypadEquals", width: 1.0, keyCode: 81, label: "=", feedbackKind: .printable),
                .special(id: "keypadDivide", width: 1.0, keyCode: 75, label: "/", feedbackKind: .printable),
                .special(id: "keypadMultiply", width: 1.0, keyCode: 67, label: "*", feedbackKind: .printable)
            ],
            [
                .special(id: "keypad7", width: 1.0, keyCode: 89, label: "7", feedbackKind: .printable),
                .special(id: "keypad8", width: 1.0, keyCode: 91, label: "8", feedbackKind: .printable),
                .special(id: "keypad9", width: 1.0, keyCode: 92, label: "9", feedbackKind: .printable),
                .special(id: "keypadMinus", width: 1.0, keyCode: 78, label: "-", feedbackKind: .printable)
            ],
            [
                .special(id: "keypad4", width: 1.0, keyCode: 86, label: "4", feedbackKind: .printable),
                .special(id: "keypad5", width: 1.0, keyCode: 87, label: "5", feedbackKind: .printable),
                .special(id: "keypad6", width: 1.0, keyCode: 88, label: "6", feedbackKind: .printable),
                .special(id: "keypadPlus", width: 1.0, keyCode: 69, label: "+", feedbackKind: .printable)
            ],
            [
                .special(id: "keypad1", width: 1.0, keyCode: 83, label: "1", feedbackKind: .printable),
                .special(id: "keypad2", width: 1.0, keyCode: 84, label: "2", feedbackKind: .printable),
                .special(id: "keypad3", width: 1.0, keyCode: 85, label: "3", feedbackKind: .printable),
                .special(id: "keypadEnter", width: 1.0, keyCode: 76, label: "Enter", feedbackKind: .action)
            ],
            [
                .special(id: "keypad0", width: 2.0, keyCode: 82, label: "0", feedbackKind: .printable),
                .special(id: "keypadDecimal", width: 1.0, keyCode: 65, label: ".", feedbackKind: .printable),
                .special(id: "keypadDelete", width: 1.0, keyCode: 51, label: "Del", symbolName: "delete.left", feedbackKind: .action)
            ]
        ]
    }

    private var functionRow: [KeyboardLayoutKey] {
        [
            .special(id: "f1", width: 1.0, keyCode: 122, label: "F1", feedbackKind: .action),
            .special(id: "f2", width: 1.0, keyCode: 120, label: "F2", feedbackKind: .action),
            .special(id: "f3", width: 1.0, keyCode: 99, label: "F3", feedbackKind: .action),
            .special(id: "f4", width: 1.0, keyCode: 118, label: "F4", feedbackKind: .action),
            .special(id: "f5", width: 1.0, keyCode: 96, label: "F5", feedbackKind: .action),
            .special(id: "f6", width: 1.0, keyCode: 97, label: "F6", feedbackKind: .action),
            .special(id: "f7", width: 1.0, keyCode: 98, label: "F7", feedbackKind: .action),
            .special(id: "f8", width: 1.0, keyCode: 100, label: "F8", feedbackKind: .action),
            .special(id: "f9", width: 1.0, keyCode: 101, label: "F9", feedbackKind: .action),
            .special(id: "f10", width: 1.0, keyCode: 109, label: "F10", feedbackKind: .action),
            .special(id: "f11", width: 1.0, keyCode: 103, label: "F11", feedbackKind: .action),
            .special(id: "f12", width: 1.0, keyCode: 111, label: "F12", feedbackKind: .action)
        ]
    }

    private func utilityBottomRow(primarySwitchLabel: String, spaceLabel: String) -> [KeyboardLayoutKey] {
        [
            .utility(id: "globe", width: 1.15, label: inputSource.shortLabel, symbolName: "globe", action: .cycleInputSource),
            .utility(id: "primarySwitch", width: 1.15, label: primarySwitchLabel, action: .togglePrimaryLayer),
            .modifierKey(id: "control", width: 1.35, modifier: .control),
            .modifierKey(id: "option", width: 1.35, modifier: .option),
            .modifierKey(id: "command", width: 1.55, modifier: .command),
            .special(id: "space", width: 5.15, keyCode: 49, label: spaceLabel, feedbackKind: .printable),
            .special(id: "left", width: 1.0, keyCode: 123, label: "Left", symbolName: "arrow.left", feedbackKind: .action),
            .special(id: "down", width: 1.0, keyCode: 125, label: "Down", symbolName: "arrow.down", feedbackKind: .action),
            .special(id: "right", width: 1.0, keyCode: 124, label: "Right", symbolName: "arrow.right", feedbackKind: .action)
        ]
    }
}

@MainActor
private final class KeyboardFeedbackEngine {
    static let shared = KeyboardFeedbackEngine()

    private let selectionGenerator = UISelectionFeedbackGenerator()
    private let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private let rigidGenerator = UIImpactFeedbackGenerator(style: .rigid)

    private init() {
        prepare()
    }

    func play(_ kind: KeyboardFeedbackKind) {
        AudioServicesPlaySystemSound(1104)

        switch kind {
        case .modifier:
            selectionGenerator.selectionChanged()
        case .printable:
            lightGenerator.impactOccurred(intensity: 0.82)
        case .action:
            rigidGenerator.impactOccurred(intensity: 0.96)
        }

        prepare()
    }

    private func prepare() {
        selectionGenerator.prepare()
        lightGenerator.prepare()
        rigidGenerator.prepare()
    }
}

private enum KeyboardFeedbackKind {
    case printable
    case modifier
    case action
}

private struct KeyboardBadge: View {
    let text: String
    var accent = false

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(accent ? Color.white : Color(red: 0.28, green: 0.33, blue: 0.40))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(accent ? Color(red: 0.18, green: 0.21, blue: 0.28) : Color(red: 0.91, green: 0.93, blue: 0.96))
            )
    }
}

private struct LayerChipButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? Color.white : Color(red: 0.27, green: 0.32, blue: 0.39))
            .background(
                Capsule(style: .continuous)
                    .fill(selected ? Color(red: 0.18, green: 0.21, blue: 0.28) : Color.white.opacity(0.72))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(selected ? 0.18 : 0.9), lineWidth: 1)
                    )
            )
            .opacity(configuration.isPressed ? 0.9 : 1)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct KeyboardSurfaceMetrics {
    let size: CGSize
    let showsNumberPad: Bool

    var isPortrait: Bool {
        size.height >= size.width
    }

    var stacksNumberPad: Bool {
        showsNumberPad && (isPortrait || size.width < 980)
    }

    var scale: CGFloat {
        let referenceHeight: CGFloat = stacksNumberPad ? 860 : 650
        return max(0.84, min(1.08, size.height / referenceHeight))
    }

    var sectionSpacing: CGFloat {
        isPortrait ? 14 : 18
    }

    var deckSpacing: CGFloat {
        isPortrait ? 12 : 16
    }

    var deckRowSpacing: CGFloat {
        isPortrait ? 8 : 10
    }

    var keySpacing: CGFloat {
        isPortrait ? 6 : 8
    }

    var outerPadding: CGFloat {
        isPortrait ? 18 : 20
    }

    var mainDeckPadding: CGFloat {
        isPortrait ? 12 : 14
    }

    var compactDeckPadding: CGFloat {
        isPortrait ? 10 : 12
    }

    var surfaceCornerRadius: CGFloat {
        isPortrait ? 28 : 32
    }

    var mainDeckCornerRadius: CGFloat {
        isPortrait ? 24 : 28
    }

    var compactDeckCornerRadius: CGFloat {
        isPortrait ? 22 : 26
    }

    var sideNumberPadWidth: CGFloat {
        min(max(size.width * 0.24, 220), 280)
    }

    var stackedNumberPadWidth: CGFloat {
        min(max(size.width * 0.54, 260), 380)
    }

    var titleSize: CGFloat {
        isPortrait ? 24 : 28
    }

    var subtitleSize: CGFloat {
        isPortrait ? 12 : 13
    }

    var footnoteSize: CGFloat {
        isPortrait ? 11 : 12
    }

    var functionRowHeight: CGFloat {
        round((isPortrait ? 30 : 34) * scale)
    }

    var standardRowHeight: CGFloat {
        round((isPortrait ? 46 : 54) * scale)
    }

    var bottomRowHeight: CGFloat {
        round((isPortrait ? 48 : 56) * scale)
    }

    var compactFunctionRowHeight: CGFloat {
        round((isPortrait ? 36 : 42) * scale)
    }

    var compactRowHeight: CGFloat {
        round((isPortrait ? 44 : 54) * scale)
    }

    var keyHorizontalPadding: CGFloat {
        isPortrait ? 8 : 10
    }

    var keyVerticalPadding: CGFloat {
        isPortrait ? 6 : 8
    }

    var keyCornerRadius: CGFloat {
        isPortrait ? 14 : 16
    }

    var letterFontSize: CGFloat {
        isPortrait ? 16 : 18
    }

    var symbolUpperFontSize: CGFloat {
        isPortrait ? 9 : 10
    }

    var symbolLowerFontSize: CGFloat {
        isPortrait ? 16 : 18
    }

    var modifierFontSize: CGFloat {
        isPortrait ? 12 : 13
    }

    var specialFontSize: CGFloat {
        isPortrait ? 13 : 14
    }

    var specialCompactFontSize: CGFloat {
        isPortrait ? 10 : 11
    }

    var symbolFontSize: CGFloat {
        isPortrait ? 12 : 13
    }
}

private struct KeyboardRow: View {
    let keys: [KeyboardLayoutKey]
    let labelProvider: (KeyboardLayoutKey) -> String
    let isActive: (KeyboardLayoutKey) -> Bool
    let onTap: (KeyboardLayoutKey) -> Void
    let metrics: KeyboardSurfaceMetrics

    var body: some View {
        GeometryReader { proxy in
            let spacing = metrics.keySpacing
            let totalWidthUnits = keys.reduce(CGFloat.zero) { $0 + $1.widthUnits }
            let usableWidth = proxy.size.width - (CGFloat(keys.count - 1) * spacing)

            HStack(spacing: spacing) {
                ForEach(keys) { key in
                    Button {
                        onTap(key)
                    } label: {
                        KeyboardKeyFace(
                            key: key,
                            label: labelProvider(key),
                            active: isActive(key),
                            metrics: metrics
                        )
                    }
                    .buttonStyle(KeyboardKeyButtonStyle(key: key, active: isActive(key), metrics: metrics))
                    .frame(
                        width: usableWidth * key.widthUnits / totalWidthUnits,
                        height: proxy.size.height
                    )
                }
            }
        }
    }
}

private struct KeyboardKeyFace: View {
    let key: KeyboardLayoutKey
    let label: String
    let active: Bool
    let metrics: KeyboardSurfaceMetrics

    var body: some View {
        switch key.role {
        case .printable(let printable):
            printableFace(printable)
        case .special(let special):
            specialFace(label: label, symbolName: special.symbolName)
        case .utility(let utility):
            specialFace(label: label, symbolName: utility.symbolName)
        case .modifier:
            Text(label)
                .font(.system(size: metrics.modifierFontSize, weight: .semibold, design: .rounded))
                .foregroundStyle(active ? Color.white : Color(red: 0.20, green: 0.24, blue: 0.30))
        }
    }

    private func printableFace(_ printable: PrintableKey) -> some View {
        Group {
            if printable.isLetter {
                Text(label.uppercased())
                    .font(.system(size: metrics.letterFontSize, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.14, green: 0.16, blue: 0.20))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Spacer()
                        Text(printable.upper)
                            .font(.system(size: metrics.symbolUpperFontSize, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(red: 0.55, green: 0.58, blue: 0.64))
                    }

                    Spacer(minLength: 0)

                    HStack {
                        Text(label)
                            .font(.system(size: metrics.symbolLowerFontSize, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(red: 0.14, green: 0.16, blue: 0.20))
                        Spacer()
                    }
                }
            }
        }
    }

    private func specialFace(label: String, symbolName: String?) -> some View {
        VStack(spacing: symbolName == nil ? 0 : 4) {
            if let symbolName {
                Image(systemName: symbolName)
                    .font(.system(size: metrics.symbolFontSize, weight: .bold))
            }

            Text(label)
                .font(.system(size: symbolName == nil ? metrics.specialFontSize : metrics.specialCompactFontSize, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(Color(red: 0.18, green: 0.21, blue: 0.27))
    }
}

private struct KeyboardKeyButtonStyle: ButtonStyle {
    let key: KeyboardLayoutKey
    let active: Bool
    let metrics: KeyboardSurfaceMetrics

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed

        return configuration.label
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, metrics.keyHorizontalPadding)
            .padding(.vertical, metrics.keyVerticalPadding)
            .background(
                RoundedRectangle(cornerRadius: metrics.keyCornerRadius, style: .continuous)
                    .fill(background(pressed: pressed))
                    .overlay(
                        RoundedRectangle(cornerRadius: metrics.keyCornerRadius, style: .continuous)
                            .stroke(border(pressed: pressed), lineWidth: 1)
                    )
            )
            .shadow(color: shadow(pressed: pressed), radius: pressed ? 3 : 9, y: pressed ? 2 : 6)
            .offset(y: pressed ? 1.5 : 0)
            .animation(.easeOut(duration: 0.12), value: pressed)
    }

    private func background(pressed: Bool) -> Color {
        if active {
            return pressed
                ? Color(red: 0.24, green: 0.27, blue: 0.34)
                : Color(red: 0.18, green: 0.21, blue: 0.28)
        }

        switch key.role {
        case .modifier:
            return pressed
                ? Color(red: 0.84, green: 0.87, blue: 0.91)
                : Color(red: 0.88, green: 0.90, blue: 0.94)
        case .utility:
            return pressed
                ? Color(red: 0.87, green: 0.90, blue: 0.93)
                : Color(red: 0.91, green: 0.93, blue: 0.96)
        case .special:
            return pressed
                ? Color(red: 0.89, green: 0.91, blue: 0.95)
                : Color(red: 0.94, green: 0.95, blue: 0.97)
        case .printable:
            return pressed ? Color(red: 0.97, green: 0.97, blue: 0.99) : Color.white
        }
    }

    private func border(pressed: Bool) -> Color {
        if active {
            return Color.white.opacity(pressed ? 0.16 : 0.24)
        }

        return Color.white.opacity(pressed ? 0.8 : 0.96)
    }

    private func shadow(pressed: Bool) -> Color {
        active ? Color.black.opacity(pressed ? 0.10 : 0.18) : Color.black.opacity(pressed ? 0.04 : 0.08)
    }
}

private struct KeyboardLayoutKey: Identifiable {
    enum Role {
        case printable(PrintableKey)
        case special(SpecialKey)
        case utility(UtilityKey)
        case modifier(ModifierVisual)
    }

    let id: String
    let widthUnits: CGFloat
    let role: Role
}

private struct PrintableKey {
    let keyCode: UInt16
    let lower: String
    let upper: String
    let isLetter: Bool
}

private struct SpecialKey {
    let keyCode: UInt16
    let label: String
    let symbolName: String?
    let feedbackKind: KeyboardFeedbackKind
    let intrinsicModifiers: Set<ModifierKey>
}

private struct UtilityKey {
    let label: String
    let symbolName: String?
    let action: UtilityAction
}

private enum UtilityAction {
    case cycleInputSource
    case togglePrimaryLayer
    case setLayer(KeyboardLayer)
}

private enum ModifierVisual {
    case control
    case option
    case command
    case shift
    case caps

    var label: String {
        switch self {
        case .control:
            return "Control"
        case .option:
            return "Option"
        case .command:
            return "Command"
        case .shift:
            return "Shift"
        case .caps:
            return "Caps"
        }
    }
}

private enum KeyboardInputSource: CaseIterable {
    case english
    case pinyin
    case kana

    var badgeTitle: String {
        "Input \(shortLabel)"
    }

    var shortLabel: String {
        switch self {
        case .english:
            return "EN"
        case .pinyin:
            return "Pinyin"
        case .kana:
            return "Kana"
        }
    }

    var spaceLabel: String {
        switch self {
        case .english:
            return "English"
        case .pinyin:
            return "Pinyin"
        case .kana:
            return "Kana"
        }
    }

    var next: KeyboardInputSource {
        switch self {
        case .english:
            return .pinyin
        case .pinyin:
            return .kana
        case .kana:
            return .english
        }
    }
}

private enum KeyboardLayer: CaseIterable {
    case letters
    case numbers
    case symbols

    var toolbarTitle: String {
        switch self {
        case .letters:
            return "ABC"
        case .numbers:
            return "123"
        case .symbols:
            return "#+="
        }
    }

    var badgeTitle: String {
        switch self {
        case .letters:
            return "Letters"
        case .numbers:
            return "Numbers"
        case .symbols:
            return "Symbols"
        }
    }
}

private func fixedOutput(
    id: String,
    width: CGFloat,
    keyCode: UInt16,
    label: String,
    intrinsicModifiers: Set<ModifierKey> = []
) -> KeyboardLayoutKey {
    .special(
        id: id,
        width: width,
        keyCode: keyCode,
        label: label,
        feedbackKind: .printable,
        intrinsicModifiers: intrinsicModifiers
    )
}

private extension KeyboardLayoutKey {
    static func printable(
        id: String,
        width: CGFloat,
        keyCode: UInt16,
        lower: String,
        upper: String,
        isLetter: Bool
    ) -> KeyboardLayoutKey {
        KeyboardLayoutKey(
            id: id,
            widthUnits: width,
            role: .printable(
                PrintableKey(
                    keyCode: keyCode,
                    lower: lower,
                    upper: upper,
                    isLetter: isLetter
                )
            )
        )
    }

    static func special(
        id: String,
        width: CGFloat,
        keyCode: UInt16,
        label: String,
        symbolName: String? = nil,
        feedbackKind: KeyboardFeedbackKind,
        intrinsicModifiers: Set<ModifierKey> = []
    ) -> KeyboardLayoutKey {
        KeyboardLayoutKey(
            id: id,
            widthUnits: width,
            role: .special(
                SpecialKey(
                    keyCode: keyCode,
                    label: label,
                    symbolName: symbolName,
                    feedbackKind: feedbackKind,
                    intrinsicModifiers: intrinsicModifiers
                )
            )
        )
    }

    static func utility(
        id: String,
        width: CGFloat,
        label: String,
        symbolName: String? = nil,
        action: UtilityAction
    ) -> KeyboardLayoutKey {
        KeyboardLayoutKey(
            id: id,
            widthUnits: width,
            role: .utility(
                UtilityKey(
                    label: label,
                    symbolName: symbolName,
                    action: action
                )
            )
        )
    }

    static func modifierKey(id: String, width: CGFloat, modifier: ModifierVisual) -> KeyboardLayoutKey {
        KeyboardLayoutKey(
            id: id,
            widthUnits: width,
            role: .modifier(modifier)
        )
    }
}
#endif
