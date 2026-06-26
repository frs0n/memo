import ARKit
import CoreImage
import Foundation
import ImageIO
import simd
import UIKit

struct CaptureIngestResult: Sendable {
    var didAcceptKeyframe: Bool
    var statusText: String
}

struct CaptureSessionPackage: Hashable, Sendable {
    var rootURL: URL
    var pointCloudURL: URL
    var thumbnailURL: URL
    var keyframeCount: Int
    var pointCount: Int
}

final class GSScanRecorder {
    private let fileManager = FileManager.default
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let jpegColorSpace = CGColorSpaceCreateDeviceRGB()
    private let minimumDisplacement: Float = 0.05
    private let minimumSharpness: Double = 7.5
    private let minimumDepthCoverage: Double = 0.16
    private let minimumHighConfidenceDepthRatio: Double = 0.28
    private let candidateWindowSize = 8
    private let depthSampleStride = 3
    private let maximumPointCount = 700_000
    private let pointVoxelSize: Float = 0.012
    private let minimumConsistentDepthNeighbors = 2

    private var rootURL: URL?
    private var imagesURL: URL?
    private var sparseURL: URL?
    private var depthURL: URL?
    private var framesLog: FileHandle?
    private var camerasText = "# CAMERA_ID, MODEL, WIDTH, HEIGHT, PARAMS[]\n"
    private var imagesText = "# IMAGE_ID, QW, QX, QY, QZ, TX, TY, TZ, CAMERA_ID, NAME\n# POINTS2D[] as X, Y, POINT3D_ID\n"
    private var points: [PLYPoint] = []
    private var pointVoxels: [PointVoxelKey: PointVoxelAccumulator] = [:]
    private var candidateWindow: [KeyframeCandidate] = []
    private var lastKeyframePosition: SIMD3<Float>?
    private var frameIndex = 0
    private(set) var keyframeCount = 0

    func begin() throws {
        let sessionName = "memo_scan_\(Self.timestamp())"
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(sessionName, isDirectory: true)

        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }

        let images = root.appendingPathComponent("images", isDirectory: true)
        let sparse = root.appendingPathComponent("sparse/0", isDirectory: true)
        let arkit = root.appendingPathComponent("arkit", isDirectory: true)
        let depth = root.appendingPathComponent("depth", isDirectory: true)

        try fileManager.createDirectory(at: images, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sparse, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: arkit, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: depth, withIntermediateDirectories: true)

        let framesLogURL = arkit.appendingPathComponent("frames.jsonl")
        fileManager.createFile(atPath: framesLogURL.path, contents: nil)
        framesLog = try FileHandle(forWritingTo: framesLogURL)

