import Metal
import MetalKit
import MetalSplatter
import Msplat
import SplatIO
import SwiftUI
import UIKit
import simd

struct PointCloudPreviewView: View {
    @Environment(\.dismiss) private var dismiss

    let scan: MemoScanRecord
    @ObservedObject var store: MemoScanStore

    @StateObject private var trainer: ScanTrainingController
    @State private var shareSheet: SharedFileSheetItem?
    @State private var shareError: String?

    init(scan: MemoScanRecord, store: MemoScanStore) {
        self.scan = scan
        self.store = store
        _trainer = StateObject(wrappedValue: ScanTrainingController(scan: scan, store: store))
    }

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            if let previewImage = trainer.previewImage {
                TrainingImagePreview(image: previewImage)
                    .ignoresSafeArea()
            } else if let gaussianFileURL = trainer.previewGaussianFileURL {
                GaussianSplatView(
                    gaussianFileURL: gaussianFileURL,
                    reloadToken: trainer.previewReloadToken
                )
                .ignoresSafeArea()
            } else {
                PreviewPlaceholder(thumbnailURL: scan.thumbnailURL)
                    .ignoresSafeArea()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TrainingBottomBar(
                phase: trainer.phase,
                iteration: trainer.iteration,
                totalIterations: trainer.totalIterations,
                splatCount: trainer.splatCount,
                errorMessage: trainer.errorMessage,
                mode: Binding(
                    get: { trainer.trainingMode },
                    set: { trainer.trainingMode = $0 }
                ),
                action: { trainer.start(scan: scan) }
            )
        }
        .navigationTitle(trainer.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.headline)
                }
                .accessibilityLabel("Back")
            }

            if trainer.phase.isRendering {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        shareGaussianSplat()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share splat")
                }
            }
        }
        .sheet(item: $shareSheet) { item in
            ActivityViewController(activityItems: [item.url])
        }
        .alert("Unable to Share", isPresented: shareErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(shareError ?? "The exported splat file is unavailable.")
        }
        .onDisappear {
            trainer.cancel(scan: scan)
        }
    }

    private var shareErrorBinding: Binding<Bool> {
        Binding(
            get: { shareError != nil },
            set: { isPresented in
                if !isPresented {
                    shareError = nil
                }
            }
        )
    }

    private func shareGaussianSplat() {
        let url = scan.gaussianSplatURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            shareError = "This scan does not have an exported Gaussian splat file yet."
            return
        }
        shareSheet = SharedFileSheetItem(url: url)
    }
}

@MainActor
private final class ScanTrainingController: ObservableObject, @unchecked Sendable {
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

    var totalIterations: Int { trainingMode.preset.iterations }
    private let store: MemoScanStore
    private var task: Task<Void, Never>?
    private let previewInterval = 120

