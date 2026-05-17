#if canImport(UIKit) && !os(macOS)
import Combine
import ControllerShared
import Network
import SwiftUI
import UIKit

@MainActor
final class RemotePadSessionModel: ObservableObject {
    @Published var host = ""
    @Published var port = "\(RemoteCompanionService.defaultPort)"
    @Published var showsManualFallback = false
    @Published private(set) var statusText = "Not connected"
    @Published private(set) var discoveryStatusText = "Scanning for Macs on your local network…"
    @Published private(set) var discoveredCompanions: [DiscoveredCompanion] = []
    @Published private(set) var activeCompanionID: String?
    @Published private(set) var connectionState: RemoteClient.State = .idle

    private let discoveryQueue = DispatchQueue(label: "controller.discovery")
    private let defaults = UserDefaults.standard
    private var browser: NWBrowser?
    private var client: RemoteClient?
    private var autoReconnectTask: Task<Void, Never>?
    private var preferredConnection: SavedConnectionPreference?
    private var pendingConnectionPreference: SavedConnectionPreference?
    private var autoReconnectSuspended = false
    private var connectionToken = UUID()

    init() {
        preferredConnection = loadPreferredConnection()

        if let preferredConnection, preferredConnection.method == .manual {
            host = preferredConnection.host ?? ""
            port = String(preferredConnection.port ?? RemoteCompanionService.defaultPort)
            showsManualFallback = true
        }

        refreshDiscovery()
        attemptAutoReconnectIfNeeded()
    }

    deinit {
        browser?.cancel()
        autoReconnectTask?.cancel()
    }

    func refreshDiscovery() {
        browser?.cancel()

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true

        let browser = NWBrowser(
            for: .bonjour(type: RemoteCompanionService.bonjourType, domain: nil),
            using: parameters
        )

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleBrowserState(state)
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let companions = results
                .compactMap(DiscoveredCompanion.init(result:))
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            Task { @MainActor in
                self?.applyDiscoveredCompanions(companions)
            }
        }

