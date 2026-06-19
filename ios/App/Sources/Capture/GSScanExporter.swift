import ARKit
import CoreImage
import Foundation
import ImageIO
import simd
import UIKit

struct CaptureIngestResult {
    var didAcceptKeyframe: Bool
    var statusText: String
}

struct CaptureExportPackage {
    var url: URL
    var keyframeCount: Int
}

final class GSScanExporter {
    private let fileManager = FileManager.default
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let jpegColorSpace = CGColorSpaceCreateDeviceRGB()
    private let minimumDisplacement: Float = 0.05
    private let minimumSharpness: Double = 7.5
    private let depthSampleStride = 3
    private let maximumPointCount = 700_000

    private var rootURL: URL?
    private var imagesURL: URL?
    private var sparseURL: URL?
    private var depthURL: URL?
    private var framesLog: FileHandle?
    private var camerasText = "# CAMERA_ID, MODEL, WIDTH, HEIGHT, PARAMS[]\n"
    private var imagesText = "# IMAGE_ID, QW, QX, QY, QZ, TX, TY, TZ, CAMERA_ID, NAME\n# POINTS2D[] as X, Y, POINT3D_ID\n"
    private var points: [PLYPoint] = []
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
        lastKeyframePosition = nil
        frameIndex = 0
        keyframeCount = 0
    }

    func ingest(frame: ARFrame) -> CaptureIngestResult {
        guard rootURL != nil else {
            return CaptureIngestResult(didAcceptKeyframe: false, statusText: "Not ready")
        }

        frameIndex += 1
        appendFrameMetadata(frame)

        guard frame.camera.trackingState.isNormal else {
            return CaptureIngestResult(didAcceptKeyframe: false, statusText: "Tracking")
        }

        let currentPosition = frame.camera.transform.translation
        if let lastKeyframePosition {
            let displacement = simd_distance(currentPosition, lastKeyframePosition)
            guard displacement >= minimumDisplacement else {
                return CaptureIngestResult(didAcceptKeyframe: false, statusText: "Move for parallax")
            }
        }

        let sharpness = Self.gradientSharpness(frame.capturedImage)
        guard sharpness >= minimumSharpness else {
            return CaptureIngestResult(didAcceptKeyframe: false, statusText: "Too blurry")
        }

        guard writeKeyframe(frame, sharpness: sharpness) else {
            return CaptureIngestResult(didAcceptKeyframe: false, statusText: "Saving")
        }

        lastKeyframePosition = currentPosition
        fuseDepthPoints(from: frame)
        return CaptureIngestResult(didAcceptKeyframe: true, statusText: "Recording")
    }

    func finish() throws -> CaptureExportPackage {
        guard let rootURL, let sparseURL, let depthURL else {
            throw CaptureExportError.noActiveCapture
        }

        try framesLog?.close()
        framesLog = nil

        try camerasText.write(to: sparseURL.appendingPathComponent("cameras.txt"), atomically: true, encoding: .utf8)
        try imagesText.write(to: sparseURL.appendingPathComponent("images.txt"), atomically: true, encoding: .utf8)
        try writePLY(to: depthURL.appendingPathComponent("fused_points.ply"))
        try writeManifest(to: rootURL.appendingPathComponent("capture.json"))

        let zipURL = rootURL.deletingLastPathComponent()
            .appendingPathComponent(rootURL.lastPathComponent)
            .appendingPathExtension("zip")
        if fileManager.fileExists(atPath: zipURL.path) {
            try fileManager.removeItem(at: zipURL)
        }
        try ZipStoreWriter.zipDirectory(rootURL, to: zipURL)
        return CaptureExportPackage(url: zipURL, keyframeCount: keyframeCount)
    }

    private func writeKeyframe(_ frame: ARFrame, sharpness: Double) -> Bool {
        guard let imagesURL else { return false }

        let imageName = String(format: "frame_%06d.jpg", keyframeCount + 1)
        let imageURL = imagesURL.appendingPathComponent(imageName)
        let ciImage = CIImage(cvPixelBuffer: frame.capturedImage)

        guard let jpeg = ciContext.jpegRepresentation(
            of: ciImage,
            colorSpace: jpegColorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.94]
        ) else {
            return false
        }

        do {
            try jpeg.write(to: imageURL, options: .atomic)
            keyframeCount += 1

            let imageSize = CGSize(width: CVPixelBufferGetWidth(frame.capturedImage), height: CVPixelBufferGetHeight(frame.capturedImage))
            let intrinsics = frame.camera.intrinsics
            let cameraID = keyframeCount
            camerasText += "\(cameraID) PINHOLE \(Int(imageSize.width)) \(Int(imageSize.height)) \(intrinsics[0, 0]) \(intrinsics[1, 1]) \(intrinsics[2, 0]) \(intrinsics[2, 1])\n"

            let worldToCamera = frame.camera.transform.inverse
            let q = Quaternion(matrix: worldToCamera.rotationMatrix)
            let t = worldToCamera.translation
            imagesText += "\(keyframeCount) \(q.w) \(q.x) \(q.y) \(q.z) \(t.x) \(t.y) \(t.z) \(cameraID) \(imageName)\n\n"

            appendAcceptedMetadata(frame, imageName: imageName, sharpness: sharpness)
            return true
        } catch {
            return false
        }
    }

    private func appendFrameMetadata(_ frame: ARFrame) {
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
            sharpness: nil
        )
        appendJSONLine(payload)
    }

    private func appendAcceptedMetadata(_ frame: ARFrame, imageName: String, sharpness: Double) {
        let payload = FrameMetadata(
            index: frameIndex,
            timestamp: frame.timestamp,
            acceptedKeyframe: true,
            imageName: imageName,
            trackingState: frame.camera.trackingState.description,
            resolution: [
                CVPixelBufferGetWidth(frame.capturedImage),
                CVPixelBufferGetHeight(frame.capturedImage)
            ],
            intrinsics: frame.camera.intrinsics.array,
            transform: frame.camera.transform.array,
            sharpness: sharpness
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

    private func fuseDepthPoints(from frame: ARFrame) {
        guard points.count < maximumPointCount else { return }
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }

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

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap)?.assumingMemoryBound(to: Float32.self) else { return }
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

        for y in stride(from: 0, to: depthHeight, by: depthSampleStride) {
            for x in stride(from: 0, to: depthWidth, by: depthSampleStride) {
                if points.count >= maximumPointCount { return }
                if let confidenceBase {
                    let confidence = confidenceBase[y * confidenceStride + x]
                    if confidence < 1 { continue }
                }

                let depth = depthBase[y * depthStride + x]
                if !depth.isFinite || depth <= 0.05 || depth > 8.0 { continue }

                let cameraPoint = SIMD4<Float>(
                    (Float(x) - cx) * depth / fx,
                    -(Float(y) - cy) * depth / fy,
                    -depth,
                    1
                )
                let worldPoint = cameraToWorld * cameraPoint
                let color = Self.sampleColor(frame.capturedImage, imageX: x * imageWidth / depthWidth, imageY: y * imageHeight / depthHeight)
                points.append(PLYPoint(x: worldPoint.x, y: worldPoint.y, z: worldPoint.z, r: color.r, g: color.g, b: color.b))
            }
        }
    }

    private func writePLY(to url: URL) throws {
        var text = """
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
        for point in points {
            text += "\(point.x) \(point.y) \(point.z) \(point.r) \(point.g) \(point.b)\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
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
                lidarConfidence: "medium-or-high",
                maximumDepthMeters: 8
            ),
            layout: [
                "images/*.jpg": "RGB accepted keyframes",
                "arkit/frames.jsonl": "Per ARFrame pose, intrinsics, tracking state, and accepted-keyframe markers",
                "sparse/0/cameras.txt": "COLMAP text cameras, one PINHOLE entry per accepted keyframe",
                "sparse/0/images.txt": "COLMAP text camera poses for accepted keyframes",
                "depth/fused_points.ply": "Fused LiDAR points with XYZ and RGB"
            ]
        )
        let data = try JSONEncoder.capture.encode(manifest)
        try data.write(to: url, options: .atomic)
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
    var lidarConfidence: String
    var maximumDepthMeters: Float
}

private enum CaptureExportError: Error {
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
