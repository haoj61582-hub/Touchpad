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
    @Published var invertPointerY = false
    @Published private(set) var statusText = "Not connected"
    @Published private(set) var discoveryStatusText = "Scanning for Macs on your local network…"
    @Published private(set) var lastFailureDetail: String?
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
        invertPointerY = defaults.bool(forKey: SessionDefaults.invertPointerYKey)

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

    @discardableResult
    func applyPairingCode(_ rawValue: String) -> Bool {
        guard let payload = RemotePairingCode.decode(rawValue) else {
            statusText = "QR code not recognized"
            lastFailureDetail = "Scanned code was not a valid Touchpad pairing code."
            return false
        }

        host = payload.host
        port = String(payload.port)
        showsManualFallback = true
        activeCompanionID = nil
        lastFailureDetail = nil

        if let displayName = payload.displayName, !displayName.isEmpty {
            statusText = "Pairing loaded for \(displayName)"
            discoveryStatusText = "QR pairing loaded. Tap Connect to try \(displayName)."
        } else {
            statusText = "Pairing loaded for \(payload.host)"
            discoveryStatusText = "QR pairing loaded. Tap Connect to try \(payload.host)."
        }

        return true
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
        let adjustedDY = invertPointerY ? -dy : dy
        client?.send(.pointerMove(dx: dx, dy: adjustedDY))
    }

    func sendScroll(dx: Double, dy: Double) {
        client?.send(.scroll(dx: dx, dy: dy))
    }

    func sendClick(_ button: MouseButton) {
        client?.send(.mouseButton(button, state: .click))
    }

    func sendDoubleClick(_ button: MouseButton) {
        client?.send(.mouseButton(button, state: .doubleClick))
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

    func togglePointerYInversion() {
        invertPointerY.toggle()
        defaults.set(invertPointerY, forKey: SessionDefaults.invertPointerYKey)
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
            lastFailureDetail = "Manual host is empty."
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
        lastFailureDetail = nil

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
            lastFailureDetail = nil
            if let pendingConnectionPreference {
                preferredConnection = pendingConnectionPreference
                savePreferredConnection(pendingConnectionPreference)
                self.pendingConnectionPreference = nil
            }
        case .failed(let message):
            lastFailureDetail = message
            client = nil
            if !autoReconnectSuspended {
                scheduleAutoReconnect()
            }
        case .cancelled:
            lastFailureDetail = nil
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
            lastFailureDetail = error.localizedDescription
        case .cancelled:
            discoveryStatusText = "Discovery stopped."
        case .waiting(let error):
            discoveryStatusText = "Waiting for network: \(error.localizedDescription)"
            lastFailureDetail = error.localizedDescription
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
    @State private var showsManualConnectionSheet = false
    @State private var showsConnectionHelpSheet = false

    public init() {}

    public var body: some View {
        GeometryReader { proxy in
            let viewport = proxy.size
            let compact = isCompactViewport(viewport)

            ScrollView(showsIndicators: false) {
                VStack(spacing: compact ? 16 : 20) {
                    if isSessionDeckCollapsed {
                        collapsedSessionBar(viewport: viewport)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    } else {
                        sessionDeck(viewport: viewport)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    surfaceSwitcher(viewport: viewport)

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
                .padding(compact ? 16 : 24)
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity)
            }
            // The trackpad surface needs to own single-finger drags; otherwise
            // the parent ScrollView can steal them and cursor motion appears dead.
            .scrollDisabled(activeSurface == .trackpad)
            .background(background.ignoresSafeArea())
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.84), value: activeSurface)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isSessionDeckCollapsed)
        .sheet(isPresented: $showsManualConnectionSheet) {
            ManualConnectionSheet(model: model)
        }
        .sheet(isPresented: $showsConnectionHelpSheet) {
            ConnectionHelpSheet(model: model)
        }
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

    private func sessionDeck(viewport: CGSize) -> some View {
        let compact = isCompactViewport(viewport)

        return VStack(alignment: .leading, spacing: 18) {
            Group {
                if compact {
                    VStack(alignment: .leading, spacing: 12) {
                        sessionDeckIntro(compact: true)
                        StatusPill(text: model.statusText, compact: true)

                        if model.isReady {
                            Button {
                                isSessionDeckCollapsed = true
                            } label: {
                                Label("Hide Setup", systemImage: "rectangle.compress.vertical")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(ActionCapsuleButtonStyle(primary: false, compact: true))
                        }
                    }
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        sessionDeckIntro(compact: false)

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
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                if compact {
                    VStack(alignment: .leading, spacing: 12) {
                        connectionHeader(compact: true)
                        HStack(spacing: 10) {
                            Button {
                                model.refreshDiscovery()
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(ActionCapsuleButtonStyle(primary: false, compact: true))

                            Button {
                                showsConnectionHelpSheet = true
                            } label: {
                                Label("Help", systemImage: "questionmark.circle")
                            }
                            .buttonStyle(ActionCapsuleButtonStyle(primary: false, compact: true))

                            Button("Disconnect") {
                                model.disconnect()
                            }
                            .buttonStyle(ActionCapsuleButtonStyle(primary: false, compact: true))
                        }
                    }
                } else {
                    HStack(alignment: .center, spacing: 12) {
                        connectionHeader(compact: false)

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

                        Button {
                            showsConnectionHelpSheet = true
                        } label: {
                            Label("Help", systemImage: "questionmark.circle")
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
                }

                if model.discoveredCompanions.isEmpty {
                    EmptyDiscoveryState()
                } else {
                    VStack(spacing: 10) {
                        ForEach(model.discoveredCompanions) { companion in
                            Group {
                                if compact {
                                    VStack(alignment: .leading, spacing: 12) {
                                        companionSummary(companion: companion, compact: true)

                                        Button(model.buttonTitle(for: companion)) {
                                            model.connect(to: companion)
                                        }
                                        .buttonStyle(ActionCapsuleButtonStyle(primary: model.isActive(companion), compact: true))
                                        .disabled(model.isConnectButtonDisabled(for: companion))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                } else {
                                    HStack(spacing: 14) {
                                        companionSummary(companion: companion, compact: false)

                                        Spacer(minLength: 12)

                                        Button(model.buttonTitle(for: companion)) {
                                            model.connect(to: companion)
                                        }
                                        .buttonStyle(ActionCapsuleButtonStyle(primary: model.isActive(companion)))
                                        .disabled(model.isConnectButtonDisabled(for: companion))
                                    }
                                }
                            }
                            .padding(compact ? 14 : 16)
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
                VStack(alignment: .leading, spacing: 12) {
                    Text("If Bonjour discovery misses your Mac, open a dedicated connection sheet to enter the host and port manually.")
                        .font(.system(size: compact ? 12 : 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(red: 0.43, green: 0.48, blue: 0.55))
                        .fixedSize(horizontal: false, vertical: true)

                    Button(compact ? "Open Manual Connect" : "Manual Connect") {
                        showsManualConnectionSheet = true
                    }
                    .buttonStyle(ActionCapsuleButtonStyle(primary: true, compact: compact))
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

    private func sessionDeckIntro(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Remote Deck")
                .font(.system(size: compact ? 24 : 30, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.12, green: 0.14, blue: 0.18))

            Text("Use the iPhone or iPad as a focused controller surface for your Mac. Trackpad and keyboard stay separated so each mode feels calmer and more intentional.")
                .font(.system(size: compact ? 13 : 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color(red: 0.42, green: 0.47, blue: 0.54))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func connectionHeader(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Available Macs", systemImage: "macbook")
                .font(.system(size: compact ? 14 : 15, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.17, green: 0.20, blue: 0.25))

            Text(model.discoveryStatusText)
                .font(.system(size: compact ? 11 : 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color(red: 0.43, green: 0.48, blue: 0.55))
        }
    }

    private func companionSummary(companion: DiscoveredCompanion, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(companion.name)
                .font(.system(size: compact ? 15 : 16, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.15, green: 0.17, blue: 0.21))

            Text(companion.subtitle)
                .font(.system(size: compact ? 11 : 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color(red: 0.45, green: 0.50, blue: 0.56))
        }
    }

    private func collapsedSessionBar(viewport: CGSize) -> some View {
        let compact = isCompactViewport(viewport)
        let prefersSingleLine = viewport.width > viewport.height || viewport.width >= 820

        return Group {
            if compact {
                HStack(spacing: 8) {
                    collapsedSessionIdentity(compact: true)

                    CompactStatusTag(text: model.statusText, compact: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    collapsedSessionActions(compact: true)
                }
            } else if prefersSingleLine {
                HStack(spacing: 12) {
                    collapsedSessionIdentity(compact: compact)

                    CompactStatusTag(text: model.statusText)
                        .frame(maxWidth: min(viewport.width * (compact ? 0.48 : 0.38), compact ? 300 : 360), alignment: .leading)

                    Spacer(minLength: 8)

                    collapsedSessionActions(compact: compact)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        collapsedSessionIdentity(compact: compact)
                        CompactStatusTag(text: model.statusText)
                    }

                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        collapsedSessionActions(compact: compact)
                    }
                }
            }
        }
        .padding(.horizontal, compact ? 10 : (prefersSingleLine ? 14 : 12))
        .padding(.vertical, compact ? 7 : (prefersSingleLine ? 10 : 12))
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(compact ? 0.78 : 0.94), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(compact ? 0.04 : 0.05), radius: compact ? 14 : 20, y: compact ? 5 : 8)
    }

    private func collapsedSessionIdentity(compact: Bool) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.89, green: 0.92, blue: 0.96).opacity(compact ? 0.9 : 1))
                    .frame(width: compact ? 24 : 30, height: compact ? 24 : 30)

                Image(systemName: "macbook.and.iphone")
                    .font(.system(size: compact ? 10 : 12, weight: .bold))
                    .foregroundStyle(Color(red: 0.18, green: 0.22, blue: 0.29))
            }

            if compact {
                EmptyView()
            } else {
                Text("Remote Deck")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.12, green: 0.14, blue: 0.18))
            }
        }
    }

    private func collapsedSessionActions(compact: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                isSessionDeckCollapsed = false
            } label: {
                if compact {
                    Image(systemName: "slider.horizontal.3")
                } else {
                    Label("Setup", systemImage: "slider.horizontal.3")
                }
            }
            .buttonStyle(ToolbarPillButtonStyle(compact: compact))

            Button {
                model.disconnect()
            } label: {
                if compact {
                    Image(systemName: "power")
                } else {
                    Label("Disconnect", systemImage: "power")
                }
            }
            .buttonStyle(ToolbarPillButtonStyle(accent: .red, compact: compact))
            .disabled(!model.isReady && model.connectionState != .connecting)
        }
    }

    private func surfaceSwitcher(viewport: CGSize) -> some View {
        let compact = isCompactViewport(viewport)

        return Group {
            if compact {
                HStack(spacing: 8) {
                    ForEach(InputSurface.allCases, id: \.self) { surface in
                        Button {
                            activeSurface = surface
                        } label: {
                            compactSurfaceButtonContent(surface: surface)
                        }
                        .buttonStyle(SurfaceSwitchButtonStyle(selected: activeSurface == surface, compact: true))
                        .keyboardShortcut(surface.shortcut, modifiers: [.command])
                    }

                    Button {
                        toggleSurface()
                    } label: {
                        Image(systemName: "rectangle.2.swap")
                            .font(.system(size: 13, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                    }
                    .buttonStyle(SurfaceSwitchButtonStyle(selected: false, compact: true))
                    .keyboardShortcut("k", modifiers: [.command])
                }
                .padding(6)
                .background(segmentedSwitcherBackground(compact: true))
            } else {
                HStack(spacing: 12) {
                    ForEach(InputSurface.allCases, id: \.self) { surface in
                        Button {
                            activeSurface = surface
                        } label: {
                            surfaceButtonContent(surface: surface, compact: false)
                        }
                        .buttonStyle(SurfaceSwitchButtonStyle(selected: activeSurface == surface))
                        .keyboardShortcut(surface.shortcut, modifiers: [.command])
                    }

                    Button {
                        toggleSurface()
                    } label: {
                        surfaceButtonContent(title: "Quick Toggle", hint: "Cmd + K", compact: false)
                            .frame(width: 116, alignment: .leading)
                    }
                    .buttonStyle(SurfaceSwitchButtonStyle(selected: false, compact: true))
                    .keyboardShortcut("k", modifiers: [.command])
                }
                .padding(6)
                .background(segmentedSwitcherBackground(compact: false))
            }
        }
    }

    private func surfaceButtonContent(surface: InputSurface, compact: Bool) -> some View {
        surfaceButtonContent(title: surface.title, hint: surface.shortcutHint, compact: compact)
    }

    private func compactSurfaceButtonContent(surface: InputSurface) -> some View {
        HStack(spacing: 6) {
            Image(systemName: surface.systemImage)
                .font(.system(size: 12, weight: .bold))
            Text(surface.title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 11)
    }

    private func segmentedSwitcherBackground(compact: Bool) -> some View {
        RoundedRectangle(cornerRadius: compact ? 22 : 26, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 22 : 26, style: .continuous)
                    .stroke(Color.white.opacity(0.78), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(compact ? 0.035 : 0.045), radius: compact ? 12 : 18, y: compact ? 4 : 8)
    }

    private func surfaceButtonContent(title: String, hint: String, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: compact ? 14 : 15, weight: .bold, design: .rounded))

            Text(hint)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color(red: 0.47, green: 0.52, blue: 0.58))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, compact ? 14 : 16)
        .padding(.vertical, compact ? 12 : 14)
    }

    private func trackpadPanel(viewport: CGSize) -> some View {
        let compact = isCompactViewport(viewport)
        let portrait = viewport.height > viewport.width

        return VStack(alignment: .leading, spacing: compact ? 14 : 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Precision Trackpad")
                        .font(.system(size: compact ? 21 : 24, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.12, green: 0.14, blue: 0.18))

                    Text(portrait ? "Double tap opens items. Long press and drag to move." : "Minimal chrome, maximum surface.")
                        .font(.system(size: compact ? 12 : 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(red: 0.42, green: 0.47, blue: 0.54))
                }

                Spacer(minLength: 12)

                if !compact {
                    Text(model.invertPointerY ? "Vertical reversed" : "Vertical standard")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.43, green: 0.48, blue: 0.55))
                }
            }

            TrackpadSurface(
                onPointerMove: model.sendPointer(dx:dy:),
                onScroll: model.sendScroll(dx:dy:),
                onPrimaryClick: { model.sendClick(.primary) },
                onPrimaryDoubleClick: { model.sendDoubleClick(.primary) },
                onSecondaryClick: { model.sendClick(.secondary) },
                onPrimaryMouseState: model.sendMouseState(_:)
            )
            .frame(height: trackpadSurfaceHeight(for: viewport))
            .overlay(alignment: .topTrailing) {
                Button(model.invertPointerY ? "Use Standard" : "Reverse Vertical") {
                    model.togglePointerYInversion()
                }
                .buttonStyle(ToolbarPillButtonStyle(compact: compact))
                .padding(compact ? 12 : 16)
            }
            .overlay(alignment: .topLeading) {
                TrackpadFloatingBadge(
                    text: model.invertPointerY ? "Finger up -> Cursor up" : "Double tap opens items",
                    compact: compact
                )
                .padding(compact ? 12 : 16)
                .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomLeading) {
                trackpadLegendBar(compact: compact)
                    .padding(compact ? 12 : 16)
                    .allowsHitTesting(false)
            }

            Text("One finger moves. Two fingers scroll. Two-finger tap right-clicks.")
                .font(.system(size: compact ? 11 : 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color(red: 0.42, green: 0.47, blue: 0.54))
        }
        .frame(minHeight: trackpadPanelHeight(for: viewport), alignment: .top)
        .deckSurface()
    }

    private func keyboardPanel(viewport: CGSize) -> some View {
        let compact = isCompactViewport(viewport)

        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Multifunction Keyboard")
                    .font(.system(size: compact ? 21 : 24, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.12, green: 0.14, blue: 0.18))

                Text("Apple-inspired layout with multilingual switching, layered symbols, and a dedicated number pad.")
                    .font(.system(size: compact ? 12 : 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.42, green: 0.47, blue: 0.54))
            }

            MechanicalKeyboardView { keyCode, modifiers, label in
                model.sendKeyCode(keyCode, modifiers: modifiers, label: label)
            }
            .frame(height: keyboardSurfaceHeight(for: viewport))

            VStack(alignment: .leading, spacing: 10) {
                Label("Quick Commit Field", systemImage: "text.cursor")
                    .font(.system(size: compact ? 13 : 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.21, green: 0.25, blue: 0.31))

                TextCaptureField(
                    placeholder: "Emoji, paste, or text committed through the system keyboard",
                    onText: model.sendText(_:) ,
                    onDeleteBackward: { model.sendKey(.delete) },
                    onReturn: { model.sendKey(.return) }
                )
                .frame(height: 50)

                Text("Useful for emoji, pasted snippets, or characters that are easier to confirm through the iPad input method.")
                    .font(.system(size: compact ? 11 : 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.42, green: 0.47, blue: 0.54))
            }
            .deckSurface()
        }
        .frame(
            maxWidth: min(viewport.width - (compact ? 32 : 48), viewport.width > viewport.height ? 1120 : 980),
            minHeight: keyboardPanelHeight(for: viewport),
            alignment: .topLeading
        )
    }

    private func toggleSurface() {
        activeSurface = activeSurface == .trackpad ? .keyboard : .trackpad
    }

    private func trackpadSurfaceHeight(for viewport: CGSize) -> CGFloat {
        let compact = isCompactViewport(viewport)
        let portrait = viewport.height > viewport.width
        let target = viewport.height * (compact ? (portrait ? 0.58 : 0.66) : (portrait ? 0.64 : 0.74))
        return min(max(target, compact ? (portrait ? 340 : 280) : (portrait ? 520 : 500)), compact ? (portrait ? 640 : 500) : (portrait ? 860 : 720))
    }

    private func trackpadPanelHeight(for viewport: CGSize) -> CGFloat {
        trackpadSurfaceHeight(for: viewport) + 86
    }

    private func keyboardSurfaceHeight(for viewport: CGSize) -> CGFloat {
        let compact = isCompactViewport(viewport)
        let portrait = viewport.height > viewport.width
        let target = viewport.height * (compact ? (portrait ? 0.48 : 0.58) : (portrait ? 0.60 : 0.68))
        return min(max(target, compact ? (portrait ? 340 : 280) : (portrait ? 520 : 460)), compact ? (portrait ? 620 : 440) : (portrait ? 800 : 660))
    }

    private func keyboardPanelHeight(for viewport: CGSize) -> CGFloat {
        keyboardSurfaceHeight(for: viewport) + 140
    }

    private func isCompactViewport(_ viewport: CGSize) -> Bool {
        min(viewport.width, viewport.height) < 430
    }

    private func trackpadLegendBar(compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 8) {
            HintChip(text: "Move", compact: compact)
            HintChip(text: "Tap", compact: compact)
            HintChip(text: "Double Tap", compact: compact)
            if !compact {
                HintChip(text: "Scroll", compact: compact)
                HintChip(text: "Drag", compact: compact)
            }
        }
        .padding(compact ? 6 : 8)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.76), lineWidth: 1)
                )
        )
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

    var systemImage: String {
        switch self {
        case .trackpad:
            return "cursorarrow.motionlines"
        case .keyboard:
            return "keyboard"
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
    static let invertPointerYKey = "controller.invert-pointer-y"
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

private struct ManualConnectionSheet: View {
    @ObservedObject var model: RemotePadSessionModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?
    @State private var showsPairingScanner = false

    private enum Field {
        case host
        case port
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Mac Address") {
                    TextField("Mac host", text: $model.host)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .host)
                        .submitLabel(.next)
                        .onSubmit {
                            focusedField = .port
                        }

                    TextField("Port", text: $model.port)
                        .keyboardType(.numberPad)
                        .focused($focusedField, equals: .port)
                }

                Section("Pair With QR") {
                    Button {
                        showsPairingScanner = true
                    } label: {
                        Label("Scan QR From Mac", systemImage: "qrcode.viewfinder")
                    }

                    Text("Run `MacCompanionCLI --show-qr` on your Mac to display a pairing code, then scan it here to fill the host and port automatically.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Connect") {
                        model.connectManually()
                        dismiss()
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }

                Section {
                    Text("Use `.local` first when possible, for example `贾浩的MacBook Pro.local`, then keep port `38765`.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Manual Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                focusedField = .host
            }
            .sheet(isPresented: $showsPairingScanner) {
                PairingCodeScannerSheet { code in
                    if model.applyPairingCode(code) {
                        focusedField = nil
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct ConnectionHelpSheet: View {
    @ObservedObject var model: RemotePadSessionModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Current Status") {
                    helpRow(title: "Connection", value: model.statusText)
                    helpRow(title: "Discovery", value: model.discoveryStatusText)

                    if let lastFailureDetail, !lastFailureDetail.isEmpty {
                        helpRow(title: "Last Failure", value: lastFailureDetail)
                    }
                }

                Section("Best Path") {
                    Text("1. Keep only one `MacCompanionCLI` instance running on the Mac.")
                    Text("2. Make sure the iPad and Mac are on the same local network.")
                    Text("3. If auto discovery stays empty, use `Manual Connect`, then either scan the QR code from the Mac or enter the `.local` host shown in the Mac terminal.")
                    Text("4. If the `.local` host fails, use one of the IPv4 addresses printed by the Mac companion instead.")
                }

                Section("What To Look For On Mac") {
                    Text("When `MacCompanionCLI` starts, it now prints:")
                    Text("• Manual host candidates")
                    Text("• Manual IPv4 candidates")
                    Text("• Port number")
                    Text("• A pairing QR when you launch it with `--show-qr`")
                    Text("Use those exact values, or the QR code, in the iPad manual connection sheet.")
                }

                Section("Common Failures") {
                    Text("`Address already in use`: another MacCompanionCLI is already running.")
                    Text("`No Macs discovered yet`: local network permission is off, the Mac companion is not running, or the devices are on different networks.")
                    Text("Connects but cannot control the Mac: grant Accessibility permission on macOS.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Connection Help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func helpRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(value)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private var lastFailureDetail: String? {
        model.lastFailureDetail
    }
}

private struct StatusPill: View {
    let text: String
    var compact = false

    var body: some View {
        Text(text)
            .font(.system(size: compact ? 12 : 13, weight: .bold, design: .rounded))
            .foregroundStyle(Color(red: 0.16, green: 0.18, blue: 0.22))
            .padding(.horizontal, compact ? 12 : 14)
            .padding(.vertical, compact ? 8 : 10)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(red: 0.89, green: 0.92, blue: 0.96))
            )
    }
}

private struct CompactStatusTag: View {
    let text: String
    var compact = false

    var body: some View {
        Text(text)
            .font(.system(size: compact ? 11 : 12, weight: .semibold, design: .rounded))
            .foregroundStyle(Color(red: 0.25, green: 0.29, blue: 0.35))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, compact ? 10 : 12)
            .padding(.vertical, compact ? 6 : 8)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.86))
            )
    }
}

private struct HintChip: View {
    let text: String
    var compact = false

    var body: some View {
        Text(text)
            .font(.system(size: compact ? 10 : 11, weight: .semibold, design: .rounded))
            .foregroundStyle(Color(red: 0.29, green: 0.34, blue: 0.41))
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 7 : 8)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.78))
            )
    }
}