        self.browser = browser
        browser.start(queue: discoveryQueue)
    }

    func connect(to companion: DiscoveredCompanion) {
        autoReconnectSuspended = false
        activeCompanionID = companion.id
        connect(
            using: RemoteClient(endpoint: companion.endpoint),
            companionLabel: companion.name,
            preferredConnection: SavedConnectionPreference(
                method: .bonjour,
                identifier: companion.persistenceID,
                displayName: companion.name,
                host: nil,
                port: nil
            )
        )
    }

    func connectManually() {
        autoReconnectSuspended = false
        connectManuallyIfPossible()
    }

    func disconnect() {
        autoReconnectSuspended = true
        autoReconnectTask?.cancel()
        connectionToken = UUID()
        client?.stop()
        client = nil
        connectionState = .cancelled
        statusText = "Disconnected"
    }

    func sendPointer(dx: Double, dy: Double) {
        client?.send(.pointerMove(dx: dx, dy: dy))
    }

    func sendScroll(dx: Double, dy: Double) {
        client?.send(.scroll(dx: dx, dy: dy))
    }

    func sendClick(_ button: MouseButton) {
        client?.send(.mouseButton(button, state: .click))
    }

    func sendMouseState(_ state: MouseButtonState) {
        client?.send(.mouseButton(.primary, state: state))
    }

    func sendText(_ text: String) {
        client?.send(.text(text))
    }

    func sendKey(_ key: NamedKey, modifiers: Set<ModifierKey> = []) {
        client?.send(.keyPress(KeyPressPayload(key: key, modifiers: modifiers)))
    }

    func sendKeyCode(_ keyCode: UInt16, modifiers: Set<ModifierKey> = [], label: String? = nil) {
        client?.send(.keyPress(KeyPressPayload(keyCode: keyCode, modifiers: modifiers, keyLabel: label)))
    }

    var isReady: Bool {
        connectionState == .ready
    }

    func buttonTitle(for companion: DiscoveredCompanion) -> String {
        guard activeCompanionID == companion.id else {
            return "Connect"
        }

        switch connectionState {
        case .connecting:
            return "Connecting"
        case .ready:
            return "Connected"
        default:
            return "Reconnect"
        }
    }

    func isActive(_ companion: DiscoveredCompanion) -> Bool {
        activeCompanionID == companion.id
    }

    func isConnectButtonDisabled(for companion: DiscoveredCompanion) -> Bool {
        activeCompanionID == companion.id && connectionState == .connecting
    }

    private func connectManuallyIfPossible() {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            statusText = "Enter a Mac host first."
            return
        }

        let portValue = UInt16(port) ?? RemoteCompanionService.defaultPort
        activeCompanionID = nil
        connect(
            using: RemoteClient(host: trimmedHost, port: portValue),
            companionLabel: trimmedHost,
            preferredConnection: SavedConnectionPreference(
                method: .manual,
                identifier: nil,
                displayName: trimmedHost,
                host: trimmedHost,
                port: portValue
            )
        )
    }
    
    private func connect(
        using remoteClient: RemoteClient,
        companionLabel: String,
        preferredConnection newPreferredConnection: SavedConnectionPreference
    ) {
        autoReconnectTask?.cancel()
        let token = UUID()
        connectionToken = token
        client?.stop()
        client = remoteClient
        pendingConnectionPreference = newPreferredConnection

        remoteClient.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.handleConnectionState(state, companionLabel: companionLabel, token: token)
            }
        }

        remoteClient.start(
            hello: PeerHello(
                deviceName: UIDevice.current.name,
                platform: .ipadOS,
                appVersion: "0.1.0"
            )
        )
    }

    private func handleConnectionState(_ state: RemoteClient.State, companionLabel: String, token: UUID) {
        guard token == connectionToken else {
            return
        }

        connectionState = state
        statusText = Self.label(for: state, companion: companionLabel)

        switch state {
        case .ready:
            autoReconnectSuspended = false
            if let pendingConnectionPreference {
                preferredConnection = pendingConnectionPreference
                savePreferredConnection(pendingConnectionPreference)
                self.pendingConnectionPreference = nil
            }
        case .failed, .cancelled:
            client = nil
            if !autoReconnectSuspended {
                scheduleAutoReconnect()
            }
        case .idle, .connecting:
            break
        }
    }

    private func handleBrowserState(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            if discoveredCompanions.isEmpty {
                discoveryStatusText = "Looking for Macs running the companion app…"
            }
        case .failed(let error):
            discoveryStatusText = "Discovery failed: \(error.localizedDescription)"
        case .cancelled:
            discoveryStatusText = "Discovery stopped."
        case .waiting(let error):
            discoveryStatusText = "Waiting for network: \(error.localizedDescription)"
        default:
            discoveryStatusText = "Preparing local network discovery…"
        }
    }

    private func applyDiscoveredCompanions(_ companions: [DiscoveredCompanion]) {
        discoveredCompanions = companions

        if companions.isEmpty {
            if case .ready = connectionState {
                return
            }

            if let preferredConnection, preferredConnection.method == .bonjour {
                let name = preferredConnection.displayName ?? "your last Mac"
                discoveryStatusText = "Looking for \(name) to auto reconnect…"
            } else {
                discoveryStatusText = "No Macs found yet. Keep the Mac companion open, then tap Refresh."
            }
            return
        }

        if activeCompanionID == nil || !companions.contains(where: { $0.id == activeCompanionID }) {
            activeCompanionID = companions.first?.id
        }

        if let preferredConnection, preferredConnection.method == .bonjour {
            if companions.contains(where: { $0.persistenceID == preferredConnection.identifier }) {
                discoveryStatusText = "Last Mac found. Auto reconnect is ready."
            } else {
                discoveryStatusText = "Tap a Mac below to connect instantly."
            }
        } else {
            discoveryStatusText = "Tap a Mac below to connect instantly."
        }

        attemptAutoReconnectIfNeeded()
    }

    private func attemptAutoReconnectIfNeeded() {
        guard !autoReconnectSuspended else {
            return
        }

        guard connectionState != .connecting && connectionState != .ready else {
            return
        }

        guard let preferredConnection else {
            return
        }

        switch preferredConnection.method {
        case .bonjour:
            guard let identifier = preferredConnection.identifier else {
                return
            }

            guard let companion = discoveredCompanions.first(where: { $0.persistenceID == identifier }) else {
                return
            }

            connect(to: companion)
        case .manual:
            guard let savedHost = preferredConnection.host, !savedHost.isEmpty else {
                return
            }

            host = savedHost
            port = String(preferredConnection.port ?? RemoteCompanionService.defaultPort)
            connectManuallyIfPossible()
        }
    }

    private func scheduleAutoReconnect() {
        autoReconnectTask?.cancel()
        autoReconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.attemptAutoReconnectIfNeeded()
        }
    }

    private func loadPreferredConnection() -> SavedConnectionPreference? {
        guard let data = defaults.data(forKey: SessionDefaults.preferredConnectionKey) else {
            return nil
        }

        return try? JSONDecoder().decode(SavedConnectionPreference.self, from: data)
    }

    private func savePreferredConnection(_ preference: SavedConnectionPreference) {
        guard let data = try? JSONEncoder().encode(preference) else {
            return
        }

        defaults.set(data, forKey: SessionDefaults.preferredConnectionKey)
    }

    private static func label(for state: RemoteClient.State, companion: String) -> String {
        switch state {
        case .idle:
            return "Idle"
        case .connecting:
            return "Connecting to \(companion)…"
        case .ready:
            return "Connected to \(companion)"
        case .failed(let message):
            return "Failed: \(message)"
        case .cancelled:
            return "Disconnected"
        }
    }
}