        rootURL = root
        imagesURL = images
        sparseURL = sparse
        depthURL = depth
        camerasText = "# CAMERA_ID, MODEL, WIDTH, HEIGHT, PARAMS[]\n"
        imagesText = "# IMAGE_ID, QW, QX, QY, QZ, TX, TY, TZ, CAMERA_ID, NAME\n# POINTS2D[] as X, Y, POINT3D_ID\n"
        points.removeAll(keepingCapacity: true)
        pointVoxels.removeAll(keepingCapacity: true)
        candidateWindow.removeAll(keepingCapacity: true)
        lastKeyframePosition = nil
        frameIndex = 0
        keyframeCount = 0
    }

    func ingest(frame: ARFrame) -> CaptureIngestResult {
        guard rootURL != nil else {
            return CaptureIngestResult(didAcceptKeyframe: false, statusText: "Not ready")
        }

        frameIndex += 1
        let currentFrameIndex = frameIndex

        guard frame.camera.trackingState.isNormal else {
            appendFrameMetadata(frame, quality: nil)
            return CaptureIngestResult(didAcceptKeyframe: false, statusText: "Tracking")
        }

        let quality = measureFrameQuality(frame)
        appendFrameMetadata(frame, quality: quality)

        if lastKeyframePosition != nil {
            guard quality.displacement >= minimumDisplacement else {
                return CaptureIngestResult(didAcceptKeyframe: false, statusText: "Move for parallax")
            }
        }

        guard quality.sharpness >= minimumSharpness else {
            return CaptureIngestResult(didAcceptKeyframe: false, statusText: "Too blurry")
        }

        guard quality.depthCoverage >= minimumDepthCoverage,
              quality.highConfidenceDepthRatio >= minimumHighConfidenceDepthRatio else {
            return CaptureIngestResult(didAcceptKeyframe: false, statusText: "Find depth")
        }

        guard let candidate = makeCandidate(from: frame, frameIndex: currentFrameIndex, quality: quality) else {
            return CaptureIngestResult(didAcceptKeyframe: false, statusText: "Selecting")
        }

        candidateWindow.append(candidate)
        if candidateWindow.count >= candidateWindowSize {
            guard commitBestCandidate() else {
                return CaptureIngestResult(didAcceptKeyframe: false, statusText: "Saving")
            }
            return CaptureIngestResult(didAcceptKeyframe: true, statusText: "Recording")
        }

        return CaptureIngestResult(didAcceptKeyframe: false, statusText: "Selecting")
    }

    func finish() throws -> CaptureSessionPackage {
        guard let rootURL, let sparseURL, let depthURL else {
            throw CaptureSessionError.noActiveCapture
        }

        _ = commitBestCandidate()

        try framesLog?.close()
        framesLog = nil
        points = fusedPointCloud()

        try camerasText.write(to: sparseURL.appendingPathComponent("cameras.txt"), atomically: true, encoding: .utf8)
        try imagesText.write(to: sparseURL.appendingPathComponent("images.txt"), atomically: true, encoding: .utf8)
        let pointCloudURL = depthURL.appendingPathComponent("fused_points.ply")
        try writePLY(to: pointCloudURL)
        try writeManifest(to: rootURL.appendingPathComponent("capture.json"))

        return CaptureSessionPackage(
            rootURL: rootURL,
            pointCloudURL: pointCloudURL,
            thumbnailURL: rootURL.appendingPathComponent("thumbnail.jpg"),
            keyframeCount: keyframeCount,
            pointCount: points.count
        )
    }

    private func makeCandidate(from frame: ARFrame, frameIndex: Int, quality: FrameQuality) -> KeyframeCandidate? {
        guard let jpeg = jpegData(from: frame.capturedImage) else { return nil }

        let depthSample = sampleDepthPoints(from: frame)
        guard !depthSample.points.isEmpty else { return nil }

        let thumbnail = keyframeCount == 0 ? thumbnailData(from: frame.capturedImage) : nil
        return KeyframeCandidate(
            frameIndex: frameIndex,
            timestamp: frame.timestamp,
            resolution: [
                CVPixelBufferGetWidth(frame.capturedImage),
                CVPixelBufferGetHeight(frame.capturedImage)
            ],
            intrinsics: frame.camera.intrinsics,
            transform: frame.camera.transform,
            jpegData: jpeg,
            thumbnailData: thumbnail,
            depthPoints: depthSample.points,
            quality: quality.withDepthStats(depthSample.stats)
        )
    }

    private func commitBestCandidate() -> Bool {
        guard let bestIndex = candidateWindow.indices.max(by: {
            candidateWindow[$0].quality.sharpness < candidateWindow[$1].quality.sharpness
        }) else {
            return false
        }

        let candidate = candidateWindow[bestIndex]
        candidateWindow.removeAll(keepingCapacity: true)

        guard writeKeyframe(candidate) else { return false }
        appendDepthPoints(candidate.depthPoints)
        lastKeyframePosition = candidate.transform.translation
        return true
    }

    private func writeKeyframe(_ candidate: KeyframeCandidate) -> Bool {
        guard let imagesURL else { return false }

        let imageName = String(format: "frame_%06d.jpg", keyframeCount + 1)
        let imageURL = imagesURL.appendingPathComponent(imageName)

        do {
            try candidate.jpegData.write(to: imageURL, options: .atomic)
            if keyframeCount == 0, let rootURL, let thumbnailData = candidate.thumbnailData {
                try thumbnailData.write(to: rootURL.appendingPathComponent("thumbnail.jpg"), options: .atomic)
            }
            keyframeCount += 1

            let intrinsics = candidate.intrinsics
            let cameraID = keyframeCount
            camerasText += "\(cameraID) PINHOLE \(candidate.resolution[0]) \(candidate.resolution[1]) \(intrinsics[0, 0]) \(intrinsics[1, 1]) \(intrinsics[2, 0]) \(intrinsics[2, 1])\n"

            let worldToCamera = candidate.transform.inverse
            let q = Quaternion(matrix: worldToCamera.rotationMatrix)
            let t = worldToCamera.translation
            imagesText += "\(keyframeCount) \(q.w) \(q.x) \(q.y) \(q.z) \(t.x) \(t.y) \(t.z) \(cameraID) \(imageName)\n\n"

            appendAcceptedMetadata(candidate, imageName: imageName)
            return true
        } catch {
            return false
        }
    }

    private func jpegData(from pixelBuffer: CVPixelBuffer) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        return ciContext.jpegRepresentation(
            of: ciImage,
            colorSpace: jpegColorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.94]
        )
    }

    private func thumbnailData(from pixelBuffer: CVPixelBuffer) -> Data? {
        let source = CIImage(cvPixelBuffer: pixelBuffer).oriented(Self.thumbnailOrientation())
        let extent = source.extent
        let maximumSide: CGFloat = 900
        let scale = min(maximumSide / max(extent.width, extent.height), 1)
        let resized = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = ciContext.createCGImage(resized, from: resized.extent) else { return nil }

        let size = CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.82)
    }

    private static func thumbnailOrientation() -> CGImagePropertyOrientation {
        switch UIDevice.current.orientation {
        case .landscapeLeft:
            return .up
        case .landscapeRight:
            return .down
        case .portraitUpsideDown:
            return .left
        default:
            return .right
        }
    }

    private func appendFrameMetadata(_ frame: ARFrame, quality: FrameQuality?) {
        let payload = FrameMetadata(
            index: frameIndex,
            timestamp: frame.timestamp,
            acceptedKeyframe: false,
            imageName: nil,
            trackingState: frame.camera.trackingState.description,
            resolution: [
                CVPixelBufferGetWidth(frame.capturedImage),
                CVPixelBufferGetHeight(frame.capturedImage)
            ],
            intrinsics: frame.camera.intrinsics.array,
            transform: frame.camera.transform.array,
            sharpness: quality?.sharpness,
            depthCoverage: quality?.depthCoverage,
            highConfidenceDepthRatio: quality?.highConfidenceDepthRatio,
            displacement: quality?.displacement,
            sharpnessRankScore: quality?.sharpness
        )
        appendJSONLine(payload)
    }

    private func appendAcceptedMetadata(_ candidate: KeyframeCandidate, imageName: String) {
        let payload = FrameMetadata(
            index: candidate.frameIndex,
            timestamp: candidate.timestamp,
            acceptedKeyframe: true,
            imageName: imageName,
            trackingState: "normal",
            resolution: candidate.resolution,
            intrinsics: candidate.intrinsics.array,
            transform: candidate.transform.array,
            sharpness: candidate.quality.sharpness,
            depthCoverage: candidate.quality.depthCoverage,
            highConfidenceDepthRatio: candidate.quality.highConfidenceDepthRatio,
            displacement: candidate.quality.displacement,
            sharpnessRankScore: candidate.quality.sharpness
        )
        appendJSONLine(payload)
    }

    private func appendJSONLine<T: Encodable>(_ value: T) {
        guard let data = try? JSONEncoder.capture.encode(value),
              let newline = "\n".data(using: .utf8) else {
            return
        }
        try? framesLog?.write(contentsOf: data)
        try? framesLog?.write(contentsOf: newline)
    }

    private func appendDepthPoints(_ newPoints: [PLYPoint]) {
        guard pointVoxels.count < maximumPointCount else { return }

        for point in newPoints {
            let key = PointVoxelKey(point: point, voxelSize: pointVoxelSize)
            if var accumulator = pointVoxels[key] {
                accumulator.add(point)
                pointVoxels[key] = accumulator
            } else if pointVoxels.count < maximumPointCount {
                pointVoxels[key] = PointVoxelAccumulator(point)
            } else {
                break
            }
        }
    }

    private func fusedPointCloud() -> [PLYPoint] {
        let observedMoreThanOnce = pointVoxels.values.filter { $0.observationCount > 1 }
        let source = observedMoreThanOnce.count >= max(keyframeCount * 1_000, 12_000)
            ? observedMoreThanOnce
            : Array(pointVoxels.values)

        return source
            .sorted {
                if $0.observationCount != $1.observationCount {
                    return $0.observationCount > $1.observationCount
                }
                return $0.sortKey < $1.sortKey
            }
            .prefix(maximumPointCount)
            .map { $0.point }
    }

    private func measureFrameQuality(_ frame: ARFrame) -> FrameQuality {
        let sharpness = Self.gradientSharpness(frame.capturedImage)
        let depthStats = measureDepthStats(from: frame, stride: depthSampleStride * 2)
        let position = frame.camera.transform.translation
        let displacement = lastKeyframePosition.map { simd_distance(position, $0) } ?? 0

        return FrameQuality(
            sharpness: sharpness,
            depthCoverage: depthStats.coverage,
            highConfidenceDepthRatio: depthStats.highConfidenceRatio,
            displacement: displacement
        )
    }

    private func measureDepthStats(from frame: ARFrame, stride sampleStride: Int) -> DepthStats {
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return .empty }

        let depthMap = depthData.depthMap
        let confidenceMap = depthData.confidenceMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        if let confidenceMap {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        }
        defer {
            if let confidenceMap {
                CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
            }
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
        }

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap)?.assumingMemoryBound(to: Float32.self) else {
            return .empty
        }

        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        let depthStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.size
        let confidenceBase = confidenceMap.flatMap { CVPixelBufferGetBaseAddress($0)?.assumingMemoryBound(to: UInt8.self) }
        let confidenceStride = confidenceMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
        var totalSamples = 0
        var validSamples = 0
        var highConfidenceSamples = 0

        for y in stride(from: 0, to: depthHeight, by: sampleStride) {
            for x in stride(from: 0, to: depthWidth, by: sampleStride) {
                totalSamples += 1
                let confidence = confidenceBase.map { $0[y * confidenceStride + x] } ?? 2
                if confidence < 1 { continue }

                let depth = depthBase[y * depthStride + x]
                if !depth.isFinite || depth <= 0.05 || depth > 8.0 { continue }

                validSamples += 1
                if confidence >= 2 {
                    highConfidenceSamples += 1
                }
            }
        }

        return DepthStats(
            coverage: totalSamples == 0 ? 0 : Double(validSamples) / Double(totalSamples),
            highConfidenceRatio: validSamples == 0 ? 0 : Double(highConfidenceSamples) / Double(validSamples)
        )
    }

    private func sampleDepthPoints(from frame: ARFrame) -> DepthSample {
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return .empty }

        let depthMap = depthData.depthMap
        let confidenceMap = depthData.confidenceMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        if let confidenceMap {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        }
        CVPixelBufferLockBaseAddress(frame.capturedImage, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(frame.capturedImage, .readOnly)
            if let confidenceMap {
                CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
            }
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
        }

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap)?.assumingMemoryBound(to: Float32.self) else {
            return .empty
        }
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        let depthStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.size
        let confidenceBase = confidenceMap.flatMap { CVPixelBufferGetBaseAddress($0)?.assumingMemoryBound(to: UInt8.self) }
        let confidenceStride = confidenceMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0

        let imageWidth = CVPixelBufferGetWidth(frame.capturedImage)
        let imageHeight = CVPixelBufferGetHeight(frame.capturedImage)
        let intrinsics = frame.camera.intrinsics
        let scaleX = Float(depthWidth) / Float(imageWidth)
        let scaleY = Float(depthHeight) / Float(imageHeight)
        let fx = intrinsics[0, 0] * scaleX
        let fy = intrinsics[1, 1] * scaleY
        let cx = intrinsics[2, 0] * scaleX
        let cy = intrinsics[2, 1] * scaleY
        let cameraToWorld = frame.camera.transform
        var sampledPoints: [PLYPoint] = []
        sampledPoints.reserveCapacity((depthWidth / depthSampleStride) * (depthHeight / depthSampleStride))
        var totalSamples = 0
        var validSamples = 0
        var highConfidenceSamples = 0

        for y in stride(from: 0, to: depthHeight, by: depthSampleStride) {
            for x in stride(from: 0, to: depthWidth, by: depthSampleStride) {
                totalSamples += 1
                let confidence = confidenceBase.map { $0[y * confidenceStride + x] } ?? 2
                if confidence < 1 { continue }

                let depth = depthBase[y * depthStride + x]
                if !depth.isFinite || depth <= 0.05 || depth > 8.0 { continue }
                guard Self.hasConsistentDepthNeighborhood(
                    x: x,
                    y: y,
                    depth: depth,
                    depthBase: depthBase,
                    depthWidth: depthWidth,
                    depthHeight: depthHeight,
                    depthStride: depthStride,
                    confidenceBase: confidenceBase,
                    confidenceStride: confidenceStride,
                    sampleStride: depthSampleStride,
                    minimumNeighbors: minimumConsistentDepthNeighbors
                ) else {
                    continue
                }
                validSamples += 1
                if confidence >= 2 {
                    highConfidenceSamples += 1
                }

                let cameraPoint = SIMD4<Float>(
                    (Float(x) - cx) * depth / fx,
                    -(Float(y) - cy) * depth / fy,
                    -depth,
                    1
                )
                let worldPoint = cameraToWorld * cameraPoint
                let color = Self.sampleColor(frame.capturedImage, imageX: x * imageWidth / depthWidth, imageY: y * imageHeight / depthHeight)
                sampledPoints.append(PLYPoint(x: worldPoint.x, y: worldPoint.y, z: worldPoint.z, r: color.r, g: color.g, b: color.b))
            }
        }

        let stats = DepthStats(
            coverage: totalSamples == 0 ? 0 : Double(validSamples) / Double(totalSamples),
            highConfidenceRatio: validSamples == 0 ? 0 : Double(highConfidenceSamples) / Double(validSamples)
        )
        return DepthSample(points: sampledPoints, stats: stats)
    }

    private func writePLY(to url: URL) throws {
        let header = """
        ply
        format ascii 1.0
        element vertex \(points.count)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        end_header

        """
        try Data(header.utf8).write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        defer { try? handle.close() }

        for point in points {
            let line = "\(point.x) \(point.y) \(point.z) \(point.r) \(point.g) \(point.b)\n"
            try handle.write(contentsOf: Data(line.utf8))
        }
    }

    private func writeManifest(to url: URL) throws {
        let manifest = CaptureManifest(
            format: "memo-arkit-colmap-like-v1",
            createdAt: ISO8601DateFormatter().string(from: Date()),
            keyframeCount: keyframeCount,
            pointCount: points.count,
            camera: "ARKit back wide camera, requested 4:3 video format and 1x/no-digital-zoom capture",
            qualityGates: CaptureQualityGates(
                tracking: "ARCamera.TrackingState.normal",
                minimumDisplacementMeters: minimumDisplacement,
                minimumSharpness: minimumSharpness,
                minimumDepthCoverage: minimumDepthCoverage,
                minimumHighConfidenceDepthRatio: minimumHighConfidenceDepthRatio,
                candidateWindowSize: candidateWindowSize,
                ranking: "highest sparse-luma gradient sharpness in each eligible window",
                lidarConfidence: "medium-or-high",
                maximumDepthMeters: 8,
                pointVoxelSizeMeters: pointVoxelSize,
                depthConsistency: "requires two locally consistent depth neighbors before voxel fusion"
            ),
            layout: [
                "images/*.jpg": "RGB accepted keyframes",
                "arkit/frames.jsonl": "Per ARFrame pose, intrinsics, tracking state, and accepted-keyframe markers",
                "sparse/0/cameras.txt": "COLMAP text cameras, one PINHOLE entry per accepted keyframe",
                "sparse/0/images.txt": "COLMAP text camera poses for accepted keyframes",
                "depth/fused_points.ply": "Voxel-fused, locally depth-consistent LiDAR points with XYZ and RGB"
            ]
        )
        let data = try JSONEncoder.capture.encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    private static func hasConsistentDepthNeighborhood(
        x: Int,
        y: Int,
        depth: Float,
        depthBase: UnsafePointer<Float32>,
        depthWidth: Int,
        depthHeight: Int,
        depthStride: Int,
        confidenceBase: UnsafePointer<UInt8>?,
        confidenceStride: Int,
        sampleStride: Int,
        minimumNeighbors: Int
    ) -> Bool {
        let tolerance = max(0.035, depth * 0.025)
        let offsets = [
            (-sampleStride, 0),
            (sampleStride, 0),
            (0, -sampleStride),
            (0, sampleStride)
        ]
        var consistentNeighbors = 0

        for offset in offsets {
            let nx = x + offset.0
            let ny = y + offset.1
            guard nx >= 0, nx < depthWidth, ny >= 0, ny < depthHeight else { continue }

            let confidence = confidenceBase.map { $0[ny * confidenceStride + nx] } ?? 2
            if confidence < 1 { continue }

            let neighborDepth = depthBase[ny * depthStride + nx]
            if neighborDepth.isFinite,
               neighborDepth > 0.05,
               neighborDepth <= 8.0,
               abs(neighborDepth - depth) <= tolerance {
                consistentNeighbors += 1
                if consistentNeighbors >= minimumNeighbors {
                    return true
                }
            }
        }

        return false
    }

    private static func gradientSharpness(_ pixelBuffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let plane = CVPixelBufferIsPlanar(pixelBuffer) ? 0 : 0
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane)?.assumingMemoryBound(to: UInt8.self) else {
            return 0
        }

        let sampleStride = 12
        var sum = 0
        var samples = 0
        for y in stride(from: sampleStride, to: height - sampleStride, by: sampleStride) {
            for x in stride(from: sampleStride, to: width - sampleStride, by: sampleStride) {
                let center = Int(base[y * rowBytes + x])
                let right = Int(base[y * rowBytes + x + sampleStride])
                let down = Int(base[(y + sampleStride) * rowBytes + x])
                sum += abs(right - center) + abs(down - center)
                samples += 1
            }
        }
        return samples == 0 ? 0 : Double(sum) / Double(samples)
    }

    private static func sampleColor(_ pixelBuffer: CVPixelBuffer, imageX: Int, imageY: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let x = min(max(imageX, 0), width - 1)
        let y = min(max(imageY, 0), height - 1)

        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)?.assumingMemoryBound(to: UInt8.self),
              let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)?.assumingMemoryBound(to: UInt8.self) else {
            return (255, 255, 255)
        }

        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let cbcrStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let yValue = Float(yBase[y * yStride + x])
        let chromaIndex = (y / 2) * cbcrStride + (x / 2) * 2
        let cb = Float(cbcrBase[chromaIndex]) - 128
        let cr = Float(cbcrBase[chromaIndex + 1]) - 128

        let r = yValue + 1.402 * cr
        let g = yValue - 0.344_136 * cb - 0.714_136 * cr
        let b = yValue + 1.772 * cb
        return (UInt8(clamping: Int(r.rounded())), UInt8(clamping: Int(g.rounded())), UInt8(clamping: Int(b.rounded())))
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }
}

