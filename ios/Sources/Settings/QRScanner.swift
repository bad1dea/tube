import AVFoundation
import SwiftUI
import VisionKit

/// Camera view that reports the first QR code whose text starts with `prefix`.
/// Callers check `isSupported` (A12 or later) and `requestCamera()` first.
struct QRScanner: UIViewControllerRepresentable {
    let prefix: String
    let onFound: (String) -> Void

    static var isSupported: Bool { DataScannerViewController.isSupported }

    /// Asks for camera access the first time; false if it is off or restricted.
    static func requestCamera() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        vc.delegate = context.coordinator
        return vc
    }

    // Scanning can only start once the view is on screen.
    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {
        DispatchQueue.main.async { if !vc.isScanning && !context.coordinator.done { try? vc.startScanning() } }
    }

    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) {
        vc.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let parent: QRScanner
        var done = false

        init(_ parent: QRScanner) { self.parent = parent }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for case .barcode(let code) in items {
                guard let text = code.payloadStringValue, text.hasPrefix(parent.prefix) else { continue }
                done = true
                scanner.stopScanning()
                parent.onFound(text)
                return
            }
        }
    }
}

/// Full-screen sheet around QRScanner with a hint and Cancel.
struct QRScanSheet: View {
    let prefix: String
    let hint: String
    let onFound: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            QRScanner(prefix: prefix) { text in
                onFound(text)
                dismiss()
            }
            .ignoresSafeArea()
            .overlay(alignment: .bottom) {
                Text(hint)
                    .font(.callout)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 24)
            }
            .navigationTitle("Scan Pairing Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