public struct RemotePadView: View {
    @StateObject private var model = RemotePadSessionModel()
    @State private var activeSurface: InputSurface = .trackpad
    @State private var isSessionDeckCollapsed = false

    public init() {}

    public var body: some View {
        GeometryReader { proxy in
            let viewport = proxy.size

            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    if isSessionDeckCollapsed {
                        collapsedSessionBar(viewport: viewport)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    } else {
                        sessionDeck
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    surfaceSwitcher

                    Group {
                        switch activeSurface {
                        case .trackpad:
                            trackpadPanel(viewport: viewport)
                                .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: .opacity))
                        case .keyboard:
                            keyboardPanel(viewport: viewport)
                                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                        }
                    }
                }
                .frame(minHeight: max(viewport.height - 48, 0), alignment: .top)
                .padding(24)
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity)
            }
            .background(background.ignoresSafeArea())
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.84), value: activeSurface)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isSessionDeckCollapsed)
        .onChange(of: model.connectionState) { _, newState in
            switch newState {
            case .ready:
                isSessionDeckCollapsed = true
            case .failed, .cancelled, .idle:
                isSessionDeckCollapsed = false
            case .connecting:
                break
            }
        }
    }

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.95, green: 0.96, blue: 0.97),
                    Color(red: 0.91, green: 0.93, blue: 0.95)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.white.opacity(0.66))
                .frame(width: 420, height: 420)
                .blur(radius: 30)
                .offset(x: -220, y: -260)

            Circle()
                .fill(Color(red: 0.86, green: 0.89, blue: 0.94).opacity(0.7))
                .frame(width: 380, height: 380)
                .blur(radius: 56)
                .offset(x: 220, y: 260)
        }
    }

    private var sessionDeck: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Remote Deck")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.12, green: 0.14, blue: 0.18))

                    Text("Use the iPad as a focused controller surface for your Mac. Trackpad and keyboard stay separated so each mode feels calmer and more intentional.")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(red: 0.42, green: 0.47, blue: 0.54))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 16)

                VStack(alignment: .trailing, spacing: 10) {
                    StatusPill(text: model.statusText)

                    if model.isReady {
                        Button {
                            isSessionDeckCollapsed = true
                        } label: {
                            Label("Hide Setup", systemImage: "rectangle.compress.vertical")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(ActionCapsuleButtonStyle(primary: false))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Available Macs", systemImage: "macbook")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(red: 0.17, green: 0.20, blue: 0.25))

                        Text(model.discoveryStatusText)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Color(red: 0.43, green: 0.48, blue: 0.55))
                    }

                    Spacer(minLength: 12)

                    Button {
                        model.refreshDiscovery()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(ActionCapsuleButtonStyle(primary: false))

                    Button("Disconnect") {
                        model.disconnect()
                    }
                    .buttonStyle(ActionCapsuleButtonStyle(primary: false))
                }

                if model.discoveredCompanions.isEmpty {
                    EmptyDiscoveryState()
                } else {
                    VStack(spacing: 10) {
                        ForEach(model.discoveredCompanions) { companion in
                            HStack(spacing: 14) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(companion.name)
                                        .font(.system(size: 16, weight: .bold, design: .rounded))
                                        .foregroundStyle(Color(red: 0.15, green: 0.17, blue: 0.21))

                                    Text(companion.subtitle)
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(Color(red: 0.45, green: 0.50, blue: 0.56))
                                }

                                Spacer(minLength: 12)

                                Button(model.buttonTitle(for: companion)) {
                                    model.connect(to: companion)
                                }
                                .buttonStyle(ActionCapsuleButtonStyle(primary: model.isActive(companion)))
                                .disabled(model.isConnectButtonDisabled(for: companion))
                            }
                            .padding(16)
                            .background(
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .fill(model.isActive(companion) ? Color.white.opacity(0.95) : Color.white.opacity(0.8))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                                            .stroke(
                                                model.isActive(companion)
                                                    ? Color(red: 0.78, green: 0.83, blue: 0.90)
                                                    : Color.white.opacity(0.92),
                                                lineWidth: 1
                                            )
                                    )
                            )
                        }
                    }
                }
            }
            .deckSurface(padding: 16)

            DisclosureGroup(isExpanded: $model.showsManualFallback) {
                HStack(spacing: 12) {
                    TextField("Mac host", text: $model.host)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .keyboardType(.numbersAndPunctuation)
                        .padding(.horizontal, 16)
                        .frame(height: 48)
                        .background(InputCapsuleBackground())

                    TextField("Port", text: $model.port)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .frame(width: 112, height: 48)
                        .keyboardType(.numberPad)
                        .padding(.horizontal, 16)
                        .background(InputCapsuleBackground())

                    Button("Manual Connect") {
                        model.connectManually()
                    }
                    .buttonStyle(ActionCapsuleButtonStyle(primary: true))
                }
                .padding(.top, 12)
            } label: {
                Text("Manual Host Fallback")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.28, green: 0.33, blue: 0.40))
            }
        }
        .deckSurface()
    }

    private func collapsedSessionBar(viewport: CGSize) -> some View {
        let prefersSingleLine = viewport.width > viewport.height || viewport.width >= 820

        return Group {
            if prefersSingleLine {
                HStack(spacing: 12) {
                    collapsedSessionIdentity

                    CompactStatusTag(text: model.statusText)
                        .frame(maxWidth: min(viewport.width * 0.38, 360), alignment: .leading)

                    Spacer(minLength: 8)

                    collapsedSessionActions
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        collapsedSessionIdentity
                        CompactStatusTag(text: model.statusText)
                    }

                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        collapsedSessionActions
                    }
                }
            }
        }
        .padding(.horizontal, prefersSingleLine ? 14 : 12)
        .padding(.vertical, prefersSingleLine ? 10 : 12)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.76))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.94), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.05), radius: 20, y: 8)
    }

    private var collapsedSessionIdentity: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.89, green: 0.92, blue: 0.96))
                    .frame(width: 30, height: 30)

                Image(systemName: "macbook.and.iphone")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(red: 0.18, green: 0.22, blue: 0.29))
            }

            Text("Remote Deck")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.12, green: 0.14, blue: 0.18))
        }
    }

    private var collapsedSessionActions: some View {
        HStack(spacing: 8) {
            Button {
                isSessionDeckCollapsed = false
            } label: {
                Label("Setup", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(ToolbarPillButtonStyle())

            Button {
                model.disconnect()
            } label: {
                Label("Disconnect", systemImage: "power")
            }
            .buttonStyle(ToolbarPillButtonStyle(accent: .red))
            .disabled(!model.isReady && model.connectionState != .connecting)
        }
    }

    private var surfaceSwitcher: some View {
        HStack(spacing: 12) {
            ForEach(InputSurface.allCases, id: \.self) { surface in
                Button {
                    activeSurface = surface
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(surface.title)
                            .font(.system(size: 15, weight: .bold, design: .rounded))

                        Text(surface.shortcutHint)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(activeSurface == surface ? Color.white.opacity(0.74) : Color(red: 0.47, green: 0.52, blue: 0.58))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .buttonStyle(SurfaceSwitchButtonStyle(selected: activeSurface == surface))
                .keyboardShortcut(surface.shortcut, modifiers: [.command])
            }

            Button {
                toggleSurface()
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Quick Toggle")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Text("Cmd + K")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(red: 0.47, green: 0.52, blue: 0.58))
                }
                .frame(width: 116, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
            .buttonStyle(SurfaceSwitchButtonStyle(selected: false, compact: true))
            .keyboardShortcut("k", modifiers: [.command])
        }
        .deckSurface(padding: 12)
    }

    private func trackpadPanel(viewport: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Precision Trackpad")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.12, green: 0.14, blue: 0.18))

                Text("A dedicated pointer surface with minimal chrome. Use Cmd+K when you want to jump back to the keyboard.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.42, green: 0.47, blue: 0.54))
            }

            TrackpadSurface(
                onPointerMove: model.sendPointer(dx:dy:),
                onScroll: model.sendScroll(dx:dy:),
                onPrimaryClick: { model.sendClick(.primary) },
                onSecondaryClick: { model.sendClick(.secondary) },
                onPrimaryMouseState: model.sendMouseState(_:)
            )
            .frame(height: trackpadSurfaceHeight(for: viewport))

            HStack(spacing: 10) {
                HintChip(text: "Move")
                HintChip(text: "Scroll")
                HintChip(text: "Tap")
                HintChip(text: "Right Click")
                HintChip(text: "Drag")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Single-finger drag moves the cursor.")
                Text("Two-finger drag scrolls.")
                Text("Tap to click, two-finger tap for secondary click, and long press plus drag to hold the mouse down.")
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(Color(red: 0.42, green: 0.47, blue: 0.54))
        }
        .frame(minHeight: trackpadPanelHeight(for: viewport), alignment: .top)
        .deckSurface()
    }

    private func keyboardPanel(viewport: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Multifunction Keyboard")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.12, green: 0.14, blue: 0.18))

                Text("Apple-inspired layout with multilingual switching, layered symbols, and a dedicated number pad.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.42, green: 0.47, blue: 0.54))
            }

            MechanicalKeyboardView { keyCode, modifiers, label in
                model.sendKeyCode(keyCode, modifiers: modifiers, label: label)
            }
            .frame(height: keyboardSurfaceHeight(for: viewport))

            VStack(alignment: .leading, spacing: 10) {
                Label("Quick Commit Field", systemImage: "text.cursor")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.21, green: 0.25, blue: 0.31))

                TextCaptureField(
                    placeholder: "Emoji, paste, or text committed through the system keyboard",
                    onText: model.sendText(_:) ,
                    onDeleteBackward: { model.sendKey(.delete) },
                    onReturn: { model.sendKey(.return) }
                )
                .frame(height: 50)

                Text("Useful for emoji, pasted snippets, or characters that are easier to confirm through the iPad input method.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.42, green: 0.47, blue: 0.54))
            }
            .deckSurface()
        }
        .frame(
            maxWidth: min(viewport.width - 48, viewport.width > viewport.height ? 1120 : 980),
            minHeight: keyboardPanelHeight(for: viewport),
            alignment: .topLeading
        )
    }

    private func toggleSurface() {
        activeSurface = activeSurface == .trackpad ? .keyboard : .trackpad
    }

    private func trackpadSurfaceHeight(for viewport: CGSize) -> CGFloat {
        let portrait = viewport.height > viewport.width
        let target = viewport.height * (portrait ? 0.56 : 0.64)
        return min(max(target, portrait ? 460 : 420), portrait ? 760 : 620)
    }

    private func trackpadPanelHeight(for viewport: CGSize) -> CGFloat {
        trackpadSurfaceHeight(for: viewport) + 150
    }

    private func keyboardSurfaceHeight(for viewport: CGSize) -> CGFloat {
        let portrait = viewport.height > viewport.width
        let target = viewport.height * (portrait ? 0.60 : 0.68)
        return min(max(target, portrait ? 520 : 460), portrait ? 800 : 660)
    }

    private func keyboardPanelHeight(for viewport: CGSize) -> CGFloat {
        keyboardSurfaceHeight(for: viewport) + 140
    }
}

private enum InputSurface: CaseIterable {
    case trackpad
    case keyboard

    var title: String {
        switch self {
        case .trackpad:
            return "Trackpad"
        case .keyboard:
            return "Keyboard"
        }
    }

    var shortcutHint: String {
        switch self {
        case .trackpad:
            return "Cmd + 1"
        case .keyboard:
            return "Cmd + 2"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .trackpad:
            return "1"
        case .keyboard:
            return "2"
        }
    }
}

struct DiscoveredCompanion: Identifiable {
    let id: String
    let persistenceID: String
    let name: String
    let subtitle: String
    let endpoint: NWEndpoint

    init?(result: NWBrowser.Result) {
        switch result.endpoint {
        case let .service(name, _, domain, interface):
            persistenceID = [name, domain].joined(separator: "|")
            id = [persistenceID, interface?.debugDescription ?? "local"].joined(separator: "|")
            self.name = name
            subtitle = interface == nil
                ? "Auto-discovered on \(domain)"
                : "Auto-discovered on \(interface!.debugDescription)"
            endpoint = result.endpoint
        case let .hostPort(host, port):
            let hostString = host.debugDescription
            persistenceID = "\(hostString):\(port.rawValue)"
            id = persistenceID
            name = hostString
            subtitle = "Direct address \(hostString):\(port.rawValue)"
            endpoint = result.endpoint
        default:
            return nil
        }
    }
}

private struct SavedConnectionPreference: Codable {
    enum Method: String, Codable {
        case bonjour
        case manual
    }

    let method: Method
    let identifier: String?
    let displayName: String?
    let host: String?
    let port: UInt16?
}

private enum SessionDefaults {
    static let preferredConnectionKey = "controller.preferred-connection"
}

private struct EmptyDiscoveryState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No Mac discovered yet", systemImage: "dot.radiowaves.left.and.right")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.23, green: 0.27, blue: 0.33))

            Text("Keep `MacCompanionCLI` running on the same Wi-Fi network. The list refreshes whenever Bonjour finds a compatible Mac.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color(red: 0.45, green: 0.50, blue: 0.56))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.8))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.92), lineWidth: 1)
                )
        )
    }
}