private struct PLYPoint {
    var x: Float
    var y: Float
    var z: Float
    var r: UInt8
    var g: UInt8
    var b: UInt8
}

private struct PointVoxelKey: Hashable {
    var x: Int
    var y: Int
    var z: Int

    init(point: PLYPoint, voxelSize: Float) {
        x = Int(floor(point.x / voxelSize))
        y = Int(floor(point.y / voxelSize))
        z = Int(floor(point.z / voxelSize))
    }
}

private struct PointVoxelAccumulator {
    private var sum = SIMD3<Float>(repeating: 0)
    private var redSum = 0
    private var greenSum = 0
    private var blueSum = 0
    private(set) var observationCount = 0
    let sortKey: Int

    init(_ point: PLYPoint) {
        sortKey = Self.makeSortKey(point)
        add(point)
    }

    mutating func add(_ point: PLYPoint) {
        sum += SIMD3<Float>(point.x, point.y, point.z)
        redSum += Int(point.r)
        greenSum += Int(point.g)
        blueSum += Int(point.b)
        observationCount += 1
    }

    var point: PLYPoint {
        let invCount = 1 / Float(max(observationCount, 1))
        let rgbDivisor = max(observationCount, 1)
        return PLYPoint(
            x: sum.x * invCount,
            y: sum.y * invCount,
            z: sum.z * invCount,
            r: UInt8(clamping: redSum / rgbDivisor),
            g: UInt8(clamping: greenSum / rgbDivisor),
            b: UInt8(clamping: blueSum / rgbDivisor)
        )
    }

