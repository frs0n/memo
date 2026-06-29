import Metal
import MetalKit
import MetalSplatter
import SplatIO
import SwiftUI
import UIKit
import simd

struct GaussianSplatView: UIViewRepresentable {
    let gaussianFileURL: URL
    let reloadToken: Int
    let isDroneModeEnabled: Bool
    let droneControlVector: CGSize

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
        }

        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.renderer?.configureDroneMode(
            isEnabled: isDroneModeEnabled,
            controlVector: SIMD2<Float>(
                Float(droneControlVector.width / 33),
                Float(droneControlVector.height / 33)
            )
        )
        context.coordinator.renderer?.load(url: gaussianFileURL, force: context.coordinator.reloadToken != reloadToken)
        context.coordinator.reloadToken = reloadToken
    }
}

final class GaussianSplatRendererCoordinator {
    var renderer: GaussianSplatRenderer?
    var reloadToken = 0
}

@MainActor
final class GaussianSplatRenderer: NSObject, MTKViewDelegate {
    private let view: MTKView
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let inFlightSemaphore = DispatchSemaphore(value: 3)
    private let gestureDelegate = SimultaneousSplatGestureDelegate()

    private var splatRenderer: SplatRenderer?
    private var loadedURL: URL?
    private var drawableSize: CGSize = .zero
    private var lastFrameDate = Date()
    private var targetYaw: Float = 0
    private var targetPitch: Float = 0
    private var targetPanOffset = SIMD2<Float>(0, 0)
    private var targetDistance: Float = 3
    private var targetDronePosition = SIMD3<Float>.zero
    private var renderedYaw: Float = 0
    private var renderedPitch: Float = 0
    private var renderedPanOffset = SIMD2<Float>(0, 0)
    private var renderedDistance: Float = 3
    private var renderedDronePosition = SIMD3<Float>.zero
    private var droneControlVector = SIMD2<Float>.zero
    private var isDroneModeEnabled = false
    private var gestureStartYaw: Float = 0
    private var gestureStartPitch: Float = 0
    private var gestureStartPanOffset = SIMD2<Float>(0, 0)
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

