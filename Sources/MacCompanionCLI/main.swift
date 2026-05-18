import ControllerShared
import Foundation

struct ServerConfiguration {
    let port: UInt16
    let promptForAccessibility: Bool
    let showQRCode: Bool
    let qrOutputPath: String?

    init(arguments: [String]) {
        var parsedPort: UInt16 = 38_765
        var shouldPrompt = true
        var shouldShowQRCode = false
        var parsedQROutputPath: String?

        var index = 1
        while index < arguments.count {
            let argument = arguments[index]

            switch argument {
            case "--port":
                let nextIndex = index + 1
                if nextIndex < arguments.count, let value = UInt16(arguments[nextIndex]) {
                    parsedPort = value
                }
                index = nextIndex
            case "--show-qr":
                shouldShowQRCode = true
            case "--qr-output":
                let nextIndex = index + 1
                if nextIndex < arguments.count {
                    parsedQROutputPath = arguments[nextIndex]
                }
                index = nextIndex
            case "--no-accessibility-prompt":
                shouldPrompt = false
            default:
                break
            }

            index += 1
        }

        port = parsedPort
        promptForAccessibility = shouldPrompt
        showQRCode = shouldShowQRCode
        qrOutputPath = parsedQROutputPath
    }
}

let configuration = ServerConfiguration(arguments: CommandLine.arguments)
let server = try CompanionServer(
    port: configuration.port,
    promptForAccessibility: configuration.promptForAccessibility
)

print("MacCompanionCLI listening on tcp://0.0.0.0:\(configuration.port)")
print("Advertising Bonjour service type \(RemoteCompanionService.bonjourType)")
print("Open System Settings > Privacy & Security > Accessibility if input injection is blocked.")
ConnectionHints.printStartupHints(port: configuration.port)
if let pairingPayload = ConnectionHints.preferredPairingPayload(port: configuration.port) {
    PairingQRCodePresenter.present(
        payload: pairingPayload,
        showQRCode: configuration.showQRCode,
        outputPath: configuration.qrOutputPath
    )
}
server.start()
dispatchMain()
