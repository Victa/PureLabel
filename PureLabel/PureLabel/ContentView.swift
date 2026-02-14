import Photos
import SwiftUI
import UIKit

private enum PickerMode: String, Identifiable {
    case camera
    case library

    var id: String { rawValue }

    var sourceType: UIImagePickerController.SourceType {
        switch self {
        case .camera: return .camera
        case .library: return .photoLibrary
        }
    }
}

struct ContentView: View {
    @State private var sourceImage: UIImage?
    @State private var detectedCircle: DetectedCircle?
    @State private var cutImage: UIImage?
    @State private var pngData: Data?

    @State private var activePickerMode: PickerMode?
    @State private var isSharing = false
    @State private var isAdjusting = false
    @State private var isProcessing = false

    @State private var centerX: CGFloat = 0.5
    @State private var centerY: CGFloat = 0.5
    @State private var radiusRatio: CGFloat = 0.35
    @State private var holeRadiusToLabelRatio: CGFloat = 0.07

    @State private var statusText: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    previewBlock
                    actionsBlock
                    if isAdjusting, sourceImage != nil {
                        adjustBlock
                    }
                    if let statusText {
                        Text(statusText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
                .padding()
            }
            .navigationTitle("PureLabel")
            .sheet(item: $activePickerMode) { mode in
                CameraPicker(sourceType: mode.sourceType) { image in
                    sourceImage = image
                    processImage()
                }
                .id(mode.id)
            }
            .sheet(isPresented: $isSharing) {
                if let fileURL = exportedFileURL() {
                    ShareSheet(items: [fileURL])
                }
            }
        }
    }

    private var previewBlock: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemBackground))

            if let image = sourceImage {
                GeometryReader { geo in
                    let imageRect = aspectFitRect(for: image.size, in: geo.size)

                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)

                    if let overlayCircle = workingCircle(for: image.size) {
                        let imageScale = imageRect.width / image.size.width
                        Circle()
                            .stroke(Color.yellow, lineWidth: 3)
                            .frame(width: overlayCircle.radius * 2 * imageScale,
                                   height: overlayCircle.radius * 2 * imageScale)
                            .position(
                                x: imageRect.minX + overlayCircle.center.x * imageRect.width / image.size.width,
                                y: imageRect.minY + overlayCircle.center.y * imageRect.height / image.size.height
                            )

                        Circle()
                            .stroke(Color.orange, lineWidth: 2)
                            .frame(width: workingHoleRadius(for: overlayCircle) * 2 * imageScale,
                                   height: workingHoleRadius(for: overlayCircle) * 2 * imageScale)
                            .position(
                                x: imageRect.minX + overlayCircle.center.x * imageRect.width / image.size.width,
                                y: imageRect.minY + overlayCircle.center.y * imageRect.height / image.size.height
                            )
                    }
                }
            } else {
                Text("Take a photo of a vinyl label")
                    .foregroundStyle(.secondary)
                    .padding()
            }

            if isProcessing {
                ProgressView("Detecting circle...")
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(height: 320)
    }

    private var actionsBlock: some View {
        VStack(spacing: 12) {
            Button {
                statusText = nil
                activePickerMode = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .library
            } label: {
                Label("Take Photo", systemImage: "camera")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button {
                statusText = nil
                activePickerMode = .library
            } label: {
                Label("Choose from Gallery", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            if sourceImage != nil {
                Button {
                    isAdjusting.toggle()
                    if isAdjusting == false {
                        applyCurrentCircle()
                    }
                } label: {
                    Label(isAdjusting ? "Apply Adjustment" : "Manual Adjust Circle", systemImage: "slider.horizontal.3")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 10) {
                Button("Save PNG") {
                    saveToPhotos()
                }
                .buttonStyle(.bordered)
                .disabled(pngData == nil)

                Button("Share") {
                    isSharing = true
                }
                .buttonStyle(.bordered)
                .disabled(pngData == nil)
            }

            if let image = cutImage {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Transparent output preview")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 200)
                        .background(checkerboard)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var adjustBlock: some View {
        VStack(spacing: 12) {
            Group {
                Text("Center X")
                Slider(value: $centerX, in: 0...1, step: 0.001)
                Text("Center Y")
                Slider(value: $centerY, in: 0...1, step: 0.001)
                Text("Radius")
                Slider(value: $radiusRatio, in: 0.1...0.5, step: 0.001)
                Text("Center Hole")
                Slider(value: $holeRadiusToLabelRatio, in: 0...0.15, step: 0.001)
            }
            .font(.footnote)

            Button("Rebuild PNG") {
                applyCurrentCircle()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var checkerboard: some View {
        Canvas { context, size in
            let tile: CGFloat = 14
            for y in stride(from: 0 as CGFloat, to: size.height, by: tile) {
                for x in stride(from: 0 as CGFloat, to: size.width, by: tile) {
                    let rect = CGRect(x: x, y: y, width: tile, height: tile)
                    let dark = Int((x / tile) + (y / tile)) % 2 == 0
                    context.fill(Path(rect), with: .color(dark ? Color.gray.opacity(0.35) : Color.white))
                }
            }
        }
    }

    private func processImage() {
        guard let sourceImage else { return }

        isProcessing = true
        Task {
            let circle = LabelProcessor.detectCircle(in: sourceImage)

            await MainActor.run {
                isProcessing = false
                guard let circle else {
                    statusText = "No clear circle detected. Use Manual Adjust Circle."
                    setDefaultCircle(using: sourceImage.size)
                    isAdjusting = true
                    applyCurrentCircle()
                    return
                }

                detectedCircle = circle
                syncSliders(with: circle, imageSize: sourceImage.size)
                if let holeRadius = LabelProcessor.detectCenterHoleRadius(in: sourceImage, labelCircle: circle) {
                    holeRadiusToLabelRatio = min(max(holeRadius / circle.radius, 0), 0.15)
                } else {
                    holeRadiusToLabelRatio = 0.07
                }
                applyCurrentCircle()
                statusText = "Circle detected and PNG generated."
            }
        }
    }

    private func syncSliders(with circle: DetectedCircle, imageSize: CGSize) {
        centerX = circle.center.x / imageSize.width
        centerY = circle.center.y / imageSize.height
        radiusRatio = circle.radius / min(imageSize.width, imageSize.height)
    }

    private func setDefaultCircle(using imageSize: CGSize) {
        centerX = 0.5
        centerY = 0.5
        radiusRatio = 0.35
        holeRadiusToLabelRatio = 0.07
    }

    private func workingCircle(for imageSize: CGSize) -> DetectedCircle? {
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }
        let center = CGPoint(x: centerX * imageSize.width, y: centerY * imageSize.height)
        let radius = radiusRatio * min(imageSize.width, imageSize.height)
        return DetectedCircle(center: center, radius: radius)
    }

    private func applyCurrentCircle() {
        guard let sourceImage, let circle = workingCircle(for: sourceImage.size) else { return }
        detectedCircle = circle
        cutImage = LabelProcessor.cutLabel(from: sourceImage, circle: circle, holeRadius: workingHoleRadius(for: circle))
        pngData = cutImage?.pngData()
    }

    private func workingHoleRadius(for circle: DetectedCircle) -> CGFloat {
        max(0, holeRadiusToLabelRatio * circle.radius)
    }

    private func saveToPhotos() {
        guard let pngData, let image = UIImage(data: pngData) else { return }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    statusText = "Photos permission denied."
                }
                return
            }

            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, _ in
                DispatchQueue.main.async {
                    statusText = success ? "Saved to Photos." : "Failed to save image."
                }
            }
        }
    }

    private func exportedFileURL() -> URL? {
        guard let pngData else { return nil }
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("purelabel-\(UUID().uuidString).png")
        do {
            try pngData.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            statusText = "Failed to prepare file for sharing."
            return nil
        }
    }

    private func aspectFitRect(for imageSize: CGSize, in containerSize: CGSize) -> CGRect {
        let imageRatio = imageSize.width / imageSize.height
        let containerRatio = containerSize.width / containerSize.height

        if imageRatio > containerRatio {
            let width = containerSize.width
            let height = width / imageRatio
            let y = (containerSize.height - height) / 2
            return CGRect(x: 0, y: y, width: width, height: height)
        } else {
            let height = containerSize.height
            let width = height * imageRatio
            let x = (containerSize.width - width) / 2
            return CGRect(x: x, y: 0, width: width, height: height)
        }
    }
}
