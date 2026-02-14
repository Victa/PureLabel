import AVFoundation
import SwiftUI
import UIKit

struct CameraPicker: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    let onImagePicked: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = sourceType
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage else {
                parent.dismiss()
                return
            }
            parent.onImagePicked(image)
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

struct NativeCameraCaptureView: View {
    let onImageCaptured: (UIImage) -> Void
    let onCancel: () -> Void

    @StateObject private var model = CameraCaptureModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if model.authorizationStatus == .authorized {
                CameraPreview(session: model.session)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }

            VStack {
                HStack {
                    Button("Cancel") {
                        onCancel()
                    }
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.35), in: Capsule())

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
        .onAppear {
            model.onPhotoCaptured = onImageCaptured
            model.prepareSession()
        }
        .onDisappear {
            model.stopSession()
        }
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

private final class CameraCaptureModel: NSObject, ObservableObject {
    @Published var authorizationStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

    let session = AVCaptureSession()

    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "purelabel.camera.session")
    private var isConfigured = false
    private var isSessionRunning = false

    var onPhotoCaptured: ((UIImage) -> Void)?

    func prepareSession() {
        let current = AVCaptureDevice.authorizationStatus(for: .video)
        if current == .authorized {
            authorizationStatus = .authorized
            configureAndStart()
            return
        }

        if current == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.authorizationStatus = granted ? .authorized : .denied
                    if granted {
                        self.configureAndStart()
                    }
                }
            }
            return
        }

        authorizationStatus = current
    }

    func stopSession() {
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

    private func configureAndStart() {
        sessionQueue.async {
            if !self.isConfigured {
                self.configureSession()
            }
            guard self.isConfigured, !self.isSessionRunning else { return }
            self.session.startRunning()
            self.isSessionRunning = true
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

        DispatchQueue.main.async {
            self.onPhotoCaptured?(image)
        }
    }
}