    private static func makeSortKey(_ point: PLYPoint) -> Int {
        let x = Int((point.x * 10_000).rounded())
        let y = Int((point.y * 10_000).rounded())
        let z = Int((point.z * 10_000).rounded())
        return x &* 73_856_093 ^ y &* 19_349_663 ^ z &* 83_492_791
    }
}

private struct DepthStats {
    var coverage: Double
    var highConfidenceRatio: Double

    static let empty = DepthStats(coverage: 0, highConfidenceRatio: 0)
}

private struct DepthSample {
    var points: [PLYPoint]
    var stats: DepthStats

    static let empty = DepthSample(points: [], stats: .empty)
}

private struct FrameQuality {
    var sharpness: Double
    var depthCoverage: Double
    var highConfidenceDepthRatio: Double
    var displacement: Float

    func withDepthStats(_ stats: DepthStats) -> FrameQuality {
        var copy = self
        copy.depthCoverage = stats.coverage
        copy.highConfidenceDepthRatio = stats.highConfidenceRatio
        return copy
    }
}

private struct KeyframeCandidate {
    var frameIndex: Int
    var timestamp: TimeInterval
    var resolution: [Int]
    var intrinsics: simd_float3x3
    var transform: simd_float4x4
    var jpegData: Data
    var thumbnailData: Data?
    var depthPoints: [PLYPoint]
    var quality: FrameQuality
}

