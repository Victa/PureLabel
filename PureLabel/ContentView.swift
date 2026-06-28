import AVFoundation
import Photos
import SwiftUI
import UIKit

private enum PickerMode: String, Identifiable {
    case camera
    case library

    var id: String { rawValue }
}

private enum WorkspaceScreen {
    case home
    case editor
    case preview
}

struct ContentView: View {
    @ObservedObject private var cameraService = CameraCaptureModel.shared

    @State private var sourceImage: UIImage?
    @State private var detectedCircle: DetectedCircle?
    @State private var cutImage: UIImage?
    @State private var pngData: Data?

    @State private var activePickerMode: PickerMode?
    @State private var activeScreen: WorkspaceScreen = .home
    @State private var isSharing = false
    @State private var isProcessing = false
    @State private var isOpeningPicker = false
    @State private var shareFileURL: URL?
    @State private var exportedTempURLs: [URL] = []
    @State private var processingRequestID = UUID()
    @State private var circleApplyTask: Task<Void, Never>?

    @State private var centerX: CGFloat = 0.5
    @State private var centerY: CGFloat = 0.5
    @State private var radiusRatio: CGFloat = 0.35
    @State private var holeRadiusToLabelRatio: CGFloat = 0.07
    @State private var holeOffsetXRatio: CGFloat = 0
    @State private var holeOffsetYRatio: CGFloat = 0

    @State private var statusText: String?

    var body: some View {
        GeometryReader { proxy in
            Group {
                if activeScreen == .home || sourceImage == nil {
                    homeScreen(topInset: proxy.safeAreaInsets.top)
                } else if activeScreen == .editor {
                    editorScreen(
                        topInset: proxy.safeAreaInsets.top,
                        containerHeight: proxy.size.height
                    )
                } else {
                    previewScreen(topInset: proxy.safeAreaInsets.top)
                }
            }
        }
        .sheet(item: $activePickerMode, onDismiss: {
            isOpeningPicker = false
            if activeScreen == .home {
                cameraService.warmupIfAuthorized()
            }
        }) { mode in
            switch mode {
            case .camera:
                NativeCameraCaptureView(
                    model: cameraService,
                    onImageCaptured: { image in
                        isOpeningPicker = false
                        sourceImage = image
                        activeScreen = .editor
                        activePickerMode = nil
                        processImage()
                    },
                    onCancel: {
                        isOpeningPicker = false
                        activePickerMode = nil
                    },
                    onReady: {
                        isOpeningPicker = false
                    }
                )
            case .library:
                PhotoLibraryPicker(
                    onImagePicked: { image in
                        isOpeningPicker = false
                        sourceImage = image
                        activeScreen = .editor
                        activePickerMode = nil
                        processImage()
                    },
                    onReady: {
                        isOpeningPicker = false
                    }
                )
                .id(mode.id)
            }
        }
        .sheet(isPresented: $isSharing, onDismiss: {
            cleanupExportedFiles()
        }) {
            if let shareFileURL {
                ShareSheet(items: [shareFileURL])
            }
        }
    }

