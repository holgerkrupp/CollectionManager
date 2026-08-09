import SwiftUI
import VisionKit
import Vision
import AVFoundation

struct BarcodeScannerView: UIViewControllerRepresentable {
    let onScan: (Barcode) -> Void
    let onError: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan, onError: onError) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce])], qualityLevel: .balanced, recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: true, isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }
    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        guard DataScannerViewController.isSupported else { onError("Barcode scanning is not supported on this device."); return }
        guard DataScannerViewController.isAvailable else { onError("Barcode scanning is currently unavailable. Check camera access in Settings."); return }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { onError("Camera access is required to scan barcodes."); return }
        guard !controller.isScanning else { return }
        do { try controller.startScanning() } catch { onError("The barcode scanner could not start. Please try again.") }
    }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (Barcode) -> Void; let onError: (String) -> Void
        init(onScan: @escaping (Barcode) -> Void, onError: @escaping (String) -> Void) { self.onScan = onScan; self.onError = onError }
        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) { if case .barcode(let code) = item, let value = code.payloadStringValue, let barcode = Barcode(rawValue: value) { onScan(barcode); dataScanner.stopScanning() } else { onError("That barcode could not be read. Try holding the camera steady.") } }
        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: Error) { onError("The barcode scanner became unavailable. You can enter the barcode manually.") }
    }
}

struct BarcodeScannerSheet: View {
    let onScan: (Barcode) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    @State private var permissionRequested = false

    var body: some View {
        Group {
            if let message {
                ContentUnavailableView("Scanner unavailable", systemImage: "camera.slash", description: Text(message))
                    .overlay(alignment: .bottom) { Button("Close") { dismiss() }.buttonStyle(.bordered).padding(.bottom, 24) }
            } else {
                BarcodeScannerView(onScan: { value in onScan(value); dismiss() }, onError: { message = $0 })
                    .ignoresSafeArea()
            }
        }
        .task {
            guard !permissionRequested else { return }
            permissionRequested = true
            guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else { return }
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted { message = "Camera access was denied. Enable it in Settings or enter the barcode manually." }
        }
    }
}

struct PhotoCaptureView: UIViewControllerRepresentable {
    let onImage: (Data) -> Void; @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(onImage: onImage, dismiss: dismiss) }
    func makeUIViewController(context: Context) -> UIImagePickerController { let picker = UIImagePickerController(); picker.sourceType = .camera; picker.delegate = context.coordinator; return picker }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) { }
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate { let onImage: (Data) -> Void; let dismiss: DismissAction; init(onImage: @escaping (Data) -> Void, dismiss: DismissAction) { self.onImage = onImage; self.dismiss = dismiss }; func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) { if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.8) { onImage(data) }; dismiss() }; func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { dismiss() } }
}
