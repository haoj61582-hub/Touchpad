#if canImport(UIKit) && !os(macOS)
import AVFoundation
import SwiftUI
import UIKit

struct PairingCodeScannerSheet: View {
    let onCodeScanned: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var cameraError: String?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                PairingCodeScannerView(
                    onCodeScanned: { code in
                        onCodeScanned(code)
                        dismiss()
                    },
                    onError: { error in
                        cameraError = error
                    }
                )
                .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 10) {
                    Label("Scan the QR code shown on your Mac", systemImage: "qrcode.viewfinder")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("Run `MacCompanionCLI --show-qr` on the Mac, then hold the iPad camera over the pairing code.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.9))

                    if let cameraError {
                        Text(cameraError)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(red: 1.0, green: 0.84, blue: 0.84))
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.0),
                            Color.black.opacity(0.72)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Scan Pairing QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct PairingCodeScannerView: UIViewControllerRepresentable {
    let onCodeScanned: (String) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCodeScanned: onCodeScanned, onError: onError)
    }

    func makeUIViewController(context: Context) -> PairingScannerViewController {
        let controller = PairingScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: PairingScannerViewController, context: Context) {}

    final class Coordinator: NSObject, PairingScannerViewControllerDelegate {
        private let onCodeScanned: (String) -> Void
        private let onError: (String) -> Void

        init(onCodeScanned: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
            self.onCodeScanned = onCodeScanned
            self.onError = onError
        }

        func scannerViewController(_ controller: PairingScannerViewController, didScanCode code: String) {
            onCodeScanned(code)
        }

        func scannerViewController(_ controller: PairingScannerViewController, didFailWithError message: String) {
            onError(message)
        }
    }
}

protocol PairingScannerViewControllerDelegate: AnyObject {
    func scannerViewController(_ controller: PairingScannerViewController, didScanCode code: String)
    func scannerViewController(_ controller: PairingScannerViewController, didFailWithError message: String)
}

final class PairingScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    weak var delegate: PairingScannerViewControllerDelegate?

    private let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isConfigured = false
    private var hasDeliveredCode = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        requestCameraAccessIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
    }

    private func requestCameraAccessIfNeeded() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStartIfNeeded()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else {
                        return
                    }

                    if granted {
                        self.configureAndStartIfNeeded()
                    } else {
                        self.delegate?.scannerViewController(self, didFailWithError: "Camera access is required to scan the Mac pairing QR code.")
                    }
                }
            }
        case .denied, .restricted:
            delegate?.scannerViewController(self, didFailWithError: "Enable Camera access for ControlleriPad in Settings to scan the pairing QR code.")
        @unknown default:
            delegate?.scannerViewController(self, didFailWithError: "Camera access is unavailable on this iPad.")
        }
    }

    private func configureAndStartIfNeeded() {
        guard !isConfigured else {
            startRunningIfNeeded()
            return
        }

        guard let videoDevice = AVCaptureDevice.default(for: .video) else {
            delegate?.scannerViewController(self, didFailWithError: "No camera is available on this device.")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: videoDevice)
            guard captureSession.canAddInput(input) else {
                delegate?.scannerViewController(self, didFailWithError: "Unable to use the iPad camera for scanning.")
                return
            }

            captureSession.addInput(input)

            let metadataOutput = AVCaptureMetadataOutput()
            guard captureSession.canAddOutput(metadataOutput) else {
                delegate?.scannerViewController(self, didFailWithError: "Unable to read QR codes from the camera feed.")
                return
            }

            captureSession.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
            metadataOutput.metadataObjectTypes = [.qr]

            let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
            previewLayer.videoGravity = .resizeAspectFill
            view.layer.insertSublayer(previewLayer, at: 0)
            self.previewLayer = previewLayer
            isConfigured = true
            startRunningIfNeeded()
        } catch {
            delegate?.scannerViewController(self, didFailWithError: error.localizedDescription)
        }
    }

    private func startRunningIfNeeded() {
        guard !captureSession.isRunning else {
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession.startRunning()
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasDeliveredCode,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let payload = object.stringValue,
              !payload.isEmpty
        else {
            return
        }

        hasDeliveredCode = true
        captureSession.stopRunning()
        delegate?.scannerViewController(self, didScanCode: payload)
    }
}
#endif
