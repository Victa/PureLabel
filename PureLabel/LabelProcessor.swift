import CoreImage
import SwiftUI
import Vision

struct DetectedCircle {
    var center: CGPoint
    var radius: CGFloat
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0xDEADBEEF : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

enum LabelProcessor {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private static var hasWarmedUp = false

    static func warmup() {
        guard !hasWarmedUp else { return }
        hasWarmedUp = true

        DispatchQueue.global(qos: .utility).async {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let cgImage = CGContext(
                data: nil,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage() else {
                return
            }

            let ciImage = CIImage(cgImage: cgImage)
            if let blurFilter = CIFilter(name: "CIGaussianBlur") {
                blurFilter.setValue(ciImage, forKey: kCIInputImageKey)
                blurFilter.setValue(1.0, forKey: kCIInputRadiusKey)
                if let blurred = blurFilter.outputImage {
                    _ = ciContext.createCGImage(blurred, from: blurred.extent)
                }
            }

            let request = VNDetectContoursRequest()
            request.maximumImageDimension = 64
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
        }
    }

    static func processLabel(
        from image: UIImage,
        circle: DetectedCircle,
        holeCenter: CGPoint,
        holeRadius: CGFloat
    ) -> (cutImage: UIImage?, pngData: Data?) {
        guard let processedImage = cutLabel(
            from: image,
            circle: circle,
            holeCenter: holeCenter,
            holeRadius: holeRadius
        ) else {
            return (nil, nil)
        }

        let exportImage = cropForExport(processedImage, circle: circle)
        return (processedImage, exportImage.pngData())
    }

    static func detectCircle(in image: UIImage) -> DetectedCircle? {
        guard let cgImage = image.fixedOrientation().cgImage else { return nil }

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let imageMin = min(width, height)

        guard let (contourImage, scaleX, scaleY) = preprocessedContourImage(from: cgImage) else { return nil }

        let workWidth = CGFloat(contourImage.width)
        let workHeight = CGFloat(contourImage.height)

        let request = VNDetectContoursRequest()
        request.contrastAdjustment = 1.0
        request.detectsDarkOnLight = false
        request.maximumImageDimension = 1024

        let handler = VNImageRequestHandler(cgImage: contourImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observation = request.results?.first else { return nil }

        var points: [CGPoint] = []
        collectPoints(from: observation.topLevelContours, points: &points, width: workWidth, height: workHeight)

        points = points.map { CGPoint(x: $0.x * scaleX, y: $0.y * scaleY) }

        if points.count < 80 { return nil }
        points = deterministicallySubsample(points, maxCount: 2400)

        let minRadius = imageMin * 0.12
        let maxRadius = imageMin * 0.58
        let iterations = 800
        let angularBins = 36
        let minScore: CGFloat = 0.18

        let centroid = centroid(of: points)
        let seed = deterministicSeed(width: width, height: height, pointCount: points.count)
        var rng = SeededGenerator(seed: seed)

        var bestCircle: DetectedCircle?
        var bestScore: CGFloat = 0

        for _ in 0..<iterations {
            guard let sample = sampleTriple(from: points, around: centroid, using: &rng) else { continue }
            guard let candidate = circle(from: sample.0, sample.1, sample.2) else { continue }
            if candidate.radius < minRadius || candidate.radius > maxRadius { continue }

            let tolerance = max(6.0, candidate.radius * 0.018)
            let (inlierCount, coverage) = scoreInliers(
                points: points,
                circle: candidate,
                tolerance: tolerance,
                binCount: angularBins
            )

            let inlierRatio = CGFloat(inlierCount) / CGFloat(points.count)
            let score = inlierRatio * 0.35 + coverage * 0.65

            if score > bestScore {
                bestScore = score
                bestCircle = candidate
            }
        }

        guard var circle = bestCircle else { return nil }
        if bestScore < minScore { return circle }

        let tolerance = max(6.0, circle.radius * 0.018)
        var inliers = collectInliers(points: points, circle: circle, tolerance: tolerance)
        if inliers.count >= 3, let refined = fitCircleLeastSquares(inliers) {
            circle = refined
            inliers = collectInliers(points: points, circle: circle, tolerance: tolerance)
            if inliers.count >= 3, let refinedAgain = fitCircleLeastSquares(inliers) {
                circle = refinedAgain
            }
        }

        if circle.radius < minRadius || circle.radius > maxRadius { return bestCircle }

        circle.center.x = max(0, min(width, circle.center.x))
        circle.center.y = max(0, min(height, circle.center.y))

        return circle
    }

    static func detectCenterHole(in image: UIImage, labelCircle: DetectedCircle) -> DetectedCircle? {
        guard let cgImage = image.fixedOrientation().cgImage,
              let bytes = cgImage.dataProvider?.data,
              let ptr = CFDataGetBytePtr(bytes) else {
            return nil
        }

        let bpp = cgImage.bitsPerPixel / 8
        guard bpp >= 3 else { return nil }

        let sampler = RadialLumaSampler(
            ptr: ptr,
            width: cgImage.width,
            height: cgImage.height,
            bpp: bpp,
            bpr: cgImage.bytesPerRow
        )

        let labelRadius = labelCircle.radius
        let maxOffset = labelRadius * 0.14
        let offsetFractions: [CGFloat] = stride(from: -0.12, through: 0.12, by: 0.04).map { $0 }

        var bestScore: CGFloat = 0
        var bestHole: DetectedCircle?

        for fractionX in offsetFractions {
            for fractionY in offsetFractions {
                let offsetX = fractionX * labelRadius
                let offsetY = fractionY * labelRadius
                guard hypot(offsetX, offsetY) <= maxOffset else { continue }

                let center = CGPoint(
                    x: labelCircle.center.x + offsetX,
                    y: labelCircle.center.y + offsetY
                )

                guard let candidate = scoreHoleRadius(at: center, labelRadius: labelRadius, sampler: sampler),
                      candidate.score > bestScore else {
                    continue
                }

                bestScore = candidate.score
                bestHole = DetectedCircle(center: center, radius: candidate.radius)
            }
        }

        guard var bestHole, bestScore > 0.07 else { return nil }

        // Refine center around the best coarse match.
        let refineFractions: [CGFloat] = [-0.03, 0, 0.03]
        for fractionX in refineFractions {
            for fractionY in refineFractions {
                let center = CGPoint(
                    x: bestHole.center.x + fractionX * labelRadius,
                    y: bestHole.center.y + fractionY * labelRadius
                )
                guard let candidate = scoreHoleRadius(at: center, labelRadius: labelRadius, sampler: sampler),
                      abs(candidate.radius - bestHole.radius) <= labelRadius * 0.06,
                      candidate.score >= bestScore * 0.92 else {
                    continue
                }

                if candidate.score > bestScore {
                    bestScore = candidate.score
                    bestHole = DetectedCircle(center: center, radius: candidate.radius)
                }
            }
        }

        return bestHole
    }

    static func detectCenterHoleRadius(in image: UIImage, labelCircle: DetectedCircle) -> CGFloat? {
        detectCenterHole(in: image, labelCircle: labelCircle)?.radius
    }

    private static func isFullVinylDisc(
        center: CGPoint,
        labelRadius: CGFloat,
        sampler: RadialLumaSampler
    ) -> Bool {
        guard let rimLuma = sampler.medianAnnulusLuma(
            center: center,
            innerRadius: labelRadius * 0.86,
            outerRadius: labelRadius * 0.98
        ) else {
            return false
        }

        return rimLuma < 0.30
    }

    private static func interiorIsLabelArt(
        center: CGPoint,
        radius: CGFloat,
        sampler: RadialLumaSampler
    ) -> Bool {
        guard let interiorLuma = sampler.medianDiskLuma(center: center, radius: radius * 0.72) else {
            return false
        }

        return interiorLuma > 0.36
    }

    private static func interiorIsVoid(
        center: CGPoint,
        radius: CGFloat,
        sampler: RadialLumaSampler
    ) -> Bool {
        guard let interiorLuma = sampler.medianDiskLuma(center: center, radius: radius * 0.68),
              let ringLuma = sampler.medianAnnulusLuma(
                center: center,
                innerRadius: radius * 0.72,
                outerRadius: radius * 0.92
              ) else {
            return false
        }

        let isGrayVoid = interiorLuma > 0.24 && interiorLuma < 0.72
        let isDarkVoid = interiorLuma < 0.24
        let outsideIsDarker = ringLuma < interiorLuma - 0.05 || ringLuma < 0.32
        return (isGrayVoid || isDarkVoid) && outsideIsDarker
    }

    private static func largestVoidHolePeak(
        from peaks: [(index: Int, radius: CGFloat, score: CGFloat)],
        center: CGPoint,
        labelRadius: CGFloat,
        sampler: RadialLumaSampler,
        minScore: CGFloat
    ) -> (index: Int, radius: CGFloat, score: CGFloat)? {
        peaks
            .filter { peak in
                peak.score >= minScore
                    && peak.radius / labelRadius >= 0.18
                    && interiorIsVoid(center: center, radius: peak.radius, sampler: sampler)
            }
            .max(by: { $0.radius < $1.radius })
    }

    private static func scoreHoleRadius(
        at center: CGPoint,
        labelRadius: CGFloat,
        sampler: RadialLumaSampler
    ) -> (radius: CGFloat, score: CGFloat)? {
        // LP spindle holes are ~3–8% of label radius; 7-inch 45 RPM holes can reach ~45%.
        let minRadius = max(2.0, labelRadius * 0.012)
        let maxRadius = max(minRadius + 2.0, labelRadius * 0.50)
        let stepCount = 64
        let ringHalfWidth = max(1.5, labelRadius * 0.007)

        var radii: [CGFloat] = []
        var scores: [CGFloat] = []
        radii.reserveCapacity(stepCount)
        scores.reserveCapacity(stepCount)

        for index in 0..<stepCount {
            let t = CGFloat(index) / CGFloat(max(stepCount - 1, 1))
            let radius = minRadius + (maxRadius - minRadius) * t

            guard let innerLuma = sampler.medianDiskLuma(center: center, radius: radius * 0.42),
                  let edgeLuma = sampler.medianRingLuma(center: center, radius: radius, halfWidth: ringHalfWidth),
                  let outerLuma = sampler.medianAnnulusLuma(
                    center: center,
                    innerRadius: radius * 1.06,
                    outerRadius: radius * 1.24
                  ) else {
                continue
            }

            let interiorToEdge = abs(edgeLuma - innerLuma)
            let edgeToLabel = abs(outerLuma - edgeLuma)
            let holeToLabel = abs(outerLuma - innerLuma)
            let contrast = max(interiorToEdge, edgeToLabel, holeToLabel)

            guard contrast > 0.03 else { continue }

            let interiorExtremity = max(innerLuma, 1 - innerLuma)
            let edgeSharpness = abs((outerLuma - innerLuma) - (edgeLuma - innerLuma) * 0.5)
            var score = contrast * (0.45 + 0.35 * interiorExtremity + 0.20 * min(1, edgeSharpness * 4))

            if outerLuma < 0.32, innerLuma > outerLuma + 0.06, radius / labelRadius >= 0.18 {
                score *= 1.35
            }

            radii.append(radius)
            scores.append(score)
        }

        guard !scores.isEmpty else { return nil }

        var peaks: [(index: Int, radius: CGFloat, score: CGFloat)] = []
        for index in scores.indices {
            let leftOK = index == 0 || scores[index] >= scores[index - 1]
            let rightOK = index == scores.count - 1 || scores[index] >= scores[index + 1]
            guard leftOK, rightOK, scores[index] > 0.06 else { continue }
            peaks.append((index, radii[index], scores[index]))
        }

        guard !peaks.isEmpty else { return nil }

        let maxScore = peaks.map(\.score).max() ?? 0
        let strongPeaks = peaks.filter { $0.score >= maxScore * 0.68 }
        let peakIndex: Int

        let peakRatio: ((index: Int, radius: CGFloat, score: CGFloat)) -> CGFloat = { $0.radius / labelRadius }
        let smallPeaks = strongPeaks.filter { peakRatio($0) <= 0.11 }
        let largePeaks = strongPeaks.filter { peakRatio($0) >= 0.18 && peakRatio($0) <= 0.52 }

        let fullVinylDisc = isFullVinylDisc(
            center: center,
            labelRadius: labelRadius,
            sampler: sampler
        )

        if fullVinylDisc,
           let voidHole = largestVoidHolePeak(
                from: largePeaks,
                center: center,
                labelRadius: labelRadius,
                sampler: sampler,
                minScore: maxScore * 0.58
           ) {
            peakIndex = voidHole.index
        } else if let largeHole = largePeaks.max(by: { $0.radius < $1.radius }),
                  interiorIsLabelArt(
                    center: center,
                    radius: largeHole.radius,
                    sampler: sampler
                  ),
                  let smallHole = smallPeaks.max(by: { $0.score < $1.score }) {
            // Paper label sticker: don't punch out the artwork — keep the spindle hole.
            peakIndex = smallHole.index
        } else if let dieCutHole = largePeaks
            .filter({
                interiorIsVoid(
                    center: center,
                    radius: $0.radius,
                    sampler: sampler
                ) && $0.score >= maxScore * 0.62
            })
            .max(by: { $0.radius < $1.radius }) {
            // 7-inch paper label with a wide die-cut center opening.
            peakIndex = dieCutHole.index
        } else if let smallHole = smallPeaks.max(by: { $0.score < $1.score }),
                  smallHole.score >= maxScore * 0.70 {
            peakIndex = smallHole.index
        } else {
            peakIndex = strongPeaks.max(by: { $0.score < $1.score })?.index
                ?? peaks.max(by: { $0.score < $1.score })!.index
        }

        let peakScore = scores[peakIndex]
        let peakRadius = radii[peakIndex]

        if peakIndex > 0, peakIndex + 1 < radii.count {
            let left = scores[peakIndex - 1]
            let centerScore = scores[peakIndex]
            let right = scores[peakIndex + 1]
            let denominator = left - 2 * centerScore + right
            if abs(denominator) > 0.0001 {
                let offset = 0.5 * (left - right) / denominator
                let clampedOffset = max(-0.5, min(0.5, offset))
                let step = radii[1] - radii[0]
                return (max(1.0, peakRadius + clampedOffset * step), peakScore)
            }
        }

        return (max(1.0, peakRadius), peakScore)
    }

    static func cutLabel(from image: UIImage, circle: DetectedCircle, holeCenter: CGPoint, holeRadius: CGFloat) -> UIImage? {
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
                    x: holeCenter.x - holeRadius,
                    y: holeCenter.y - holeRadius,
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

    private static func cropForExport(_ image: UIImage, circle: DetectedCircle) -> UIImage {
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

    private static func preprocessedContourImage(from cgImage: CGImage) -> (CGImage, CGFloat, CGFloat)? {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let maxDim: CGFloat = 1024
        let scale = min(1.0, maxDim / max(width, height))

        let ciImage = CIImage(cgImage: cgImage)
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = scaled.extent.integral

        let blurRadius = max(2.0, min(extent.width, extent.height) * 0.004)
        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { return nil }
        blurFilter.setValue(scaled, forKey: kCIInputImageKey)
        blurFilter.setValue(blurRadius, forKey: kCIInputRadiusKey)
        guard let blurred = blurFilter.outputImage?.cropped(to: extent) else { return nil }

        guard let output = ciContext.createCGImage(blurred, from: extent) else { return nil }

        let scaleX = width / CGFloat(output.width)
        let scaleY = height / CGFloat(output.height)
        return (output, scaleX, scaleY)
    }

    private static func deterministicallySubsample(_ points: [CGPoint], maxCount: Int) -> [CGPoint] {
        guard points.count > maxCount else { return points }
        let stride = max(1, points.count / maxCount)
        var sampled: [CGPoint] = []
        sampled.reserveCapacity(maxCount)
        var index = 0
        while index < points.count {
            sampled.append(points[index])
            index += stride
        }
        return sampled
    }

    private static func deterministicSeed(width: CGFloat, height: CGFloat, pointCount: Int) -> UInt64 {
        let w = UInt64(bitPattern: Int64(width.rounded()))
        let h = UInt64(bitPattern: Int64(height.rounded()))
        let c = UInt64(pointCount)
        return w &* 1_103_515_245 &+ h &* 1_234_567_891 &+ c &* 2_654_435_769 &+ 0xA5A5_5A5A_A5A5_5A5A
    }

    private static func centroid(of points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        for p in points {
            sumX += p.x
            sumY += p.y
        }
        let count = CGFloat(points.count)
        return CGPoint(x: sumX / count, y: sumY / count)
    }

    private static func sampleTriple(
        from points: [CGPoint],
        around center: CGPoint,
        using rng: inout SeededGenerator
    ) -> (CGPoint, CGPoint, CGPoint)? {
        guard points.count >= 3 else { return nil }

        let firstIndex = Int.random(in: 0..<points.count, using: &rng)
        let first = points[firstIndex]
        let angle1 = angle(from: center, to: first)

        var second: CGPoint?
        for _ in 0..<24 {
            let candidate = points[Int.random(in: 0..<points.count, using: &rng)]
            if candidate == first { continue }
            let delta = angularDistance(angle1, angle(from: center, to: candidate))
            if delta >= .pi / 3 {
                second = candidate
                break
            }
        }
        guard let second else { return nil }

        let angle2 = angle(from: center, to: second)
        var third: CGPoint?
        for _ in 0..<24 {
            let candidate = points[Int.random(in: 0..<points.count, using: &rng)]
            if candidate == first || candidate == second { continue }
            let candidateAngle = angle(from: center, to: candidate)
            if angularDistance(angle1, candidateAngle) >= .pi / 3,
               angularDistance(angle2, candidateAngle) >= .pi / 3 {
                third = candidate
                break
            }
        }
        guard let third else { return nil }
        return (first, second, third)
    }

    private static func angle(from center: CGPoint, to point: CGPoint) -> CGFloat {
        atan2(point.y - center.y, point.x - center.x)
    }

    private static func angularDistance(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        var delta = abs(a - b)
        if delta > .pi { delta = (2 * .pi) - delta }
        return delta
    }

    private static func scoreInliers(
        points: [CGPoint],
        circle: DetectedCircle,
        tolerance: CGFloat,
        binCount: Int
    ) -> (Int, CGFloat) {
        var inlierCount = 0
        var bins = [Bool](repeating: false, count: binCount)

        for p in points {
            let d = hypot(p.x - circle.center.x, p.y - circle.center.y)
            guard abs(d - circle.radius) <= tolerance else { continue }
            inlierCount += 1
            let theta = angle(from: circle.center, to: p)
            let normalized = (theta + .pi) / (2 * .pi)
            let bin = min(binCount - 1, max(0, Int(normalized * CGFloat(binCount))))
            bins[bin] = true
        }

        let populatedBins = bins.filter { $0 }.count
        let coverage = CGFloat(populatedBins) / CGFloat(binCount)
        return (inlierCount, coverage)
    }

    private static func collectInliers(points: [CGPoint], circle: DetectedCircle, tolerance: CGFloat) -> [CGPoint] {
        points.filter { p in
            let d = hypot(p.x - circle.center.x, p.y - circle.center.y)
            return abs(d - circle.radius) <= tolerance
        }
    }

    private static func fitCircleLeastSquares(_ points: [CGPoint]) -> DetectedCircle? {
        guard points.count >= 3 else { return nil }

        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        var sumXX: CGFloat = 0
        var sumYY: CGFloat = 0
        var sumXY: CGFloat = 0
        var sumXZ: CGFloat = 0
        var sumYZ: CGFloat = 0
        var sumZ: CGFloat = 0

        for p in points {
            let x = p.x
            let y = p.y
            let z = x * x + y * y
            sumX += x
            sumY += y
            sumXX += x * x
            sumYY += y * y
            sumXY += x * y
            sumXZ += x * z
            sumYZ += y * z
            sumZ += z
        }

        let n = CGFloat(points.count)
        let a11 = sumXX
        let a12 = sumXY
        let a13 = sumX
        let a21 = sumXY
        let a22 = sumYY
        let a23 = sumY
        let a31 = sumX
        let a32 = sumY
        let a33 = n
        let b1 = -sumXZ
        let b2 = -sumYZ
        let b3 = -sumZ

        guard let det = invert3x3(
            a11, a12, a13,
            a21, a22, a23,
            a31, a32, a33
        ) else { return nil }

        let d = det.0 * b1 + det.1 * b2 + det.2 * b3
        let e = det.3 * b1 + det.4 * b2 + det.5 * b3
        let f = det.6 * b1 + det.7 * b2 + det.8 * b3

        let centerX = -d / 2
        let centerY = -e / 2
        let radiusSquared = centerX * centerX + centerY * centerY - f
        guard radiusSquared.isFinite, radiusSquared > 0 else { return nil }

        let radius = sqrt(radiusSquared)
        guard radius.isFinite, radius > 0 else { return nil }

        return DetectedCircle(center: CGPoint(x: centerX, y: centerY), radius: radius)
    }

    private static func invert3x3(
        _ a11: CGFloat, _ a12: CGFloat, _ a13: CGFloat,
        _ a21: CGFloat, _ a22: CGFloat, _ a23: CGFloat,
        _ a31: CGFloat, _ a32: CGFloat, _ a33: CGFloat
    ) -> (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)? {
        let det =
            a11 * (a22 * a33 - a23 * a32) -
            a12 * (a21 * a33 - a23 * a31) +
            a13 * (a21 * a32 - a22 * a31)

        guard abs(det) > 1e-8 else { return nil }

        let invDet = 1 / det
        return (
            (a22 * a33 - a23 * a32) * invDet,
            (a13 * a32 - a12 * a33) * invDet,
            (a12 * a23 - a13 * a22) * invDet,
            (a23 * a31 - a21 * a33) * invDet,
            (a11 * a33 - a13 * a31) * invDet,
            (a13 * a21 - a11 * a23) * invDet,
            (a21 * a32 - a22 * a31) * invDet,
            (a12 * a31 - a11 * a32) * invDet,
            (a11 * a22 - a12 * a21) * invDet
        )
    }

    fileprivate static func median(of values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    private static func smoothProfile(_ values: [CGFloat], window: Int) -> [CGFloat] {
        guard window > 1, values.count >= window else { return values }
        let half = window / 2
        return values.indices.map { index in
            let start = max(0, index - half)
            let end = min(values.count - 1, index + half)
            let slice = values[start...end]
            return slice.reduce(0, +) / CGFloat(slice.count)
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

private struct RadialLumaSampler {
    let ptr: UnsafePointer<UInt8>
    let width: Int
    let height: Int
    let bpp: Int
    let bpr: Int

    func medianDiskLuma(center: CGPoint, radius: CGFloat) -> CGFloat? {
        guard radius > 0 else { return nil }

        var samples: [CGFloat] = []
        let radialSteps = max(3, Int(radius / 2))
        let angleSamples = 20
        samples.reserveCapacity(radialSteps * angleSamples)

        for radialIndex in 1...radialSteps {
            let r = radius * CGFloat(radialIndex) / CGFloat(radialSteps)
            collectRingSamples(center: center, radius: r, angleSamples: angleSamples, into: &samples)
        }

        guard samples.count >= 8 else { return nil }
        return LabelProcessor.median(of: samples)
    }

    func medianRingLuma(center: CGPoint, radius: CGFloat, halfWidth: CGFloat) -> CGFloat? {
        guard radius > 0, halfWidth > 0 else { return nil }

        var samples: [CGFloat] = []
        samples.reserveCapacity(96)
        let angleSamples = 48
        let widthSteps = max(2, Int(halfWidth * 2))

        for widthIndex in 0..<widthSteps {
            let offset = -halfWidth + (CGFloat(widthIndex) + 0.5) * (2 * halfWidth / CGFloat(widthSteps))
            collectRingSamples(center: center, radius: radius + offset, angleSamples: angleSamples, into: &samples)
        }

        guard samples.count >= 12 else { return nil }
        return LabelProcessor.median(of: samples)
    }

    func medianAnnulusLuma(center: CGPoint, innerRadius: CGFloat, outerRadius: CGFloat) -> CGFloat? {
        guard outerRadius > innerRadius, innerRadius > 0 else { return nil }

        var samples: [CGFloat] = []
        let radialSteps = max(2, Int(outerRadius - innerRadius))
        let angleSamples = 36
        samples.reserveCapacity(radialSteps * angleSamples)

        for radialIndex in 0..<radialSteps {
            let t = CGFloat(radialIndex + 1) / CGFloat(radialSteps + 1)
            let radius = innerRadius + (outerRadius - innerRadius) * t
            collectRingSamples(center: center, radius: radius, angleSamples: angleSamples, into: &samples)
        }

        guard samples.count >= 12 else { return nil }
        return LabelProcessor.median(of: samples)
    }

    private func collectRingSamples(
        center: CGPoint,
        radius: CGFloat,
        angleSamples: Int,
        into samples: inout [CGFloat]
    ) {
        for angleIndex in 0..<angleSamples {
            let angle = (2 * CGFloat.pi * CGFloat(angleIndex)) / CGFloat(angleSamples)
            let x = Int((center.x + cos(angle) * radius).rounded())
            let y = Int((center.y + sin(angle) * radius).rounded())
            guard x >= 0, y >= 0, x < width, y < height else { continue }
            let offset = y * bpr + x * bpp
            let red = CGFloat(ptr[offset]) / 255.0
            let green = CGFloat(ptr[offset + 1]) / 255.0
            let blue = CGFloat(ptr[offset + 2]) / 255.0
            samples.append(0.2126 * red + 0.7152 * green + 0.0722 * blue)
        }
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
