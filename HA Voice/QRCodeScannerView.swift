import AVFoundation
import SwiftUI
import Vision
import VisionKit

struct QRCodeScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var errorMessage: String?

    let onScan: (String) -> Void

    var body: some View {
        NavigationStack {
            Group {
                switch authorizationStatus {
                case .authorized:
                    scannerView
                case .notDetermined:
                    ProgressView("Requesting camera access")
                case .denied, .restricted:
                    ContentUnavailableView(
                        "Camera Access Needed",
                        systemImage: "camera",
                        description: Text("Enable camera access in Settings to scan a Home Assistant token QR code.")
                    )
                @unknown default:
                    ContentUnavailableView("Camera Unavailable", systemImage: "camera")
                }
            }
            .navigationTitle("Scan Token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Scanner Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .task {
            await requestCameraAccessIfNeeded()
        }
    }

    private func requestCameraAccessIfNeeded() async {
        guard authorizationStatus == .notDetermined else { return }
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        authorizationStatus = granted ? .authorized : .denied
    }

    @ViewBuilder
    private var scannerView: some View {
        Group {
            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                SystemQRScannerRepresentable { value in
                    onScan(value)
                    dismiss()
                } onFailure: { message in
                    errorMessage = message
                }
            } else {
                QRScannerRepresentable { value in
                    onScan(value)
                    dismiss()
                } onFailure: { message in
                    errorMessage = message
                }
            }
        }
        .overlay(alignment: .center) {
            ScannerReticle()
        }
        .overlay(alignment: .bottom) {
            Text("Hold the QR code steady inside the frame.")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.black.opacity(0.45), in: Capsule())
                .padding(.bottom, 24)
        }
        .ignoresSafeArea(edges: .bottom)
    }
}

private struct ScannerReticle: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 18)
            .stroke(.white, lineWidth: 4)
            .frame(width: 240, height: 240)
            .shadow(radius: 8)
            .accessibilityHidden(true)
    }
}

private struct SystemQRScannerRepresentable: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onFailure: onFailure)
    }

    func makeUIViewController(context: Context) -> SystemQRScannerContainerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .accurate,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: true,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return SystemQRScannerContainerViewController(
            scanner: scanner,
            onFailure: onFailure
        )
    }

    func updateUIViewController(_ uiViewController: SystemQRScannerContainerViewController, context: Context) {}

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScan: (String) -> Void
        private let onFailure: (String) -> Void
        private var didScan = false

        init(
            onScan: @escaping (String) -> Void,
            onFailure: @escaping (String) -> Void
        ) {
            self.onScan = onScan
            self.onFailure = onFailure
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            scan(items: addedItems)
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didUpdate updatedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            scan(items: updatedItems)
        }

        private func scan(items: [RecognizedItem]) {
            guard !didScan else { return }

            for item in items {
                guard case .barcode(let barcode) = item,
                      barcode.observation.symbology == .qr,
                      let value = barcode.payloadStringValue
                else {
                    continue
                }

                didScan = true
                onScan(value)
                return
            }
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable
        ) {
            onFailure("The system QR scanner became unavailable.")
        }
    }
}

private struct QRScannerRepresentable: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onFailure: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        QRScannerViewController(onScan: onScan, onFailure: onFailure)
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

final class SystemQRScannerContainerViewController: UIViewController {
    private let scanner: DataScannerViewController
    private let onFailure: (String) -> Void

    init(
        scanner: DataScannerViewController,
        onFailure: @escaping (String) -> Void
    ) {
        self.scanner = scanner
        self.onFailure = onFailure
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(scanner)
        view.addSubview(scanner.view)
        scanner.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scanner.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scanner.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scanner.view.topAnchor.constraint(equalTo: view.topAnchor),
            scanner.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        scanner.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !scanner.isScanning else { return }

        do {
            try scanner.startScanning()
        } catch {
            onFailure("The system QR scanner could not start.")
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        scanner.stopScanning()
    }
}

final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let metadataOutput = AVCaptureMetadataOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "WaverlyWorks.HAVoice.QRScanner.video")
    private let onScan: (String) -> Void
    private let onFailure: (String) -> Void
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didScan = false

    init(
        onScan: @escaping (String) -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        self.onScan = onScan
        self.onFailure = onFailure
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [session] in
                session.startRunning()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning {
            session.stopRunning()
        }
    }

    private func configureSession() {
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device)
        else {
            onFailure("No camera is available on this device.")
            return
        }
        configureCamera(device)

        guard session.canAddInput(input) else {
            onFailure("The camera could not be opened.")
            return
        }
        session.addInput(input)

        guard session.canAddOutput(metadataOutput) else {
            onFailure("QR scanning is not available.")
            return
        }
        session.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
        metadataOutput.metadataObjectTypes = [.qr]

        if session.canAddOutput(videoOutput) {
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            session.addOutput(videoOutput)
        }

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = view.bounds
        view.layer.insertSublayer(previewLayer, at: 0)
        self.previewLayer = previewLayer
    }

    private func configureCamera(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()

            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5)
            }

            device.unlockForConfiguration()
        } catch {
            onFailure("The camera could not be configured for QR scanning.")
        }
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue
        else {
            return
        }

        Task { @MainActor in
            handleScan(value)
        }
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let request = VNDetectBarcodesRequest { request, _ in
            guard let observation = request.results?.compactMap({ $0 as? VNBarcodeObservation }).first(where: { $0.symbology == .qr }),
                  let value = observation.payloadStringValue
            else {
                return
            }

            Task { @MainActor in
                self.handleScan(value)
            }
        }
        request.symbologies = [.qr]

        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .right)
        try? handler.perform([request])
    }

    private func handleScan(_ value: String) {
        guard !didScan else { return }
        didScan = true
        session.stopRunning()
        onScan(value)
    }
}