private struct StatusPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(Color(red: 0.16, green: 0.18, blue: 0.22))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(red: 0.89, green: 0.92, blue: 0.96))
            )
    }
}

private struct CompactStatusTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(Color(red: 0.25, green: 0.29, blue: 0.35))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.86))
            )
    }
}

private struct HintChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(Color(red: 0.29, green: 0.34, blue: 0.41))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.78))
            )
    }
}

private struct InputCapsuleBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.white.opacity(0.92))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.94), lineWidth: 1)
            )
    }
}

private struct ToolbarPillButtonStyle: ButtonStyle {
    let accent: Color?

    init(accent: Color? = nil) {
        self.accent = accent
    }

    func makeBody(configuration: Configuration) -> some View {
        let foreground = accent ?? Color(red: 0.22, green: 0.26, blue: 0.32)
        let background = accent?.opacity(configuration.isPressed ? 0.18 : 0.12) ?? Color.white.opacity(configuration.isPressed ? 0.72 : 0.84)

        return configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(background)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.94), lineWidth: 1)
                    )
            )
            .opacity(configuration.isPressed ? 0.92 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct ActionCapsuleButtonStyle: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(primary ? Color.white : Color(red: 0.20, green: 0.24, blue: 0.30))
            .padding(.horizontal, 18)
            .frame(height: 48)
            .background(
                Capsule(style: .continuous)
                    .fill(primary ? Color(red: 0.18, green: 0.21, blue: 0.28) : Color.white.opacity(0.84))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(primary ? 0.12 : 0.92), lineWidth: 1)
                    )
            )
            .opacity(configuration.isPressed ? 0.88 : 1)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct SurfaceSwitchButtonStyle: ButtonStyle {
    let selected: Bool
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? Color.white : Color(red: 0.20, green: 0.24, blue: 0.30))
            .background(
                RoundedRectangle(cornerRadius: compact ? 20 : 22, style: .continuous)
                    .fill(selected ? Color(red: 0.18, green: 0.21, blue: 0.28) : Color.white.opacity(0.84))
                    .overlay(
                        RoundedRectangle(cornerRadius: compact ? 20 : 22, style: .continuous)
                            .stroke(Color.white.opacity(selected ? 0.12 : 0.9), lineWidth: 1)
                    )
            )
            .opacity(configuration.isPressed ? 0.9 : 1)
            .scaleEffect(configuration.isPressed ? 0.995 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct DeckSurfaceModifier: ViewModifier {
    let padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Color.white.opacity(0.72))
                    .overlay(
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .stroke(Color.white.opacity(0.92), lineWidth: 1)
                    )
            )
            .shadow(color: Color.black.opacity(0.05), radius: 26, y: 12)
    }
}

