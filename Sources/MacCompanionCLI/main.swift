import ControllerShared
import Foundation

struct ServerConfiguration {
    let port: UInt16
    let promptForAccessibility: Bool

    init(arguments: [String]) {
        var parsedPort: UInt16 = 38_765
        var shouldPrompt = true

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
            case "--no-accessibility-prompt":
                shouldPrompt = false
            default:
                break
            }

            index += 1
        }

        port = parsedPort
        promptForAccessibility = shouldPrompt
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
server.start()
dispatchMain()
