import AppKit
import ControllerShared
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

enum PairingQRCodePresenter {
    static func present(
        payload: RemotePairingPayload,
        showQRCode: Bool,
        outputPath: String?
    ) {
        guard let pairingString = RemotePairingCode.encode(payload) else {
            print("Failed to encode pairing QR payload.")
            return
        }

        print("Pairing code for iPad scanner:")
        print("  \(pairingString)")

        guard showQRCode || outputPath != nil else {
            print("Run with `--show-qr` to open a QR code on this Mac.")
            return
        }

        do {
            let destinationURL = resolvedOutputURL(customPath: outputPath)
            try writeQRCodePNG(from: pairingString, to: destinationURL)
            print("Pairing QR saved to \(destinationURL.path)")

            if showQRCode {
                NSWorkspace.shared.open(destinationURL)
            }
        } catch {
            print("Failed to create pairing QR: \(error.localizedDescription)")
        }
    }

    private static func resolvedOutputURL(customPath: String?) -> URL {
        if let customPath, !customPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: customPath)
        }

        let desktop = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)

        return desktop.appendingPathComponent("TouchpadPairingQR.png", isDirectory: false)
    }

    private static func writeQRCodePNG(from payload: String, to url: URL) throws {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else {
            throw NSError(domain: "PairingQRCodePresenter", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "QR generator did not produce an image."
            ])
        }

        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: 14, y: 14))
        let context = CIContext()

        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            throw NSError(domain: "PairingQRCodePresenter", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Failed to render QR image."
            ])
        }

        let image = NSImage(cgImage: cgImage, size: NSSize(width: scaledImage.extent.width, height: scaledImage.extent.height))
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            throw NSError(domain: "PairingQRCodePresenter", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Failed to encode QR image as PNG."
            ])
        }

        try pngData.write(to: url, options: .atomic)
    }
}