    func configureDroneMode(isEnabled: Bool, controlVector: SIMD2<Float>) {
        if isDroneModeEnabled != isEnabled, isEnabled {
            autoRotates = false
            let offset = orbitCameraOffset
            targetDronePosition = offset
            renderedDronePosition = offset
            targetPanOffset = .zero
            renderedPanOffset = .zero
        }
        isDroneModeEnabled = isEnabled
        droneControlVector = isEnabled ? controlVector : .zero
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
                targetDronePosition = .zero
                renderedDronePosition = .zero
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

        updateCameraMotion()
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
            gestureStartYaw = targetYaw
            gestureStartPitch = targetPitch
        case .changed:
            let translation = gesture.translation(in: view)
            targetYaw = gestureStartYaw + Float(translation.x) * 0.008
            targetPitch = clamp(gestureStartPitch + Float(translation.y) * 0.008, min: -.pi * 0.48, max: .pi * 0.48)
        default:
            break
        }
    }

    @objc private func handlePanGesture(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            autoRotates = false
            gestureStartPanOffset = targetPanOffset
        case .changed:
            let translation = gesture.translation(in: view)
            let scale = targetDistance * 0.0014
            targetPanOffset = gestureStartPanOffset + SIMD2<Float>(
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
            gesture.scale = 1
        case .changed:
            let scale = Float(gesture.scale)
            guard scale > 0 else { return }
            let sensitivity = zoomSensitivity(for: targetDistance)
            targetDistance = max(targetDistance * powf(scale, -sensitivity), minimumInteractiveDistance)
            gesture.scale = 1
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
            nearZ: max(renderedDistance * 0.001, 0.0001),
            farZ: max(100, renderedDistance + revealAnimationRadius * 4)
        )
        let viewMatrix = isDroneModeEnabled ? droneViewMatrix : orbitViewMatrix
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

    private var orbitViewMatrix: simd_float4x4 {
        matrix4x4Translation(renderedPanOffset.x, renderedPanOffset.y, -renderedDistance) *
            cameraRotationMatrix *
            matrix4x4Translation(-rotationCenter.x, -rotationCenter.y, -rotationCenter.z)
    }

    private var droneViewMatrix: simd_float4x4 {
        let cameraPosition = rotationCenter + renderedDronePosition
        return cameraRotationMatrix *
            matrix4x4Translation(-cameraPosition.x, -cameraPosition.y, -cameraPosition.z)
    }

    private var cameraRotationMatrix: simd_float4x4 {
        matrix4x4Rotation(radians: renderedPitch, axis: SIMD3<Float>(1, 0, 0)) *
            matrix4x4Rotation(radians: renderedYaw, axis: SIMD3<Float>(0, 1, 0))
    }

    private var orbitCameraOffset: SIMD3<Float> {
        let inverseRotation = matrix4x4Rotation(radians: -targetYaw, axis: SIMD3<Float>(0, 1, 0)) *
            matrix4x4Rotation(radians: -targetPitch, axis: SIMD3<Float>(1, 0, 0))
        let offset = inverseRotation * SIMD4<Float>(0, 0, targetDistance, 0)
        return SIMD3<Float>(offset.x, offset.y, offset.z)
    }

    private func updateCameraMotion() {
        let now = Date()
        let deltaTime = Float(now.timeIntervalSince(lastFrameDate))
        if autoRotates {
            targetYaw += deltaTime * 0.22
        }
        if isDroneModeEnabled {
            updateDroneFlight(deltaTime: deltaTime)
        }
        smoothCameraState(deltaTime: deltaTime)
        lastFrameDate = now
    }

    private func smoothCameraState(deltaTime: Float) {
        let factor = smoothingFactor(deltaTime: deltaTime, response: 16)
        renderedYaw = lerp(renderedYaw, targetYaw, factor)
        renderedPitch = lerp(renderedPitch, targetPitch, factor)
        renderedPanOffset = simd_mix(renderedPanOffset, targetPanOffset, SIMD2<Float>(repeating: factor))
        renderedDistance = lerp(renderedDistance, targetDistance, factor)
        renderedDronePosition = simd_mix(renderedDronePosition, targetDronePosition, SIMD3<Float>(repeating: factor))
    }

    private var minimumInteractiveDistance: Float {
        max(revealAnimationRadius * 0.000001, Float.ulpOfOne)
    }

    private func zoomSensitivity(for distance: Float) -> Float {
        let sceneScale = max(revealAnimationRadius, 0.1)
        let normalizedDistance = max(distance / sceneScale, 0.000001)
        let distanceFromSceneScale = abs(logf(normalizedDistance))
        return clamp(0.9 / (1 + distanceFromSceneScale * 0.65), min: 0.08, max: 0.9)
    }

    private func updateDroneFlight(deltaTime: Float) {
        let input = SIMD2<Float>(
            clamp(droneControlVector.x, min: -1, max: 1),
            clamp(droneControlVector.y, min: -1, max: 1)
        )
        guard simd_length(input) > 0.02 else { return }

        let speed = Swift.max(revealAnimationRadius, 0.8) * 0.72
        let forward = normalize(SIMD3<Float>(
            -sinf(targetYaw) * cosf(targetPitch),
            sinf(targetPitch),
            cosf(targetYaw) * cosf(targetPitch)
        ))
        let right = normalize(simd_cross(SIMD3<Float>(0, 1, 0), forward))
        let movement = right * input.x + forward * input.y
        targetDronePosition += movement * speed * deltaTime
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

private func lerp(_ start: Float, _ end: Float, _ factor: Float) -> Float {
    start + (end - start) * factor
}

private func smoothingFactor(deltaTime: Float, response: Float) -> Float {
    let clampedDeltaTime = clamp(deltaTime, min: 0, max: 1 / 15)
    return 1 - expf(-response * clampedDeltaTime)
}