private struct TrackpadFloatingBadge: View {
    let text: String
    var compact = false

    var body: some View {
        Text(text)
            .font(.system(size: compact ? 10 : 11, weight: .bold, design: .rounded))
            .foregroundStyle(Color(red: 0.23, green: 0.27, blue: 0.33))
            .padding(.horizontal, compact ? 10 : 12)
            .padding(.vertical, compact ? 8 : 9)
            .background(
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.78), lineWidth: 1)
                    )
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
    var compact = false

    init(accent: Color? = nil, compact: Bool = false) {
        self.accent = accent
        self.compact = compact
    }

    func makeBody(configuration: Configuration) -> some View {
        let foreground = accent ?? Color(red: 0.22, green: 0.26, blue: 0.32)
        let background = accent?.opacity(configuration.isPressed ? 0.18 : 0.12) ?? Color.white.opacity(configuration.isPressed ? 0.72 : 0.84)

        return configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold, design: .rounded))
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? 9 : 12)
            .padding(.vertical, compact ? 6 : 8)
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
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 14 : 15, weight: .bold, design: .rounded))
            .foregroundStyle(primary ? Color.white : Color(red: 0.20, green: 0.24, blue: 0.30))
            .padding(.horizontal, compact ? 14 : 18)
            .frame(height: compact ? 44 : 48)
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
            .foregroundStyle(selected ? Color(red: 0.16, green: 0.18, blue: 0.22) : Color(red: 0.35, green: 0.40, blue: 0.47))
            .background(
                RoundedRectangle(cornerRadius: compact ? 20 : 22, style: .continuous)
                    .fill(selected ? Color.white.opacity(compact ? 0.96 : 0.92) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: compact ? 20 : 22, style: .continuous)
                            .stroke(selected ? Color.white.opacity(0.95) : Color.clear, lineWidth: 1)
                    )
            )
            .shadow(color: selected ? Color.black.opacity(compact ? 0.05 : 0.06) : .clear, radius: compact ? 8 : 12, y: compact ? 3 : 5)
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
    let onPrimaryDoubleClick: () -> Void
    let onSecondaryClick: () -> Void
    let onPrimaryMouseState: (MouseButtonState) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onPointerMove: onPointerMove,
            onScroll: onScroll,
            onPrimaryClick: onPrimaryClick,
            onPrimaryDoubleClick: onPrimaryDoubleClick,
            onSecondaryClick: onSecondaryClick,
            onPrimaryMouseState: onPrimaryMouseState
        )
    }

    func makeUIView(context: Context) -> TrackpadInputView {
        let view = TrackpadInputView()
        view.backgroundColor = UIColor.systemGray6
        view.layer.cornerRadius = 28
        view.layer.borderWidth = 1
        view.layer.borderColor = UIColor.white.withAlphaComponent(0.92).cgColor
        view.clipsToBounds = true
        view.isMultipleTouchEnabled = true
        view.onSingleFingerDelta = { [weak coordinator = context.coordinator] dx, dy in
            coordinator?.handleSingleFingerDelta(dx: dx, dy: dy)
        }
        view.onTwoFingerDelta = { [weak coordinator = context.coordinator] dx, dy in
            coordinator?.handleTwoFingerDelta(dx: dx, dy: dy)
        }

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePrimaryTap))
        tap.numberOfTouchesRequired = 1

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePrimaryDoubleTap))
        doubleTap.numberOfTouchesRequired = 1
        doubleTap.numberOfTapsRequired = 2

        let secondaryTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSecondaryTap))
        secondaryTap.numberOfTouchesRequired = 2

        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.3

        tap.require(toFail: doubleTap)
        tap.require(toFail: secondaryTap)

        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(doubleTap)
        view.addGestureRecognizer(secondaryTap)
        view.addGestureRecognizer(longPress)
        return view
    }

    func updateUIView(_ uiView: TrackpadInputView, context: Context) {}

    final class Coordinator: NSObject {
        private let onPointerMove: (Double, Double) -> Void
        private let onScroll: (Double, Double) -> Void
        private let onPrimaryClick: () -> Void
        private let onPrimaryDoubleClick: () -> Void
        private let onSecondaryClick: () -> Void
        private let onPrimaryMouseState: (MouseButtonState) -> Void
        private let pointerGain = 1.18

        init(
            onPointerMove: @escaping (Double, Double) -> Void,
            onScroll: @escaping (Double, Double) -> Void,
            onPrimaryClick: @escaping () -> Void,
            onPrimaryDoubleClick: @escaping () -> Void,
            onSecondaryClick: @escaping () -> Void,
            onPrimaryMouseState: @escaping (MouseButtonState) -> Void
        ) {
            self.onPointerMove = onPointerMove
            self.onScroll = onScroll
            self.onPrimaryClick = onPrimaryClick
            self.onPrimaryDoubleClick = onPrimaryDoubleClick
            self.onSecondaryClick = onSecondaryClick
            self.onPrimaryMouseState = onPrimaryMouseState
        }

        func handleSingleFingerDelta(dx: CGFloat, dy: CGFloat) {
            onPointerMove(Double(dx * pointerGain), Double(dy * pointerGain))
        }

        func handleTwoFingerDelta(dx: CGFloat, dy: CGFloat) {
            onScroll(Double(dx), Double(dy))
        }

        @objc func handlePrimaryTap() {
            onPrimaryClick()
        }

        @objc func handlePrimaryDoubleTap() {
            onPrimaryDoubleClick()
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

private final class TrackpadInputView: UIView {
    var onSingleFingerDelta: ((CGFloat, CGFloat) -> Void)?
    var onTwoFingerDelta: ((CGFloat, CGFloat) -> Void)?

    private var lastSingleFingerPoint: CGPoint?
    private var lastTwoFingerCentroid: CGPoint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        syncTrackingState(with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)

        guard let activeTouches = activeTouches(from: event) else {
            resetTrackingState()
            return
        }

        if activeTouches.count == 1, let touch = activeTouches.first {
            let point = touch.location(in: self)
            if let lastSingleFingerPoint {
                onSingleFingerDelta?(point.x - lastSingleFingerPoint.x, point.y - lastSingleFingerPoint.y)
            }
            lastSingleFingerPoint = point
            lastTwoFingerCentroid = nil
        } else if activeTouches.count == 2 {
            let centroid = midpoint(between: activeTouches[0].location(in: self), and: activeTouches[1].location(in: self))
            if let lastTwoFingerCentroid {
                onTwoFingerDelta?(centroid.x - lastTwoFingerCentroid.x, centroid.y - lastTwoFingerCentroid.y)
            }
            lastTwoFingerCentroid = centroid
            lastSingleFingerPoint = nil
        } else {
            resetTrackingState()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        syncTrackingState(with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        resetTrackingState()
    }

    private func syncTrackingState(with event: UIEvent?) {
        guard let activeTouches = activeTouches(from: event) else {
            resetTrackingState()
            return
        }

        switch activeTouches.count {
        case 1:
            lastSingleFingerPoint = activeTouches[0].location(in: self)
            lastTwoFingerCentroid = nil
        case 2:
            lastTwoFingerCentroid = midpoint(
                between: activeTouches[0].location(in: self),
                and: activeTouches[1].location(in: self)
            )
            lastSingleFingerPoint = nil
        default:
            resetTrackingState()
        }
    }

    private func activeTouches(from event: UIEvent?) -> [UITouch]? {
        guard let touches = event?.allTouches else {
            return nil
        }

        return touches
            .filter { touch in
                switch touch.phase {
                case .began, .moved, .stationary:
                    return true
                case .ended, .cancelled, .regionEntered, .regionMoved, .regionExited:
                    return false
                @unknown default:
                    return false
                }
            }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private func midpoint(between first: CGPoint, and second: CGPoint) -> CGPoint {
        CGPoint(x: (first.x + second.x) * 0.5, y: (first.y + second.y) * 0.5)
    }

    private func resetTrackingState() {
        lastSingleFingerPoint = nil
        lastTwoFingerCentroid = nil
    }
}
#endif