private struct FrameMetadata: Encodable {
    var index: Int
    var timestamp: TimeInterval
    var acceptedKeyframe: Bool
    var imageName: String?
    var trackingState: String
    var resolution: [Int]
    var intrinsics: [Float]
    var transform: [Float]
    var sharpness: Double?
    var depthCoverage: Double?
    var highConfidenceDepthRatio: Double?
    var displacement: Float?
    var sharpnessRankScore: Double?
}

private struct CaptureManifest: Encodable {
    var format: String
    var createdAt: String
    var keyframeCount: Int
    var pointCount: Int
    var camera: String
    var qualityGates: CaptureQualityGates
    var layout: [String: String]
}

private struct CaptureQualityGates: Encodable {
    var tracking: String
    var minimumDisplacementMeters: Float
    var minimumSharpness: Double
    var minimumDepthCoverage: Double
    var minimumHighConfidenceDepthRatio: Double
    var candidateWindowSize: Int
    var ranking: String
    var lidarConfidence: String
    var maximumDepthMeters: Float
    var pointVoxelSizeMeters: Float
    var depthConsistency: String
}

private enum CaptureSessionError: Error {
    case noActiveCapture
}

private extension JSONEncoder {
    static var capture: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension ARCamera.TrackingState {
    var isNormal: Bool {
        if case .normal = self { return true }
        return false
    }

    var description: String {
        switch self {
        case .normal:
            return "normal"
        case .notAvailable:
            return "notAvailable"
        case .limited(let reason):
            return "limited.\(reason)"
        @unknown default:
            return "unknown"
        }
    }
}

private struct Quaternion {
    var w: Float
    var x: Float
    var y: Float
    var z: Float