    init(scan: MemoScanRecord, store: MemoScanStore) {
        self.store = store
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
        splatCount = 0
        errorMessage = nil
        let rootPath = scan.packageURL.path
        let outputURL = scan.gaussianSplatURL
        let preset = trainingMode.preset
        let previewInterval = previewInterval
        let fileManager = FileManager.default

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
                await controller.complete(scan: scan, gaussianFileURL: gaussianFileURL)
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

    private func complete(scan: MemoScanRecord, gaussianFileURL: URL) {
        do {
            try? FileManager.default.removeItem(at: scan.legacyGaussianPlyURL)
            _ = try store.markTrained(scan, iterations: trainingMode.preset.iterations)
            iteration = trainingMode.preset.iterations
            previewImage = nil
            previewGaussianFileURL = gaussianFileURL
            previewReloadToken += 1
            phase = .rendering(gaussianFileURL)
            task = nil
        } catch {
            fail(scan: scan, error)
        }
    }

    private func fail(scan: MemoScanRecord, _ error: Error) {
        errorMessage = error.localizedDescription
        store.markTrainingFailed(scan, message: error.localizedDescription)
        phase = .failed
        task = nil
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

private enum ScanTrainingMode: String, CaseIterable, Identifiable {
    case fast
    case quality

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast: return "Fast"
        case .quality: return "Quality"
        }
    }

    var preset: ScanTrainingPreset {
        switch self {
        case .fast:
            return .fast
        case .quality:
            return .quality
        }
    }
}

private struct ScanTrainingPreset: Sendable {
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
        resolutionSchedule: 500,
        refineEvery: 150,
        warmupLength: 300,
        resetAlphaEvery: 30,
        densifyGradThresh: 0.0004
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

private extension ScanTrainingController.Phase {
    var isRendering: Bool {
        if case .rendering = self {
            return true
        }
        return false
    }
}

private struct TrainingProgressSnapshot: Sendable {
    var iteration: Int
    var splatCount: Int
    var didFinishExport: Bool
    var previewFrame: TrainingPreviewFrame?
    var previewGaussianFileURL: URL?
}

private struct TrainingPreviewFrame: Sendable {
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

private struct TrainingBottomBar: View {
    let phase: ScanTrainingController.Phase
    let iteration: Int
    let totalIterations: Int
    let splatCount: Int
    let errorMessage: String?
    @Binding var mode: ScanTrainingMode
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch phase {
            case .idle:
                TrainingModeSelector(mode: $mode)
                TrainButton(action: action)
            case .training:
                TrainingProgressBar(iteration: iteration, totalIterations: totalIterations)
                Text("\(iteration) / \(totalIterations)")
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Training iteration \(iteration) of \(totalIterations)")
            case .rendering:
                EmptyView()
            case .failed:
                VStack(alignment: .leading, spacing: 8) {
                    Text(errorMessage ?? "Training failed")
                        .font(.caption)
                        .lineLimit(2)
                        .foregroundStyle(.red)
                    TrainingModeSelector(mode: $mode)
                    TrainButton(action: action)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TrainingModeSelector: View {
    @Binding var mode: ScanTrainingMode

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(ScanTrainingMode.allCases) { item in
                        modeButton(item)
                    }
                }
            }
        } else {
            Picker("Training Mode", selection: $mode) {
                ForEach(ScanTrainingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Training mode")
        }
    }

    @available(iOS 26.0, *)
    private func modeButton(_ item: ScanTrainingMode) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) {
                mode = item
            }
        } label: {
            Text(item.title)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 36)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .modifier(TrainingModeGlassStyle(isSelected: mode == item))
        .accessibilityAddTraits(mode == item ? .isSelected : [])
    }
}

@available(iOS 26.0, *)
private struct TrainingModeGlassStyle: ViewModifier {
    var isSelected: Bool

    func body(content: Content) -> some View {
        if isSelected {
            content
                .foregroundStyle(.primary)
                .glassEffect(.regular.tint(.primary.opacity(0.16)).interactive(), in: .capsule)
        } else {
            content
                .foregroundStyle(.secondary)
                .glassEffect(.regular.interactive(), in: .capsule)
        }
    }
}

private struct TrainingProgressBar: View {
    let iteration: Int
    let totalIterations: Int

    var body: some View {
        ProgressView(value: Double(iteration), total: Double(max(totalIterations, 1)))
            .progressViewStyle(.linear)
            .tint(.primary)
            .animation(.linear(duration: 0.12), value: iteration)
    }
}

private struct TrainButton: View {
    let action: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            Button("Train", action: action)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 54)
                .buttonStyle(.glass)
                .controlSize(.large)
                .accessibilityLabel("Train")
        } else {
            Button("Train", action: action)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 54)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .accessibilityLabel("Train")
        }
    }
}

private struct PreviewPlaceholder: View {
    let thumbnailURL: URL

