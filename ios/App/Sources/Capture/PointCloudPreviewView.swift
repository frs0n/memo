import Metal
import MetalKit
import MetalSplatter
import Msplat
import SceneKit
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

            switch trainer.phase {
            case .idle, .training, .failed:
                PointCloudSceneView(pointCloudURL: scan.pointCloudURL)
                    .ignoresSafeArea()
            case .rendering(let splatURL):
                GaussianSplatView(splatURL: splatURL)
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
                        shareGaussianPly()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share PLY")
                }
            }
        }
        .sheet(item: $shareSheet) { item in
            ActivityViewController(activityItems: [item.url])
        }
        .alert("Unable to Share", isPresented: shareErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(shareError ?? "The exported PLY file is unavailable.")
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

    private func shareGaussianPly() {
        let url = scan.gaussianPlyURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            shareError = "This scan does not have an exported Gaussian PLY file yet."
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

    let totalIterations = 2_000
    private let store: MemoScanStore
    private var task: Task<Void, Never>?

    init(scan: MemoScanRecord, store: MemoScanStore) {
        self.store = store
        errorMessage = scan.errorMessage
        if scan.canRenderSplat {
            phase = .rendering(scan.splatURL)
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
        store.markTrainingStarted(scan)

        let rootPath = scan.packageURL.path
        let outputURL = scan.splatURL
        let totalIterations = totalIterations

        let controller = self
        task = Task.detached(priority: .userInitiated) { [controller] in
            do {
                let splatURL = try await Self.train(
                    datasetPath: rootPath,
                    outputURL: outputURL,
                    iterations: totalIterations
                ) { stats in
                    await controller.update(stats: stats)
                }
                await controller.complete(scan: scan, splatURL: splatURL)
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
    }

    private func complete(scan: MemoScanRecord, splatURL: URL) {
        do {
            _ = try store.markTrained(scan, iterations: totalIterations)
            iteration = totalIterations
            phase = .rendering(splatURL)
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
        iterations: Int,
        progress: @escaping @Sendable (TrainingProgressSnapshot) async -> Void
    ) async throws -> URL {
        let dataset = GaussianDataset(path: datasetPath, downscaleFactor: 2.0)
        var config = TrainingConfig()
        config.iterations = Int32(iterations)
        config.downscaleFactor = 2.0
        config.numDownscales = 1
        config.bgColor = (0, 0, 0)

        let trainer = GaussianTrainer(dataset: dataset, config: config)

        for step in 1...iterations {
            try Task.checkCancellation()
            let stats = trainer.step()
            if step == 1 || step.isMultiple(of: 10) || step == iterations {
                await progress(
                    TrainingProgressSnapshot(
                        iteration: min(stats.iteration, iterations),
                        splatCount: stats.splatCount
                    )
                )
            }
        }

        try? FileManager.default.removeItem(at: outputURL)
        trainer.exportSplat(to: outputURL.path)
        let plyURL = outputURL.deletingPathExtension().appendingPathExtension("ply")
        try? FileManager.default.removeItem(at: plyURL)
        trainer.exportPly(to: plyURL.path)
        msplatSync()
        return outputURL
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
}

private struct TrainingBottomBar: View {
    let phase: ScanTrainingController.Phase
    let iteration: Int
    let totalIterations: Int
    let splatCount: Int
    let errorMessage: String?
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch phase {
            case .idle:
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

private struct GaussianSplatView: UIViewRepresentable {
    let splatURL: URL

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
            renderer.load(url: splatURL)
        }

        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.renderer?.load(url: splatURL)
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

    func load(url: URL) {
        guard loadedURL != url else { return }
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
                let chunk = try SplatChunk(device: device, from: points)
                await renderer.addChunk(chunk)
                splatRenderer = renderer
            } catch {
                splatRenderer = nil
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
            matrix4x4Rotation(radians: yaw, axis: SIMD3<Float>(0, 1, 0))
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
}

private final class SimultaneousSplatGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

private struct PointCloudSceneView: UIViewRepresentable {
    let pointCloudURL: URL

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = .systemBackground
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.scene = PointCloudSceneBuilder.scene(from: pointCloudURL)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}

private enum PointCloudSceneBuilder {
    static func scene(from url: URL) -> SCNScene {
        let scene = SCNScene()
        let points = PLYPointCloudLoader.load(url: url, maximumPointCount: 160_000)
        let geometry = makeGeometry(points: points)
        let node = SCNNode(geometry: geometry)
        scene.rootNode.addChildNode(node)

        let bounds = bounds(for: points)
        let center = SCNVector3(
            (bounds.min.x + bounds.max.x) * 0.5,
            (bounds.min.y + bounds.max.y) * 0.5,
            (bounds.min.z + bounds.max.z) * 0.5
        )
        node.position = SCNVector3(-center.x, -center.y, -center.z)

        let span = max(bounds.max.x - bounds.min.x, bounds.max.y - bounds.min.y, bounds.max.z - bounds.min.z)
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zNear = 0.001
        cameraNode.camera?.zFar = Double(max(span * 8, 20))
        cameraNode.position = SCNVector3(0, 0, max(span * 1.8, 1.2))
        scene.rootNode.addChildNode(cameraNode)

        return scene
    }

    private static func makeGeometry(points: [PreviewPoint]) -> SCNGeometry {
        let vertices = points.map { SCNVector3($0.x, $0.y, $0.z) }
        let colors = points.flatMap { point in
            [
                Float(point.r) / 255,
                Float(point.g) / 255,
                Float(point.b) / 255,
                Float(1)
            ]
        }

        let vertexData = vertices.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
        let colorData = colors.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }

        let vertexSource = SCNGeometrySource(
            data: vertexData,
            semantic: .vertex,
            vectorCount: vertices.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.stride,
            dataOffset: 0,
            dataStride: MemoryLayout<SCNVector3>.stride
        )
        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: points.count,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.stride,
            dataOffset: 0,
            dataStride: MemoryLayout<Float>.stride * 4
        )
        let element = SCNGeometryElement(data: nil, primitiveType: .point, primitiveCount: points.count, bytesPerIndex: 0)
        element.pointSize = 2
        element.minimumPointScreenSpaceRadius = 1
        element.maximumPointScreenSpaceRadius = 4

        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }

    private static func bounds(for points: [PreviewPoint]) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        guard let first = points.first else {
            return (SIMD3<Float>(-0.5, -0.5, -0.5), SIMD3<Float>(0.5, 0.5, 0.5))
        }

        var minPoint = SIMD3<Float>(first.x, first.y, first.z)
        var maxPoint = minPoint
        for point in points.dropFirst() {
            let value = SIMD3<Float>(point.x, point.y, point.z)
            minPoint = simd_min(minPoint, value)
            maxPoint = simd_max(maxPoint, value)
        }
        return (minPoint, maxPoint)
    }
}

private enum PLYPointCloudLoader {
    static func load(url: URL, maximumPointCount: Int) -> [PreviewPoint] {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let headerEnd = text.range(of: "end_header\n")?.upperBound else {
            return []
        }

        let lines = text[headerEnd...].split(separator: "\n", omittingEmptySubsequences: true)
        let stride = max(lines.count / maximumPointCount, 1)
        return lines.enumerated().compactMap { index, line in
            guard index.isMultiple(of: stride) else { return nil }
            return PreviewPoint(line: line)
        }
    }
}

private struct PreviewPoint {
    var x: Float
    var y: Float
    var z: Float
    var r: UInt8
    var g: UInt8
    var b: UInt8

    init?(line: Substring) {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 6,
              let x = Float(parts[0]),
              let y = Float(parts[1]),
              let z = Float(parts[2]),
              let r = UInt8(parts[3]),
              let g = UInt8(parts[4]),
              let b = UInt8(parts[5]) else {
            return nil
        }

        self.x = x
        self.y = y
        self.z = z
        self.r = r
        self.g = g
        self.b = b
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
