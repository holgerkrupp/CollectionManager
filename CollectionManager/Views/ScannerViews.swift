import SwiftUI
import VisionKit
import Vision
import AVFoundation

struct BarcodeScannerView: UIViewControllerRepresentable {
    let onScan: (Barcode) -> Void
    let onError: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan, onError: onError) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce])], qualityLevel: .fast, recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: true, isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
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
    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
        controller.delegate = nil
    }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (Barcode) -> Void; let onError: (String) -> Void; private var didScan = false
        init(onScan: @escaping (Barcode) -> Void, onError: @escaping (String) -> Void) { self.onScan = onScan; self.onError = onError }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) { for item in addedItems where scan(item, with: dataScanner) { break } }
        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) { _ = scan(item, with: dataScanner, reportInvalid: true) }
        private func scan(_ item: RecognizedItem, with dataScanner: DataScannerViewController, reportInvalid: Bool = false) -> Bool {
            guard !didScan else { return false }
            guard case .barcode(let code) = item, let value = code.payloadStringValue, let barcode = Barcode(rawValue: value) else {
                if reportInvalid { onError("That barcode could not be read. Try holding the camera steady.") }
                return false
            }
            didScan = true
            dataScanner.stopScanning()
            // Let the SwiftUI sheet own dismissal so VisionKit can finish
            // delivering the recognized item to the callback.
            onScan(barcode)
            return true
        }
        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: Error) { onError("The barcode scanner became unavailable. You can enter the barcode manually.") }
    }
}

struct BarcodeScannerSheet: View {
    let onScan: (Barcode) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    @State private var permissionRequested = false
    @State private var detectedBarcode: Barcode?

    var body: some View {
        ZStack {
            if let message {
                ContentUnavailableView("Scanner unavailable", systemImage: "camera.slash", description: Text(message))
                    .overlay(alignment: .bottom) { Button("Close") { dismiss() }.buttonStyle(.bordered).padding(.bottom, 24) }
            } else {
                BarcodeScannerView(onScan: { value in
                    detectedBarcode = value
                    onScan(value)
                    UIAccessibility.post(notification: .announcement, argument: "Barcode detected: \(value.value)")
                    dismiss()
                }, onError: { message = $0 })
                    .ignoresSafeArea()
            }

            if let detectedBarcode {
                VStack(spacing: 4) {
                    Label("Barcode detected", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                    Text(detectedBarcode.value)
                        .font(.system(.title3, design: .monospaced, weight: .semibold))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .foregroundStyle(.white)
                .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 16))
                .accessibilityElement(children: .combine)
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
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onImage: (Data) -> Void; let dismiss: DismissAction
        init(onImage: @escaping (Data) -> Void, dismiss: DismissAction) { self.onImage = onImage; self.dismiss = dismiss }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage else { dismiss(); return }
            dismiss()
            Task.detached(priority: .userInitiated) { [onImage] in
                guard let data = image.jpegData(compressionQuality: 0.82) else { return }
                await MainActor.run { onImage(data) }
            }
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { dismiss() }
    }
}