private extension View {
    func deckSurface(padding: CGFloat = 20) -> some View {
        modifier(DeckSurfaceModifier(padding: padding))
    }
}

private struct TrackpadSurface: UIViewRepresentable {
    let onPointerMove: (Double, Double) -> Void
    let onScroll: (Double, Double) -> Void
    let onPrimaryClick: () -> Void
    let onSecondaryClick: () -> Void
    let onPrimaryMouseState: (MouseButtonState) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onPointerMove: onPointerMove,
            onScroll: onScroll,
            onPrimaryClick: onPrimaryClick,
            onSecondaryClick: onSecondaryClick,
            onPrimaryMouseState: onPrimaryMouseState
        )
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = UIColor.systemGray6
        view.layer.cornerRadius = 28
        view.layer.borderWidth = 1
        view.layer.borderColor = UIColor.white.withAlphaComponent(0.92).cgColor
        view.clipsToBounds = true

        let movePan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleMovePan(_:)))
        movePan.minimumNumberOfTouches = 1
        movePan.maximumNumberOfTouches = 1

        let scrollPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleScrollPan(_:)))
        scrollPan.minimumNumberOfTouches = 2
        scrollPan.maximumNumberOfTouches = 2

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePrimaryTap))
        tap.numberOfTouchesRequired = 1

        let secondaryTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSecondaryTap))
        secondaryTap.numberOfTouchesRequired = 2

        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.3

        tap.require(toFail: secondaryTap)
        movePan.require(toFail: scrollPan)

        view.addGestureRecognizer(movePan)
        view.addGestureRecognizer(scrollPan)
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(secondaryTap)
        view.addGestureRecognizer(longPress)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    final class Coordinator: NSObject {
        private let onPointerMove: (Double, Double) -> Void
        private let onScroll: (Double, Double) -> Void
        private let onPrimaryClick: () -> Void
        private let onSecondaryClick: () -> Void
        private let onPrimaryMouseState: (MouseButtonState) -> Void

        init(
            onPointerMove: @escaping (Double, Double) -> Void,
            onScroll: @escaping (Double, Double) -> Void,
            onPrimaryClick: @escaping () -> Void,
            onSecondaryClick: @escaping () -> Void,
            onPrimaryMouseState: @escaping (MouseButtonState) -> Void
        ) {
            self.onPointerMove = onPointerMove
            self.onScroll = onScroll
            self.onPrimaryClick = onPrimaryClick
            self.onSecondaryClick = onSecondaryClick
            self.onPrimaryMouseState = onPrimaryMouseState
        }

        @objc func handleMovePan(_ recognizer: UIPanGestureRecognizer) {
            let translation = recognizer.translation(in: recognizer.view)
            recognizer.setTranslation(.zero, in: recognizer.view)
            onPointerMove(Double(translation.x), Double(translation.y))
        }

        @objc func handleScrollPan(_ recognizer: UIPanGestureRecognizer) {
            let translation = recognizer.translation(in: recognizer.view)
            recognizer.setTranslation(.zero, in: recognizer.view)
            onScroll(Double(translation.x), Double(translation.y))
        }

        @objc func handlePrimaryTap() {
            onPrimaryClick()
        }

        @objc func handleSecondaryTap() {
            onSecondaryClick()
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began:
                onPrimaryMouseState(.down)
            case .ended, .cancelled, .failed:
                onPrimaryMouseState(.up)
            default:
                break
            }
        }
    }
}
#endif
