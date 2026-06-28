import AVFoundation
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PhotoLibraryPicker: UIViewControllerRepresentable {
    let onImagePicked: (UIImage) -> Void
    var onReady: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        DispatchQueue.main.async {
            onReady?()
        }
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: PhotoLibraryPicker

        init(_ parent: PhotoLibraryPicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider,
                  provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
                parent.dismiss()
                return
            }

            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data, let image = UIImage(data: data) else {
                    DispatchQueue.main.async {
                        self.parent.dismiss()
                    }
                    return
                }

                DispatchQueue.main.async {
                    self.parent.onImagePicked(image)
                    self.parent.dismiss()
                }
            }
        }
    }
}

struct NativeCameraCaptureView: View {
    @ObservedObject var model: CameraCaptureModel
    let onImageCaptured: (UIImage) -> Void
    let onCancel: () -> Void
    var onReady: (() -> Void)?

    var body: some View {
        GeometryReader { geo in
            let squareSide = geo.size.width

            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer(minLength: 0)

                    ZStack {
                        if model.authorizationStatus == .authorized {
                            CameraPreview(model: model, session: model.session)
                            CameraCrosshairOverlay()
                        }
                    }
                    .frame(width: squareSide, height: squareSide)
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        model.focus(at: location)
                    }

                    Spacer(minLength: 0)
                }

                VStack {
                    HStack {
                        Button {
                            onCancel()
                        } label: {
                            Text("Cancel")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(Color.black.opacity(0.35), in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        Spacer()
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)

                    Spacer()

                    if model.authorizationStatus == .authorized {
                        Button {
                            model.capturePhoto()
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 74, height: 74)
                                Circle()
                                    .stroke(Color.black.opacity(0.85), lineWidth: 2)
                                    .frame(width: 62, height: 62)
                            }
                            .frame(width: 74, height: 74)
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 34)
                    } else if model.authorizationStatus == .denied || model.authorizationStatus == .restricted {
                        Text("Camera access is required. Enable it in Settings.")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 42)
                    } else {
                        ProgressView()
                            .tint(.white)
                            .padding(.bottom, 42)
                    }
                }
            }
        }
        .onAppear {
            model.onPhotoCaptured = onImageCaptured
            model.prepareSession(requestPermissionIfNeeded: true) {
                model.focusOnCenterIfReady()
                onReady?()
            }
        }
        .onDisappear {
            model.pauseSession()
        }
        .onChange(of: model.authorizationStatus) { status in
            if status == .authorized {
                model.focusOnCenterIfReady()
                onReady?()
            }
        }
    }
}

private struct CameraCrosshairOverlay: View {
    private let armLength: CGFloat = 16
    private let gap: CGFloat = 6
    private let lineWidth: CGFloat = 2.5

    var body: some View {
        Canvas { context, size in
            let midX = size.width / 2
            let midY = size.height / 2
            var path = Path()

            path.move(to: CGPoint(x: midX, y: midY - gap / 2 - armLength))
            path.addLine(to: CGPoint(x: midX, y: midY - gap / 2))
            path.move(to: CGPoint(x: midX, y: midY + gap / 2))
            path.addLine(to: CGPoint(x: midX, y: midY + gap / 2 + armLength))
            path.move(to: CGPoint(x: midX - gap / 2 - armLength, y: midY))
            path.addLine(to: CGPoint(x: midX - gap / 2, y: midY))
            path.move(to: CGPoint(x: midX + gap / 2, y: midY))
            path.addLine(to: CGPoint(x: midX + gap / 2 + armLength, y: midY))

            context.stroke(path, with: .color(.black.opacity(0.6)), lineWidth: lineWidth + 2)
            context.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: lineWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

private struct CameraPreview: UIViewRepresentable {
    @ObservedObject var model: CameraCaptureModel
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = session
        model.setPreviewView(view)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
        model.setPreviewView(uiView)
    }
}

private final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            fatalError("Expected AVCaptureVideoPreviewLayer")
        }
        return layer
    }

    func devicePoint(for viewPoint: CGPoint) -> CGPoint {
        previewLayer.captureDevicePointConverted(fromLayerPoint: viewPoint)
    }
}

final class CameraCaptureModel: NSObject, ObservableObject {
    static let shared = CameraCaptureModel()

    @Published var authorizationStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

