import CoreImage
import SwiftUI
import Vision

struct DetectedCircle {
    var center: CGPoint
    var radius: CGFloat
}

enum LabelProcessor {
    static func detectCircle(in image: UIImage) -> DetectedCircle? {
        guard let cgImage = image.fixedOrientation().cgImage else { return nil }

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)

        let request = VNDetectContoursRequest()
        request.contrastAdjustment = 1.0
        request.detectsDarkOnLight = false
        request.maximumImageDimension = 1024

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observation = request.results?.first else { return nil }

        var points: [CGPoint] = []
        collectPoints(from: observation.topLevelContours, points: &points, width: width, height: height)

        if points.count < 80 { return nil }
        if points.count > 1800 {
            points.shuffle()
            points = Array(points.prefix(1800))
        }

        let minRadius = min(width, height) * 0.18
        let maxRadius = min(width, height) * 0.52
        let iterations = 450
        var bestCircle: DetectedCircle?
        var bestInliers = 0

        for _ in 0..<iterations {
            guard let a = points.randomElement(), let b = points.randomElement(), let c = points.randomElement() else { continue }
            if a == b || b == c || a == c { continue }
            guard let candidate = circle(from: a, b, c) else { continue }
            if candidate.radius < minRadius || candidate.radius > maxRadius { continue }

            let tolerance = max(6.0, candidate.radius * 0.018)
            var inliers = 0
            for p in points {
                let d = hypot(p.x - candidate.center.x, p.y - candidate.center.y)
                if abs(d - candidate.radius) <= tolerance {
                    inliers += 1
                }
            }

            if inliers > bestInliers {
                bestInliers = inliers
                bestCircle = candidate
            }
        }

        guard var circle = bestCircle else { return nil }
        if bestInliers < 90 { return nil }

        circle.center.x = max(0, min(width, circle.center.x))
        circle.center.y = max(0, min(height, circle.center.y))

        return circle
    }

    static func detectCenterHoleRadius(in image: UIImage, labelCircle: DetectedCircle) -> CGFloat? {
        guard let cgImage = image.fixedOrientation().cgImage,
              let bytes = cgImage.dataProvider?.data,
              let ptr = CFDataGetBytePtr(bytes) else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        let bpp = cgImage.bitsPerPixel / 8
        let bpr = cgImage.bytesPerRow
        if bpp < 3 { return nil }

        let minR = max(2.0, labelCircle.radius * 0.03)
        let maxR = max(minR + 2.0, labelCircle.radius * 0.12)
        let steps = max(12, Int(maxR - minR))
        let angleSamples = 48

        var ringLuma: [CGFloat] = []
        ringLuma.reserveCapacity(steps)

        for i in 0..<steps {
            let t = CGFloat(i) / CGFloat(max(steps - 1, 1))
            let r = minR + (maxR - minR) * t
            var sum: CGFloat = 0
            var count: CGFloat = 0

            for k in 0..<angleSamples {
                let a = (2.0 * CGFloat.pi * CGFloat(k)) / CGFloat(angleSamples)
                let x = labelCircle.center.x + cos(a) * r
                let y = labelCircle.center.y + sin(a) * r
                let xi = Int(x.rounded())
                let yi = Int(y.rounded())
                guard xi >= 0, yi >= 0, xi < width, yi < height else { continue }
                let offset = yi * bpr + xi * bpp
                let rr = CGFloat(ptr[offset + 0]) / 255.0
                let gg = CGFloat(ptr[offset + 1]) / 255.0
                let bb = CGFloat(ptr[offset + 2]) / 255.0
                let luma = 0.2126 * rr + 0.7152 * gg + 0.0722 * bb
                sum += luma
                count += 1
            }

            ringLuma.append(count > 0 ? sum / count : 0)
        }

        if ringLuma.count < 4 { return nil }

        var bestJump: CGFloat = 0
        var bestIndex = 0
        for i in 0..<(ringLuma.count - 1) {
            let jump = ringLuma[i + 1] - ringLuma[i]
            if jump > bestJump {
                bestJump = jump
                bestIndex = i
            }
        }

        guard bestJump > 0.03 else { return nil }

        let t = CGFloat(bestIndex) / CGFloat(max(steps - 1, 1))
        let radius = minR + (maxR - minR) * t
        return max(1.0, radius)
    }

    static func cutLabel(from image: UIImage, circle: DetectedCircle, holeRadius: CGFloat) -> UIImage? {
        let fixed = image.fixedOrientation()
        let size = fixed.size
        let bounds = CGRect(origin: .zero, size: size)

        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        format.scale = fixed.scale

        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.image { context in
            UIColor.clear.setFill()
            context.fill(bounds)

            let cg = context.cgContext
            let outerRect = CGRect(
                x: circle.center.x - circle.radius,
                y: circle.center.y - circle.radius,
                width: circle.radius * 2,
                height: circle.radius * 2
            )
            cg.addEllipse(in: outerRect)
            if holeRadius > 0 {
                let innerRect = CGRect(
                    x: circle.center.x - holeRadius,
                    y: circle.center.y - holeRadius,
                    width: holeRadius * 2,
                    height: holeRadius * 2
                )
                cg.addEllipse(in: innerRect)
                cg.setFillColor(UIColor.black.cgColor)
                cg.clip(using: .evenOdd)
            } else {
                cg.clip()
            }
            fixed.draw(in: bounds)
        }
    }

    private static func collectPoints(from contours: [VNContour], points: inout [CGPoint], width: CGFloat, height: CGFloat) {
        for contour in contours {
            for p in contour.normalizedPoints {
                let x = CGFloat(p.x) * width
                let y = (1.0 - CGFloat(p.y)) * height
                points.append(CGPoint(x: x, y: y))
            }
            if !contour.childContours.isEmpty {
                collectPoints(from: contour.childContours, points: &points, width: width, height: height)
            }
        }
    }

    private static func circle(from p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) -> DetectedCircle? {
        let x1 = p1.x, y1 = p1.y
        let x2 = p2.x, y2 = p2.y
        let x3 = p3.x, y3 = p3.y

        let d = 2 * (x1 * (y2 - y3) + x2 * (y3 - y1) + x3 * (y1 - y2))
        if abs(d) < 0.001 { return nil }

        let ux = ((x1 * x1 + y1 * y1) * (y2 - y3) +
                  (x2 * x2 + y2 * y2) * (y3 - y1) +
                  (x3 * x3 + y3 * y3) * (y1 - y2)) / d

        let uy = ((x1 * x1 + y1 * y1) * (x3 - x2) +
                  (x2 * x2 + y2 * y2) * (x1 - x3) +
                  (x3 * x3 + y3 * y3) * (x2 - x1)) / d

        let center = CGPoint(x: ux, y: uy)
        let radius = hypot(center.x - x1, center.y - y1)
        if !radius.isFinite || radius <= 0 { return nil }

        return DetectedCircle(center: center, radius: radius)
    }
}

private extension UIImage {
    func fixedOrientation() -> UIImage {
        if imageOrientation == .up { return self }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