    var body: some View {
        ZStack {
            Color.black

            if let image = UIImage(contentsOfFile: thumbnailURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct TrainingImagePreview: View {
    let image: UIImage

    var body: some View {
        ZStack {
            Color.black

            Image(uiImage: image)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
        }
    }
}

private struct GaussianSplatView: UIViewRepresentable {
    let gaussianFileURL: URL
    let reloadToken: Int

    func makeCoordinator() -> GaussianSplatRendererCoordinator {
        GaussianSplatRendererCoordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.backgroundColor = .systemBackground
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 1

        if let renderer = GaussianSplatRenderer(view: view) {
            context.coordinator.renderer = renderer
            view.delegate = renderer
            renderer.load(url: gaussianFileURL)
        }

        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.renderer?.load(url: gaussianFileURL, force: context.coordinator.reloadToken != reloadToken)
        context.coordinator.reloadToken = reloadToken
    }
}

private struct SharedFileSheetItem: Identifiable {
    let url: URL

    var id: URL { url }
}

private struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private final class GaussianSplatRendererCoordinator {
    var renderer: GaussianSplatRenderer?
    var reloadToken = 0
}

@MainActor
private final class GaussianSplatRenderer: NSObject, MTKViewDelegate {
    private let view: MTKView
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let inFlightSemaphore = DispatchSemaphore(value: 3)
    private let gestureDelegate = SimultaneousSplatGestureDelegate()

    private var splatRenderer: SplatRenderer?
    private var loadedURL: URL?
    private var drawableSize: CGSize = .zero
    private var lastFrameDate = Date()
    private var yaw: Float = 0
    private var pitch: Float = 0
    private var panOffset = SIMD2<Float>(0, 0)
    private var distance: Float = 7
    private var gestureStartYaw: Float = 0
    private var gestureStartPitch: Float = 0
    private var gestureStartPanOffset = SIMD2<Float>(0, 0)
    private var gestureStartDistance: Float = 7
    private var autoRotates = true
    private var revealAnimationStartDate: Date?
    private var revealAnimationCenter = SIMD3<Float>.zero
    private var revealAnimationRadius: Float = 1
    private var rotationCenter = SIMD3<Float>.zero
    private let revealAnimationDuration: TimeInterval = 3.2

    init?(view: MTKView) {
        guard let device = view.device,
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        self.view = view
        self.device = device
        self.commandQueue = commandQueue
        super.init()
        configureGestures()
    }

    func load(url: URL, force: Bool = false) {
        guard force || loadedURL != url else { return }
        loadedURL = url

        Task { [weak self] in
            guard let self else { return }
            do {
                let renderer = try SplatRenderer(
                    device: device,
                    colorFormat: view.colorPixelFormat,
                    depthFormat: view.depthStencilPixelFormat,
                    sampleCount: view.sampleCount,
                    maxViewCount: 1,
                    maxSimultaneousRenders: 3
                )
                let points = try await AutodetectSceneReader(url).readAll()
                let revealBounds = Self.revealBounds(for: points)
                let chunk = try SplatChunk(device: device, from: points)
                await renderer.addChunk(chunk)
                renderer.animation = .pointCloudReveal(
                    center: revealBounds.center,
                    radius: revealBounds.radius,
                    progress: 0
                )
                revealAnimationCenter = revealBounds.center
                revealAnimationRadius = revealBounds.radius
                rotationCenter = revealBounds.center
                revealAnimationStartDate = Date()
                splatRenderer = renderer
            } catch {
                splatRenderer = nil
                revealAnimationStartDate = nil
            }
        }
    }

    func draw(in view: MTKView) {
        guard let splatRenderer, splatRenderer.isReadyToRender else { return }
        guard let drawable = view.currentDrawable else { return }

        _ = inFlightSemaphore.wait(timeout: .distantFuture)
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }

        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { _ in
            semaphore.signal()
        }

        updateRotation()
        updateRevealAnimation()

        let didRender: Bool
        do {
            didRender = try splatRenderer.render(
                viewports: [viewport],
                colorTexture: view.multisampleColorTexture ?? drawable.texture,
                colorStoreAction: view.multisampleColorTexture == nil ? .store : .multisampleResolve,
                depthTexture: view.depthStencilTexture,
                rasterizationRateMap: nil,
                renderTargetArrayLength: 0,
                to: commandBuffer
            )
        } catch {
            didRender = false
        }

        if didRender {
            commandBuffer.present(drawable)
        }
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        drawableSize = size
    }

    private func configureGestures() {
        view.isMultipleTouchEnabled = true

        let rotateGesture = UIPanGestureRecognizer(target: self, action: #selector(handleRotateGesture(_:)))
        rotateGesture.minimumNumberOfTouches = 1
        rotateGesture.maximumNumberOfTouches = 1
        rotateGesture.delegate = gestureDelegate
        view.addGestureRecognizer(rotateGesture)

        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePanGesture(_:)))
        panGesture.minimumNumberOfTouches = 2
        panGesture.maximumNumberOfTouches = 2
        panGesture.delegate = gestureDelegate
        view.addGestureRecognizer(panGesture)

        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinchGesture(_:)))
        pinchGesture.delegate = gestureDelegate
        view.addGestureRecognizer(pinchGesture)
    }