    let session = AVCaptureSession()

    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "purelabel.camera.session")
    private var isConfigured = false
    private var isSessionRunning = false
    private var captureDevice: AVCaptureDevice?
    private weak var previewView: PreviewView?
    private var lastFocusPoint = CGPoint(x: 0.5, y: 0.5)

    var onPhotoCaptured: ((UIImage) -> Void)?

    fileprivate func setPreviewView(_ view: PreviewView) {
        DispatchQueue.main.async {
            self.previewView = view
        }
    }

    func warmupIfAuthorized() {
        let current = AVCaptureDevice.authorizationStatus(for: .video)
        authorizationStatus = current
        guard current == .authorized else { return }
        configureAndStart()
    }

    func prepareSession(requestPermissionIfNeeded: Bool, onReady: (() -> Void)? = nil) {
        let current = AVCaptureDevice.authorizationStatus(for: .video)
        if current == .authorized {
            authorizationStatus = .authorized
            configureAndStart {
                DispatchQueue.main.async {
                    onReady?()
                }
            }
            return
        }

        if current == .notDetermined, requestPermissionIfNeeded {
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.authorizationStatus = granted ? .authorized : .denied
                    if granted {
                        self.configureAndStart {
                            DispatchQueue.main.async {
                                onReady?()
                            }
                        }
                    }
                }
            }
            return
        }

        authorizationStatus = current
    }

    func pauseSession() {
        sessionQueue.async {
            guard self.isSessionRunning else { return }
            self.session.stopRunning()
            self.isSessionRunning = false
        }
    }

    func focus(at viewPoint: CGPoint) {
        guard let preview = previewView else { return }
        sessionQueue.async {
            let devicePoint = preview.devicePoint(for: viewPoint)
            self.lastFocusPoint = devicePoint
            self.applyFocus(at: devicePoint, lock: false)
        }
    }

    func focusOnCenterIfReady() {
        guard let preview = previewView else { return }
        let center = CGPoint(x: preview.bounds.midX, y: preview.bounds.midY)
        focus(at: center)
    }

    func capturePhoto() {
        sessionQueue.async {
            self.lockFocusAndExposure()
            let settings = AVCapturePhotoSettings()
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            settings.flashMode = .off
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func configureAndStart(completion: (() -> Void)? = nil) {
        sessionQueue.async {
            if !self.isConfigured {
                self.configureSession()
            }
            guard self.isConfigured else {
                completion?()
                return
            }
            if !self.isSessionRunning {
                self.session.startRunning()
                self.isSessionRunning = true
            }
            completion?()
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        captureDevice = device

        guard session.canAddOutput(photoOutput) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .quality

        if let connection = photoOutput.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }

        session.commitConfiguration()
        isConfigured = true
    }

    private func lockFocusAndExposure() {
        applyFocus(at: lastFocusPoint, lock: true)
    }

    private func applyFocus(at point: CGPoint, lock: Bool) {
        guard let device = captureDevice else { return }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
                if lock, device.isFocusModeSupported(.locked) {
                    device.focusMode = .locked
                } else if device.isFocusModeSupported(.autoFocus) {
                    device.focusMode = .autoFocus
                } else if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
            }

            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
                if lock, device.isExposureModeSupported(.locked) {
                    device.exposureMode = .locked
                } else if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                } else if device.isExposureModeSupported(.autoExpose) {
                    device.exposureMode = .autoExpose
                }
            }
        } catch {
            return
        }
    }
}

extension CameraCaptureModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil,
              let cgImage = photo.cgImageRepresentation() else {
            return
        }

        let orientation = Self.imageOrientation(from: photo)
        let image = UIImage(cgImage: cgImage, scale: 1.0, orientation: orientation)
        let squareImage = Self.squareCenterCropped(image)

        DispatchQueue.main.async {
            self.onPhotoCaptured?(squareImage)
        }
    }

    private static func imageOrientation(from photo: AVCapturePhoto) -> UIImage.Orientation {
        guard let raw = photo.metadata[kCGImagePropertyOrientation as String] as? UInt32,
              let cgOrientation = CGImagePropertyOrientation(rawValue: raw) else {
            return .right
        }
        return UIImage.Orientation(cgOrientation)
    }

    private static func orientationNormalized(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }

        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    private static func squareCenterCropped(_ image: UIImage) -> UIImage {
        let normalized = orientationNormalized(image)
        guard let cgImage = normalized.cgImage else { return image }

        let width = cgImage.width
        let height = cgImage.height
        let side = min(width, height)
        guard side > 0 else { return image }

        let x = (width - side) / 2
        let y = (height - side) / 2
        let cropRect = CGRect(x: x, y: y, width: side, height: side).integral

        guard let cropped = cgImage.cropping(to: cropRect) else { return image }
        return UIImage(cgImage: cropped, scale: normalized.scale, orientation: .up)
    }
}

private extension UIImage.Orientation {
    init(_ cgOrientation: CGImagePropertyOrientation) {
        switch cgOrientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
