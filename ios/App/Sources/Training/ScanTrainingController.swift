import Msplat
import SplatIO
import SwiftUI
import UIKit

@MainActor
final class ScanTrainingController: ObservableObject, @unchecked Sendable {
    enum Phase: Equatable {
        case idle
        case training
        case rendering(URL)
        case failed
    }

    @Published var phase: Phase = .idle
    @Published var iteration = 0
    @Published var splatCount = 0
    @Published var errorMessage: String?
    @Published var previewImage: UIImage?
    @Published var previewGaussianFileURL: URL?
    @Published var previewReloadToken = 0
    @Published var trainingMode: ScanTrainingMode = .fast

    var totalIterations: Int {
        activePreset?.iterations ?? trainingMode.preset(keyframeCount: keyframeCount).iterations
    }

    private let store: MemoScanStore
    private let keyframeCount: Int
    private var activePreset: ScanTrainingPreset?
    private var task: Task<Void, Never>?
    private let previewInterval = 120

    init(scan: MemoScanRecord, store: MemoScanStore) {
        self.store = store
        keyframeCount = scan.keyframeCount
        errorMessage = scan.errorMessage
        if scan.canRenderGaussian {
            phase = .rendering(scan.gaussianSplatURL)
            previewGaussianFileURL = scan.gaussianSplatURL
        } else if scan.status == .failed {
            phase = .failed
        } else {
            phase = .idle
        }
    }

    var navigationTitle: String {
        switch phase {
        case .idle:
            return "Train"
        case .training:
            return "Training"
        case .rendering:
            return "3D Gaussian"
        case .failed:
            return "Train"
        }
    }

    func start(scan: MemoScanRecord) {
        guard phase != .training else { return }
        guard scan.canTrain else {
            errorMessage = "Original training data is missing."
            phase = .failed
            return
        }

        task?.cancel()
        phase = .training
        iteration = 0
        splatCount = 0
        errorMessage = nil
        let rootPath = scan.packageURL.path
        let outputURL = scan.gaussianSplatURL
        let preset = trainingMode.preset(keyframeCount: scan.keyframeCount)
        let previewInterval = previewInterval
        let fileManager = FileManager.default
        activePreset = preset

        if !FileManager.default.fileExists(atPath: outputURL.path) {
            previewGaussianFileURL = nil
            previewReloadToken = 0
        }
        previewImage = nil
        try? fileManager.removeItem(at: scan.legacyGaussianPlyURL)
        try? fileManager.removeItem(at: outputURL)
        store.markTrainingStarted(scan)

        let controller = self
        task = Task.detached(priority: .userInitiated) { [controller] in
            do {
                let gaussianFileURL = try await Self.train(
                    datasetPath: rootPath,
                    outputURL: outputURL,
                    preset: preset,
                    previewInterval: previewInterval
                ) { stats in
                    await controller.update(stats: stats)
                }
                await controller.complete(
                    scan: scan,
                    gaussianFileURL: gaussianFileURL,
                    iterations: preset.iterations
                )
            } catch is CancellationError {
            } catch {
                await controller.fail(scan: scan, error)
            }
        }
    }

    func cancel(scan: MemoScanRecord) {
        if phase == .training {
            store.markTrainingCancelled(scan)
        }
        task?.cancel()
        task = nil
        activePreset = nil
    }

    private func update(stats: TrainingProgressSnapshot) {
        iteration = stats.iteration
        splatCount = stats.splatCount
        if let preview = stats.previewFrame {
            previewImage = preview.uiImage
        }
        if stats.didFinishExport {
            previewImage = nil
            previewGaussianFileURL = stats.previewGaussianFileURL
            previewReloadToken += 1
        }
    }

