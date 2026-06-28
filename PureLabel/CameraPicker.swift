import AVFoundation
import PhotosUI
import SwiftUI
import UIKit

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
                  provider.canLoadObject(ofClass: UIImage.self) else {
                parent.dismiss()
                return
            }

            provider.loadObject(ofClass: UIImage.self) { object, _ in
                guard let image = object as? UIImage else {
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
                            CameraPreview(session: model.session)
                            CameraCrosshairOverlay()
                        }
                    }
                    .frame(width: squareSide, height: squareSide)
                    .clipped()

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
                onReady?()
            }
        }
        .onDisappear {
            model.pauseSession()
        }
        .onChange(of: model.authorizationStatus) { status in
            if status == .authorized {
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
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = session
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
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
}

final class CameraCaptureModel: NSObject, ObservableObject {
    static let shared = CameraCaptureModel()

    @Published var authorizationStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

    let session = AVCaptureSession()

    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "purelabel.camera.session")
    private var isConfigured = false
    private var isSessionRunning = false

    var onPhotoCaptured: ((UIImage) -> Void)?

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

    func capturePhoto() {
        sessionQueue.async {
            let settings = AVCapturePhotoSettings()
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

        guard session.canAddOutput(photoOutput) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(photoOutput)

        if let connection = photoOutput.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }

        session.commitConfiguration()
        isConfigured = true
    }
}

extension CameraCaptureModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
            return
        }

        let squareImage = Self.squareCenterCropped(image)
        DispatchQueue.main.async {
            self.onPhotoCaptured?(squareImage)
        }
    }

    private static func squareCenterCropped(_ image: UIImage) -> UIImage {
        let size = image.size
        let side = min(size.width, size.height)
        guard side > 0 else { return image }

        let origin = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        return renderer.image { _ in
            image.draw(at: CGPoint(x: -origin.x, y: -origin.y))
        }
    }
}