    private func homeScreen(topInset: CGFloat) -> some View {
        ZStack {
            Color(.systemGray5)
                .ignoresSafeArea()

            VStack {
                Spacer()

                Text("Take a photo of a vinyl label")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(.systemGray))
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)

                Spacer()

                VStack(spacing: 16) {
                    Button {
                        statusText = nil
                        isOpeningPicker = true
                        activePickerMode = AVCaptureDevice.default(for: .video) != nil ? .camera : .library
                    } label: {
                        Text("Take Photo")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 17)
                            .background(Color.blue, in: Capsule())
                            .contentShape(Capsule())
                            .shadow(color: Color.black.opacity(0.15), radius: 6, x: 0, y: 3)
                    }
                    .buttonStyle(.plain)

                    Button {
                        statusText = nil
                        isOpeningPicker = true
                        activePickerMode = .library
                    } label: {
                        Text("Choose from Gallery")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Color.black.opacity(0.75))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 17)
                            .background(Color(.systemGray6), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, max(20, topInset))
            }

            if isOpeningPicker {
                Color.black.opacity(0.2)
                    .ignoresSafeArea()
                ProgressView()
                    .controlSize(.large)
            }
        }
        .onAppear {
            cameraService.warmupIfAuthorized()
            LabelProcessor.warmup()
        }
    }

    private func editorScreen(topInset: CGFloat, containerHeight: CGFloat) -> some View {
        let imageHeight = max(300, containerHeight * 0.62)

        return VStack(spacing: 0) {
            HStack {
                Button {
                    processingRequestID = UUID()
                    circleApplyTask?.cancel()
                    sourceImage = nil
                    detectedCircle = nil
                    cutImage = nil
                    pngData = nil
                    statusText = nil
                    cleanupExportedFiles()
                    activeScreen = .home
                    cameraService.warmupIfAuthorized()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.7))
                        .frame(width: 58, height: 58)
                        .background(Color(.systemGray6), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    Task {
                        await applyCurrentCircleImmediately()
                        activeScreen = .preview
                    }
                } label: {
                    Text("OPEN PREVIEW")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 13)
                        .background(Color.blue, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(sourceImage == nil)
            }
            .padding(.top, topInset + 8)
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
            .background(Color(.systemGray5))

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    imageArea(height: imageHeight)
                    controlsArea
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
    }

    private func previewScreen(topInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    activeScreen = .editor
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.7))
                        .frame(width: 58, height: 58)
                        .background(Color(.systemGray6), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)

                Spacer()

                HStack(spacing: 10) {
                    Button {
                        saveToPhotos()
                    } label: {
                        Text("Save PNG")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 11)
                            .background(Color.blue, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(pngData == nil)

                    Button {
                        guard let fileURL = exportedFileURL() else { return }
                        shareFileURL = fileURL
                        isSharing = true
                    } label: {
                        Text("Share")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 11)
                            .background(Color.black.opacity(0.3), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(pngData == nil)
                }
            }
            .padding(.top, topInset + 8)
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
            .background(Color(.systemGray5))

            outputArea
        }
        .background(Color.black.ignoresSafeArea())
    }

    private func imageArea(height: CGFloat) -> some View {
        ZStack {
            Color.black

            if let image = sourceImage {
                GeometryReader { geo in
                    let imageRect = aspectFitRect(for: image.size, in: geo.size)

                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)

                    if let overlayCircle = workingCircle(for: image.size) {
                        let imageScale = imageRect.width / image.size.width
                        let holeCenter = workingHoleCenter(for: overlayCircle)
                        let holeDisplayCenter = CGPoint(
                            x: imageRect.minX + holeCenter.x * imageRect.width / image.size.width,
                            y: imageRect.minY + holeCenter.y * imageRect.height / image.size.height
                        )
                        let holeDisplayDiameter = workingHoleRadius(for: overlayCircle) * 2 * imageScale

                        Circle()
                            .stroke(Color.yellow, lineWidth: 3)
                            .frame(width: overlayCircle.radius * 2 * imageScale,
                                   height: overlayCircle.radius * 2 * imageScale)
                            .position(
                                x: imageRect.minX + overlayCircle.center.x * imageRect.width / image.size.width,
                                y: imageRect.minY + overlayCircle.center.y * imageRect.height / image.size.height
                            )

                        Circle()
                            .stroke(Color.orange, lineWidth: holeRadiusToLabelRatio > 0.15 ? 3 : 2)
                            .frame(width: holeDisplayDiameter, height: holeDisplayDiameter)
                            .position(holeDisplayCenter)

                        Circle()
                            .fill(Color.clear)
                            .frame(
                                width: max(54, holeDisplayDiameter + 20),
                                height: max(54, holeDisplayDiameter + 20)
                            )
                            .contentShape(Circle())
                            .position(holeDisplayCenter)
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        updateHoleOffset(
                                            with: value.location,
                                            imageRect: imageRect,
                                            imageSize: image.size,
                                            circle: overlayCircle
                                        )
                                        scheduleApplyCurrentCircle()
                                    }
                                    .onEnded { _ in
                                        Task {
                                            await applyCurrentCircleImmediately()
                                        }
                                    }
                            )
                    }
                }
            } else {
                Text("Image taken here")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(.white.opacity(0.9))
            }

            if isProcessing {
                ProgressView("Detecting circle...")
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(height: height)
    }

    private var controlsArea: some View {
        VStack(spacing: 14) {
            VStack(spacing: 0) {
                HStack(spacing: 18) {
                    sliderCell(title: "Center X", value: $centerX, range: 0...1)
                    sliderCell(title: "Center Y", value: $centerY, range: 0...1)
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 14)

                Divider()

                HStack(spacing: 18) {
                    sliderCell(title: "Radius", value: $radiusRatio, range: 0.1...0.6)
                    sliderCell(title: "Center Hole", value: $holeRadiusToLabelRatio, range: 0...0.55)
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 8)

                Button("Re-detect Hole") {
                    redetectCenterHole()
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.blue)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 14)

                Divider()

                HStack(spacing: 18) {
                    sliderCell(title: "Hole X", value: $holeOffsetXRatio, range: -0.2...0.2)
                    sliderCell(title: "Hole Y", value: $holeOffsetYRatio, range: -0.2...0.2)
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 14)

                Divider()
            }
            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 28))

            if let statusText {
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(Color.black.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Color(.systemGray5))
        .onChange(of: centerX) { _ in scheduleApplyCurrentCircle() }
        .onChange(of: centerY) { _ in scheduleApplyCurrentCircle() }
        .onChange(of: radiusRatio) { _ in scheduleApplyCurrentCircle() }
        .onChange(of: holeRadiusToLabelRatio) { _ in scheduleApplyCurrentCircle() }
        .onChange(of: holeOffsetXRatio) { _ in scheduleApplyCurrentCircle() }
        .onChange(of: holeOffsetYRatio) { _ in scheduleApplyCurrentCircle() }
    }

    private var outputArea: some View {
        VStack(spacing: 18) {
            Text("Output Preview Here")
                .font(.system(size: 20, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.center)

            if let image = cutImage {
                Image(uiImage: previewImage(from: image))
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 420)
                    .background(checkerboard)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 20)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .background(Color.black)
    }

    private func sliderCell(title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.black.opacity(0.92))

            Slider(value: value, in: range)
                .tint(Color(.systemGray3))
        }
        .frame(maxWidth: .infinity)
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

    private func redetectCenterHole() {
        guard let sourceImage, let circle = workingCircle(for: sourceImage.size) else { return }

        Task {
            let image = sourceImage
            let labelCircle = circle
            let detectedHole = LabelProcessor.detectCenterHole(in: image, labelCircle: labelCircle)

            await MainActor.run {
                guard let hole = detectedHole else {
                    statusText = "Could not detect hole. Adjust Center Hole manually."
                    return
                }

                holeRadiusToLabelRatio = min(max(hole.radius / labelCircle.radius, 0), 0.55)
                holeOffsetXRatio = (hole.center.x - labelCircle.center.x) / labelCircle.radius
                holeOffsetYRatio = (hole.center.y - labelCircle.center.y) / labelCircle.radius

                let isWideHole = holeRadiusToLabelRatio >= 0.18
                statusText = isWideHole
                    ? "Wide center hole detected."
                    : "Spindle hole detected."
            }

            await applyCurrentCircleImmediately()
        }
    }

    private func processImage() {
        guard let sourceImage else { return }

        let requestID = UUID()
        processingRequestID = requestID
        isProcessing = true
        let image = sourceImage

        Task {
            let circle = LabelProcessor.detectCircle(in: image)
            let detectedHole = circle.flatMap { LabelProcessor.detectCenterHole(in: image, labelCircle: $0) }

            let holeRadiusRatio: CGFloat
            let holeOffsetX: CGFloat
            let holeOffsetY: CGFloat
            if let circle, let hole = detectedHole {
                holeRadiusRatio = min(max(hole.radius / circle.radius, 0), 0.55)
                holeOffsetX = (hole.center.x - circle.center.x) / circle.radius
                holeOffsetY = (hole.center.y - circle.center.y) / circle.radius
            } else {
                holeRadiusRatio = 0.07
                holeOffsetX = 0
                holeOffsetY = 0
            }

            let defaultCircle = DetectedCircle(
                center: CGPoint(x: image.size.width * 0.5, y: image.size.height * 0.5),
                radius: min(image.size.width, image.size.height) * 0.35
            )
            let resolvedCircle = circle ?? defaultCircle
            let holeCenter = CGPoint(
                x: resolvedCircle.center.x + holeOffsetX * resolvedCircle.radius,
                y: resolvedCircle.center.y + holeOffsetY * resolvedCircle.radius
            )
            let output = LabelProcessor.processLabel(
                from: image,
                circle: resolvedCircle,
                holeCenter: holeCenter,
                holeRadius: max(0, holeRadiusRatio * resolvedCircle.radius)
            )

            let detected = circle
            await MainActor.run {
                guard requestID == processingRequestID else { return }
                isProcessing = false

                guard let detected else {
                    statusText = "No clear circle detected. Adjust sliders then open preview."
                    setDefaultCircle(using: image.size)
                    return
                }

                detectedCircle = detected
                syncSliders(with: detected, imageSize: image.size)
                holeRadiusToLabelRatio = holeRadiusRatio
                holeOffsetXRatio = holeOffsetX
                holeOffsetYRatio = holeOffsetY
                cutImage = output.cutImage
                pngData = output.pngData
                statusText = detectedHole == nil
                    ? "Circle detected. Adjust center hole if needed."
                    : (holeRadiusRatio >= 0.18
                        ? "Circle detected. Wide center hole (7-inch style)."
                        : "Circle detected and PNG generated.")
            }

            if detected == nil {
                await applyCurrentCircleImmediately()
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
        holeOffsetXRatio = 0
        holeOffsetYRatio = 0
    }

    private func workingCircle(for imageSize: CGSize) -> DetectedCircle? {
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }
        let center = CGPoint(x: centerX * imageSize.width, y: centerY * imageSize.height)
        let radius = radiusRatio * min(imageSize.width, imageSize.height)
        return DetectedCircle(center: center, radius: radius)
    }

    private func applyCurrentCircleImmediately() async {
        circleApplyTask?.cancel()
        guard let sourceImage, let circle = workingCircle(for: sourceImage.size) else { return }

        let image = sourceImage
        let holeCenter = workingHoleCenter(for: circle)
        let holeRadius = workingHoleRadius(for: circle)

        let output = await Task.detached(priority: .userInitiated) {
            LabelProcessor.processLabel(
                from: image,
                circle: circle,
                holeCenter: holeCenter,
                holeRadius: holeRadius
            )
        }.value

        detectedCircle = circle
        cutImage = output.cutImage
        pngData = output.pngData
    }

    private func scheduleApplyCurrentCircle() {
        circleApplyTask?.cancel()
        guard let sourceImage else { return }

        let image = sourceImage
        let circle = workingCircle(for: image.size)
        let holeCenter = circle.map { workingHoleCenter(for: $0) }
        let holeRadius = circle.map { workingHoleRadius(for: $0) }

        circleApplyTask = Task {
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled, let circle, let holeCenter, let holeRadius else { return }

            let output = await Task.detached(priority: .userInitiated) {
                LabelProcessor.processLabel(
                    from: image,
                    circle: circle,
                    holeCenter: holeCenter,
                    holeRadius: holeRadius
                )
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run {
                detectedCircle = circle
                cutImage = output.cutImage
                pngData = output.pngData
            }
        }
    }

    private func updateHoleOffset(with location: CGPoint, imageRect: CGRect, imageSize: CGSize, circle: DetectedCircle) {
        guard imageRect.width > 0, imageRect.height > 0, circle.radius > 0 else { return }

        let mappedX = (location.x - imageRect.minX) * imageSize.width / imageRect.width
        let mappedY = (location.y - imageRect.minY) * imageSize.height / imageRect.height

        holeOffsetXRatio = clamp((mappedX - circle.center.x) / circle.radius, min: -0.2, max: 0.2)
        holeOffsetYRatio = clamp((mappedY - circle.center.y) / circle.radius, min: -0.2, max: 0.2)
    }

    private func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        max(minValue, min(maxValue, value))
    }

    private func workingHoleCenter(for circle: DetectedCircle) -> CGPoint {
        CGPoint(
            x: circle.center.x + holeOffsetXRatio * circle.radius,
            y: circle.center.y + holeOffsetYRatio * circle.radius
        )
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

    private func previewImage(from image: UIImage) -> UIImage {
        guard let circle = detectedCircle else { return image }
        return cropOutputImage(image, circle: circle)
    }

    private func cropOutputImage(_ image: UIImage, circle: DetectedCircle) -> UIImage {
        guard let cgImage = image.cgImage else { return image }

        let pad = circle.radius * 0.2
        var rect = CGRect(
            x: circle.center.x - circle.radius - pad,
            y: circle.center.y - circle.radius - pad,
            width: (circle.radius + pad) * 2,
            height: (circle.radius + pad) * 2
        ).integral

        let maxRect = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        rect = rect.intersection(maxRect)
        guard let cropped = cgImage.cropping(to: rect) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: .up)
    }

    private func exportedFileURL() -> URL? {
        guard let pngData else { return nil }
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("purelabel-\(UUID().uuidString).png")
        do {
            try pngData.write(to: fileURL, options: .atomic)
            exportedTempURLs.append(fileURL)
            return fileURL
        } catch {
            statusText = "Failed to prepare file for sharing."
            return nil
        }
    }

    private func cleanupExportedFiles() {
        for url in exportedTempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        exportedTempURLs.removeAll()
        shareFileURL = nil
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