    init(matrix m: simd_float3x3) {
        let trace = m[0, 0] + m[1, 1] + m[2, 2]
        if trace > 0 {
            let s = sqrt(trace + 1) * 2
            w = 0.25 * s
            x = (m[2, 1] - m[1, 2]) / s
            y = (m[0, 2] - m[2, 0]) / s
            z = (m[1, 0] - m[0, 1]) / s
        } else if m[0, 0] > m[1, 1], m[0, 0] > m[2, 2] {
            let s = sqrt(1 + m[0, 0] - m[1, 1] - m[2, 2]) * 2
            w = (m[2, 1] - m[1, 2]) / s
            x = 0.25 * s
            y = (m[0, 1] + m[1, 0]) / s
            z = (m[0, 2] + m[2, 0]) / s
        } else if m[1, 1] > m[2, 2] {
            let s = sqrt(1 + m[1, 1] - m[0, 0] - m[2, 2]) * 2
            w = (m[0, 2] - m[2, 0]) / s
            x = (m[0, 1] + m[1, 0]) / s
            y = 0.25 * s
            z = (m[1, 2] + m[2, 1]) / s
        } else {
            let s = sqrt(1 + m[2, 2] - m[0, 0] - m[1, 1]) * 2
            w = (m[1, 0] - m[0, 1]) / s
            x = (m[0, 2] + m[2, 0]) / s
            y = (m[1, 2] + m[2, 1]) / s
            z = 0.25 * s
        }
    }
}

private extension simd_float4x4 {
    var translation: SIMD3<Float> {
        SIMD3<Float>(columns.3.x, columns.3.y, columns.3.z)
    }

    var rotationMatrix: simd_float3x3 {
        simd_float3x3(
            SIMD3<Float>(columns.0.x, columns.0.y, columns.0.z),
            SIMD3<Float>(columns.1.x, columns.1.y, columns.1.z),
            SIMD3<Float>(columns.2.x, columns.2.y, columns.2.z)
        )
    }

    var array: [Float] {
        [
            columns.0.x, columns.0.y, columns.0.z, columns.0.w,
            columns.1.x, columns.1.y, columns.1.z, columns.1.w,
            columns.2.x, columns.2.y, columns.2.z, columns.2.w,
            columns.3.x, columns.3.y, columns.3.z, columns.3.w
        ]
    }
}

private extension simd_float3x3 {
    var array: [Float] {
        [
            columns.0.x, columns.0.y, columns.0.z,
            columns.1.x, columns.1.y, columns.1.z,
            columns.2.x, columns.2.y, columns.2.z
        ]
    }
}
