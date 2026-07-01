import Foundation
import Msplat
import UIKit

enum ScanTrainingMode: String, CaseIterable, Identifiable {
    case fast
    case quality
    case adaptive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast: return "Fast"
        case .quality: return "Quality"
        case .adaptive: return "Adaptive"
        }
    }

    var preset: ScanTrainingPreset {
        switch self {
        case .fast:
            return .fast
        case .quality:
            return .quality
        case .adaptive:
            return .adaptive
        }
    }
}

struct ScanTrainingPreset: Sendable {
    var iterations: Int
    var imageDownscale: Float
    var numDownscales: Int32
    var resolutionSchedule: Int32
    var refineEvery: Int32
    var warmupLength: Int32
    var resetAlphaEvery: Int32
    var densifyGradThresh: Float

    static let fast = ScanTrainingPreset(
        iterations: 1_900,
        imageDownscale: 2,
        numDownscales: 2,
        // Increase resolution schedule for better mid-stage quality
        resolutionSchedule: 1_000,
        // Increase refine interval to reduce densification frequency
        refineEvery: 200,
        warmupLength: 300,
        resetAlphaEvery: 30,
        // Raise densify threshold to suppress early densification
        densifyGradThresh: 0.0006
    )

    static let quality = ScanTrainingPreset(
        iterations: 4_500,
        imageDownscale: 2,
        numDownscales: 2,
        resolutionSchedule: 2_000,
        refineEvery: 100,
        warmupLength: 300,
        resetAlphaEvery: 30,
        densifyGradThresh: 0.00022
    )

    static let adaptive = ScanTrainingPreset(
        iterations: 3_000,
        imageDownscale: 2,
        numDownscales: 2,
        // Balanced resolution schedule for adaptive mode
        resolutionSchedule: 1_000,
        refineEvery: 150,
        warmupLength: 300,
        resetAlphaEvery: 30,
        densifyGradThresh: 0.0003
    )

    var trainingConfig: TrainingConfig {
        var config = TrainingConfig()
        config.iterations = Int32(iterations)
        config.shDegree = 3
        config.shDegreeInterval = 1_000
        config.ssimWeight = 0.2
        config.downscaleFactor = imageDownscale
        config.numDownscales = numDownscales
        config.resolutionSchedule = resolutionSchedule
        config.refineEvery = refineEvery
        config.warmupLength = warmupLength
        config.resetAlphaEvery = resetAlphaEvery
        config.densifyGradThresh = densifyGradThresh
        config.densifySizeThresh = 0.01
        config.stopScreenSizeAt = 3_000
        config.splitScreenSize = 0.05
        config.bgColor = (0, 0, 0)
        return config
    }
}

struct TrainingProgressSnapshot: Sendable {
    var iteration: Int
    var splatCount: Int
    var didFinishExport: Bool
    var previewFrame: TrainingPreviewFrame?
    var previewGaussianFileURL: URL?
}

struct TrainingPreviewFrame: Sendable {
    var rgba: Data
    var width: Int
    var height: Int

    @MainActor
    var uiImage: UIImage? {
        guard let provider = CGDataProvider(data: rgba as CFData) else { return nil }
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            return nil
        }
        let orientation: UIImage.Orientation = width > height ? .right : .up
        return UIImage(cgImage: image, scale: 1, orientation: orientation)
    }
}