    private func complete(scan: MemoScanRecord, gaussianFileURL: URL, iterations: Int) {
        do {
            try? FileManager.default.removeItem(at: scan.legacyGaussianPlyURL)
            _ = try store.markTrained(scan, iterations: iterations)
            iteration = iterations
            previewImage = nil
            if previewGaussianFileURL != gaussianFileURL {
                previewGaussianFileURL = gaussianFileURL
                previewReloadToken += 1
            }
            phase = .rendering(gaussianFileURL)
            task = nil
            activePreset = nil
        } catch {
            fail(scan: scan, error)
        }
    }

    private func fail(scan: MemoScanRecord, _ error: Error) {
        errorMessage = error.localizedDescription
        store.markTrainingFailed(scan, message: error.localizedDescription)
        phase = .failed
        task = nil
        activePreset = nil
    }

    private nonisolated static func train(
        datasetPath: String,
        outputURL: URL,
        preset: ScanTrainingPreset,
        previewInterval: Int,
        progress: @escaping @Sendable (TrainingProgressSnapshot) async -> Void
    ) async throws -> URL {
        let dataset = GaussianDataset(path: datasetPath, downscaleFactor: preset.imageDownscale)
        let config = preset.trainingConfig
        let previewPose = dataset.cameraPose(at: 0)

        let trainer = GaussianTrainer(dataset: dataset, config: config)
        await progress(
            TrainingProgressSnapshot(
                iteration: 0,
                splatCount: trainer.splatCount,
                didFinishExport: false,
                previewFrame: nil,
                previewGaussianFileURL: nil
            )
        )

        for step in 1...preset.iterations {
            try Task.checkCancellation()
            let stats = trainer.step()
            let shouldRefreshPreview = step == 1 || step.isMultiple(of: previewInterval)
            let previewFrame = shouldRefreshPreview ? renderPreviewFrame(trainer: trainer, camToWorld: previewPose) : nil

            if step == 1 || step.isMultiple(of: 10) || shouldRefreshPreview || step == preset.iterations {
                await progress(
                    TrainingProgressSnapshot(
                        iteration: min(stats.iteration, preset.iterations),
                        splatCount: stats.splatCount,
                        didFinishExport: false,
                        previewFrame: previewFrame,
                        previewGaussianFileURL: nil
                    )
                )
            }
        }

        try exportFinalSplat(trainer: trainer, to: outputURL)
        await progress(
            TrainingProgressSnapshot(
                iteration: preset.iterations,
                splatCount: trainer.splatCount,
                didFinishExport: true,
                previewFrame: nil,
                previewGaussianFileURL: outputURL
            )
        )

        return outputURL
    }

    private nonisolated static func exportFinalSplat(trainer: GaussianTrainer, to outputURL: URL) throws {
        let tempURL = outputURL.deletingPathExtension().appendingPathExtension("exporting.splat")
        let fileManager = FileManager.default

        try? fileManager.removeItem(at: tempURL)
        trainer.exportSplat(to: tempURL.path)
        msplatSync()

        if fileManager.fileExists(atPath: outputURL.path) {
            _ = try fileManager.replaceItemAt(outputURL, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: outputURL)
        }
    }

    private nonisolated static func renderPreviewFrame(
        trainer: GaussianTrainer,
        camToWorld: [Float]
    ) -> TrainingPreviewFrame? {
        var width: Int32 = 0
        var height: Int32 = 0
        trainer.renderFromPoseToBuffer(camToWorld: camToWorld, rgba: nil, width: &width, height: &height)

        guard width > 0, height > 0 else { return nil }

        var rgba = [UInt8](repeating: 0, count: Int(width * height * 4))
        rgba.withUnsafeMutableBufferPointer { buffer in
            trainer.renderFromPoseToBuffer(
                camToWorld: camToWorld,
                rgba: buffer.baseAddress,
                width: &width,
                height: &height
            )
        }
        return TrainingPreviewFrame(rgba: Data(rgba), width: Int(width), height: Int(height))
    }
}

extension ScanTrainingController.Phase {
    var isRendering: Bool {
        if case .rendering = self {
            return true
        }
        return false
    }
}