    @objc private func handleRotateGesture(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            autoRotates = false
            gestureStartYaw = yaw
            gestureStartPitch = pitch
        case .changed:
            let translation = gesture.translation(in: view)
            yaw = gestureStartYaw + Float(translation.x) * 0.008
            pitch = clamp(gestureStartPitch + Float(translation.y) * 0.008, min: -.pi * 0.48, max: .pi * 0.48)
        default:
            break
        }
    }

    @objc private func handlePanGesture(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            autoRotates = false
            gestureStartPanOffset = panOffset
        case .changed:
            let translation = gesture.translation(in: view)
            let scale = distance * 0.0014
            panOffset = gestureStartPanOffset + SIMD2<Float>(
                Float(translation.x) * scale,
                -Float(translation.y) * scale
            )
        default:
            break
        }
    }

    @objc private func handlePinchGesture(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            autoRotates = false
            gestureStartDistance = distance
        case .changed:
            distance = clamp(gestureStartDistance / Float(gesture.scale), min: 1.2, max: 30)
        default:
            break
        }
    }

    private var viewport: SplatRenderer.ViewportDescriptor {
        let width = max(drawableSize.width, 1)
        let height = max(drawableSize.height, 1)
        let projection = matrixPerspectiveRightHand(
            fovyRadians: Float(Angle(degrees: 62).radians),
            aspectRatio: Float(width / height),
            nearZ: 0.1,
            farZ: 100
        )
        let viewMatrix = matrix4x4Translation(panOffset.x, panOffset.y, -distance) *
            matrix4x4Rotation(radians: pitch, axis: SIMD3<Float>(1, 0, 0)) *
            matrix4x4Rotation(radians: yaw, axis: SIMD3<Float>(0, 1, 0)) *
            matrix4x4Translation(-rotationCenter.x, -rotationCenter.y, -rotationCenter.z)
        let metalViewport = MTLViewport(
            originX: 0,
            originY: 0,
            width: width,
            height: height,
            znear: 0,
            zfar: 1
        )
        return SplatRenderer.ViewportDescriptor(
            viewport: metalViewport,
            projectionMatrix: projection,
            viewMatrix: viewMatrix,
            screenSize: SIMD2(x: Int(width), y: Int(height))
        )
    }

    private func updateRotation() {
        let now = Date()
        if autoRotates {
            yaw += Float(now.timeIntervalSince(lastFrameDate)) * 0.22
        }
        lastFrameDate = now
    }

    private func updateRevealAnimation() {
        guard let splatRenderer, let revealAnimationStartDate else { return }
        let elapsed = Date().timeIntervalSince(revealAnimationStartDate)
        let linearProgress = Float(min(max(elapsed / revealAnimationDuration, 0), 1))
        let progress = easeInOutCubic(linearProgress)
        splatRenderer.animation = .pointCloudReveal(
            center: revealAnimationCenter,
            radius: revealAnimationRadius,
            progress: progress
        )
        if linearProgress >= 1 {
            self.revealAnimationStartDate = nil
        }
    }

    private func easeInOutCubic(_ value: Float) -> Float {
        value < 0.5
            ? 4 * value * value * value
            : 1 - powf(-2 * value + 2, 3) / 2
    }

    private static func revealBounds(for points: [SplatPoint]) -> (center: SIMD3<Float>, radius: Float) {
        guard !points.isEmpty else { return (.zero, 1) }
        let center = points.reduce(SIMD3<Float>.zero) { $0 + $1.position } / Float(points.count)
        let radius = points.reduce(Float(0)) { partial, point in
            Swift.max(partial, simd_length(point.position - center))
        }
        return (center, Swift.max(radius, 0.1))
    }
}

private final class SimultaneousSplatGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

private func matrix4x4Rotation(radians: Float, axis: SIMD3<Float>) -> simd_float4x4 {
    let unitAxis = normalize(axis)
    let ct = cosf(radians)
    let st = sinf(radians)
    let ci = 1 - ct
    let x = unitAxis.x
    let y = unitAxis.y
    let z = unitAxis.z
    return simd_float4x4(columns: (
        SIMD4<Float>(ct + x * x * ci, y * x * ci + z * st, z * x * ci - y * st, 0),
        SIMD4<Float>(x * y * ci - z * st, ct + y * y * ci, z * y * ci + x * st, 0),
        SIMD4<Float>(x * z * ci + y * st, y * z * ci - x * st, ct + z * z * ci, 0),
        SIMD4<Float>(0, 0, 0, 1)
    ))
}

private func matrix4x4Translation(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
    simd_float4x4(columns: (
        SIMD4<Float>(1, 0, 0, 0),
        SIMD4<Float>(0, 1, 0, 0),
        SIMD4<Float>(0, 0, 1, 0),
        SIMD4<Float>(x, y, z, 1)
    ))
}

private func matrixPerspectiveRightHand(
    fovyRadians fovy: Float,
    aspectRatio: Float,
    nearZ: Float,
    farZ: Float
) -> simd_float4x4 {
    let ys = 1 / tanf(fovy * 0.5)
    let xs = ys / aspectRatio
    let zs = farZ / (nearZ - farZ)
    return simd_float4x4(columns: (
        SIMD4<Float>(xs, 0, 0, 0),
        SIMD4<Float>(0, ys, 0, 0),
        SIMD4<Float>(0, 0, zs, -1),
        SIMD4<Float>(0, 0, zs * nearZ, 0)
    ))
}

private func clamp(_ value: Float, min minimum: Float, max maximum: Float) -> Float {
    Swift.min(Swift.max(value, minimum), maximum)
}
